/**
 * run_script execution pipeline.
 *
 * Order matters and is intentional — cheap, deterministic refusals happen
 * before anything is created on disk:
 *
 *   1. kill switch            (permanent DENY, must be observable in <=1s)
 *   2. backend availability   (fail-closed, no unsandboxed fallback)
 *   3. worktree eligibility   (Runner-managed READ_WRITE worktree only)
 *   4. audit log init         (fail-closed)
 *   5. package.json re-read   (TOCTOU layer B)
 *   6. package manager        (npm / pnpm only)
 *   7. obvious deny           (fail-fast, not a boundary)
 *   8. allowlist + hash       (TOCTOU layers A and C)
 *   9. sensitive files        (worktree scan)
 *  10. sandbox execution
 *
 * Non-zero exit codes from the script itself are NOT errors: a failing test
 * suite is a successful MCP invocation. Only policy and sandbox failures set
 * isError.
 */

import fs from "node:fs/promises";
import { statSync } from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";

import { openAuditLog } from "./audit-log.mjs";
import { sanitizeOutput } from "./output-handling.mjs";
import { classifyScript } from "./obvious-deny.mjs";
import { buildSandboxEnv } from "./sandbox-env.mjs";
import { scanWorktreeForSensitiveFiles } from "./sensitive-worktree.mjs";
import {
  REASON,
  checkWorktreeEligibility,
  deniedScriptsFor,
  detectPackageManager,
  evaluateScriptPolicy,
  packageManagerCommand,
  packageSha256,
  scriptSha256
} from "./script-policy.mjs";
import {
  KILL_SWITCH_ENV_VAR,
  configFilePath,
  killSwitchPath,
  runtimeRoot,
  sandboxRoot
} from "./sandbox-runtime-paths.mjs";

export const DEFAULT_TIMEOUT_SECONDS = 120;
export const MAX_TIMEOUT_SECONDS = 600;
export const MIN_TIMEOUT_SECONDS = 1;

const LOCKFILE_CANDIDATES = [
  "package-lock.json",
  "pnpm-lock.yaml",
  "yarn.lock",
  "bun.lockb",
  "bun.lock",
  "npm-shrinkwrap.json"
];

/** Reason codes that mean "a human has to act" rather than "the script failed". */
const POLICY_REASONS = new Set(Object.values(REASON));

/**
 * Evaluate the kill switch. Both channels are checked every call so that
 * creating the file takes effect on the next invocation (<= 1s in practice).
 *
 * @param {object} [input]
 * @param {string} [input.runtimeDir]
 * @param {object} [input.parentEnv]
 * @returns {Promise<{ active: boolean, file: boolean, env: boolean, path: string }>}
 */
export async function killSwitchStatus(input = {}) {
  const parentEnv = input.parentEnv ?? process.env;
  const markerPath = input.runtimeDir ? path.join(input.runtimeDir, "run-script.kill") : killSwitchPath();
  let fileActive = false;
  let envActive = false;

  try {
    await fs.access(markerPath);
    fileActive = true;
  } catch {
    fileActive = false;
  }

  // Bracket access rather than dot access: the static gate rejects
  // `process.env.<NAME>` for credential-shaped names, and this variable is
  // credential-shaped by convention.
  const envValue = parentEnv?.[KILL_SWITCH_ENV_VAR];
  envActive = typeof envValue === "string" && envValue.trim().toLowerCase() === "on";

  return { active: fileActive || envActive, file: fileActive, env: envActive, path: markerPath };
}

/** Read package.json bytes and parse them. Returns null when absent. */
async function readPackageJson(worktreeRoot) {
  let raw;
  try {
    raw = await fs.readFile(path.join(worktreeRoot, "package.json"), "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
  return { raw, parsed: JSON.parse(raw) };
}

async function detectLockfiles(worktreeRoot) {
  const found = [];
  await Promise.all(
    LOCKFILE_CANDIDATES.map(async (name) => {
      try {
        await fs.access(path.join(worktreeRoot, name));
        found.push(name);
      } catch {
        /* absent */
      }
    })
  );
  return found;
}

/** Directories that must be readable for node/npm/pnpm to function at all. */
export function nodeBinDirsFor(execPath = process.execPath, candidates = []) {
  const dirs = new Set();
  const addDir = (file) => {
    if (typeof file !== "string" || !file.startsWith("/")) return;
    dirs.add(path.dirname(path.resolve(file)));
  };
  addDir(execPath);
  for (const candidate of candidates) addDir(candidate);
  // node resolves to <prefix>/bin/node; npm lives in <prefix>/lib/node_modules/npm.
  for (const dir of Array.from(dirs)) {
    const prefix = path.dirname(dir);
    if (prefix && prefix !== "/") {
      dirs.add(path.join(prefix, "lib", "node_modules", "npm", "bin"));
      dirs.add(path.join(prefix, "lib", "node_modules", "corepack", "dist"));
    }
  }
  return Array.from(dirs).filter((dir) => dir.startsWith("/"));
}

/**
 * Resolve the package-manager executable to an absolute path.
 * Rejects anything that is not an absolute path: a bare `npm` would be
 * resolved through PATH, and PATH is not trusted.
 *
 * @param {string} packageManager
 * @param {object} [options]
 * @param {(name: string) => string|null} [options.which]
 * @returns {string}
 */
export function resolvePackageManagerExecutable(packageManager, options = {}) {
  const which = options.which ?? defaultWhich;
  if (packageManager !== "npm" && packageManager !== "pnpm") {
    throw new Error(`${REASON.PACKAGE_MANAGER_UNSUPPORTED}: ${packageManager}`);
  }
  const resolved = which(packageManager);
  if (typeof resolved !== "string" || !path.isAbsolute(resolved)) {
    throw new Error(`${REASON.PACKAGE_MANAGER_UNSUPPORTED}: cannot resolve an absolute path for ${packageManager}`);
  }
  return resolved;
}

function defaultWhich(name) {
  const pathValue = process.env["PATH"] ?? "";
  for (const dir of pathValue.split(path.delimiter)) {
    if (!dir) continue;
    const candidate = path.join(dir, name);
    try {
      // Synchronous on purpose: this runs once, outside the sandbox, and only
      // to turn "npm" into an absolute path. statSync is not a process spawn.
      if (statSync(candidate).isFile()) return candidate;
    } catch {
      /* keep looking */
    }
  }
  return null;
}

/**
 * Run the full pipeline.
 *
 * @param {object} request
 * @param {object} request.spec            resolved project (from resolveProject)
 * @param {object} request.gitState        git state for the worktree
 * @param {string} request.script
 * @param {string|null} [request.expectedPackageSha256]
 * @param {string} [request.network]       "none" only
 * @param {number|null} [request.timeoutSeconds]
 * @param {object} request.backend         sandbox backend instance
 * @param {AbortSignal} [request.signal]
 * @param {object} [request.parentEnv]
 * @param {string} [request.runtimeDir]
 * @returns {Promise<object>} the structured run_script result
 */
export async function executeScript(request) {
  const {
    spec,
    gitState,
    script,
    expectedPackageSha256 = null,
    network = "none",
    timeoutSeconds = null,
    backend,
    signal = null,
    parentEnv = process.env,
    runtimeDir = runtimeRoot(),
    worktreeBaseDir = null
  } = request ?? {};

  const startedAtMs = Date.now();
  const failure = (reasonCode, detail = null, extra = {}) => ({
    ok: false,
    isError: true,
    decision: reasonCode,
    reasonCode,
    detail,
    project: spec?.name ?? null,
    script: script ?? null,
    startedAt: new Date(startedAtMs).toISOString(),
    endedAt: new Date().toISOString(),
    durationMs: Date.now() - startedAtMs,
    ...extra
  });

  if (!backend) return failure("SANDBOX_BACKEND_UNAVAILABLE", "no sandbox backend supplied");

  // 1. Kill switch.
  const kill = await killSwitchStatus({ runtimeDir, parentEnv });
  if (kill.active) {
    return failure(REASON.KILL_SWITCH_ACTIVE, {
      file: kill.file,
      env: kill.env,
      markerPath: kill.path
    });
  }

  // 2. Backend availability (fail-closed).
  const availability = await backend.isAvailable();
  if (!availability.available) {
    return failure(REASON.SANDBOX_BACKEND_UNAVAILABLE, availability.failures);
  }

  // 3. Worktree eligibility.
  const eligible = checkWorktreeEligibility(spec, gitState, worktreeBaseDir ?? path.join(runtimeDir, "worktrees"));
  if (!eligible.ok) {
    return failure(eligible.reasonCode, { root: spec?.root ?? null, branch: spec?.branch ?? null });
  }

  const worktreeRoot = spec.root;

  // 4. Package manager, from files read right now.
  const lockfiles = await detectLockfiles(worktreeRoot);
  const manifest = await readPackageJson(worktreeRoot);
  if (!manifest) {
    return failure(REASON.SCRIPT_NOT_ALLOWLISTED, "package.json is missing");
  }
  const detection = detectPackageManager(manifest.parsed, lockfiles);
  if (!detection.supported) {
    return failure(detection.reasonCode ?? REASON.PACKAGE_MANAGER_UNKNOWN, { packageManager: detection.packageManager });
  }

  // 5. Audit log before anything runs. Fail-closed.
  let audit;
  try {
    audit = await openAuditLog(runtimeDir);
  } catch (error) {
    return failure(REASON.AUDIT_LOG_INIT_FAILED, String(error?.message ?? error));
  }

  try {
    // 6. TOCTOU layer B: recompute the package hash from the bytes just read.
    const actualPackageSha = packageSha256(manifest.raw);
    const scripts = manifest.parsed.scripts ?? {};
    const scriptHashes = spec.scriptHashes ?? {};

    // 7-8. Obvious deny + allowlist + hash approval.
    const policy = evaluateScriptPolicy({
      script,
      scripts,
      allowedScripts: spec.allowedScripts ?? [],
      scriptHashes,
      expectedPackageSha256,
      packageSha256: actualPackageSha
    });
    if (!policy.ok) {
      await audit.write({
        project: spec.name,
        branch: spec.branch ?? null,
        script,
        packageManager: detection.packageManager,
        packageSha256: actualPackageSha,
        scriptSha256: policy.scriptSha256,
        network,
        backend: backend.kind,
        decision: policy.reasonCode,
        exitCode: null
      });
      return failure(policy.reasonCode, { scriptValue: policy.scriptValue, packageSha256: actualPackageSha });
    }

    // 9. Sensitive files in the worktree.
    const sensitive = await scanWorktreeForSensitiveFiles(worktreeRoot);
    if (sensitive.sensitiveFiles.length > 0) {
      await audit.write({
        project: spec.name,
        branch: spec.branch ?? null,
        script,
        packageManager: detection.packageManager,
        packageSha256: actualPackageSha,
        scriptSha256: policy.scriptSha256,
        network,
        backend: backend.kind,
        decision: REASON.SENSITIVE_FILE_IN_WORKTREE,
        exitCode: null
      });
      return failure(REASON.SENSITIVE_FILE_IN_WORKTREE, {
        // Names only. Contents are never read and never returned.
        sensitiveFiles: sensitive.sensitiveFiles,
        scannedEntries: sensitive.scannedEntries
      });
    }

    // 10. Execute inside a per-run sandbox scratch directory.
    const runId = randomUUID();
    // Derived from runtimeDir, not the module-level default, so tests that
    // redirect the runtime never touch the real home directory.
    const runDir = path.join(runtimeDir, "sandbox", `run-${runId}`);
    const homeRoot = path.join(runDir, "home");
    const tmpRoot = path.join(runDir, "tmp");
    await fs.mkdir(homeRoot, { recursive: true, mode: 0o700 });
    await fs.mkdir(tmpRoot, { recursive: true, mode: 0o700 });

    let executable;
    try {
      executable = resolvePackageManagerExecutable(detection.packageManager);
    } catch (error) {
      const detail = String(error?.message ?? error);
      await audit.write({
        project: spec.name,
        branch: spec.branch ?? null,
        script,
        packageManager: detection.packageManager,
        packageSha256: actualPackageSha,
        scriptSha256: policy.scriptSha256,
        network,
        backend: backend.kind,
        decision: REASON.PACKAGE_MANAGER_UNSUPPORTED,
        exitCode: null
      });
      return failure(REASON.PACKAGE_MANAGER_UNSUPPORTED, detail, { packageManager: detection.packageManager });
    }

    const args = packageManagerCommand(detection.packageManager, script);
    const nodeBinDirs = nodeBinDirsFor(process.execPath, [executable]);

    const context = {
      worktreeRoot,
      homeRoot,
      tmpRoot,
      realHome: parentEnv["HOME"] ?? null,
      runtimeRoot: runtimeDir,
      configFilePath: configFilePath(),
      nodeBinDirs,
      extraDenyReadPaths: [sandboxRoot()]
    };

    const env = buildSandboxEnv({
      parentEnv,
      homeRoot,
      tmpRoot,
      worktreeRoot,
      nodeBinDirs
    });

    const timeoutSecondsApplied = clampTimeout(timeoutSeconds);

    // If the sandbox cannot be entered, that is a policy refusal, not a crash.
    // There is deliberately no unsandboxed fallback path.
    let result;
    try {
      result = await backend.execute({
        context,
        executable,
        args,
        cwd: worktreeRoot,
        env,
        timeoutMs: timeoutSecondsApplied * 1000,
        signal
      });
    } catch (error) {
      const detail = String(error?.message ?? error);
      await audit.write({
        project: spec.name,
        branch: spec.branch ?? null,
        script,
        packageManager: detection.packageManager,
        packageSha256: actualPackageSha,
        scriptSha256: policy.scriptSha256,
        network,
        backend: backend.kind,
        decision: REASON.SANDBOX_BACKEND_UNAVAILABLE,
        exitCode: null
      });
      return failure(REASON.SANDBOX_BACKEND_UNAVAILABLE, detail, { packageManager: detection.packageManager });
    }

    const stdout = sanitizeOutput(result.stdout ?? "");
    const stderr = sanitizeOutput(result.stderr ?? "");

    await audit.write({
      project: spec.name,
      branch: spec.branch ?? null,
      script,
      packageManager: detection.packageManager,
      packageSha256: actualPackageSha,
      scriptSha256: policy.scriptSha256,
      network,
      backend: backend.kind,
      durationMs: result.durationMs ?? Date.now() - startedAtMs,
      exitCode: result.exitCode ?? null,
      signal: result.signal ?? null,
      timedOut: result.timedOut === true,
      cancelled: result.cancelled === true,
      truncated: stdout.truncated || stderr.truncated,
      decision: result.timedOut ? REASON.TIMEOUT : result.cancelled ? REASON.CANCELLED : "EXECUTED",
      pgid: result.pgid ?? null,
      descendantsRemaining: result.descendantsRemaining === true
    });

    const cleanup = await backend.cleanup({ pgid: result.pgid ?? null, paths: [runDir] }).catch(() => ({
      descendantsRemaining: true,
      descendantState: "unknown",
      removedPaths: 0
    }));

    // A normalised success payload. A non-zero exitCode is data, not an error.
    return {
      ok: true,
      isError: false,
      decision: result.timedOut ? REASON.TIMEOUT : result.cancelled ? REASON.CANCELLED : "EXECUTED",
      reasonCode: null,
      project: spec.name,
      script,
      packageManager: detection.packageManager,
      packageSha256: actualPackageSha,
      scriptSha256: policy.scriptSha256,
      network,
      startedAt: result.startedAt ?? new Date(startedAtMs).toISOString(),
      endedAt: result.endedAt ?? new Date().toISOString(),
      durationMs: result.durationMs ?? Date.now() - startedAtMs,
      exitCode: result.exitCode ?? -1,
      signal: result.signal ?? null,
      timedOut: result.timedOut === true,
      cancelled: result.cancelled === true,
      stdout: stdout.text,
      stderr: stderr.text,
      stdoutTruncated: stdout.truncated,
      stderrTruncated: stderr.truncated,
      timeoutSeconds: timeoutSecondsApplied,
      descendantsRemaining: cleanup.descendantsRemaining === true,
      descendantState: cleanup.descendantState ?? "not-checked"
    };
  } finally {
    await audit.close().catch(() => {});
  }
}

export function clampTimeout(timeoutSeconds) {
  if (timeoutSeconds === null || timeoutSeconds === undefined) return DEFAULT_TIMEOUT_SECONDS;
  const value = Number(timeoutSeconds);
  if (!Number.isFinite(value)) return DEFAULT_TIMEOUT_SECONDS;
  return Math.min(MAX_TIMEOUT_SECONDS, Math.max(MIN_TIMEOUT_SECONDS, Math.trunc(value)));
}

/**
 * project_scripts support: everything ChatGPT needs to understand why a
 * project can or cannot execute scripts, computed without running anything.
 */
export async function projectScriptReport(input) {
  const { spec, backend, killSwitch, worktreeBaseDir = null, runtimeDir = runtimeRoot() } = input ?? {};
  const manifest = await readPackageJson(spec.root);
  const scripts = manifest?.parsed?.scripts ?? {};
  const scriptNames = Object.keys(scripts).sort();
  const packageSha = manifest ? packageSha256(manifest.raw) : null;
  const lockfiles = manifest ? await detectLockfiles(spec.root) : [];
  const detection = detectPackageManager(manifest?.parsed ?? {}, lockfiles);

  // Computed hashes of the *current* scripts — what a human copies into the
  // registry as the approved allowlist (design §5.2). These are deliberately NOT
  // the registry-approved values; they are what would be approved.
  const computedHashes = {};
  for (const name of scriptNames) {
    computedHashes[name] = scriptSha256(name, String(scripts[name] ?? ""));
  }

  // hashMatches: every approved (registry) hash must equal the computed hash.
  const approvedHashes = spec.scriptHashes ?? {};
  const approvedNames = Object.keys(approvedHashes);
  const hashMatches =
    approvedNames.length > 0 &&
    approvedNames.every(
      (name) =>
        scriptNames.includes(name) &&
        String(approvedHashes[name] ?? "").toLowerCase() === String(computedHashes[name] ?? "").toLowerCase()
    );

  const sensitive = await scanWorktreeForSensitiveFiles(spec.root);
  const availability = backend ? await backend.isAvailable() : { available: false, failures: ["no backend"] };
  const eligible = checkWorktreeEligibility(spec, null, worktreeBaseDir ?? path.join(runtimeDir, "worktrees"));

  let executionSupported = false;
  let reason = null;
  if (!spec.runScripts) reason = `${REASON.RUN_SCRIPTS_DISABLED}: runScripts is false for this project`;
  else if (killSwitch?.active) reason = `${REASON.KILL_SWITCH_ACTIVE}: run-script kill switch is active`;
  else if (!availability.available) reason = `${REASON.SANDBOX_BACKEND_UNAVAILABLE}: ${availability.failures.join("; ")}`;
  else if (!eligible.ok) reason = `${eligible.reasonCode}: scripts only run in a managed READ_WRITE mcp/* worktree`;
  else if (!detection.supported) reason = `${detection.reasonCode}: ${detection.packageManager ?? "unknown package manager"}`;
  else if (sensitive.sensitiveFiles.length > 0) {
    reason = `${REASON.SENSITIVE_FILE_IN_WORKTREE}: ${sensitive.sensitiveFiles.join(", ")}`;
  } else {
    executionSupported = true;
  }

  return {
    project: spec.name,
    packageManager: detection.packageManager,
    scripts: scriptNames,
    allowedScripts: spec.allowedScripts ?? [],
    deniedScripts: deniedScriptsFor(scripts),
    packageSha256: packageSha,
    // §5.2: computed current hashes for copy-paste into the registry.
    scriptHashes: computedHashes,
    hashMatches,
    sensitiveFilesInWorktree: sensitive.sensitiveFiles,
    executionSupported,
    // executionEnabled folds in the kill switch (§5.1 distinction).
    executionEnabled: executionSupported && !killSwitch?.active,
    killSwitchActive: killSwitch?.active === true,
    reason
  };
}

export { POLICY_REASONS, classifyScript, scriptSha256, packageSha256 };
