/**
 * P2 native process lifecycle and descendant reaping.
 *
 * When a script times out, the runner SIGTERM/SIGKILLs the whole process group.
 * A grandchild spawned in the SAME group (no detached:true) must be reaped too.
 * The backend reports descendantsRemaining=false once the group is gone.
 */

import { describe, it, before } from "node:test";
import assert from "node:assert/strict";
import { makeWorld, runNode } from "./_helpers.mjs";

describe("P2 native process lifecycle and descendant reaping", () => {
  let world;
  before(async () => {
    world = await makeWorld();
    const avail = await world.backend.isAvailable();
    assert.ok(avail.available, `sandbox backend must be available: ${JSON.stringify(avail.failures)}`);
  });

  it("reaps the process group (including a grandchild) on timeout", async () => {
    // Spawn a long-running grandchild in the SAME process group (no detached),
    // then keep the main script alive until the runner's timeout fires.
    const code = [
      "process.stdout.write('STARTED;');",
      "const cp=require('child_process');",
      "cp.spawn('sleep',['60'],{stdio:'ignore'});",
      "setInterval(()=>{},1000);"
    ].join("");
    const result = await runNode(world, code, 1500);
    assert.match(result.stdout, /STARTED/, "parent target must have started before the timeout fired");
    assert.equal(result.timedOut, true, `expected a timeout, got exitCode=${result.exitCode}`);
    // The group must be torn down by a real signal (not a clean exit): the
    // runner preserves `signal` even when exit code is normalized to -1.
    assert.ok(
      ["SIGTERM", "SIGKILL"].includes(result.signal),
      `process group must be killed by a signal, got signal=${result.signal} exitCode=${result.exitCode}`
    );
    assert.equal(
      result.descendantsRemaining,
      false,
      "the grandchild sleep must have been reaped together with the group"
    );
  });

  it("spawns a child with stdio:'ignore' without EPERM (F4 /dev/null write allow)", async () => {
    // The sandboxed node spawns a grandchild whose stdio is redirected to
    // /dev/null. Without the (allow file-write* (literal "/dev/null")) rule the
    // inner spawn fails with EPERM and never runs. Prove the grandchild starts
    // and exits 0 (TARGET_RAN_AND_OPERATION_ALLOWED), not a spawn error.
    const code = [
      "process.stdout.write('STARTED;');",
      "const cp=require('child_process');",
      "const child=cp.spawn(process.execPath,['-e','process.exit(0)'],[stdio:'ignore']);",
      "child.on('error',(e)=>{process.stdout.write('SPAWN_ERR:'+e.code);process.exit(7)});",
      "child.on('exit',(c)=>process.exit(c===0?0:6));"
    ].join("");
    const result = await runNode(world, code, 15000);
    assert.match(result.stdout, /STARTED/, "parent target must have started");
    assert.equal(result.exitCode, 0, `stdio:'ignore' child must spawn and exit 0, stderr=${result.stderr}`);
    assert.doesNotMatch(result.stdout, /SPAWN_ERR/, "inner spawn must not fail with EPERM");
  });
});
