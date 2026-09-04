#!/usr/bin/env node
/**
 * Tool inventory gate.
 *
 * Boots the runner binary under an isolated HOME with an empty project registry,
 * asks it for its tool list over the real MCP protocol, and requires exactly the
 * 22 baseline tools.
 *
 * Usage:
 *   node scripts/check-inventory.mjs                 # check SOURCE_ROOT/server.mjs
 *   node scripts/check-inventory.mjs --server <path> # check an arbitrary server.mjs
 *
 * This is the gate the deploy script runs against the staged tree before it is
 * swapped into place, so a broken build can never reach RUNTIME_ROOT.
 *
 * Read-only with respect to RUNTIME_ROOT and ~/.config/local-mcp-dev-runner.
 */

import { mkdtemp, rm, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const PROJECT_ROOT = path.resolve(import.meta.dirname, "..");

export const EXPECTED_TOOLS = [
  "list_projects",
  "project_info",
  "list_directory",
  "find_files",
  "search_text",
  "read_file",
  "read_files",
  "file_info",
  "create_directory",
  "create_file",
  "replace_text",
  "delete_file",
  "git_status",
  "git_diff",
  "git_log",
  "git_branch_list",
  "git_create_branch",
  "git_worktree_create",
  "git_worktree_remove",
  "git_commit",
  "project_scripts",
  "run_script",
  "github_repository_info",
  "github_repository_create"
];

function parseArgs(argv) {
  const out = { server: path.join(PROJECT_ROOT, "server.mjs") };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--server" && argv[i + 1]) {
      out.server = path.resolve(argv[i + 1]);
      i += 1;
    } else if (argv[i] === "--help" || argv[i] === "-h") {
      out.help = true;
    }
  }
  return out;
}

const { server, help } = parseArgs(process.argv.slice(2));
if (help) {
  console.log("usage: node scripts/check-inventory.mjs [--server <path/to/server.mjs>]");
  process.exit(0);
}

const home = await mkdtemp(path.join(tmpdir(), "lmdr-inventory-"));
await mkdir(path.join(home, ".config", "local-mcp-dev-runner"), { recursive: true });
await writeFile(
  path.join(home, ".config", "local-mcp-dev-runner", "projects.json"),
  JSON.stringify({ projects: {} }, null, 2) + "\n",
  { mode: 0o600 }
);

const client = new Client({ name: "lmdr-inventory-gate", version: "1.0.0" }, { capabilities: {} });
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [server],
  cwd: PROJECT_ROOT,
  env: {
    HOME: home,
    XDG_CONFIG_HOME: path.join(home, ".config"),
    GIT_CONFIG_GLOBAL: path.join(home, ".gitconfig"),
    GIT_CONFIG_SYSTEM: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    PATH: process.env.PATH,
    TMPDIR: tmpdir()
  },
  stderr: "pipe"
});

let exitCode = 0;
try {
  await client.connect(transport);
  const { tools } = await client.listTools();
  const names = tools.map((tool) => tool.name).sort();
  const expected = [...EXPECTED_TOOLS].sort();

  if (tools.length !== EXPECTED_TOOLS.length) {
    exitCode = 1;
    console.error(`FAIL  expected ${EXPECTED_TOOLS.length} tools, got ${tools.length}`);
    console.error(`      ${names.join(", ")}`);
  } else if (JSON.stringify(names) !== JSON.stringify(expected)) {
    exitCode = 1;
    console.error("FAIL  tool set differs from the v1.0 baseline");
    console.error(`      missing: ${expected.filter((n) => !names.includes(n)).join(", ") || "(none)"}`);
    console.error(`      extra:   ${names.filter((n) => !expected.includes(n)).join(", ") || "(none)"}`);
  } else {
    console.log(`ok    ${server}`);
    console.log(`      ${tools.length} tools: ${expected.join(", ")}`);
  }
} catch (error) {
  exitCode = 1;
  console.error(`FAIL  could not inventory ${server}`);
  console.error(`      ${error?.message ?? error}`);
} finally {
  await client.close().catch(() => {});
  await transport.close().catch(() => {});
  await rm(home, { recursive: true, force: true }).catch(() => {});
}

process.exit(exitCode);
