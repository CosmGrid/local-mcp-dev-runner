/**
 * P2 native network isolation: under network:none, even a localhost/DNS-bound
 * outbound connection must be refused by the sandbox.
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import { makeWorld, runNode } from "./_helpers.mjs";

describe("P2 native network isolation", () => {
  let world;
  before(async () => {
    world = await makeWorld();
    const avail = await world.backend.isAvailable();
    assert.ok(avail.available, `sandbox backend must be available: ${JSON.stringify(avail.failures)}`);
  });

  it("denies outbound network connections (network:none)", async () => {
    const code = [
      "const net=require('net');",
      "const s=net.connect(443,'example.com',()=>process.exit(0));",
      "s.on('error',()=>process.exit(3));",
      "s.setTimeout(3000,()=>process.exit(2));"
    ].join("");
    const result = await runNode(world, code, 15000);
    assert.notEqual(result.exitCode, 0, "outbound connect must be denied by the sandbox");
  });
});
