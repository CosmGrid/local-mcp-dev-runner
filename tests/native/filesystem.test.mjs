/**
 * P2 native filesystem isolation: a sandboxed process may write only inside the
 * declared write paths (worktree / per-run HOME / per-run TMP). Everything else
 * -- including the real /tmp and the sealed "real home" -- is denied.
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import { makeWorld, runNode } from "./_helpers.mjs";

describe("P2 native filesystem isolation", () => {
  let world;
  before(async () => {
    world = await makeWorld();
    const avail = await world.backend.isAvailable();
    assert.ok(avail.available, `sandbox backend must be available: ${JSON.stringify(avail.failures)}`);
  });

  it("allows writing inside the per-run sandbox HOME", async () => {
    const result = await runNode(world, "require('fs').writeFileSync(process.env.HOME + '/ok.txt','x'); process.stdout.write('WROTE')");
    assert.equal(result.exitCode, 0, `expected success, stderr=${result.stderr}`);
    assert.match(result.stdout, /WROTE/);
  });

  it("denies writing to real /tmp (outside allowed paths)", async () => {
    const result = await runNode(
      world,
      "try{require('fs').writeFileSync('/tmp/lmdr-escape-test.txt','x');process.stdout.write('ESCAPED')}catch(e){process.stdout.write('DENIED')}"
    );
    assert.equal(result.exitCode, 0, "the guard must catch the error (process still exits 0)");
    assert.match(result.stdout, /DENIED/);
    assert.doesNotMatch(result.stdout, /ESCAPED/);
  });

  it("denies writing into the sealed real home directory", async () => {
    const target = world.realHome + "/lmdr-escape.txt";
    const result = await runNode(
      world,
      `try{require('fs').writeFileSync(${JSON.stringify(target)},'x');process.stdout.write('ESCAPED')}catch(e){process.stdout.write('DENIED')}`
    );
    assert.equal(result.exitCode, 0);
    assert.match(result.stdout, /DENIED/);
    assert.doesNotMatch(result.stdout, /ESCAPED/);
  });
});
