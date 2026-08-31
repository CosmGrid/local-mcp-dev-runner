/**
 * Script execution gate.
 *
 * v1.0 ships with run_script permanently disabled: the tool exists so the
 * contract is discoverable, but every invocation is refused before any
 * allowlist check or shell call happens.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { assertDenied, assertOk, withFixtureAndRunner } from "../support/harness.mjs";

const DISABLED = /run_script is disabled in v1\.0 security profile/;

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

describe("run_script default deny", () => {
  it("refuses run_script even for a valid registered project", async () => {
    await withFixtureAndRunner(withManifest, async (client) => {
      const result = await client.callTool({
        name: "run_script",
        arguments: { project: "fixture-source", script: "test" }
      });
      assertDenied(result, DISABLED);
    });
  });

  it("refuses run_script for a script that is not in the manifest either", async () => {
    await withFixtureAndRunner(withManifest, async (client) => {
      const result = await client.callTool({
        name: "run_script",
        arguments: { project: "fixture-source", script: "totally-unknown-script" }
      });
      assertDenied(result, DISABLED);
    });
  });

  it("refuses run_script for a destructive command without ever reaching a shell", async () => {
    await withFixtureAndRunner(withManifest, async (client) => {
      const result = await client.callTool({
        name: "run_script",
        arguments: { project: "fixture-source", script: "rm -rf /" }
      });
      assertDenied(result, DISABLED);
    });
  });

  it("refuses run_script on the writable sandbox project", async () => {
    await withFixtureAndRunner({}, async (client) => {
      const result = await client.callTool({
        name: "run_script",
        arguments: { project: "fixture-sandbox", script: "anything" }
      });
      assertDenied(result, DISABLED);
    });
  });

  it("requires the script argument, so no call can bypass the schema", async () => {
    await withFixtureAndRunner(withManifest, async (client) => {
      const result = await client.callTool({
        name: "run_script",
        arguments: { project: "fixture-source" }
      });
      assert.equal(result.isError, true, "run_script must never succeed");
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
  it("reports that execution is disabled and lists scripts read-only", async () => {
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
      assert.deepEqual(report.allowedScripts, []);
      assert.match(report.reason, /disabled/i);
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
