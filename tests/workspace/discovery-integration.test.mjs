/**
 * Trusted Workspace discovery — end-to-end tests through the real MCP server.
 *
 * These boot the actual runner binary against an isolated HOME (see
 * tests/support/harness.mjs) and assert the merged behaviour of
 * list_projects / project_info and the permission model. No real workspace,
 * registry, or repository is touched.
 */

import assert from "node:assert/strict";
import { realpath } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

import { assertDenied, assertOk, createFixture, openRunner } from "../support/harness.mjs";

async function withWorkspaceRunner(buildWorkspaces, fn, options = {}) {
  const fixture = await createFixture(options);
  try {
    await buildWorkspaces(fixture);
    const handle = await openRunner(fixture);
    try {
      return await fn(handle.client, fixture);
    } finally {
      await handle.close();
    }
  } finally {
    await fixture.cleanup();
  }
}

/** Declare trusted workspaces after the fixture tree has been built. */
async function declareWorkspaces(fixture, workspaces) {
  const registry = await fixture.readRegistry();
  registry.trustedWorkspaces = workspaces;
  await fixture.writeRegistry(registry);
}

/**
 * Call list_projects and return its projects array from structuredContent,
 * which is what MCP clients actually consume.
 */
async function listProjects(client) {
  const result = await client.callTool({ name: "list_projects", arguments: {} });
  assert.notEqual(
    result.isError,
    true,
    `list_projects should succeed; got: ${JSON.stringify(result.content)}`
  );
  assert.ok(result.structuredContent, "list_projects must return structuredContent");
  return result.structuredContent.projects;
}

const namesOf = listProjects;

describe("trusted workspace — list_projects", () => {
  it("is unchanged when no trusted workspace is configured", async () => {
    await withWorkspaceRunner(
      async () => {},
      async (client) => {
        const projects = await namesOf(client);
        assert.deepEqual(projects.map((p) => p.name), ["fixture-sandbox", "fixture-source"]);
        for (const project of projects) {
          assert.equal(project.source, "explicit");
          assert.equal(project.workspace, null);
        }
      }
    );
  });

  it("merges explicit projects with auto-discovered repositories", async () => {
    await withWorkspaceRunner(
      async (fixture) => {
        await fixture.makeRepo("ws/api");
        await fixture.makeRepo("ws/web");
        await fixture.makeDir("ws/not-a-repo");
        await declareWorkspaces(fixture, { dev: { root: path.join(fixture.root, "ws") } });
      },
      async (client) => {
        const projects = await namesOf(client);
        const byName = Object.fromEntries(projects.map((p) => [p.name, p]));

        assert.deepEqual(
          projects.map((p) => p.name),
          ["api", "fixture-sandbox", "fixture-source", "web"],
          "explicit and discovered projects are merged and sorted"
        );
        assert.equal(byName["fixture-source"].source, "explicit");
        assert.equal(byName["api"].source, "workspace");
        assert.equal(byName["api"].workspace, "dev");
        assert.equal(byName["api"].mode, "READ_ONLY");
        assert.equal(byName["web"].mode, "READ_ONLY");
        assert.ok(!byName["not-a-repo"], "non-Git directories are not exposed");
      }
    );
  });

  it("never exposes a repository outside the declared workspace", async () => {
    await withWorkspaceRunner(
      async (fixture) => {
        await fixture.makeRepo("ws/inside-repo");
        await fixture.makeRepo("elsewhere/outside-repo");
        await declareWorkspaces(fixture, { dev: { root: path.join(fixture.root, "ws") } });
      },
      async (client) => {
        const projects = await namesOf(client);
        const names = projects.map((p) => p.name);
        assert.ok(names.includes("inside-repo"));
        assert.ok(!names.includes("outside-repo"), "a repository outside the workspace is never discovered");
      }
    );
  });

  it("does not duplicate a repository the user already registered explicitly", async () => {
    await withWorkspaceRunner(
      async (fixture) => {
        const repoRoot = await fixture.makeRepo("ws/api");
        await declareWorkspaces(fixture, { dev: { root: path.join(fixture.root, "ws") } });
        const registry = await fixture.readRegistry();
        registry.projects["hand-registered"] = { root: repoRoot, write: true };
        await fixture.writeRegistry(registry);
      },
      async (client) => {
        const projects = await namesOf(client);
        const names = projects.map((p) => p.name);
        assert.equal(names.filter((n) => n === "hand-registered").length, 1);
        assert.ok(!names.includes("api"), "the same repository is not also exposed as auto-discovered");
      }
    );
  });
});

describe("trusted workspace — project_info", () => {
  it("resolves an auto-discovered project and reports it as READ_ONLY", async () => {
    await withWorkspaceRunner(
      async (fixture) => {
        await fixture.makeRepo("ws/api");
        await declareWorkspaces(fixture, { dev: { root: path.join(fixture.root, "ws") } });
      },
      async (client, fixture) => {
        const info = assertOk(await client.callTool({ name: "project_info", arguments: { project: "api" } }));
        assert.equal(info.project, "api");
        assert.equal(info.mode, "READ_ONLY");
        assert.equal(info.git.isGit, true);
        assert.equal(info.managedWorktree, false);
        assert.equal(info.configuredBranch, null);
        // The runner realpaths every root; compare on the resolved form.
        assert.equal(info.root, await realpath(path.join(fixture.root, "ws", "api")));
      }
    );
  });

  it("applies the same escape guards to discovered projects", async () => {
    await withWorkspaceRunner(
      async (fixture) => {
        await fixture.makeRepo("ws/api");
        await declareWorkspaces(fixture, { dev: { root: path.join(fixture.root, "ws") } });
      },
      async (client) => {
        assertDenied(
          await client.callTool({ name: "list_directory", arguments: { project: "api", path: ".." } }),
          /Path escapes registered project root/
        );
        assertDenied(
          await client.callTool({ name: "list_directory", arguments: { project: "api", path: "/etc" } }),
          /Absolute paths are not allowed/
        );
      }
    );
  });

  it("reports ambiguity instead of guessing between same-named repositories", async () => {
    await withWorkspaceRunner(
      async (fixture) => {
        await fixture.makeRepo("wsA/api");
        await fixture.makeRepo("wsB/api");
        await declareWorkspaces(fixture, {
          wsA: { root: path.join(fixture.root, "wsA") },
          wsB: { root: path.join(fixture.root, "wsB") }
        });
      },
      async (client) => {
        assertDenied(
          await client.callTool({ name: "project_info", arguments: { project: "api" } }),
          /Ambiguous project: api/
        );

        // The stable ids both resolve, to different roots.
        const infoA = assertOk(await client.callTool({ name: "project_info", arguments: { project: "wsA/api" } }));
        const infoB = assertOk(await client.callTool({ name: "project_info", arguments: { project: "wsB/api" } }));
        assert.notEqual(infoA.root, infoB.root, "the two repositories are distinct");
        assert.equal(infoA.mode, "READ_ONLY");
        assert.equal(infoB.mode, "READ_ONLY");
      }
    );
  });

  it("still reports an unknown project as unknown", async () => {
    await withWorkspaceRunner(
      async (fixture) => {
        await fixture.makeRepo("ws/api");
        await declareWorkspaces(fixture, { dev: { root: path.join(fixture.root, "ws") } });
      },
      async (client) => {
        assertDenied(
          await client.callTool({ name: "project_info", arguments: { project: "does-not-exist" } }),
          /Unknown project: does-not-exist/
        );
      }
    );
  });
});

describe("trusted workspace — permission model", () => {
  it("refuses writes to an auto-discovered project", async () => {
    await withWorkspaceRunner(
      async (fixture) => {
        await fixture.makeRepo("ws/api");
        await declareWorkspaces(fixture, { dev: { root: path.join(fixture.root, "ws") } });
      },
      async (client) => {
        assertDenied(
          await client.callTool({
            name: "create_file",
            arguments: { project: "api", path: "notes.txt", content: "nope" }
          }),
          /Project is read-only/
        );
      }
    );
  });

  it("keeps script execution disabled for an auto-discovered project", async () => {
    await withWorkspaceRunner(
      async (fixture) => {
        await fixture.makeRepo("ws/api", [["package.json", JSON.stringify({ scripts: { build: "node build.js" } })]]);
        await declareWorkspaces(fixture, { dev: { root: path.join(fixture.root, "ws") } });
      },
      async (client) => {
        const report = assertOk(await client.callTool({ name: "project_scripts", arguments: { project: "api" } }));
        assert.equal(report.executionEnabled, false, "discovery never enables runScripts");
        assert.deepEqual(report.allowedScripts ?? [], []);
      }
    );
  });

  it("keeps the managed-worktree write path intact for a discovered project", async () => {
    await withWorkspaceRunner(
      async (fixture) => {
        await fixture.makeRepo("ws/api");
        await declareWorkspaces(fixture, { dev: { root: path.join(fixture.root, "ws") } });
      },
      async (client) => {
        const created = assertOk(await client.callTool({
          name: "git_worktree_create",
          arguments: { project: "api", branch: "mcp/from-discovered" }
        }));
        assert.equal(created.created, true);
        assert.equal(created.mode, "READ_WRITE", "the managed worktree is the only writable surface");
        assert.equal(created.sourceProject, "api");

        // The discovered source project itself remains read-only.
        assertDenied(
          await client.callTool({
            name: "create_file",
            arguments: { project: "api", path: "notes.txt", content: "nope" }
          }),
          /Project is read-only/
        );

        const removed = assertOk(await client.callTool({
          name: "git_worktree_remove",
          arguments: { project: created.project }
        }));
        assert.equal(removed.removed, true);
      }
    );
  });

  it("lets an explicit override grant write without leaking it into discovery", async () => {
    await withWorkspaceRunner(
      async (fixture) => {
        await fixture.makeRepo("ws/api");
        await fixture.makeRepo("ws/other");
        await declareWorkspaces(fixture, { dev: { root: path.join(fixture.root, "ws") } });
        const registry = await fixture.readRegistry();
        registry.projects["api-writable"] = {
          root: path.join(fixture.root, "ws", "api"),
          write: true
        };
        await fixture.writeRegistry(registry);
      },
      async (client) => {
        const projects = await namesOf(client);
        const byName = Object.fromEntries(projects.map((p) => [p.name, p]));

        // The explicit override is authoritative and writable.
        assert.equal(byName["api-writable"].mode, "READ_WRITE");
        assert.equal(byName["api-writable"].source, "explicit");

        // The separately discovered repository did not inherit that permission.
        assert.equal(byName["other"].mode, "READ_ONLY");
        assert.equal(byName["other"].source, "workspace");

        // The overridden repository is not exposed twice.
        assert.ok(!byName["api"], "the overridden repository is not also auto-discovered");
      }
    );
  });
});

describe("trusted workspace — fail-closed configuration", () => {
  it("surfaces a missing workspace root instead of silently returning nothing", async () => {
    await withWorkspaceRunner(
      async (fixture) => {
        await declareWorkspaces(fixture, { dev: { root: path.join(fixture.root, "does-not-exist") } });
      },
      async (client) => {
        assertDenied(
          await client.callTool({ name: "list_projects", arguments: {} }),
          /WORKSPACE_ROOT_NOT_FOUND/
        );
      }
    );
  });

  it("surfaces an over-broad workspace root", async () => {
    await withWorkspaceRunner(
      async (fixture) => {
        await declareWorkspaces(fixture, { dev: { root: "/Users" } });
      },
      async (client) => {
        assertDenied(
          await client.callTool({ name: "list_projects", arguments: {} }),
          /WORKSPACE_ROOT_FORBIDDEN/
        );
      }
    );
  });

  it("does not break explicit projects when discovery is misconfigured", async () => {
    await withWorkspaceRunner(
      async (fixture) => {
        await declareWorkspaces(fixture, { dev: { root: path.join(fixture.root, "does-not-exist") } });
      },
      async (client) => {
        // resolveProject returns explicit entries before touching discovery.
        const info = assertOk(await client.callTool({
          name: "project_info",
          arguments: { project: "fixture-source" }
        }));
        assert.equal(info.mode, "READ_ONLY");
        assert.equal(info.git.isGit, true);
      }
    );
  });
});
