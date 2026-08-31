#!/usr/bin/env node
/**
 * Security policy gate (static tripwire).
 *
 * The behavioural suite in tests/ proves that each guard actually fires. This
 * gate proves the guards still *exist in the source*: if someone deletes a
 * guard, this fails even if no behavioural test happened to cover that path.
 *
 * Two sections:
 *   1. required guards present in server.mjs
 *   2. forbidden constructs absent from server.mjs
 *   3. required exclusions present in .gitignore
 *
 * This is a tripwire, not a replacement for tests/security/*.
 * Read-only.
 */

import { readFile } from "node:fs/promises";
import path from "node:path";

const PROJECT_ROOT = path.resolve(import.meta.dirname, "..");

/** Each entry is a stable substring of a denial message, pinned by tests/security. */
const REQUIRED_GUARDS = [
  ["read-only project enforcement", "Project is read-only"],
  ["overwrite protection", "Target file already exists"],
  ["SHA concurrency protection", "SHA-256 mismatch"],
  ["realpath escape defence", "Path escapes registered project root"],
  ["symlinked directory write block", "Writes through symlinked directories are blocked"],
  ["sensitive path block (.env/.git/keys)", "Sensitive path is blocked"],
  ["mcp/* branch namespace", "Branch must start with mcp/"],
  ["protected branch write block", "Writes are blocked on protected branch"],
  ["worktree ownership check", "Only runner-managed worktrees can be removed"],
  ["dirty worktree removal block", "Managed worktree is dirty"],
  ["run_script permanently disabled", "run_script is disabled in v1.0"],
  ["sensitive files never committed", "No safe changes to commit"],
  ["git filter driver guard", "Repository uses a Git filter via"]
];

const FORBIDDEN_CONSTRUCTS = [
  [/\bexec\s*\(/, "shell exec() instead of execFile()"],
  [/\bexecSync\b/, "execSync()"],
  [/\bspawn\s*\(/, "child_process spawn()"],
  [/\bspawnSync\b/, "child_process spawnSync()"],
  [/shell\s*:\s*true/, "shell: true"],
  [/"(push|pull|fetch)"/, "git push/pull/fetch subcommand"],
  [/rm\s+-rf/, "rm -rf"],
  [/process\.env\.[A-Za-z_]*(KEY|TOKEN|SECRET|PASSWORD)/i, "reading secrets from the environment"]
];

const REQUIRED_GITIGNORE_ENTRIES = [
  "node_modules/",
  ".env",
  "*.key",
  "worktrees/",
  "sandbox/",
  "*.bak-*",
  "logs/",
  ".DS_Store"
];

const failures = [];
const passes = [];

const serverSource = await readFile(path.join(PROJECT_ROOT, "server.mjs"), "utf8");
const gitignore = await readFile(path.join(PROJECT_ROOT, ".gitignore"), "utf8");

for (const [label, needle] of REQUIRED_GUARDS) {
  if (serverSource.includes(needle)) passes.push(`guard present: ${label}`);
  else failures.push(`guard MISSING: ${label} (expected substring: ${JSON.stringify(needle)})`);
}

for (const [pattern, label] of FORBIDDEN_CONSTRUCTS) {
  if (pattern.test(serverSource)) failures.push(`forbidden construct present: ${label}`);
  else passes.push(`construct absent: ${label}`);
}

for (const entry of REQUIRED_GITIGNORE_ENTRIES) {
  const lines = gitignore.split("\n").map((line) => line.trim());
  if (lines.includes(entry)) passes.push(`.gitignore excludes ${entry}`);
  else failures.push(`.gitignore missing entry: ${entry}`);
}

for (const line of passes) console.log(`ok    ${line}`);
for (const line of failures) console.error(`FAIL  ${line}`);

if (failures.length > 0) {
  console.error(`\nsecurity gate: ${failures.length} failure(s), ${passes.length} check(s) passed`);
  process.exit(1);
}

console.log(`\nsecurity gate: ${passes.length} checks passed`);
