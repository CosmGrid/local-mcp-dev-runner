/**
 * Script policy: package-manager detection, hash approval, worktree eligibility.
 *
 * Pure logic — every function here is deterministic and free of I/O except
 * `packageManagerCommand`, which only formats structured argv. That keeps the
 * whole policy layer unit-testable inside a restricted (non-sandboxed) host.
 *
 * Failure vocabulary is shared with the rest of P2 and is documented in
 * docs/P2_PROCESS_SANDBOX_DESIGN.md.
 */

import { createHash } from "node:crypto";
import path from "node:path";
import { classifyScript } from "./obvious-deny.mjs";

/** v2.0 supports npm and pnpm only. yarn / bun / workspaces are out of scope. */
export const SUPPORTED_PACKAGE_MANAGERS = Object.freeze(["npm", "pnpm"]);

export const REASON = Object.freeze({
  SANDBOX_BACKEND_UNAVAILABLE: "SANDBOX_BACKEND_UNAVAILABLE",
  NETWORK_NOT_NONE: "NETWORK_NOT_NONE",
  RUN_SCRIPTS_DISABLED: "RUN_SCRIPTS_DISABLED",
  KILL_SWITCH_ACTIVE: "KILL_SWITCH_ACTIVE",
  WORKTREE_NOT_MANAGED: "WORKTREE_NOT_MANAGED",
  WORKTREE_NOT_WRITABLE: "WORKTREE_NOT_WRITABLE",
  WORKTREE_BRANCH_NOT_MCP: "WORKTREE_BRANCH_NOT_MCP",
  WORKTREE_OUTSIDE_BASE: "WORKTREE_OUTSIDE_BASE",
  WORKTREE_DETACHED: "WORKTREE_DETACHED",
  SCRIPT_NOT_ALLOWLISTED: "SCRIPT_NOT_ALLOWLISTED",
  SCRIPT_NOT_APPROVED: "SCRIPT_NOT_APPROVED",
  SCRIPT_VALUE_CHANGED: "SCRIPT_VALUE_CHANGED",
  CALLER_SHA_MISMATCH: "CALLER_SHA_MISMATCH",
  PACKAGE_MANAGER_UNSUPPORTED: "PACKAGE_MANAGER_UNSUPPORTED",
  PACKAGE_MANAGER_UNKNOWN: "PACKAGE_MANAGER_UNKNOWN",
  INSTALL_DENIED: "INSTALL_DENIED",
  EXECUTABLE_OBVIOUS_DENY: "EXECUTABLE_OBVIOUS_DENY",
  SENSITIVE_FILE_IN_WORKTREE: "SENSITIVE_FILE_IN_WORKTREE",
  AUDIT_LOG_INIT_FAILED: "AUDIT_LOG_INIT_FAILED",
  TIMEOUT: "TIMEOUT",
  CANCELLED: "CANCELLED"
});

/**
 * Detect the package manager for a project.
 *
 * Precedence: an explicit `packageManager` field in package.json, then the
 * lockfile present on disk, then the lockfile list supplied by the caller.
 *
 * @param {object} packageJson       parsed package.json
 * @param {string[]} [lockfileNames] lockfile base names present in the project root
 * @returns {{ packageManager: string, supported: boolean, reasonCode: string|null }}
 */
export function detectPackageManager(packageJson, lockfileNames = []) {
  if (packageJson && typeof packageJson.packageManager === "string") {
    const name = packageJson.packageManager.split("@")[0].trim();
    if (name) {
      return SUPPORTED_PACKAGE_MANAGERS.includes(name)
        ? { packageManager: name, supported: true, reasonCode: null }
        : { packageManager: name, supported: false, reasonCode: REASON.PACKAGE_MANAGER_UNSUPPORTED };
    }
  }

  const names = new Set(lockfileNames);
  if (names.has("pnpm-lock.yaml")) return { packageManager: "pnpm", supported: true, reasonCode: null };
  if (names.has("yarn.lock")) {
    return { packageManager: "yarn", supported: false, reasonCode: REASON.PACKAGE_MANAGER_UNSUPPORTED };
  }
  if (names.has("bun.lockb") || names.has("bun.lock")) {
    return { packageManager: "bun", supported: false, reasonCode: REASON.PACKAGE_MANAGER_UNSUPPORTED };
  }
  if (names.has("package-lock.json")) return { packageManager: "npm", supported: true, reasonCode: null };

  return { packageManager: null, supported: false, reasonCode: REASON.PACKAGE_MANAGER_UNKNOWN };
}

/** SHA-256 of the package.json bytes that were approved. */
export function packageSha256(rawPackageJson) {
  return createHash("sha256").update(Buffer.from(rawPackageJson, "utf8"), "utf8").digest("hex");
}

/**
 * SHA-256 that pins one script *value* to one script *name*.
 *
 * The name and the value are separated by a NUL byte so that no combination of
 * name/value can be rearranged into the same digest.
 */
export function scriptSha256(scriptName, scriptValue) {
  return createHash("sha256")
    .update(`script:${String(scriptName)}\u0000${String(scriptValue ?? "")}`)
    .digest("hex");
}

/**
 * Full policy evaluation for one script request.
 *
 * @param {object} input
 * @param {string} input.script                 requested script name
 * @param {object} input.scripts                scripts map from package.json
 * @param {string[]} input.allowedScripts       registry allowlist
 * @param {Record<string,string>} input.scriptHashes  approved name -> scriptSha256
 * @param {string|null} input.expectedPackageSha256  optional caller pin (TOCTOU layer C)
 * @param {string} input.packageSha256          hash computed from the bytes just read
 * @returns {{
 *   ok: boolean,
 *   reasonCode: string|null,
 *   script: string,
 *   scriptValue: string|null,
 *   scriptSha256: string|null,
 *   approvedScriptSha256: string|null
 * }}
 */
export function evaluateScriptPolicy(input) {
  const {
    script,
    scripts = {},
    allowedScripts = [],
    scriptHashes = {},
    expectedPackageSha256 = null,
    packageSha256: actualPackageSha
  } = input;

  const fail = (reasonCode) => ({
    ok: false,
    reasonCode,
    script,
    scriptValue: null,
    scriptSha256: null,
    approvedScriptSha256: null
  });

  // TOCTOU layer C: caller-supplied pin. Optional, but when present it must match.
  if (expectedPackageSha256) {
    if (String(expectedPackageSha256).toLowerCase() !== String(actualPackageSha).toLowerCase()) {
      return fail(REASON.CALLER_SHA_MISMATCH);
    }
  }

  if (!Array.isArray(allowedScripts) || !allowedScripts.includes(script)) {
    return fail(REASON.SCRIPT_NOT_ALLOWLISTED);
  }

  if (!Object.prototype.hasOwnProperty.call(scripts, script)) {
    return fail(REASON.SCRIPT_NOT_ALLOWLISTED);
  }

  const scriptValue = String(scripts[script] ?? "");

  // Fail-fast pass. Not a boundary: the sandbox still contains the process.
  const obvious = classifyScript(script, scriptValue);
  if (obvious.denied) return fail(obvious.reasonCode);

  // TOCTOU layer A: the registry must carry an approved hash for this script.
  const approvedScriptSha = scriptHashes?.[script] ?? null;
  if (typeof approvedScriptSha !== "string" || approvedScriptSha.length !== 64) {
    return fail(REASON.SCRIPT_NOT_APPROVED);
  }

  // TOCTOU layer B: the script value read moments ago must match that approval.
  const actualScriptSha = scriptSha256(script, scriptValue);
  if (approvedScriptSha.toLowerCase() !== actualScriptSha.toLowerCase()) {
    return {
      ok: false,
      reasonCode: REASON.SCRIPT_VALUE_CHANGED,
      script,
      scriptValue,
      scriptSha256: actualScriptSha,
      approvedScriptSha256: approvedScriptSha
    };
  }

  return {
    ok: true,
    reasonCode: null,
    script,
    scriptValue,
    scriptSha256: actualScriptSha,
    approvedScriptSha256: approvedScriptSha
  };
}

/**
 * Which scripts can never be approved, with the reason for each.
 * Used by project_scripts so ChatGPT can explain why a script is unavailable.
 */
export function deniedScriptsFor(scripts = {}) {
  const denied = [];
  for (const [name, value] of Object.entries(scripts ?? {})) {
    const verdict = classifyScript(name, String(value ?? ""));
    if (verdict.denied) {
      denied.push({ script: name, reasonCode: verdict.reasonCode, category: verdict.category });
    }
  }
  return denied.sort((a, b) => a.script.localeCompare(b.script));
}

/**
 * Worktree eligibility — the strongest application-level gate in P2.
 *
 * A script may only run inside a Runner-managed READ_WRITE worktree. The
 * original repository, a plain writable sandbox, a hand-made worktree and any
 * arbitrarily registered directory are all refused.
 *
 * @param {object} spec      resolved project (see server.mjs resolveProject)
 * @param {object} gitState  result of getGitState(spec)
 * @param {string} worktreeBase
 * @returns {{ ok: boolean, reasonCode: string|null }}
 */
export function checkWorktreeEligibility(spec, gitState, worktreeBase) {
  if (!spec || spec.managedWorktree !== true) return { ok: false, reasonCode: REASON.WORKTREE_NOT_MANAGED };
  if (spec.write !== true) return { ok: false, reasonCode: REASON.WORKTREE_NOT_WRITABLE };
  if (typeof spec.sourceProject !== "string" || spec.sourceProject.length === 0) {
    return { ok: false, reasonCode: REASON.WORKTREE_NOT_MANAGED };
  }

  const branch = String(spec.branch ?? gitState?.branch ?? "");
  if (!branch.startsWith("mcp/")) return { ok: false, reasonCode: REASON.WORKTREE_BRANCH_NOT_MCP };

  if (gitState?.detached === true) return { ok: false, reasonCode: REASON.WORKTREE_DETACHED };
  if (gitState?.branch && gitState.branch !== branch) {
    return { ok: false, reasonCode: REASON.WORKTREE_BRANCH_NOT_MCP };
  }

  const base = path.resolve(worktreeBase);
  const root = path.resolve(spec.root);
  if (root !== base && !root.startsWith(base + path.sep)) {
    return { ok: false, reasonCode: REASON.WORKTREE_OUTSIDE_BASE };
  }

  return { ok: true, reasonCode: null };
}

/**
 * Structured argv for the package manager. No shell is involved at any point:
 * the executable is fixed by the caller and the script name travels as a single
 * argv element, so it cannot be split into extra arguments.
 *
 * @param {string} packageManager "npm" | "pnpm"
 * @param {string} script
 * @param {string[]} [extraArgs]
 * @returns {string[]}
 */
export function packageManagerCommand(packageManager, script, extraArgs = []) {
  if (packageManager !== "npm" && packageManager !== "pnpm") {
    throw new Error(`${REASON.PACKAGE_MANAGER_UNSUPPORTED}: ${packageManager}`);
  }
  if (typeof script !== "string" || script.length === 0) {
    throw new Error("SCRIPT_NOT_ALLOWLISTED: a script name is required");
  }
  return ["run", script, ...extraArgs];
}
