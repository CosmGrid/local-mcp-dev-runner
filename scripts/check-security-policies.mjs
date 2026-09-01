#!/usr/bin/env node
/**
 * Security policy gate (static tripwire).
 *
 * The behavioural suite in tests/ proves that each guard actually fires. This
 * gate proves the guards still *exist in the source*: if someone deletes a
 * guard, this fails even if no behavioural test happened to cover that path.
 *
 * Three sections:
 *   1. required guards present in server.mjs
 *   2. forbidden constructs absent from server.mjs
 *   3. required exclusions present in .gitignore
 *   4. P2 source-invariant checks over the sandbox backend modules
 *
 * This is a tripwire, not a replacement for tests/security/*.
 * Read-only.
 */

import { readFile } from "node:fs/promises";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

const PROJECT_ROOT = path.resolve(import.meta.dirname, "..");

/** Each entry is a stable substring of a denial message, pinned by tests/security. */
const REQUIRED_GUARDS = [
  ["read-only project enforcement", "Project is read-only"],
  ["overwrite protection", "Target file already exists"],
  ["SHA concurrency protection", "SHA-256 mismatch"],
  ["realpath escape defence", "Path escapes registered project root"],
  ["sensitive path block (.env/.git/keys)", "Sensitive path is blocked"],
  ["mcp/* branch namespace", "Branch must start with mcp/"],
  ["protected branch write block", "Writes are blocked on protected branch"],
  ["worktree ownership check", "Only runner-managed worktrees can be removed"],
  ["dirty worktree removal block", "Managed worktree is dirty"],
  ["sensitive files never committed", "No safe changes to commit"],
  ["git filter driver guard", "Repository uses a Git filter via"],

  // P2 — run_script is no longer a permanent deny; it is a controlled sandbox.
  // These substrings are pinned so a future edit cannot silently reintroduce a
  // permanent deny or an unsandboxed fallback.
  ["run_script refuses non-none network", "network access is never granted"],
  ["run_script requires a sandbox backend", "getSandboxBackend()"],
  ["run_script delegates to the P2 pipeline", "executeScript("],
  ["run_script has no unsandboxed fallback", "no unsandboxed fallback"],
  ["run_script rejects arbitrary shell API", "zero arbitrary shell API"]
];

const FORBIDDEN_CONSTRUCTS = [
  [/\bexec\s*\(/, "shell exec() instead of execFile()"],
  [/\bexecSync\b/, "execSync()"],
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

/**
 * P2 sandbox modules under scripts/. This is the explicit review manifest: the
 * gate asserts every manifest entry exists and is scanned, and that any other
 * scripts/*.mjs importing node:child_process is also on the list (reverse
 * coverage — danger is "a process-spawning file that escaped review", not naming).
 */
const P2_MODULES = [
  "scripts/audit-log.mjs",
  "scripts/obvious-deny.mjs",
  "scripts/output-handling.mjs",
  "scripts/sandbox-backend-mock.mjs",
  "scripts/sandbox-backend-sandbox-exec.mjs",
  "scripts/sandbox-backend.mjs",
  "scripts/sandbox-env.mjs",
  "scripts/sandbox-process-runner.mjs",
  "scripts/sandbox-runtime-paths.mjs",
  "scripts/script-execution.mjs",
  "scripts/script-policy.mjs",
  "scripts/sensitive-worktree.mjs"
];

const RUNNER_MODULE = "scripts/sandbox-process-runner.mjs";

const failures = [];
const passes = [];

const serverSource = await readFile(path.join(PROJECT_ROOT, "server.mjs"), "utf8");
const gitignore = await readFile(path.join(PROJECT_ROOT, ".gitignore"), "utf8");

for (const [label, needle] of REQUIRED_GUARDS) {
  if (serverSource.includes(needle)) passes.push(`guard present: ${label}`);
  else failures.push(`guard MISSING: ${label} (expected substring: ${JSON.stringify(needle)})`);
}

// The v1.0 permanent-deny message must be gone; run_script is now controlled.
if (serverSource.includes("run_script is disabled in v1.0")) {
  failures.push("guard REGRESSION: legacy v1.0 permanent-deny message still present in server.mjs");
} else {
  passes.push("guard absent as required: v1.0 permanent deny message");
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

/**
 * Strip // and /* *​/ comments so spawn() call-site counting is not fooled by
 * the explanatory comments in the sandbox modules (which mention spawn on every
 * other line). Handles our own single-file source style; not a general parser.
 */
function stripComments(src) {
  const out = [];
  let inBlock = false;
  for (const rawLine of src.split("\n")) {
    let line = rawLine;
    let result = "";
    let i = 0;
    while (i < line.length) {
      if (inBlock) {
        const end = line.indexOf("*/", i);
        if (end === -1) break;
        i = end + 2;
        inBlock = false;
      } else {
        const block = line.indexOf("/*", i);
        const slash = line.indexOf("//", i);
        if (block !== -1 && (slash === -1 || block < slash)) {
          result += line.slice(i, block);
          const end = line.indexOf("*/", block + 2);
          if (end === -1) {
            inBlock = true;
            break;
          }
          i = end + 2;
        } else if (slash !== -1) {
          result += line.slice(i, slash);
          break;
        } else {
          result += line.slice(i);
          break;
        }
      }
    }
    out.push(result);
  }
  return out.join("\n");
}

function countSpawn(source) {
  return (source.match(/\bspawn\s*\(/g) || []).length;
}

// --- P2 section -----------------------------------------------------------

// Manifest integrity: every entry must exist.
for (const rel of P2_MODULES) {
  try {
    await readFile(path.join(PROJECT_ROOT, rel), "utf8");
    passes.push(`p2 manifest entry present: ${rel}`);
  } catch {
    failures.push(`p2 manifest entry MISSING: ${rel}`);
  }
}

// Reverse coverage: any scripts/*.mjs that *imports* node:child_process must be
// on the P2 manifest, otherwise it could spawn a process without review. CI/helper
// gate scripts are reviewed separately and whitelisted here; only real runtime
// module imports matter.
const NON_P2_PROCESS_SCRIPTS = new Set([
  "scripts/check-input-compat.mjs",
  "scripts/check-security-policies.mjs",
  "scripts/check-syntax.mjs"
]);
const IMPORTS_CHILD_PROCESS = /from\s*["']node:child_process["']/;
const scriptsFiles = (await readdirSync(path.join(PROJECT_ROOT, "scripts"))).filter((f) => f.endsWith(".mjs"));
for (const file of scriptsFiles) {
  const rel = `scripts/${file}`;
  const abs = path.join(PROJECT_ROOT, rel);
  const src = readFileSync(abs, "utf8");
  if (IMPORTS_CHILD_PROCESS.test(src) && !P2_MODULES.includes(rel) && !NON_P2_PROCESS_SCRIPTS.has(rel)) {
    failures.push(`UNREVIEWED process-spawning module: ${rel} imports node:child_process but is not on the P2 manifest`);
  }
}

// Forbidden constructs must be absent from every scanned P2 module (comments
// stripped). spawn() is handled separately: it is allowed only in the runner.
for (const rel of P2_MODULES) {
  const src = stripComments(await readFile(path.join(PROJECT_ROOT, rel), "utf8"));
  for (const [pattern, label] of FORBIDDEN_CONSTRUCTS) {
    if (pattern.test(src)) failures.push(`forbidden construct in ${rel}: ${label}`);
  }
}

// spawn() call-site count: exactly 2 in the runner, 0 everywhere else.
const runnerSrc = stripComments(await readFile(path.join(PROJECT_ROOT, RUNNER_MODULE), "utf8"));
const runnerSpawnCount = countSpawn(runnerSrc);
if (runnerSpawnCount !== 2) {
  failures.push(`spawn call sites in ${RUNNER_MODULE} = ${runnerSpawnCount}, expected exactly 2 (enumerated: main child + pgrep descendant probe)`);
} else {
  passes.push(`spawn call sites in ${RUNNER_MODULE} = 2 (enumerated)`);
}

// The runner must declare the same count it enforces (no silent drift).
if (!/enumeratedSpawnCallSites:\s*2/.test(await readFile(path.join(PROJECT_ROOT, RUNNER_MODULE), "utf8"))) {
  failures.push(`${RUNNER_MODULE} invariant enumeratedSpawnCallSites is not 2`);
} else {
  passes.push(`${RUNNER_MODULE} invariant enumeratedSpawnCallSites = 2`);
}

// S2 must use the hardcoded pgrep path constant, never a string literal.
if (!/PGREP_PATH\s*=/.test(runnerSrc) || !/spawn\(\s*PGREP_PATH/.test(runnerSrc)) {
  failures.push(`${RUNNER_MODULE} must spawn the pgrep probe via the PGREP_PATH constant (/usr/bin/pgrep)`);
} else {
  passes.push(`${RUNNER_MODULE} uses PGREP_PATH constant`);
}

for (const rel of P2_MODULES) {
  if (rel === RUNNER_MODULE) continue;
  const src = stripComments(await readFile(path.join(PROJECT_ROOT, rel), "utf8"));
  const n = countSpawn(src);
  if (n !== 0) failures.push(`unexpected spawn call site in ${rel} (count=${n}); spawn is only permitted in ${RUNNER_MODULE}`);
  else passes.push(`no spawn call site in ${rel}`);
}

for (const line of passes) console.log(`ok    ${line}`);
for (const line of failures) console.error(`FAIL  ${line}`);

if (failures.length > 0) {
  console.error(`\nsecurity gate: ${failures.length} failure(s), ${passes.length} check(s) passed`);
  process.exit(1);
}

console.log(`\nsecurity gate: ${passes.length} checks passed`);
