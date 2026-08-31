#!/usr/bin/env node
/**
 * Syntax gate.
 *
 * Parses every .mjs file in the source tree (excluding node_modules and any
 * build/output directory) and fails on the first syntax error.
 *
 * Read-only. Safe to run at any time.
 */

import { execFile } from "node:child_process";
import { readdir } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const PROJECT_ROOT = path.resolve(import.meta.dirname, "..");
const SKIP_DIRS = new Set(["node_modules", ".git", "coverage", "dist", "build", "out"]);

async function collectMjs(dir, acc = []) {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return acc;
  }

  for (const entry of entries) {
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      await collectMjs(path.join(dir, entry.name), acc);
    } else if (entry.name.endsWith(".mjs")) {
      acc.push(path.join(dir, entry.name));
    }
  }
  return acc;
}

const files = (await collectMjs(PROJECT_ROOT)).sort();
if (files.length === 0) {
  console.error("check-syntax: no .mjs files found; refusing to pass vacuously");
  process.exit(1);
}

let failed = 0;
for (const file of files) {
  try {
    await execFileAsync(process.execPath, ["--check", file], { cwd: PROJECT_ROOT });
    console.log(`ok    ${path.relative(PROJECT_ROOT, file)}`);
  } catch (error) {
    failed += 1;
    console.error(`FAIL  ${path.relative(PROJECT_ROOT, file)}`);
    console.error(String(error.stderr || error.message).trim());
  }
}

if (failed > 0) {
  console.error(`\ncheck-syntax: ${failed}/${files.length} file(s) failed`);
  process.exit(1);
}

console.log(`\ncheck-syntax: ${files.length}/${files.length} files parse cleanly`);
