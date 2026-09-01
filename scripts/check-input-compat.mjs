/**
 * Input-schema compatibility gate (A3 / OUTPUT-SCHEMA work package).
 *
 * The OUTPUT-SCHEMA task is explicitly scoped to OUTPUT contracts only. The
 * input schema of every tool (its parameters and their semantics) must be
 * byte-for-byte unchanged versus the input-contract baseline commit, so we
 * do not silently change a tool's call surface. The baseline is the v2.0.0
 * P2 feature commit: run_script's sandbox contract (expectedPackageSha256 /
 * network / timeoutSeconds, .strict()) is sanctioned by
 * docs/P2_PROCESS_SANDBOX_DESIGN.md; the other 21 tools must stay zero-change.
 *
 * Method: boot BOTH the baseline server (extracted from git) and the current
 * working-tree server against an isolated HOME, call tools/list on each, and
 * compare the announced `inputSchema` per tool name. Names must be identical;
 * each tool's inputSchema must be deeply equal.
 *
 * Outputs `INPUT_SCHEMA_COMPATIBILITY=PASS` and exits 0 only if nothing
 * changed. Any difference prints the details and exits 1.
 */

import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile, mkdir, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const execFileAsync = promisify(execFile);

const BASELINE_REF = process.env.BASELINE_REF || "b2f907d2bfccafcc3718545d003feab383eef123";
const PROJECT_ROOT = process.cwd();
const CURRENT_SERVER = path.join(PROJECT_ROOT, "server.mjs");

function deepEqual(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

async function extractBaselineServer() {
  const dir = await mkdtemp(path.join(tmpdir(), "lmdr-baseline-"));
  // Extract the FULL baseline tree (server.mjs + its scripts/), not just
  // server.mjs: since P2 the server imports ./scripts/* at startup, so the
  // extracted copy must carry those files or it crashes on boot. node_modules
  // is not in git, so symlink it from PROJECT_ROOT; package.json IS in git and
  // is archived.
  const { stdout: tarball } = await execFileAsync("git", ["archive", BASELINE_REF], {
    cwd: PROJECT_ROOT,
    encoding: "buffer",
    maxBuffer: 64 * 1024 * 1024
  });
  const tarFile = path.join(dir, "baseline.tar");
  await writeFile(tarFile, tarball);
  await execFileAsync("tar", ["-xf", tarFile, "-C", dir]);
  await rm(tarFile);
  await symlink(path.join(PROJECT_ROOT, "node_modules"), path.join(dir, "node_modules")).catch(() => {});
  return { file: path.join(dir, "server.mjs"), dir };
}

async function bootAndListTools(serverPath) {
  const home = await mkdtemp(path.join(tmpdir(), "lmdr-compat-"));
  const configDir = path.join(home, ".config", "local-mcp-dev-runner");
  await mkdir(configDir, { recursive: true });
  // An empty registry is enough: tool registration at startup does not depend
  // on any registered project.
  await writeFile(path.join(configDir, "projects.json"), JSON.stringify({ projects: {} }) + "\n", "utf8");

  const env = {
    HOME: home,
    XDG_CONFIG_HOME: path.join(home, ".config"),
    GIT_CONFIG_GLOBAL: path.join(home, ".gitconfig"),
    GIT_CONFIG_SYSTEM: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    PATH: process.env.PATH,
    TMPDIR: tmpdir()
  };

  const client = new Client({ name: "lmdr-compat-check", version: "1.0.0" }, { capabilities: {} });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    cwd: PROJECT_ROOT,
    env,
    stderr: "ignore"
  });
  await client.connect(transport);
  try {
    const { tools } = await client.listTools();
    const map = {};
    for (const t of tools) map[t.name] = t.inputSchema;
    return map;
  } finally {
    await client.close().catch(() => {});
    await transport.close().catch(() => {});
    await rm(home, { recursive: true, force: true, maxRetries: 3 }).catch(() => {});
  }
}

async function main() {
  let baselineDir = null;
  try {
    const baseline = await extractBaselineServer();
    baselineDir = baseline.dir;
    const baselineMap = await bootAndListTools(baseline.file);
    const currentMap = await bootAndListTools(CURRENT_SERVER);

    const baselineNames = Object.keys(baselineMap).sort();
    const currentNames = Object.keys(currentMap).sort();

    const added = currentNames.filter((n) => !baselineNames.includes(n));
    const removed = baselineNames.filter((n) => !currentNames.includes(n));
    const changed = [];
    for (const name of baselineNames) {
      if (!(name in currentMap)) continue;
      if (!deepEqual(baselineMap[name], currentMap[name])) {
        changed.push(name);
      }
    }

    if (added.length === 0 && removed.length === 0 && changed.length === 0) {
      console.log(`INPUT_SCHEMA_COMPATIBILITY=PASS (${baselineNames.length} tools, no input-schema changes vs ${BASELINE_REF})`);
      process.exit(0);
    }

    console.error("INPUT_SCHEMA_COMPATIBILITY=FAIL");
    if (added.length) console.error(`  added tools:   ${added.join(", ")}`);
    if (removed.length) console.error(`  removed tools: ${removed.join(", ")}`);
    if (changed.length) {
      console.error(`  changed input schemas:`);
      for (const name of changed) {
        console.error(`    - ${name}`);
        console.error(`        baseline: ${JSON.stringify(baselineMap[name])}`);
        console.error(`        current:  ${JSON.stringify(currentMap[name])}`);
      }
    }
    process.exit(1);
  } catch (err) {
    console.error("INPUT_SCHEMA_COMPATIBILITY=FAIL");
    console.error(`  gate error: ${err && err.stack ? err.stack : err}`);
    process.exit(1);
  } finally {
    if (baselineDir) {
      await rm(baselineDir, { recursive: true, force: true, maxRetries: 3 }).catch(() => {});
    }
  }
}

main();
