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
});
