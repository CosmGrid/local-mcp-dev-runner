/**
 * Sensitive-file gate for the worktree that is about to execute a script.
 *
 * Scans the worktree root and its first level of subdirectories for credential
 * material. A hit disables execution for that worktree entirely — the process
 * would be able to read those files even though it cannot exfiltrate them, and
 * "contained but readable" is not a bar worth clearing.
 *
 * Reported to the caller as a list of file NAMES only. Contents are never read
 * and never returned.
 */

import fs from "node:fs/promises";
import path from "node:path";

/** How many directory entries to inspect before giving up (DoS guard). */
export const MAX_SCAN_ENTRIES = 2000;

/**
 * Credential-shaped file names. Matching is on the base name, case-insensitive,
 * after the allowlist below has been consulted.
 */
export const SENSITIVE_FILE_PATTERNS = Object.freeze([
  { label: "env-file", pattern: /^\.env(?:\..+)?$/i },
  { label: "netrc", pattern: /^\.netrc$/i },
  { label: "npmrc", pattern: /^\.npmrc$/i },
  { label: "pypirc", pattern: /^\.pypirc$/i },
  { label: "aws-credentials", pattern: /^credentials$/i },
  { label: "aws-config", pattern: /^config$/i, onlyIn: new Set([".aws"]) },
  { label: "service-account", pattern: /^service[-_]?account.*\.json$/i },
  { label: "secrets-file", pattern: /^secrets?\.(?:json|ya?ml|env)$/i },
  { label: "ssh-key", pattern: /^id_(?:rsa|dsa|ecdsa|ed25519)$/i },
  { label: "private-key", pattern: /\.(?:pem|key|p12|pfx|jks|keystore)$/i },
  { label: "gpg-key", pattern: /^(?:secring|private-keys-v1)\.gpg(?:\..+)?$/i },
  { label: "keychain-export", pattern: /\.(?:keychain|keychain-db)$/i }
]);

/**
 * Example/template files that look sensitive but are documentation.
 * These are checked first and always win.
 */
export const ALLOWED_EXAMPLE_PATTERNS = Object.freeze([
  /\.example(?:\.|$)/i,
  /\.sample(?:\.|$)/i,
  /\.template(?:\.|$)/i,
  /\.dist(?:\.|$)/i,
  /^env\.example$/i,
  /^example\.env$/i,
  /^sample\.env$/i,
  /^-readme$/i
]);

function isAllowedExample(name) {
  return ALLOWED_EXAMPLE_PATTERNS.some((pattern) => pattern.test(name));
}

/**
 * Classify a single base name.
 *
 * @param {string} name
 * @param {string} [parentName] immediate parent directory name (for `.aws/config`)
 * @returns {{ sensitive: boolean, label: string|null }}
 */
export function classifyFileName(name, parentName = "") {
  if (isAllowedExample(name)) return { sensitive: false, label: null };
  for (const { label, pattern, onlyIn } of SENSITIVE_FILE_PATTERNS) {
    if (!pattern.test(name)) continue;
    if (onlyIn && !onlyIn.has(parentName)) continue;
    return { sensitive: true, label };
  }
  return { sensitive: false, label: null };
}

/**
 * Scan a worktree for credential files.
 *
 * @param {string} worktreeRoot
 * @returns {Promise<{
 *   sensitiveFiles: string[],
 *   scannedEntries: number,
 *   incomplete: boolean,
 *   symlinks: string[]
 * }>}
 */
export async function scanWorktreeForSensitiveFiles(worktreeRoot) {
  const root = String(worktreeRoot ?? "");
  const sensitiveFiles = [];
  const symlinks = [];
  let scannedEntries = 0;
  let incomplete = false;

  if (root.length === 0) {
    return { sensitiveFiles, scannedEntries, incomplete: false, symlinks };
  }

  let rootEntries;
  try {
    rootEntries = await fs.readdir(root, { withFileTypes: true });
  } catch {
    return { sensitiveFiles, scannedEntries, incomplete: false, symlinks };
  }

  for (const entry of rootEntries) {
    if (scannedEntries >= MAX_SCAN_ENTRIES) {
      incomplete = true;
      break;
    }
    scannedEntries += 1;

    if (entry.isSymbolicLink()) {
      symlinks.push(entry.name);
      continue;
    }

    const verdict = classifyFileName(entry.name);
    if (verdict.sensitive) {
      sensitiveFiles.push(entry.name);
      continue;
    }

    if (!entry.isDirectory()) continue;
    // Skip dependency directories: they are huge, untrusted by definition and
    // already covered by the sandbox policy rather than by this gate.
    if (entry.name === "node_modules" || entry.name === ".git") continue;

    let childEntries;
    try {
      childEntries = await fs.readdir(path.join(root, entry.name), { withFileTypes: true });
    } catch {
      continue;
    }

    for (const child of childEntries) {
      if (scannedEntries >= MAX_SCAN_ENTRIES) {
        incomplete = true;
        break;
      }
      scannedEntries += 1;

      if (child.isSymbolicLink()) {
        symlinks.push(path.join(entry.name, child.name));
        continue;
      }
      const childVerdict = classifyFileName(child.name, entry.name);
      if (childVerdict.sensitive) {
        sensitiveFiles.push(path.join(entry.name, child.name));
      }
    }
  }

  return {
    sensitiveFiles: Array.from(new Set(sensitiveFiles)).sort(),
    scannedEntries,
    incomplete,
    symlinks: Array.from(new Set(symlinks)).sort()
  };
}
