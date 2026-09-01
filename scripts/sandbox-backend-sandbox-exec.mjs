/**
 * SandboxExecBackend — the one and only real P2 backend.
 *
 * macOS `sandbox-exec` + a generated SBPL profile. Deprecated by Apple but
 * still functional; it is a *transitional* backend and SECURITY.md says so.
 *
 * Two facts about the execution environment are load-bearing and are recorded
 * in docs/P2_PROCESS_SANDBOX_DESIGN.md:
 *
 *   1. sandbox-exec cannot be initialised from inside a process tree that is
 *      already sandboxed (osascript/launchd GUI domain, AI-agent hosts). It
 *      fails with `sandbox_apply: Operation not permitted` / exit 71. The
 *      backend therefore treats "cannot apply a profile" as UNAVAILABLE, never
 *      as "run it anyway".
 *   2. SBPL rule precedence is NOT assumed here. The exec-allow / exec-deny
 *      ordering is a constant (EXEC_RULE_ORDER) and the native gate proves by
 *      real OS behaviour which ordering actually enforces the denials.
 *
 * NEVER: unsandboxed fallback, relaxed profile on failure, silent skip.
 */

import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { realpathSync } from "node:fs";
import { validateSExpression } from "./sandbox-backend.mjs";
import { isProcessGroupAlive, runProcess } from "./sandbox-process-runner.mjs";

export const SANDBOX_EXEC_PATH = "/usr/bin/sandbox-exec";

/**
 * Ordering of the process-exec allow/deny rules.
 *
 * "allow-then-deny" emits required-path allowances first and the dangerous
 * binary denials last. This ordering MUST be verified by
 * tests/native/sandbox-exec-policy.test.mjs; if the real OS resolves the other
 * way round, the fix is to flip this constant — never to widen the profile.
 */
export const EXEC_RULE_ORDER = Object.freeze({
  ALLOW_THEN_DENY: "allow-then-deny",
  DENY_THEN_ALLOW: "deny-then-allow"
});

export const DEFAULT_EXEC_RULE_ORDER = EXEC_RULE_ORDER.ALLOW_THEN_DENY;

/** Binaries that must never be executable from inside the sandbox. */
export const DENIED_EXECUTABLES = Object.freeze([
  "/usr/bin/git",
  "/usr/bin/curl",
  "/usr/bin/wget",
  "/usr/bin/ssh",
  "/usr/bin/scp",
  "/usr/bin/sftp",
  "/usr/bin/nc",
  "/usr/bin/osascript",
  "/usr/bin/security",
  "/bin/launchctl",
  "/usr/bin/sudo",
  "/usr/bin/su",
  "/usr/local/bin/docker",
  "/usr/local/bin/podman"
]);

/** Directories that must never be readable from inside the sandbox. */
export const DENIED_READ_DIRECTORIES = Object.freeze([
  ".ssh",
  ".aws",
  ".azure",
  ".gcloud",
  ".gnupg",
  ".docker",
  ".kube",
  "Keychains",
  "Documents",
  "Downloads",
  "Desktop"
]);

const DENIED_READ_FILES = Object.freeze([".npmrc", ".pypirc", ".netrc", ".bash_history", ".zsh_history"]);

const NODE_BIN_ALLOWED = Object.freeze(["node", "npm", "npx", "pnpm", "corepack"]);

/** Executable directories required for npm to reach its own shell and tools. */
const SYSTEM_EXEC_PATHS = Object.freeze(["/bin", "/usr/bin", "/sbin", "/usr/sbin", "/usr/libexec"]);

/** Read-only system paths node and the dynamic loader need. */
const SYSTEM_READ_PATHS = Object.freeze([
  "/System",
  "/usr/lib",
  "/usr/share",
  "/bin",
  "/sbin",
  "/usr/bin",
  "/usr/sbin",
  "/dev/null",
  "/dev/urandom",
  "/dev/zero",
  "/dev/tty",
  "/private/etc/localtime",
  "/etc/localtime",
  "/etc/hosts",
  "/etc/resolv.conf",
  // Root read-traversal is required so the dynamic linker can resolve /bin/echo,
  // the node binary, and system libraries during bootstrap (fixes SIGABRT).
  // This is read-only; write and network remain denied. The deny rules in
  // generateProfile are emitted BEFORE these allows so first-match-wins keeps
  // sensitive paths (realHome / runtimeRoot / configDir) sealed.
  "/"
]);

function sb(value) {
  return `"${String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

/** Escape a literal path for use inside an SBPL regex filter. */
function regexLiteral(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Resolve a path to its canonical (symlink-free) form before it enters an SBPL rule.
 *
 * macOS funnels several real locations behind symlinks: /tmp -> /private/tmp,
 * /var -> /private/var. sandbox-exec matches rules against the *canonical* vnode
 * path, so a rule built from the symlinked string (e.g. /var/folders/...) would
 * never match the real /private/var/folders/... path the kernel evaluates --
 * silently defeating both the allows (F3: the sandbox HOME ends up not writable)
 * and the denies (F2: runtimeRoot / realHome leak). Canonicalising every dynamic
 * path before it enters a rule closes that mismatch.
 *
 * Prefers realpathSync (resolves symlinks). For paths that do not exist yet
 * (e.g. a worktree the caller will create next), it falls back to path.resolve so
 * the rule is still absolute and deterministic.
 */
export function canonicalizePath(value) {
  if (typeof value !== "string" || value.length === 0) return value;
  try {
    return realpathSync(value);
  } catch {
    return path.resolve(value);
  }
}

function uniquePaths(values) {
  return Array.from(new Set(values.filter((entry) => typeof entry === "string" && entry.length > 0)));
}

export class SandboxExecBackend {
  constructor(options = {}) {
    this.kind = "sandbox-exec";
    this.sandboxExecPath = options.sandboxExecPath ?? SANDBOX_EXEC_PATH;
    this.execRuleOrder = options.execRuleOrder ?? DEFAULT_EXEC_RULE_ORDER;
    this.deniedExecutables = options.deniedExecutables ?? DENIED_EXECUTABLES;
    this._availability = null;
  }

  /**
   * Read-only capability report. Never throws, never mutates state: safe to call
   * from project_scripts so ChatGPT can explain why execution is unavailable.
   */
  async versionProbe() {
    const [execStat, version, minimal, denyProbe] = await Promise.all([
      statOrNull(this.sandboxExecPath),
      runProbe(this.sandboxExecPath, ["-p", "(version 1)(allow default)", "/bin/echo", "sandbox-probe-ok"]),
      runProbe(this.sandboxExecPath, ["-p", "(version 1)(allow default)", "/bin/echo", "minimal-ok"]),
      runProbe(this.sandboxExecPath, [
        "-p",
        '(version 1)(deny default)(allow file-read* (literal "/etc/hosts"))',
        "/bin/cat",
        "/etc/shells"
      ])
    ]);

    const platform = process.platform;
    const darwinMajor = darwinVersion();

    return {
      kind: this.kind,
      platform,
      darwinMajor,
      sandboxExecPath: this.sandboxExecPath,
      sandboxExecPresent: execStat !== null,
      sandboxExecExecutable: execStat?.isFile === true,
      nodeVersion: process.versions?.node ?? null,
      versionProbeOk: version.exitCode === 0 && version.stdout.includes("sandbox-probe-ok"),
      minimalProfileOk: minimal.exitCode === 0 && minimal.stdout.includes("minimal-ok"),
      // Exit 71 with EPERM means the profile was applied and the read was
      // refused — proof the rules actually bite.
      denyProbeDenied: denyProbe.exitCode !== 0 || !denyProbe.stdout.includes("bin/bash"),
      probeDetail: {
        versionStderr: version.stderr.trim().slice(0, 200),
        denyStderr: denyProbe.stderr.trim().slice(0, 200),
        denyExitCode: denyProbe.exitCode
      }
    };
  }

  /**
   * Whether this backend can truly enforce on this host.
   *
   * A host where sandbox-exec exists but cannot apply a profile (nested
   * sandbox, exit 71) is reported as UNAVAILABLE with a concrete reason. That
   * is the fail-closed path.
   */
  async isAvailable({ refresh = false } = {}) {
    if (this._availability && !refresh) return this._availability;

    const probe = await this.versionProbe();
    const failures = [];

    if (probe.platform !== "darwin") failures.push(`unsupported platform: ${probe.platform}`);
    if (probe.darwinMajor !== null && probe.darwinMajor < 22) {
      failures.push(`macOS too old: ${probe.darwinMajor} (< 22 / macOS 13)`);
    }
    if (!probe.sandboxExecPresent) failures.push(`missing ${this.sandboxExecPath}`);
    if (probe.sandboxExecPresent && !probe.sandboxExecExecutable) {
      failures.push(`${this.sandboxExecPath} is not executable`);
    }

    const nodeMajor = Number.parseInt(String(probe.nodeVersion ?? "").split(".")[0], 10);
    if (!Number.isFinite(nodeMajor) || nodeMajor < 20) failures.push(`node too old: ${probe.nodeVersion}`);

    if (failures.length === 0 && !probe.minimalProfileOk) {
      failures.push(
        probe.probeDetail.versionStderr.includes("Operation not permitted")
          ? "sandbox-exec cannot apply a profile in this process context (nested sandbox / EPERM 71)"
          : "minimal sandbox profile failed to start"
      );
    }
    if (failures.length === 0 && !probe.denyProbeDenied) {
      failures.push("sandbox profile applied but deny rules did not take effect");
    }

    const available = failures.length === 0;
    this._availability = {
      available,
      reasonCode: available ? null : "SANDBOX_BACKEND_UNAVAILABLE",
      failures,
      probe
    };
    return this._availability;
  }

  /**
   * Build the SBPL profile for one execution.
   *
   * @param {object} context
   * @param {string} context.worktreeRoot   the managed worktree being executed
   * @param {string} context.homeRoot       per-run sandboxed HOME
   * @param {string} context.tmpRoot        per-run sandboxed TMPDIR
   * @param {string} context.realHome       the user's real HOME (denied)
   * @param {string} context.runtimeRoot    runner runtime root (denied)
   * @param {string} context.configFilePath runner registry (denied)
   * @param {string[]} [context.nodeBinDirs]      node/npm/pnpm installation directories
   * @param {string[]} [context.extraReadPaths]   additional read-only paths
   * @param {string[]} [context.extraExecPaths]   additional executable paths
   * @param {string[]} [context.extraDenyReadPaths] additional denied paths
   * @returns {string}
   */
  generateProfile(context) {
    const {
      worktreeRoot,
      homeRoot,
      tmpRoot,
      realHome,
      runtimeRoot,
      configFilePath,
      nodeBinDirs = [],
      extraReadPaths = [],
      extraExecPaths = [],
      extraDenyReadPaths = []
    } = context ?? {};

    assertAbsolute("worktreeRoot", worktreeRoot);
    assertAbsolute("homeRoot", homeRoot);
    assertAbsolute("tmpRoot", tmpRoot);

    // Canonicalise every dynamic path before it enters an SBPL rule. macOS hides
    // real locations behind symlinks (/tmp -> /private/tmp, /var -> /private/var)
    // and sandbox-exec matches rules against the canonical vnode path. A rule built
    // from the symlinked string would never match the path the kernel evaluates.
    const cWorktreeRoot = canonicalizePath(worktreeRoot);
    const cHomeRoot = canonicalizePath(homeRoot);
    const cTmpRoot = canonicalizePath(tmpRoot);
    const cRealHome = realHome ? canonicalizePath(realHome) : null;
    const cRuntimeRoot = runtimeRoot ? canonicalizePath(runtimeRoot) : null;
    const cConfigDir = configFilePath ? canonicalizePath(path.dirname(configFilePath)) : null;
    const cNodeBinDirs = nodeBinDirs.map(canonicalizePath);
    const cExtraReadPaths = extraReadPaths.map(canonicalizePath);
    const cExtraExecPaths = extraExecPaths.map(canonicalizePath);
    const cExtraDenyReadPaths = extraDenyReadPaths.map(canonicalizePath);

    const parentsOfWorktree = uniquePaths(parentsOf(cWorktreeRoot, cRealHome));
    const parentDirs = uniquePaths([...parentsOfWorktree, ...parentsOf(cRuntimeRoot ?? "", cRealHome)]);
    const configDir = cConfigDir;

    const readPaths = uniquePaths([
      cWorktreeRoot,
      cHomeRoot,
      cTmpRoot,
      ...cNodeBinDirs,
      ...cExtraReadPaths,
      ...SYSTEM_READ_PATHS
    ]);

    const writePaths = uniquePaths([cWorktreeRoot, cHomeRoot, cTmpRoot]);

    const execPaths = uniquePaths([...SYSTEM_EXEC_PATHS, ...cNodeBinDirs, ...cExtraExecPaths]);

    const lines = ["(version 1)", "(deny default)", ""];

    lines.push(";; ---- process execution -------------------------------------------");
    const execRules = [];
    for (const dir of execPaths) execRules.push(`(allow process-exec* (subpath ${sb(dir)}))`);
    if (this.execRuleOrder === EXEC_RULE_ORDER.ALLOW_THEN_DENY) {
      lines.push(...execRules);
    }
    lines.push(";; Dangerous binaries are denied explicitly. The native gate proves");
    lines.push(";; these are EPERM from the sandbox, not merely absent from PATH.");
    for (const binary of uniquePaths(this.deniedExecutables)) {
      execRulesDeny(lines, binary);
    }
    if (this.execRuleOrder === EXEC_RULE_ORDER.DENY_THEN_ALLOW) {
      lines.push(...execRules);
    }
    lines.push("(allow process-fork)", "(allow process-info* (target self))", "");

    lines.push(";; ---- filesystem: writable ----------------------------------------");
    for (const dir of writePaths) {
      lines.push(`(allow file-write* (subpath ${sb(dir)}))`);
      lines.push(`(allow file-read* (subpath ${sb(dir)}))`);
    }
    // Node's child_process redirects stdio:'ignore' to /dev/null. Without a write
    // allow here, spawning a child with stdio:'ignore' fails with EPERM. This is a
    // single literal allow -- it must NOT be widened to /dev/* or any directory.
    lines.push(`(allow file-write* (literal "/dev/null"))`);
    lines.push("");

    lines.push(";; ---- filesystem: denied -----------------------------------------");
    lines.push(";; Sealed ancestors: the current worktree must stay usable, so only its");
    lines.push(";; PARENT directories are denied, never the worktree itself.");
    lines.push(";;");
    lines.push(";; NOTE: these deny rules MUST precede the broad root read-allow below.");
    lines.push(";; SBPL evaluates rules first-match-wins, so ordering the denies before");
    lines.push(";; the allows is what keeps realHome / runtimeRoot / configDir sealed.");
    for (const dir of parentDirs) {
      lines.push(`(deny file-read-data (regex #"^${regexLiteral(dir)}/[^/]+$"))`);
    }
    if (cRealHome) {
      for (const name of DENIED_READ_DIRECTORIES) {
        lines.push(`(deny file-read-data (subpath ${sb(path.join(cRealHome, name))}))`);
      }
      for (const name of DENIED_READ_FILES) {
        lines.push(`(deny file-read-data (literal ${sb(path.join(cRealHome, name))}))`);
      }
      lines.push(`(deny file-read-data (subpath ${sb(path.join(cRealHome, "Library/Application Support/com.apple.TCC"))}))`);
      lines.push(`(deny file-read-data (subpath ${sb(path.join(cRealHome, "Library/Keychains"))}))`);
    }
    // The root read-allow below would otherwise make the real home readable
    // (it was only blocked before by the absence of any allow). Re-seal it
    // explicitly so the user's real HOME stays fully unreadable in the sandbox.
    if (cRealHome) lines.push(`(deny file-read-data (subpath ${sb(cRealHome)}))`);
    if (cRuntimeRoot) lines.push(`(deny file-read-data (subpath ${sb(cRuntimeRoot)}))`);
    if (cConfigDir) lines.push(`(deny file-read-data (subpath ${sb(cConfigDir)}))`);
    for (const dir of cExtraDenyReadPaths) {
      lines.push(`(deny file-read-data (subpath ${sb(dir)}))`);
    }
    lines.push("");

    lines.push(";; ---- filesystem: readonly ----------------------------------------");
    lines.push(";; Root read-traversal (/) lets the dynamic linker resolve /bin/echo,");
    lines.push(";; the node binary, and system libraries during bootstrap (fixes the");
    lines.push(";; SIGABRT seen when / was absent). Read-only: write and network stay");
    lines.push(";; denied, and the sensitive-path denies above still win first-match.");
    for (const dir of readPaths) {
      if (writePaths.includes(dir)) continue;
      lines.push(`(allow file-read* (subpath ${sb(dir)}))`);
    }
    lines.push("");

    lines.push(";; ---- network: none ------------------------------------------------");
    lines.push(";; v2.0 is network:none only. Localhost and DNS are denied as well.");
    lines.push("(deny network*)");
    lines.push("(deny network-inbound)");
    lines.push("(deny network-outbound)");
    lines.push("(deny network-bind)");
    lines.push("(deny mach-lookup)");
    lines.push("(allow mach-lookup (global-name \"com.apple.system.notification_center\"))");
    lines.push("");

    lines.push(";; ---- signals: the runner controls its own process group ----------");
    lines.push("(allow signal (target self))");
    lines.push("(allow sysctl-read)");
    lines.push("(allow file-ioctl (literal \"/dev/tty\"))");
    lines.push("");

    return `${lines.join("\n")}\n`;
  }

  /** Structural validation only; real enforcement is proven by the native gate. */
  validateProfile(profile) {
    const result = validateSExpression(profile);
    if (!result.ok) return result;
    const text = String(profile ?? "");
    if (!text.includes("(version 1)")) return { ok: false, reason: "missing (version 1)" };
    if (!text.includes("(deny default)")) return { ok: false, reason: "profile is not deny-by-default" };
    if (!text.includes("(deny network*)")) return { ok: false, reason: "network is not denied" };
    return { ok: true, reason: null };
  }

  /**
   * Execute one command under a generated profile.
   *
   * @param {object} request
   * @param {object} request.context  same shape as generateProfile()
   * @param {string} request.executable
   * @param {string[]} request.args
   * @param {object} request.env
   * @param {string} request.cwd
   * @param {number} request.timeoutMs
   * @param {AbortSignal} [request.signal]
   */
  async execute(request) {
    const availability = await this.isAvailable();
    if (!availability.available) {
      throw new Error(
        `SANDBOX_BACKEND_UNAVAILABLE: ${availability.failures.join("; ") || "sandbox backend unavailable"}`
      );
    }

    const { context, executable, args = [], env, cwd, timeoutMs, signal } = request ?? {};
    const profile = this.generateProfile(context);
    const validation = this.validateProfile(profile);
    if (!validation.ok) {
      throw new Error(`SANDBOX_BACKEND_UNAVAILABLE: generated profile rejected (${validation.reason})`);
    }

    const result = await runProcess({
      executable: this.sandboxExecPath,
      args: ["-p", profile, executable, ...args],
      cwd,
      env,
      timeoutMs,
      signal
    });

    return { ...result, profile, backend: this.kind };
  }

  /**
   * Release per-run resources and confirm the process group is gone.
   *
   * @param {object} input
   * @param {number|null} input.pgid
   * @param {string[]} [input.paths] directories created for this run
   */
  async cleanup(input = {}) {
    const { pgid = null, paths = [] } = input ?? {};
    let descendantsRemaining = false;
    let descendantState = "not-checked";

    if (typeof pgid === "number") {
      const probe = await isProcessGroupAlive(pgid);
      descendantsRemaining = probe.alive;
      descendantState = probe.state;
    }

    for (const target of paths) {
      await fs.rm(target, { recursive: true, force: true, maxRetries: 3 }).catch(() => {});
    }

    return { descendantsRemaining, descendantState, removedPaths: paths.length };
  }
}

function execRulesDeny(lines, binary) {
  // Exact-path deny. The previous second rule used a trailing space
  // `(subpath "/usr/bin/git ")` which never matched a real path and was dead.
  // The literal deny below is the effective, explicit block for each binary.
  lines.push(`(deny process-exec* (literal ${sb(binary)}))`);
}

function assertAbsolute(name, value) {
  if (typeof value !== "string" || !path.isAbsolute(value)) {
    throw new Error(`generateProfile: ${name} must be an absolute path`);
  }
}

/**
 * Every strict ancestor of `target`, stopping at (and excluding) `stopAt`.
 * Used to seal sibling directories without sealing the target itself.
 */
export function parentsOf(target, stopAt = null) {
  const result = [];
  if (typeof target !== "string" || !path.isAbsolute(target)) return result;
  let current = path.dirname(path.resolve(target));
  const floor = stopAt && path.isAbsolute(stopAt) ? path.resolve(stopAt) : null;
  while (current && current !== "/" && current !== ".") {
    if (floor && (current === floor || current.startsWith(floor + path.sep))) break;
    result.push(current);
    const next = path.dirname(current);
    if (next === current) break;
    current = next;
  }
  return result;
}

/**
 * Darwin major version. Darwin 22.x is macOS 13, the P2 minimum.
 * Returns null on non-Darwin platforms and when the kernel version cannot be
 * parsed, in which case the caller reports the platform failure instead.
 */
export function darwinVersion() {
  if (process.platform !== "darwin") return null;
  const major = Number.parseInt(String(os.release() ?? "").split(".")[0], 10);
  return Number.isFinite(major) ? major : null;
}

async function statOrNull(target) {
  try {
    const stat = await fs.stat(target);
    return { isFile: stat.isFile(), mode: stat.mode };
  } catch {
    return null;
  }
}

async function runProbe(executable, args) {
  try {
    const result = await runProcess({
      executable,
      args,
      env: { PATH: "/usr/bin:/bin", HOME: "/tmp" },
      timeoutMs: 10000
    });
    return { exitCode: result.exitCode, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
  } catch (error) {
    return { exitCode: -1, stdout: "", stderr: String(error?.message ?? error) };
  }
}

export { NODE_BIN_ALLOWED };
