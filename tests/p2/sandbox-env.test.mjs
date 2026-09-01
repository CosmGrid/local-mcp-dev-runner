/**
 * P2 unit tests: sandbox-env (allowlist-only environment construction).
 * Verifies the parent env is never spread wholesale, credential-shaped keys are
 * dropped, HOME/TMPDIR are redirected, and user-local PATH entries are dropped.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  buildSandboxEnv,
  filterEnvironment,
  buildSandboxPath,
  isSystemPath
} from "../../scripts/sandbox-env.mjs";

describe("buildSandboxEnv", () => {
  const input = {
    parentEnv: { HOME: "/real", LANG: "en_US.UTF-8", MY_SECRET_TOKEN: "x", PATH: "/usr/bin:/home/me/bin" },
    homeRoot: "/run/home",
    tmpRoot: "/run/tmp",
    worktreeRoot: "/run/wt",
    nodeBinDirs: ["/opt/node/bin"]
  };
  const env = buildSandboxEnv(input);

  it("never spreads the parent env wholesale", () => {
    assert.equal(env.MY_SECRET_TOKEN, undefined);
  });
  it("redirects HOME/TMPDIR to the per-run scratch dirs", () => {
    assert.equal(env.HOME, "/run/home");
    assert.equal(env.TMPDIR, "/run/tmp");
    assert.equal(env.PWD, "/run/wt");
  });
  it("keeps allowlisted keys", () => {
    assert.equal(env.LANG, "en_US.UTF-8");
  });
  it("forbids credential-shaped keys via the denylist", () => {
    // The denylist is \b-anchored, so whole-word secret/token keys are dropped.
    // (Underscore-joined names like AWS_SECRET are handled by the allowlist gatekeeper,
    // not by this defence-in-depth filter.)
    const e = filterEnvironment({ secret: "x", PATH: "/bin" });
    assert.equal(e.secret, undefined);
    const e2 = filterEnvironment({ npm_config_fund: "false" });
    assert.equal(e2.npm_config_fund, "false", "npm_config_fund is an explicit allowlist exception");
  });
});

describe("buildSandboxPath / isSystemPath", () => {
  it("drops user-local PATH entries", () => {
    const p = buildSandboxPath({
      worktreeRoot: "/w",
      nodeBinDirs: ["/opt/node/bin"],
      parentPath: "/usr/bin:/home/me/.local/bin"
    });
    assert.ok(p.includes("/opt/node/bin"));
    assert.ok(p.includes("/usr/bin"));
    assert.ok(!p.includes("/home/me/.local/bin"), "user-local entries must be dropped");
  });
  it("isSystemPath accepts /usr/* /bin /sbin /opt/homebrew /usr/local", () => {
    assert.equal(isSystemPath("/usr/bin"), true);
    assert.equal(isSystemPath("/opt/homebrew/bin"), true);
    assert.equal(isSystemPath("/home/me/bin"), false);
  });
});
