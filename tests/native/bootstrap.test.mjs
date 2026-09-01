/**
 * P2 native bootstrap: prove the sandbox backend is actually available on this
 * host and that it generates a deny-by-default, network-denied SBPL profile.
 *
 * On a nested sandbox (WorkBuddy) the availability assertion fails -- that is
 * the intended fail-closed signal, not a test bug.
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import { makeWorld } from "./_helpers.mjs";
import { canonicalizePath } from "../../scripts/sandbox-backend-sandbox-exec.mjs";

describe("P2 native bootstrap", () => {
  let world;
  before(async () => {
    world = await makeWorld();
    const avail = await world.backend.isAvailable();
    assert.ok(
      avail.available,
      `sandbox backend must be available in a native Terminal (not nested): ${JSON.stringify(avail.failures)}`
    );
  });

  it("generates a deny-by-default, network-denied SBPL profile", () => {
    const profile = world.backend.generateProfile(world.context);
    assert.ok(profile.includes("(version 1)"), "profile must be SBPL v1");
    assert.ok(profile.includes("(deny default)"), "profile must deny by default");
    assert.ok(profile.includes("(deny network*)"), "profile must deny all network access");
    assert.ok(profile.includes("process-exec*"), "profile must constrain process execution");
  });

  it("grants root read-traversal but keeps sensitive paths denied (path-traversal fix)", () => {
    const profile = world.backend.generateProfile(world.context);
    const rootAllow = profile.indexOf(`(allow file-read* (subpath "/"))`);
    // The profile emits canonical paths (realpathSync), but makeWorld hands us
    // the symlink form (/var/...). Canonicalize before matching so the static
    // assert checks the SAME string the profile actually emits. This is a test
    // fix only -- it must NOT relax the deny policy itself.
    const cRealHome = canonicalizePath(world.realHome);
    const cRuntimeRoot = canonicalizePath(world.runtimeRoot);
    const realHomeDeny = profile.indexOf(`(deny file-read-data (subpath "${cRealHome}"))`);
    const runtimeDeny = profile.indexOf(`(deny file-read-data (subpath "${cRuntimeRoot}"))`);
    assert.ok(rootAllow >= 0, "profile must grant root read-traversal (fixes bootstrap SIGABRT)");
    // First-match-wins: the broad root allow must come AFTER the sensitive denies.
    assert.ok(realHomeDeny >= 0 && realHomeDeny < rootAllow, "real home must stay denied before root allow");
    assert.ok(runtimeDeny >= 0 && runtimeDeny < rootAllow, "runtime root must stay denied before root allow");
    assert.ok(profile.includes(`(deny process-exec* (literal "/usr/bin/git"))`), "dangerous executables denied via literal");
    assert.ok(!profile.includes(`(subpath "/usr/bin/git ")`), "dead trailing-space exec deny must be gone");
  });
});
