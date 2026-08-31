/**
 * Git filter / Git LFS false-positive regression gate.
 *
 * Background
 * ----------
 * `git lfs install` writes a [filter "lfs"] driver into the USER's global
 * .gitconfig. That is global state, not repository state. A driver sitting in
 * ~/.gitconfig does nothing on its own: it only runs when an *attributes* rule
 * actually assigns it to a path.
 *
 * An earlier version of this runner inspected git config, saw the LFS driver and
 * refused every checkout. That is the false positive pinned here: a globally
 * installed Git LFS with no applicable attributes rule must NOT block a checkout.
 *
 * The guard is still required to fire when a filter really would run, so each
 * false-positive case below is paired with a positive control.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { stat } from "node:fs/promises";
import path from "node:path";
import {
  BASE_GITCONFIG,
  assertDenied,
  assertOk,
  withFixtureAndRunner
} from "../support/harness.mjs";

/** Exactly what `git lfs install` puts into the user's global config. */
const GIT_LFS_GLOBAL_CONFIG = [
  BASE_GITCONFIG,
  '[filter "lfs"]',
  "\tclean = git-lfs clean -- %f",
  "\tsmudge = git-lfs smudge -- %f",
  "\tprocess = git-lfs filter-process",
  "\trequired = true",
  ""
].join("\n");

const LFS_ATTRIBUTES = "*.psd filter=lfs diff=lfs merge=lfs -text\n";
const COMMENT_ONLY_ATTRIBUTES = [
  "# assets are handled elsewhere",
  "# *.psd filter=lfs diff=lfs merge=lfs -text",
  ""
].join("\n");
const BENIGN_ATTRIBUTES = "*.js text eol=lf\n";

describe("false positive: Git LFS installed globally, no filter applied", () => {
  it("still creates a managed worktree", async () => {
    await withFixtureAndRunner(
      { globalGitConfig: GIT_LFS_GLOBAL_CONFIG },
      async (client, fixture) => {
        const created = assertOk(
          await client.callTool({
            name: "git_worktree_create",
            arguments: { project: "fixture-source", branch: "mcp/lfs-global-only" }
          })
        );

        assert.equal(created.branch, "mcp/lfs-global-only");
        const info = await stat(path.join(fixture.worktreeBase, created.project));
        assert.equal(info.isDirectory(), true);
      }
    );
  });

  it("does not block when the repository .gitattributes mentions filter only in a comment", async () => {
    await withFixtureAndRunner(
      {
        globalGitConfig: GIT_LFS_GLOBAL_CONFIG,
        sourceFiles: [[".gitattributes", COMMENT_ONLY_ATTRIBUTES]]
      },
      async (client) => {
        const created = assertOk(
          await client.callTool({
            name: "git_worktree_create",
            arguments: { project: "fixture-source", branch: "mcp/lfs-comment-only" }
          })
        );
        assert.equal(created.branch, "mcp/lfs-comment-only");
      }
    );
  });

  it("does not block when the repository .gitattributes is benign", async () => {
    await withFixtureAndRunner(
      {
        globalGitConfig: GIT_LFS_GLOBAL_CONFIG,
        sourceFiles: [[".gitattributes", BENIGN_ATTRIBUTES]]
      },
      async (client) => {
        const created = assertOk(
          await client.callTool({
            name: "git_worktree_create",
            arguments: { project: "fixture-source", branch: "mcp/lfs-benign-attrs" }
          })
        );
        assert.equal(created.branch, "mcp/lfs-benign-attrs");
      }
    );
  });
});

describe("positive control: a filter that really would run", () => {
  it("blocks checkout when the repository .gitattributes assigns a filter", async () => {
    await withFixtureAndRunner(
      { sourceFiles: [[".gitattributes", LFS_ATTRIBUTES]] },
      async (client) => {
        const result = await client.callTool({
          name: "git_worktree_create",
          arguments: { project: "fixture-source", branch: "mcp/lfs-real-filter" }
        });
        assertDenied(result, /Git filter/);
      }
    );
  });

  it("blocks checkout when core.attributesFile assigns a filter", async () => {
    await withFixtureAndRunner(
      {
        rootFiles: [["attrs/global-attributes", LFS_ATTRIBUTES]],
        globalGitConfig: [
          BASE_GITCONFIG,
          "[core]",
          "\tattributesfile = {{ROOT}}/attrs/global-attributes",
          ""
        ].join("\n")
      },
      async (client) => {
        const result = await client.callTool({
          name: "git_worktree_create",
          arguments: { project: "fixture-source", branch: "mcp/lfs-core-attrs" }
        });
        assertDenied(result, /core\.attributesFile/);
      }
    );
  });

  it("blocks checkout when the user's XDG git attributes assign a filter", async () => {
    await withFixtureAndRunner(
      {
        rootFiles: [["home/.config/git/attributes", LFS_ATTRIBUTES]]
      },
      async (client) => {
        const result = await client.callTool({
          name: "git_worktree_create",
          arguments: { project: "fixture-source", branch: "mcp/lfs-xdg-attrs" }
        });
        assertDenied(result, /Git filter/);
      }
    );
  });
});
