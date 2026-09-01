/**
 * Script execution gate (v2.0 — sandboxed run_script).
 *
 * run_script is no longer a permanent deny. It executes only when a sandbox
 * backend is available and the request passes every policy check. In this test
 * environment (WorkBuddy / nested sandbox) the macOS seatbelt backend reports
 * itself unavailable, so every execution is refused with SANDBOX_BACKEND_UNAVAILABLE
 * before any script could run. That is the correct fail-closed posture — not a
 * regression.
 *
 * The only gate that can actually run a script (gate:sandbox-real) must be
 * executed by the user in a native macOS Terminal.app.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { assertDenied, assertOk, withFixtureAndRunner } from "../support/harness.mjs";

const PACKAGE_JSON =
  JSON.stringify(
    {
      name: "fixture-source",
      version: "1.0.0",
      scripts: {
        test: "echo should-never-run",
        build: "echo should-never-run"
      }
    },
    null,
    2
  ) + "\n";

// packageManager is derived from the lockfile, so the fixture needs one for npm to be detected.
const LOCKFILE = JSON.stringify({ name: "fixture-source", lockfileVersion: 3 }, null, 2) + "\n";

const withManifest = {
  sourceFiles: [
    ["package.json", PACKAGE_JSON],
    ["package-lock.json", LOCKFILE]
  ]
};

describe("run_script policy deny", () => {
  it("refuses run_script when no sandbox backend is available (fail-closed)", async () => {
    await withFixtureAndRunner(withManifest, async (client) => {
      const result = await client.callTool({
        name: "run_script",
        arguments: { project: "fixture-source", script: "test" }
      });
      assertDenied(result, /SANDBOX_BACKEND_UNAVAILABLE/);
    });
  });

  it("refuses run_script for a script that is not in the manifest either", async () => {
    await withFixtureAndRunner(withManifest, async (client) => {
      const result = await client.callTool({
        name: "run_script",
        arguments: { project: "fixture-source", script: "totally-unknown-script" }
      });
      assertDenied(result, /(SANDBOX_BACKEND_UNAVAILABLE|SCRIPT_NOT_ALLOWLISTED)/);
    });
  });

  it("refuses run_script for a destructive command without ever reaching a shell", async () => {
    await withFixtureAndRunner(withManifest, async (client) => {
      const result = await client.callTool({
        name: "run_script",
        arguments: { project: "fixture-source", script: "rm -rf /" }
      });
      assertDenied(result, /(SANDBOX_BACKEND_UNAVAILABLE|SCRIPT_NOT_ALLOWLISTED|EXECUTABLE_OBVIOUS_DENY)/);
    });
  });

  it("refuses run_script on the writable sandbox project", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "run_script",
        arguments: { project: "fixture-sandbox", script: "anything" }
      });
      assertDenied(result, /(SANDBOX_BACKEND_UNAVAILABLE|WORKTREE_NOT_MANAGED)/);
    });
  });

  it("rejects any non-none network value with NETWORK_NOT_NONE (before the sandbox)", async () => {
    await withFixtureAndRunner(withManifest, async (client) => {
      const result = await client.callTool({
        name: "run_script",
        arguments: { project: "fixture-source", script: "test", network: "local" }
      });
      assertDenied(result, /NETWORK_NOT_NONE/);
    });
  });

  it("requires the script argument, so no call can bypass the schema", async () => {
    await withFixtureAndRunner(withManifest, async (client) => {
      const result = await client.callTool({
        name: "run_script",
        arguments: { project: "fixture-source" }
      });
      assert.equal(result.isError, true, "run_script must never succeed without a script");
    });
  });

  it("rejects arbitrary shell API fields in the input schema", async () => {
    await withFixtureAndRunner(withManifest, async (client) => {
      const result = await client.callTool({
        name: "run_script",
        arguments: { project: "fixture-source", script: "test", command: "echo pwned" }
      });
      assert.equal(result.isError, true, "arbitrary shell API field must be rejected by the strict schema");
    });
  });

  it("refuses run_script for an unregistered project", async () => {
    await withFixtureAndRunner(withManifest, async (client) => {
      const result = await client.callTool({
        name: "run_script",
        arguments: { project: "not-registered", script: "test" }
      });
      assertDenied(result, /Unknown project/);
    });
  });
});

describe("project_scripts reporting", () => {
  it("reports scripts and that execution is not currently enabled (no backend here)", async () => {
    await withFixtureAndRunner(withManifest, async (client) => {
      const report = assertOk(
        await client.callTool({
          name: "project_scripts",
          arguments: { project: "fixture-source" }
        })
      );

      assert.equal(report.packageManager, "npm");
      assert.deepEqual(report.scripts, ["build", "test"]);
      assert.equal(report.executionEnabled, false);
      assert.equal(report.killSwitchActive, false);
      assert.deepEqual(report.allowedScripts, []);
      assert.ok(typeof report.packageSha256 === "string" && /^[0-9a-f]{64}$/.test(report.packageSha256), "packageSha256 must be a 64-char hex digest");
      assert.ok(typeof report.hashMatches === "boolean", "hashMatches must be a boolean");
      assert.ok(Array.isArray(report.deniedScripts), "deniedScripts must be an array");
      assert.ok(Array.isArray(report.sensitiveFilesInWorktree), "sensitiveFilesInWorktree must be an array");
      assert.ok(typeof report.scriptHashes === "object" && report.scriptHashes !== null, "scriptHashes must be an object");
      assert.ok(report.scriptHashes.build && report.scriptHashes.test, "scriptHashes should cover current scripts");
    });
  });

  it("reports no package manager when the project has no manifest", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const report = assertOk(
        await client.callTool({
          name: "project_scripts",
          arguments: { project: "fixture-sandbox" }
        })
      );
      assert.equal(report.packageManager, null);
      assert.deepEqual(report.scripts, []);
      assert.equal(report.executionEnabled, false);
    });
  });
});
