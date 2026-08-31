/**
 * Git security gate: branch policy, managed worktree lifecycle, commit hygiene.
 *
 * All worktrees and commits happen inside a throwaway fixture repository under a
 * throwaway HOME. The real business repositories are never used as test data.
 */

import { after, before, describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  assertDenied,
  assertOk,
  createFixture,
  openRunner
} from "../support/harness.mjs";

describe("mcp/* branch policy", () => {
  it("refuses to create a worktree on a non-mcp branch", async () => {
    await withTmp(async (client) => {
      const result = await client.callTool({
        name: "git_worktree_create",
        arguments: { project: "fixture-source", branch: "feature/anything" }
      });
      assertDenied(result, /Branch must start with mcp\//);
    });
  });

  it("refuses to create a branch outside the mcp/ namespace", async () => {
    await withTmp(async (client) => {
      const result = await client.callTool({
        name: "git_create_branch",
        arguments: { project: "fixture-source", branch: "hotfix/urgent" }
      });
      assertDenied(result, /Branch must start with mcp\//);
    });
  });

  it("refuses the bare mcp/ prefix with no branch name", async () => {
    await withTmp(async (client) => {
      // Branch-name validation runs before the namespace check, and "mcp/" is
      // not a legal branch name because it ends in a slash.
      const result = await client.callTool({
        name: "git_create_branch",
        arguments: { project: "fixture-source", branch: "mcp/" }
      });
      assertDenied(result, /Invalid Git branch name/);
    });
  });

  it("creates a branch inside the mcp/ namespace", async () => {
    await withTmp(async (client) => {
      const created = assertOk(
        await client.callTool({
          name: "git_create_branch",
          arguments: { project: "fixture-source", branch: "mcp/allowed-branch" }
        })
      );
      assert.equal(created.branch, "mcp/allowed-branch");
    });
  });

  it("refuses to remove a worktree that is not runner-managed", async () => {
    await withTmp(async (client) => {
      const result = await client.callTool({
        name: "git_worktree_remove",
        arguments: { project: "fixture-source" }
      });
      assertDenied(result, /Only runner-managed worktrees can be removed/);
    });
  });
});

describe("protected branch write policy", () => {
  const options = {
    extraProjectDirs: [{ key: "fixture-writable-main", write: true, git: true }]
  };

  it("refuses create_file on a protected branch even when the project is writable", async () => {
    await withTmp(async (client) => {
      const result = await client.callTool({
        name: "create_file",
        arguments: {
          project: "fixture-writable-main",
          path: "new.txt",
          content: "nope"
        }
      });
      assertDenied(result, /Writes are blocked on protected branch: main/);
    }, options);
  });

  it("refuses replace_text on a protected branch", async () => {
    await withTmp(async (client) => {
      const result = await client.callTool({
        name: "replace_text",
        arguments: {
          project: "fixture-writable-main",
          path: "README.md",
          expectedSha256: "0".repeat(64),
          oldText: "fixture-writable-main",
          newText: "changed"
        }
      });
      assertDenied(result, /Writes are blocked on protected branch: main/);
    }, options);
  });

  it("refuses delete_file on a protected branch", async () => {
    await withTmp(async (client) => {
      const result = await client.callTool({
        name: "delete_file",
        arguments: {
          project: "fixture-writable-main",
          path: "README.md",
          expectedSha256: "0".repeat(64)
        }
      });
      assertDenied(result, /Writes are blocked on protected branch: main/);
    }, options);
  });

  it("still allows read-only git inspection on a protected branch", async () => {
    await withTmp(async (client) => {
      const result = assertOk(
        await client.callTool({
          name: "git_status",
          arguments: { project: "fixture-writable-main" }
        })
      );
      // git_status returns the raw --short --branch output, whose first line is the branch header.
      assert.match(result.status, /^## main/m);
    }, options);
  });
});

describe("managed worktree lifecycle (end to end)", () => {
  let fixture;
  let runner;
  let client;
  let managedName = "mcp-baseline";
  let worktreeRoot;

  before(async () => {
    fixture = await createFixture();
    runner = await openRunner(fixture);
    client = runner.client;
  });

  after(async () => {
    await runner?.close();
    await fixture?.cleanup();
  });

  it("creates a managed worktree on an mcp/* branch", async () => {
    const created = assertOk(
      await client.callTool({
        name: "git_worktree_create",
        arguments: { project: "fixture-source", branch: "mcp/baseline" }
      })
    );

    managedName = created.project;
    assert.equal(created.branch, "mcp/baseline");
    assert.equal(created.sourceProject, "fixture-source");
    assert.equal(created.mode, "READ_WRITE");

    const registry = await fixture.readRegistry();
    const entry = registry.projects[managedName];
    assert.ok(entry, `registry is missing ${managedName}`);
    assert.equal(entry.managedWorktree, true);
    assert.equal(entry.branch, "mcp/baseline");
    assert.equal(entry.sourceProject, "fixture-source");
    assert.equal(entry.write, true);
    worktreeRoot = entry.root;

    const info = await stat(worktreeRoot);
    assert.equal(info.isDirectory(), true);
  });

  it("accepts writes inside the managed worktree", async () => {
    const created = assertOk(
      await client.callTool({
        name: "create_file",
        arguments: {
          project: managedName,
          path: "feature.txt",
          content: "generated by test\n"
        }
      })
    );
    assert.equal(created.created, true);
  });

  it("commits without picking up a planted .env", async () => {
    // Simulate a secret that already exists on disk before the commit.
    await writeFile(path.join(worktreeRoot, ".env"), "PLANTED=should-never-be-committed\n", "utf8");

    const committed = assertOk(
      await client.callTool({
        name: "git_commit",
        arguments: { project: managedName, message: "mcp: baseline change" }
      })
    );
    assert.equal(committed.branch, "mcp/baseline");
    assert.match(committed.commit, /^[0-9a-f]{7,40}$/, "expected a short commit hash");

    const tracked = await fixture.gitAt(worktreeRoot, ["ls-files"]);
    assert.match(tracked.stdout, /feature\.txt/);
    assert.doesNotMatch(tracked.stdout, /\.env/);

    const porcelain = await fixture.gitAt(worktreeRoot, ["status", "--porcelain"]);
    assert.match(porcelain.stdout, /\?\? \.env/, ".env should remain untracked");
  });

  it("refuses to commit when the only pending change is sensitive", async () => {
    const result = await client.callTool({
      name: "git_commit",
      arguments: { project: managedName, message: "mcp: nothing safe" }
    });
    assertDenied(result, /No safe changes to commit/);
  });

  it("refuses to remove a dirty managed worktree", async () => {
    const result = await client.callTool({
      name: "git_worktree_remove",
      arguments: { project: managedName }
    });
    assertDenied(result, /Managed worktree is dirty; refusing removal/);
  });

  it("removes a clean managed worktree and keeps the branch", async () => {
    await rm(path.join(worktreeRoot, ".env"), { force: true });

    const removed = assertOk(
      await client.callTool({
        name: "git_worktree_remove",
        arguments: { project: managedName }
      })
    );
    assert.equal(removed.removed, true);
    assert.equal(removed.branch, "mcp/baseline");
    assert.equal(removed.branchRetained, true);

    await assert.rejects(() => stat(worktreeRoot));

    const registry = await fixture.readRegistry();
    assert.equal(registry.projects[managedName], undefined);

    const branches = await fixture.git(["branch", "--list", "mcp/baseline"]);
    assert.match(branches.stdout, /mcp\/baseline/, "the mcp/* branch must be retained");
  });

  it("leaves the original repository on its original branch", async () => {
    const result = assertOk(
      await client.callTool({ name: "git_status", arguments: { project: "fixture-source" } })
    );
    assert.match(result.status, /^## main/m);

    const registry = await fixture.readRegistry();
    assert.equal(registry.projects["fixture-source"].write, false);
    assert.equal(registry.projects["fixture-source"].managedWorktree, undefined);
  });
});

async function withTmp(fn, options = {}) {
  const fixture = await createFixture(options);
  const runner = await openRunner(fixture);
  try {
    return await fn(runner.client, fixture);
  } finally {
    await runner.close();
    await fixture.cleanup();
  }
}
