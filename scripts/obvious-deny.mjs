/**
 * Obvious-deny scanner (fail-fast only).
 *
 * This module is NOT a security boundary. It exists to reject blatantly unsafe
 * scripts before they are ever handed to the sandbox, which keeps error
 * messages actionable and keeps obviously hostile requests out of the audit
 * log noise.
 *
 * The real boundary is the OS sandbox: SBPL process-exec policy, filesystem
 * isolation, environment isolation and network denial. Every category below is
 * designed so that even if a caller crafts a payload that slips past these
 * string checks, the sandboxed process is still contained. The P2 test suite
 * proves that explicitly (see tests/native/*).
 */

/** Shell metacharacters that indicate an inline shell invocation. */
const SHELL_METACHARACTERS = /[;&|`$]|(?:\$\()|&&|\|\|/;

/**
 * High-risk binaries. Only reached through a structured argv, never through a
 * shell; the sandbox denies their execution outright, this is the early exit.
 */
const DANGEROUS_BINARIES = [
  "curl",
  "wget",
  "ssh",
  "scp",
  "sftp",
  "nc",
  "ncat",
  "netcat",
  "telnet",
  "ftp",
  "osascript",
  "security",
  "launchctl",
  "sudo",
  "su",
  "docker",
  "podman",
  "git",
  "python",
  "python3",
  "ruby",
  "perl",
  "php",
  "bash",
  "sh",
  "zsh",
  "eval",
  "exec",
  "xargs",
  "rm",
  "chmod",
  "chown",
  "kill",
  "killall",
  "pkill",
  "reboot",
  "shutdown"
];

/** Inline-evaluation forms: interpreter -c / -e followed by arbitrary code. */
const INLINE_EVAL_PATTERNS = [
  /\bsh\s+(?:-c|--command)\b/,
  /\bbash\s+(?:-c|--command)\b/,
  /\bzsh\s+(?:-c|--command)\b/,
  /\bpython3?\s+(?:-c|--command)\b/,
  /\bnode\s+(?:-e|--eval|-p|--print)\b/,
  /\bperl\s+-e\b/,
  /\bruby\s+-e\b/,
  /\bphp\s+-r\b/,
  /\beval\b/,
  /\bexec\b/
];

/**
 * Package-manager subcommands that are permanently denied. `npm run` is the
 * only package-manager invocation the runner itself performs, so it is not
 * listed here.
 */
const INSTALL_SUBCOMMANDS =
  /\b(?:npm|pnpm|yarn|bun|npx)\b[^\n]*?\b(?:install|i|ci|add|remove|rm|update|up|exec|dlx|publish|pack|link|rebuild|audit-fund|fund)\b/;

/** Lifecycle script names that run implicitly and can never be allowlisted. */
const DENIED_LIFECYCLE_SCRIPTS = new Set([
  "preinstall",
  "install",
  "postinstall",
  "prepare",
  "prepublish",
  "prepublishOnly",
  "prepack",
  "postpack",
  "publish",
  "postpublish"
]);

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Matches a dangerous binary when it appears as a whole word preceded by a
 * non-identifier boundary (start of string, whitespace, a shell operator, etc.)
 * and followed by a word boundary. Built with an explicit character class so no
 * backslash escaping is needed inside the constructor string.
 */
export const DANGEROUS_BINARY_PATTERN = new RegExp(
  "(?:^|[^A-Za-z0-9_./-])(?:" + DANGEROUS_BINARIES.map(escapeRegExp).join("|") + ")(?:[ \\t]|$|[^A-Za-z0-9_./-])",
  "m"
);

/**
 * Classify a script name / script value pair.
 *
 * @param {string} script  the package.json script name
 * @param {string} value   the package.json script value (may be "")
 * @returns {{ denied: boolean, reasonCode: string|null, category: string|null, match: string|null }}
 */
export function classifyScript(script, value = "") {
  const name = String(script ?? "").trim();
  const body = String(value ?? "");

  if (DENIED_LIFECYCLE_SCRIPTS.has(name.toLowerCase())) {
    return { denied: true, reasonCode: "INSTALL_DENIED", category: "lifecycle-script", match: name };
  }

  if (INSTALL_SUBCOMMANDS.test(name)) {
    return { denied: true, reasonCode: "INSTALL_DENIED", category: "name-install", match: name };
  }

  if (SHELL_METACHARACTERS.test(body)) {
    const match = body.match(SHELL_METACHARACTERS)?.[0] ?? null;
    return { denied: true, reasonCode: "EXECUTABLE_OBVIOUS_DENY", category: "shell-metacharacter", match };
  }

  const inlineMatch = INLINE_EVAL_PATTERNS.find((pattern) => pattern.test(body));
  if (inlineMatch) {
    return {
      denied: true,
      reasonCode: "EXECUTABLE_OBVIOUS_DENY",
      category: "inline-eval",
      match: body.match(inlineMatch)?.[0] ?? null
    };
  }

  const dangerousMatch = body.match(DANGEROUS_BINARY_PATTERN);
  if (dangerousMatch) {
    return {
      denied: true,
      reasonCode: "EXECUTABLE_OBVIOUS_DENY",
      category: "dangerous-binary",
      match: dangerousMatch[0].trim()
    };
  }

  const installMatch = body.match(INSTALL_SUBCOMMANDS);
  if (installMatch) {
    return { denied: true, reasonCode: "INSTALL_DENIED", category: "value-install", match: installMatch[0].trim() };
  }

  return { denied: false, reasonCode: null, category: null, match: null };
}

/** True when the script name is a lifecycle hook that must never run. */
export function isDeniedLifecycleScript(script) {
  return DENIED_LIFECYCLE_SCRIPTS.has(String(script ?? "").trim().toLowerCase());
}

export const OBVIOUS_DENY_CATEGORIES = Object.freeze({
  SHELL_METACHARACTER: "shell-metacharacter",
  INLINE_EVAL: "inline-eval",
  DANGEROUS_BINARY: "dangerous-binary",
  VALUE_INSTALL: "value-install",
  NAME_INSTALL: "name-install",
  LIFECYCLE_SCRIPT: "lifecycle-script"
});
