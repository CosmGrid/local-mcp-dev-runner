/**
 * Inventory gate.
 *
 * The v1.0 baseline exposes exactly 22 tools. Any tool added or removed changes
 * the attack surface of the runner, so the count and the exact name set are
 * pinned here rather than merely asserted to be "non-empty".
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { withFixtureAndRunner } from "./support/harness.mjs";

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
  "run_script"
];

describe("tool inventory", () => {
  it("exposes exactly the 22 baseline tools", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const { tools } = await client.listTools();
      const names = tools.map((tool) => tool.name).sort();

      assert.equal(tools.length, 22, `expected 22 tools, got ${tools.length}: ${names.join(", ")}`);
      assert.deepEqual(names, [...EXPECTED_TOOLS].sort());
    });
  });

  it("reports the baseline server identity", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const info = client.getServerVersion();
      assert.equal(info?.name, "local-mcp-dev-runner");
      assert.equal(info?.version, "1.0.0");
    });
  });

  it("every tool declares a description and an input schema", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const { tools } = await client.listTools();
      for (const tool of tools) {
        assert.ok(tool.description && tool.description.length > 0, `${tool.name} has no description`);
        assert.equal(tool.inputSchema?.type, "object", `${tool.name} has no object input schema`);
      }
    });
  });
});
