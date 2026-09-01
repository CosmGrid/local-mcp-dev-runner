/**
 * P2 native executable allow/deny (SBPL rule order).
 *
 * /bin/echo lives under /bin (an allowed exec path) and is not on the denied
 * list, so it must run. /usr/bin/curl also lives under /usr/bin (allowed path)
 * but is explicitly denied by a literal rule. Both match an allow AND a deny
 * rule; which one wins is decided by EXEC_RULE_ORDER. The native OS is the
 * authority: this test proves the deny wins. If curl ever runs (exit 0 with
 * "curl" output), the constant must be flipped -- never the profile widened.
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import { makeWorld } from "./_helpers.mjs";

describe("P2 native executable allow/deny (SBPL rule order)", () => {
  let world;
  before(async () => {
    world = await makeWorld();
    const avail = await world.backend.isAvailable();
    assert.ok(avail.available, `sandbox backend must be available: ${JSON.stringify(avail.failures)}`);
  });

  it("allows an allowed executable (/bin/echo)", async () => {
    const result = await world.backend.execute({
      context: world.context,
      executable: "/bin/echo",
      args: ["sandbox-allow-ok"],
      env: world.env,
      cwd: world.worktreeRoot,
      timeoutMs: 15000
    });
    assert.equal(result.exitCode, 0, `expected /bin/echo to run, stderr=${result.stderr}`);
    assert.match(result.stdout, /sandbox-allow-ok/);
  });

  it("denies a dangerous executable (/usr/bin/curl) -- proves deny wins over allow-path", async () => {
    const result = await world.backend.execute({
      context: world.context,
      executable: "/usr/bin/curl",
      args: ["--version"],
      env: world.env,
      cwd: world.worktreeRoot,
      timeoutMs: 15000
    });
    // curl's exec is denied by the literal SBPL rule, so the curl process never
    // starts (TARGET_NEVER_RAN): it cannot print its version banner and exits
    // non-zero. This is distinct from network/fs denies where the target node
    // starts and the operation is refused inside it.
    assert.notEqual(result.exitCode, 0, "curl must be denied by the sandbox exec policy (TARGET_NEVER_RAN)");
    assert.doesNotMatch(result.stdout, /curl/i, "curl must not have executed (no version banner)");
  });
});
