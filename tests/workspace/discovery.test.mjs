/**
 * Trusted Workspace discovery — unit tests.
 *
 * These exercise scripts/workspace-discovery.mjs directly (no MCP round-trip)
 * so that boundary, naming and permission rules can be asserted precisely.
 * End-to-end behaviour through list_projects / project_info lives in
 * tests/workspace/discovery-integration.test.mjs.
 *
 * Every fixture is a temp directory; no real workspace is ever scanned.
 */

import assert from "node:assert/strict";
import { chmod, mkdir, realpath, symlink, writeFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

import { createFixture } from "../support/harness.mjs";
import {
  DEFAULT_MAX_DEPTH,
  MAX_DIRS_PER_WORKSPACE,
  MAX_MAX_DEPTH,
  MAX_REPOS_PER_WORKSPACE,
  buildDiscoveryIndex,
  discoverWorkspaceProjects,
  parseTrustedWorkspaces,
  resetDiscoveryCache,
  resolveDiscoveredProject,
  resolveWorkspaceSpecs
} from "../../scripts/workspace-discovery.mjs";

async function withWorkspace(build, fn, extraOptions = {}) {
  const fixture = await createFixture(extraOptions);
  try {
    await build(fixture);
    resetDiscoveryCache();
    return await fn(fixture);
  } finally {
    await fixture.cleanup();
  }
}

describe("trusted workspace — configuration validation", () => {
  it("returns no workspaces when the key is absent (backward compatible)", async () => {
    assert.deepEqual(parseTrustedWorkspaces({ projects: {} }), []);
    assert.deepEqual(parseTrustedWorkspaces({}), []);
  });

  it("accepts a well-formed workspace declaration", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeDir("ws");
      },
      async (fixture) => {
        const specs = await resolveWorkspaceSpecs({
          trustedWorkspaces: { dev: { root: path.join(fixture.root, "ws") } }
        });
        assert.equal(specs.length, 1);
        assert.equal(specs[0].alias, "dev");
        assert.equal(specs[0].maxDepth, 3, "maxDepth defaults to 3");
        assert.equal(specs[0].enabled, true);
      }
    );
  });

  it("rejects a non-object trustedWorkspaces block", () => {
    assert.throws(
      () => parseTrustedWorkspaces({ trustedWorkspaces: ["/tmp"] }),
      /WORKSPACE_CONFIG_INVALID/
    );
  });

  it("rejects an alias that is not a safe identifier", () => {
    for (const alias of ["", "has space", "../escape", "a/b", "-lead", "toolong".padEnd(41, "x")]) {
      assert.throws(
        () => parseTrustedWorkspaces({ trustedWorkspaces: { [alias]: { root: "/tmp" } } }),
        /WORKSPACE_ALIAS_INVALID/,
        `alias ${JSON.stringify(alias)} must be rejected`
      );
    }
  });

  it("rejects a relative workspace root", () => {
    assert.throws(
      () => parseTrustedWorkspaces({ trustedWorkspaces: { dev: { root: "relative/path" } } }),
      /WORKSPACE_ROOT_NOT_ABSOLUTE/
    );
  });

  it("rejects a workspace root containing a NUL byte", () => {
    assert.throws(
      () => parseTrustedWorkspaces({ trustedWorkspaces: { dev: { root: "/tmp/a\u0000b" } } }),
      /WORKSPACE_ROOT_INVALID/
    );
  });

  it("rejects an out-of-range maxDepth", () => {
    for (const maxDepth of [0, 6, 1.5, "3"]) {
      assert.throws(
        () => parseTrustedWorkspaces({ trustedWorkspaces: { dev: { root: "/tmp", maxDepth } } }),
        /WORKSPACE_MAX_DEPTH_INVALID/,
        `maxDepth ${JSON.stringify(maxDepth)} must be rejected`
      );
    }
  });

  it("rejects obviously-too-broad roots", async () => {
    for (const root of ["/", "/Users", "/System", "/private", "/tmp"]) {
      await assert.rejects(
        () => resolveWorkspaceSpecs({ trustedWorkspaces: { dev: { root } } }),
        /WORKSPACE_ROOT_FORBIDDEN/,
        `root ${root} must be rejected`
      );
    }
  });

  it("pins the scan bounds so they cannot be widened without review", () => {
    assert.ok(DEFAULT_MAX_DEPTH >= 1 && DEFAULT_MAX_DEPTH <= MAX_MAX_DEPTH);
    assert.ok(MAX_MAX_DEPTH <= 6, "the scan must never recurse deeply");
    assert.ok(MAX_REPOS_PER_WORKSPACE <= 500);
    assert.ok(MAX_DIRS_PER_WORKSPACE <= 10000);
  });

  it("rejects a workspace root that does not exist", async () => {
    await assert.rejects(
      () => resolveWorkspaceSpecs({ trustedWorkspaces: { dev: { root: "/nonexistent/lmdr-ws-xyz" } } }),
      /WORKSPACE_ROOT_NOT_FOUND/
    );
  });

  it("skips workspaces explicitly disabled", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeDir("ws");
        await fixture.makeRepo("ws/repo-a");
      },
      async (fixture) => {
        const specs = await resolveWorkspaceSpecs({
          trustedWorkspaces: { dev: { root: path.join(fixture.root, "ws"), enabled: false } }
        });
        assert.equal(specs.length, 0);
      }
    );
  });
});

describe("trusted workspace — discovery", () => {
  it("discovers a normal Git repository inside the workspace", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeRepo("ws/repo-a");
      },
      async (fixture) => {
        const { repos } = await discoverWorkspaceProjects({
          trustedWorkspaces: { dev: { root: path.join(fixture.root, "ws") } }
        });
        assert.equal(repos.length, 1);
        assert.equal(repos[0].basename, "repo-a");
        assert.equal(repos[0].relPath, "repo-a");
        assert.equal(repos[0].root, await realpath(path.join(fixture.root, "ws", "repo-a")));
      }
    );
  });

  it("does not discover a non-Git directory", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeDir("ws/not-a-repo");
      },
      async (fixture) => {
        const { repos } = await discoverWorkspaceProjects({
          trustedWorkspaces: { dev: { root: path.join(fixture.root, "ws") } }
        });
        assert.deepEqual(repos, []);
      }
    );
  });

  it("returns nothing for an empty workspace", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeDir("empty-ws");
      },
      async (fixture) => {
        const { repos } = await discoverWorkspaceProjects({
          trustedWorkspaces: { dev: { root: path.join(fixture.root, "empty-ws") } }
        });
        assert.deepEqual(repos, []);
      }
    );
  });

  it("never discovers a repository outside the workspace", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeDir("ws");
        await fixture.makeRepo("elsewhere/outside-repo");
      },
      async (fixture) => {
        const { repos } = await discoverWorkspaceProjects({
          trustedWorkspaces: { dev: { root: path.join(fixture.root, "ws") } }
        });
        assert.deepEqual(repos, []);
      }
    );
  });

  it("does not descend into a repository: nested repositories are not discovered", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeRepo("ws/outer");
        await fixture.makeRepo("ws/outer/nested");
      },
      async (fixture) => {
        const { repos } = await discoverWorkspaceProjects({
          trustedWorkspaces: { dev: { root: path.join(fixture.root, "ws") } }
        });
        assert.equal(repos.length, 1, "only the outer repository is discovered");
        assert.equal(repos[0].basename, "outer");
      }
    );
  });

  it("honours the scan depth boundary", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeRepo("ws/depth1");
        await fixture.makeRepo("ws/group/depth2");
        await fixture.makeRepo("ws/group/sub/depth3");
        await fixture.makeRepo("ws/group/sub/sub/depth4");
      },
      async (fixture) => {
        const root = path.join(fixture.root, "ws");
        const shallow = await discoverWorkspaceProjects({ trustedWorkspaces: { dev: { root, maxDepth: 2 } } });
        assert.deepEqual(shallow.repos.map((r) => r.basename), ["depth1", "depth2"]);

        resetDiscoveryCache();
        const deep = await discoverWorkspaceProjects({ trustedWorkspaces: { dev: { root, maxDepth: 4 } } });
        assert.deepEqual(
          deep.repos.map((r) => r.basename),
          ["depth1", "depth2", "depth3", "depth4"]
        );
      }
    );
  });

  it("never follows a symlink that escapes the workspace", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeDir("ws");
        await fixture.makeRepo("elsewhere/secret-repo");
        await symlink(
          path.join(fixture.root, "elsewhere", "secret-repo"),
          path.join(fixture.root, "ws", "linked-repo")
        );
      },
      async (fixture) => {
        const { repos } = await discoverWorkspaceProjects({
          trustedWorkspaces: { dev: { root: path.join(fixture.root, "ws") } }
        });
        assert.deepEqual(repos, [], "a symlinked repository outside the workspace is never discovered");
      }
    );
  });

  it("never follows a symlink that stays inside the workspace", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeRepo("ws/real-repo");
        await symlink(
          path.join(fixture.root, "ws", "real-repo"),
          path.join(fixture.root, "ws", "alias-repo")
        );
      },
      async (fixture) => {
        const { repos } = await discoverWorkspaceProjects({
          trustedWorkspaces: { dev: { root: path.join(fixture.root, "ws") } }
        });
        assert.deepEqual(
          repos.map((r) => r.basename),
          ["real-repo"],
          "the symlinked alias is not treated as a second repository"
        );
      }
    );
  });

  it("discovers the workspace root itself when it is a repository", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeRepo("ws-root");
      },
      async (fixture) => {
        const { repos } = await discoverWorkspaceProjects({
          trustedWorkspaces: { dev: { root: path.join(fixture.root, "ws-root") } }
        });
        assert.equal(repos.length, 1);
        assert.equal(repos[0].relPath, "", "the root repository has an empty relative path");
      }
    );
  });

  it("skips unreadable subdirectories instead of failing the scan", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeRepo("ws/visible-repo");
        const locked = await fixture.makeDir("ws/locked");
        await chmod(locked, 0o000);
      },
      async (fixture) => {
        try {
          const { repos } = await discoverWorkspaceProjects({
            trustedWorkspaces: { dev: { root: path.join(fixture.root, "ws") } }
          });
          assert.deepEqual(repos.map((r) => r.basename), ["visible-repo"]);
        } finally {
          await chmod(path.join(fixture.root, "ws", "locked"), 0o755).catch(() => {});
        }
      }
    );
  });

  it("de-duplicates repositories found by overlapping workspace declarations", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeRepo("ws/group/repo-x");
      },
      async (fixture) => {
        const { repos } = await discoverWorkspaceProjects({
          trustedWorkspaces: {
            wide: { root: path.join(fixture.root, "ws") },
            narrow: { root: path.join(fixture.root, "ws", "group") }
          }
        });
        assert.equal(repos.length, 1, "the same repository is exposed exactly once");
        assert.equal(repos[0].basename, "repo-x");
        assert.equal(repos[0].alias, "wide", "declaration order decides the owning alias");
      }
    );
  });
});

describe("trusted workspace — security defaults", () => {
  it("auto-discovered projects are READ_ONLY with runScripts=false", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeRepo("ws/repo-a");
      },
      async (fixture) => {
        const index = await buildDiscoveryIndex({
          projects: {},
          trustedWorkspaces: { dev: { root: path.join(fixture.root, "ws") } }
        });
        assert.equal(index.entries.length, 1);
        const entry = index.entries[0];
        assert.equal(entry.write, false, "discovery never grants write");
        assert.equal(entry.runScripts, false, "discovery never grants runScripts");
        assert.deepEqual(entry.allowedScripts, []);
        assert.equal(entry.managedWorktree, false);
        assert.equal(entry.packageManager, null);
      }
    );
  });

  it("ignores any attempt to raise discovery defaults from configuration", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeRepo("ws/repo-a");
      },
      async (fixture) => {
        const index = await buildDiscoveryIndex({
          projects: {},
          trustedWorkspaces: {
            dev: {
              root: path.join(fixture.root, "ws"),
              // Hostile / mistaken fields: discovery must not honour them.
              write: true,
              runScripts: true,
              defaultWrite: true,
              allowedScripts: ["build"]
            }
          }
        });
        const entry = index.entries[0];
        assert.equal(entry.write, false);
        assert.equal(entry.runScripts, false);
        assert.deepEqual(entry.allowedScripts, []);
      }
    );
  });
});

describe("trusted workspace — naming and collisions", () => {
  it("exposes the short name when it is globally unique", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeRepo("ws/api");
      },
      async (fixture) => {
        const index = await buildDiscoveryIndex({
          projects: {},
          trustedWorkspaces: { wsA: { root: path.join(fixture.root, "ws") } }
        });
        assert.deepEqual(index.entries.map((e) => e.name), ["api"]);
        assert.deepEqual(index.entries[0].id, "wsA/api");
        assert.equal(resolveDiscoveredProject(index, "api").found, true);
        assert.equal(resolveDiscoveredProject(index, "wsA/api").found, true,
          "the stable id also resolves");
      }
    );
  });

  it("exposes stable ids and reports ambiguity when two repositories share a basename", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeRepo("wsA/api");
        await fixture.makeRepo("wsB/api");
      },
      async (fixture) => {
        const index = await buildDiscoveryIndex({
          projects: {},
          trustedWorkspaces: {
            wsA: { root: path.join(fixture.root, "wsA") },
            wsB: { root: path.join(fixture.root, "wsB") }
          }
        });

        assert.deepEqual(index.entries.map((e) => e.name), ["wsA/api", "wsB/api"]);

        // The bare name must not silently pick one of them.
        const bare = resolveDiscoveredProject(index, "api");
        assert.ok(!bare.found, "an ambiguous name never resolves to a repository");
        assert.equal(bare.ambiguous, true);
        assert.deepEqual(bare.candidates, ["wsA/api", "wsB/api"]);

        // Fully qualified ids stay unambiguous.
        assert.equal(resolveDiscoveredProject(index, "wsA/api").project.id, "wsA/api");
        assert.equal(resolveDiscoveredProject(index, "wsB/api").project.id, "wsB/api");
      }
    );
  });

  it("distinguishes same-basename repositories nested at different paths", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeRepo("ws/services/api");
        await fixture.makeRepo("ws/apps/api");
      },
      async (fixture) => {
        const index = await buildDiscoveryIndex({
          projects: {},
          trustedWorkspaces: { wsA: { root: path.join(fixture.root, "ws") } }
        });
        assert.deepEqual(index.entries.map((e) => e.name), ["wsA/apps/api", "wsA/services/api"]);
        assert.equal(resolveDiscoveredProject(index, "api").ambiguous, true);
      }
    );
  });

  it("lets an explicit project take the short name; discovery falls back to its id", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeRepo("ws/api");
      },
      async (fixture) => {
        const index = await buildDiscoveryIndex({
          projects: { api: { root: await fixture.makeDir("explicit-api"), write: true } },
          trustedWorkspaces: { wsA: { root: path.join(fixture.root, "ws") } }
        });
        assert.deepEqual(
          index.entries.map((e) => e.name),
          ["wsA/api"],
          "the discovered repository does not steal the explicit project's name"
        );
        assert.equal(index.byName.has("api"), false, "explicit entries are never shadowed");
      }
    );
  });

  it("keeps a repository reachable when its stable id is claimed by an explicit project", async () => {
    await withWorkspace(
      async (fixture) => {
        await fixture.makeRepo("ws/api");
      },
      async (fixture) => {
        const index = await buildDiscoveryIndex({
          projects: { "wsA/api": { root: await fixture.makeDir("explicit-api"), write: true } },
          trustedWorkspaces: { wsA: { root: path.join(fixture.root, "ws") } }
        });
        assert.deepEqual(
          index.entries.map((e) => e.name),
          ["api"],
          "it falls back to its short name rather than stealing the explicit entry's name"
        );
        assert.equal(index.byName.has("wsA/api"), false, "the explicit project keeps its own name");
        assert.equal(resolveDiscoveredProject(index, "api").project.id, "wsA/api");
      }
    );
  });

  it("produces a deterministic, sorted set of names", async () => {
    await withWorkspace(
      async (fixture) => {
        for (const name of ["zeta", "alpha", "mid"]) {
          await fixture.makeRepo(`ws/${name}`);
        }
      },
      async (fixture) => {
        const registry = {
          projects: {},
          trustedWorkspaces: { wsA: { root: path.join(fixture.root, "ws") } }
        };
        const first = await buildDiscoveryIndex(registry);
        resetDiscoveryCache();
        const second = await buildDiscoveryIndex(registry);
        assert.deepEqual(
          first.entries.map((e) => e.name),
          ["alpha", "mid", "zeta"]
        );
        assert.deepEqual(first.entries, second.entries, "discovery is stable across runs");
      }
    );
  });
});
