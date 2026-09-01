/**
 * P2 native filesystem isolation: a sandboxed process may write only inside the
 * declared write paths (worktree / per-run HOME / per-run TMP). Everything else
 * -- including the real /tmp and the sealed "real home" -- is denied.
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { makeWorld, runNode } from "./_helpers.mjs";

describe("P2 native filesystem isolation", () => {
  let world;
  before(async () => {
    world = await makeWorld();
    const avail = await world.backend.isAvailable();
    assert.ok(avail.available, `sandbox backend must be available: ${JSON.stringify(avail.failures)}`);
  });

  it("allows writing inside the per-run sandbox HOME", async () => {
    const result = await runNode(world, "process.stdout.write('STARTED;');require('fs').writeFileSync(process.env.HOME + '/ok.txt','x'); process.stdout.write('WROTE')");
    assert.equal(result.exitCode, 0, `expected success, stderr=${result.stderr}`);
    assert.match(result.stdout, /STARTED/);
    assert.match(result.stdout, /WROTE/);
  });

  it("denies writing to real /tmp (outside allowed paths)", async () => {
    const result = await runNode(
      world,
      "process.stdout.write('STARTED;');try{require('fs').writeFileSync('/tmp/lmdr-escape-test.txt','x');process.stdout.write('ESCAPED')}catch(e){process.stdout.write('DENIED')}"
    );
    assert.equal(result.exitCode, 0, "the guard must catch the error (process still exits 0)");
    assert.match(result.stdout, /STARTED/, "target node must have started (not crashed at bootstrap)");
    assert.match(result.stdout, /DENIED/);
    assert.doesNotMatch(result.stdout, /ESCAPED/);
  });

  it("denies writing to the canonical /private/tmp path (not via the /tmp symlink)", async () => {
    const result = await runNode(
      world,
      "process.stdout.write('STARTED;');try{require('fs').writeFileSync('/private/tmp/lmdr-escape-test.txt','x');process.stdout.write('ESCAPED')}catch(e){process.stdout.write('DENIED')}"
    );
    assert.equal(result.exitCode, 0);
    assert.match(result.stdout, /STARTED/, "target node must have started");
    assert.match(result.stdout, /DENIED/);
    assert.doesNotMatch(result.stdout, /ESCAPED/);
  });

  it("denies writing into the sealed real home directory", async () => {
    const target = world.realHome + "/lmdr-escape.txt";
    const result = await runNode(
      world,
      `process.stdout.write('STARTED;');try{require('fs').writeFileSync(${JSON.stringify(target)},'x');process.stdout.write('ESCAPED')}catch(e){process.stdout.write('DENIED')}`
    );
    assert.equal(result.exitCode, 0);
    assert.match(result.stdout, /STARTED/);
    assert.match(result.stdout, /DENIED/);
    assert.doesNotMatch(result.stdout, /ESCAPED/);
  });

  it("denies writing the runtime protected config (projects.json)", async () => {
    const target = world.runtimeRoot + "/projects.json";
    const result = await runNode(
      world,
      `process.stdout.write('STARTED;');try{require('fs').writeFileSync(${JSON.stringify(target)},'x');process.stdout.write('ESCAPED')}catch(e){process.stdout.write('DENIED')}`
    );
    assert.equal(result.exitCode, 0);
    assert.match(result.stdout, /STARTED/);
    assert.match(result.stdout, /DENIED/);
    assert.doesNotMatch(result.stdout, /ESCAPED/);
  });

  it("denies reading the runtime protected config even after root read-traversal", async () => {
    // Create the secret from the parent (outside the sandbox), then prove the
    // sandboxed node cannot read it even though / is now readable for the loader.
    const target = world.runtimeRoot + "/projects.json";
    await fs.writeFile(target, "RUNTIME_SECRET", { mode: 0o600 });
    const result = await runNode(
      world,
      `process.stdout.write('STARTED;');try{const d=require('fs').readFileSync(${JSON.stringify(target)},'utf8');process.stdout.write('LEAKED:'+d)}catch(e){process.stdout.write('DENIED')}`
    );
    assert.equal(result.exitCode, 0);
    assert.match(result.stdout, /STARTED/, "target node must have started");
    assert.match(result.stdout, /DENIED/);
    assert.doesNotMatch(result.stdout, /LEAKED/);
  });
});
