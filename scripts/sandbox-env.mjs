/**
 * Sandbox environment construction.
 *
 * ALLOWLIST ONLY. The parent environment is never spread into the child: a new
 * object is built from scratch so that a secret added to the runner process
 * tomorrow is invisible to scripts today. That is the whole point — deleting a
 * known list of keys is a race you eventually lose.
 *
 * HOME and TMPDIR point into a per-run scratch directory, so writes that a
 * build tool considers "normal" (caches, temp files) land somewhere disposable
 * instead of in the developer's real home.
 */

import path from "node:path";

/**
 * Environment variable names that are allowed through verbatim, if present.
 * Deliberately short and boring.
 */
export const ALLOWED_ENV_KEYS = Object.freeze([
  "LANG",
  "LC_ALL",
  "LC_CTYPE",
  "TZ",
  "TERM",
  "COLUMNS",
  "LINES",
  "NODE_ENV",
  "NO_COLOR",
  "FORCE_COLOR",
  "CI",
  "npm_config_registry",
  "npm_config_offline",
  "npm_config_cache",
  "npm_config_userconfig",
  "npm_config_globalconfig",
  "npm_config_prefix",
  "npm_config_tmp",
  "npm_config_update_notifier",
  "npm_config_fund",
  "npm_config_audit"
]);

/**
 * Substring denylist applied as a second, independent filter. Even if a key
 * above were somehow widened later, credential-shaped names never pass.
 */
export const DENIED_ENV_PATTERNS = Object.freeze([
  /\bkey\b/i,
  /\bkeys\b/i,
  /_key$/i,
  /\btoken\b/i,
  /\bsecret\b/i,
  /\bpassword\b/i,
  /\bpasswd\b/i,
  /\bcredential/i,
  /\bauth\b/i,
  /\bsession\b/i,
  /\bcookie\b/i,
  /\btunnel\b/i,
  /\bcert\b/i,
  /\bsig\b/i,
  /\bapi\b/i
]);

/**
 * Exceptions that survive the substring filter because they are npm switches,
 * not credentials. Kept explicit and tiny on purpose.
 */
const DENIED_ENV_ALLOWLIST = new Set(["npm_config_update_notifier", "npm_config_fund", "npm_config_audit"]);

const DEFAULT_PATH = "/bin:/usr/bin:/sbin:/usr/sbin";

/**
 * Build the child environment.
 *
 * @param {object} input
 * @param {Record<string,string|undefined>} input.parentEnv  normally process.env
 * @param {string} input.homeRoot   per-run sandbox HOME
 * @param {string} input.tmpRoot    per-run sandbox TMPDIR
 * @param {string} input.worktreeRoot  the worktree being executed
 * @param {string[]} [input.nodeBinDirs] node/npm/pnpm installation directories
 * @returns {Record<string,string>}
 */
export function buildSandboxEnv(input) {
  const { parentEnv = {}, homeRoot, tmpRoot, worktreeRoot, nodeBinDirs = [] } = input ?? {};

  const env = {};

  for (const key of ALLOWED_ENV_KEYS) {
    const value = parentEnv[key];
    if (typeof value === "string" && value.length > 0) env[key] = value;
  }

  env.HOME = homeRoot;
  env.TMPDIR = tmpRoot;
  env.TMP = tmpRoot;
  env.TEMP = tmpRoot;
  env.PWD = worktreeRoot;
  env.OLDPWD = worktreeRoot;
  env.PATH = buildSandboxPath({ worktreeRoot, nodeBinDirs, homeRoot, parentPath: parentEnv.PATH });

  // npm/pnpm must never reach the network or the developer's real cache.
  env.npm_config_cache = path.join(tmpRoot, "npm-cache");
  env.npm_config_userconfig = path.join(homeRoot, ".npmrc.sandbox");
  env.npm_config_globalconfig = path.join(homeRoot, ".npmrc.sandbox.global");
  env.npm_config_prefix = path.join(homeRoot, ".npm-global");
  env.npm_config_tmp = tmpRoot;
  env.npm_config_update_notifier = "false";
  env.npm_config_fund = "false";
  env.npm_config_audit = "false";
  env.npm_config_offline = "true";
  env.npm_config_progress = "false";

  return filterEnvironment(env);
}

/**
 * Strip credential-shaped keys. Runs over the allowlist-built map as a defence
 * in depth: the allowlist decides what may enter, this decides what must not.
 *
 * @param {Record<string,string>} env
 * @returns {Record<string,string>}
 */
export function filterEnvironment(env) {
  const output = {};
  for (const [key, value] of Object.entries(env ?? {})) {
    if (DENIED_ENV_ALLOWLIST.has(key)) {
      output[key] = value;
      continue;
    }
    if (DENIED_ENV_PATTERNS.some((pattern) => pattern.test(key))) continue;
    output[key] = value;
  }
  return output;
}

/**
 * Restricted PATH.
 *
 * PATH is not a security boundary (the SBPL exec policy is) but a tight PATH
 * removes the accidental-execution surface and makes "command not found" the
 * first answer for anything the policy would have denied anyway.
 *
 * @param {object} input
 * @param {string} input.worktreeRoot
 * @param {string[]} [input.nodeBinDirs]
 * @param {string} [input.homeRoot]
 * @param {string} [input.parentPath]
 * @returns {string}
 */
export function buildSandboxPath(input) {
  const { worktreeRoot, nodeBinDirs = [], homeRoot = null, parentPath = "" } = input ?? {};
  const entries = [
    path.join(worktreeRoot, "node_modules", ".bin"),
    ...(homeRoot ? [path.join(homeRoot, ".bin")] : []),
    ...nodeBinDirs,
    ...String(parentPath ?? "")
      .split(path.delimiter)
      .map((entry) => entry.trim())
      .filter((entry) => entry.length > 0 && isSystemPath(entry)),
    DEFAULT_PATH
  ];
  return Array.from(new Set(entries.filter(Boolean))).join(path.delimiter);
}

/**
 * Only system-owned directories survive from the parent PATH. Anything under a
 * user's home is dropped: that is exactly where userland tool managers install
 * binaries, and none of them are required to run `npm test`.
 */
export function isSystemPath(entry) {
  if (typeof entry !== "string" || entry.length === 0) return false;
  if (!path.isAbsolute(entry)) return false;
  return entry.startsWith("/usr/") || entry.startsWith("/bin") || entry.startsWith("/sbin") || entry.startsWith("/opt/homebrew") || entry.startsWith("/usr/local");
}
