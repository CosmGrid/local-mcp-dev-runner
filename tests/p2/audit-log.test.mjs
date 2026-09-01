/**
 * P2 unit tests: audit-log (fail-closed metadata-only log, mode 0600).
 * Verifies forbidden fields are stripped and that a non-writable target fails
 * closed with AUDIT_LOG_INIT_FAILED.
 */

import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import fs from "node:fs/promises";
import { mkdtemp, rm, readFile, mkdir, chmod } from "node:fs/promises";
import { openAuditLog, serialize, AUDIT_LOG_MODE } from "../../scripts/audit-log.mjs";

describe("audit-log serialize", () => {
  it("strips forbidden fields (stdout/stderr/env/command/args)", () => {
    const rec = serialize({ project: "p", script: "t", stdout: "secret", env: { a: 1 }, command: "rm -rf", args: ["x"] });
    assert.equal(rec.stdout, undefined);
    assert.equal(rec.env, undefined);
    assert.equal(rec.command, undefined);
    assert.equal(rec.args, undefined);
    assert.equal(rec.project, "p");
  });
  it("fills core fields with null when absent", () => {
    const rec = serialize({});
    assert.equal(rec.decision, null);
    assert.equal(rec.exitCode, null);
  });
});

describe("audit-log openAuditLog", () => {
  let dir;
  after(async () => {
    if (dir) await rm(dir, { recursive: true, force: true });
  });
  it("opens a 0600 log and writes metadata only", async () => {
    dir = await mkdtemp(path.join(os.tmpdir(), "lmdr-audit-"));
    const log = await openAuditLog(dir);
    await log.write({ project: "p", script: "t", decision: "EXECUTED", stdout: "should-be-dropped", exitCode: 0 });
    await log.close();
    const stat = await fs.stat(path.join(dir, "logs", "run-script.log"));
    assert.equal((stat.mode & 0o777).toString(8), AUDIT_LOG_MODE.toString(8));
    const content = await readFile(path.join(dir, "logs", "run-script.log"), "utf8");
    assert.doesNotMatch(content, /should-be-dropped/);
    assert.match(content, /"decision":"EXECUTED"/);
  });
  it("throws with AUDIT_LOG_INIT_FAILED when the target is not writable", async () => {
    const badDir = path.join(os.tmpdir(), `lmdr-noexist-${process.pid}-${Date.now()}`);
    await mkdir(badDir, { recursive: true });
    await chmod(badDir, 0o555);
    try {
      await assert.rejects(() => openAuditLog(badDir), /AUDIT_LOG_INIT_FAILED/);
    } finally {
      await chmod(badDir, 0o755).catch(() => {});
      await rm(badDir, { recursive: true, force: true });
    }
  });
});
