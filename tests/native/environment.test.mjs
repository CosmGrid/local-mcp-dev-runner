/**
 * P2 native environment isolation: a credential-shaped variable present in the
 * parent environment must NOT reach the sandboxed process. HOME/TMPDIR must be
 * redirected to the per-run scratch directories.
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import { makeWorld } from "./_helpers.mjs";
import { buildSandboxEnv } from "../../scripts/sandbox-env.mjs";

describe("P2 native environment isolation", () => {
  let world;
  before(async () => {
    world = await makeWorld();
    const avail = await world.backend.isAvailable();
    assert.ok(avail.available, `sandbox backend must be available: ${JSON.stringify(avail.failures)}`);
  });

  it("target node starts and exits 0 under the sandbox (bootstrap fix)", async () => {
    const result = await world.backend.execute({
      context: world.context,
      executable: process.execPath,
      args: ["-e", "process.stdout.write('STARTED')"],
      env: world.env,
      cwd: world.worktreeRoot,
      timeoutMs: 15000
    });
    assert.equal(result.exitCode, 0, `node must start under the sandbox, stderr=${result.stderr}`);
    assert.match(result.stdout, /STARTED/, "target must reach main() -- proves the SIGABRT bootstrap is fixed");
  });

  it("does not leak credential-shaped parent variables into the sandbox (filtered at buildSandboxEnv)", async () => {
    // F1 fix: dirty the PARENT env, THEN build the sandbox env from it. The
    // allowlist + filterEnvironment must strip these keys. The previous test
    // spread the secrets onto the already-built env, which bypassed the filter
    // and thus never exercised the real protection -- that was the test bug.
    const secret = "supersecret-value-12345";
    const parentEnv = {
      ...process.env,
      HOME: world.realHome,
      OPENAI_API_KEY: secret,
      AWS_SECRET_ACCESS_KEY: secret,
      GITHUB_TOKEN: secret,
      MY_API_TOKEN: secret
    };
    const env = buildSandboxEnv({
      parentEnv,
      homeRoot: world.homeRoot,
      tmpRoot: world.tmpRoot,
      worktreeRoot: world.worktreeRoot,
      nodeBinDirs: world.nodeBinDirs
    });
    const result = await world.backend.execute({
      context: world.context,
      executable: process.execPath,
      args: [
        "-e",
        "process.stdout.write((process.env.OPENAI_API_KEY||'U')+(process.env.AWS_SECRET_ACCESS_KEY||'U')+(process.env.GITHUB_TOKEN||'U')+(process.env.MY_API_TOKEN||'U'))"
      ],
      env,
      cwd: world.worktreeRoot,
      timeoutMs: 15000
    });
    assert.equal(result.exitCode, 0);
    assert.equal(result.stdout.trim(), "UUUU", "all credential-shaped keys must be filtered out by buildSandboxEnv");
  });

  it("filters *_KEY / *_SECRET / *_TOKEN shaped keys from the parent env", async () => {
    const secret = "x".repeat(24);
    const parentEnv = {
      ...process.env,
      HOME: world.realHome,
      DEPLOY_KEY: secret,
      DB_SECRET: secret,
      CI_TOKEN: secret,
      NPM_TOKEN: secret
    };
    const env = buildSandboxEnv({
      parentEnv,
      homeRoot: world.homeRoot,
      tmpRoot: world.tmpRoot,
      worktreeRoot: world.worktreeRoot,
      nodeBinDirs: world.nodeBinDirs
    });
    const result = await world.backend.execute({
      context: world.context,
      executable: process.execPath,
      args: [
        "-e",
        "process.stdout.write((process.env.DEPLOY_KEY||'U')+(process.env.DB_SECRET||'U')+(process.env.CI_TOKEN||'U')+(process.env.NPM_TOKEN||'U'))"
      ],
      env,
      cwd: world.worktreeRoot,
      timeoutMs: 15000
    });
    assert.equal(result.exitCode, 0);
    assert.equal(result.stdout.trim(), "UUUU", "*_KEY/*_SECRET/*_TOKEN must be filtered out");
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
