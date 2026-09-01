/**
 * P2 native environment isolation: a credential-shaped variable present in the
 * parent environment must NOT reach the sandboxed process. HOME/TMPDIR must be
 * redirected to the per-run scratch directories.
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import { makeWorld } from "./_helpers.mjs";

describe("P2 native environment isolation", () => {
  let world;
  before(async () => {
    world = await makeWorld();
    const avail = await world.backend.isAvailable();
    assert.ok(avail.available, `sandbox backend must be available: ${JSON.stringify(avail.failures)}`);
  });

  it("does not leak a credential-shaped parent variable into the sandbox", async () => {
    const secret = "supersecret-value-12345";
    const env = { ...world.env, MY_API_TOKEN: secret, AWS_SECRET_ACCESS_KEY: secret };
    const result = await world.backend.execute({
      context: world.context,
      executable: process.execPath,
      args: ["-e", "process.stdout.write(process.env.MY_API_TOKEN || 'UNSET')"],
      env,
      cwd: world.worktreeRoot,
      timeoutMs: 15000
    });
    assert.equal(result.exitCode, 0);
    assert.equal(result.stdout.trim(), "UNSET", "credential must not leak into the sandboxed process");
  });

  it("redirects HOME/TMPDIR to the per-run scratch directories", async () => {
    const result = await world.backend.execute({
      context: world.context,
      executable: process.execPath,
      args: ["-e", "process.stdout.write(process.env.HOME + '\\n' + process.env.TMPDIR)"],
      env: world.env,
      cwd: world.worktreeRoot,
      timeoutMs: 15000
    });
    assert.equal(result.exitCode, 0);
    assert.equal(result.stdout.trim(), `${world.homeRoot}\n${world.tmpRoot}`);
  });
});
