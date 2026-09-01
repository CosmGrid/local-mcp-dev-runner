/**
 * P2 backend export/contract guard.
 *
 * The native (real-sandbox) suite instantiates SandboxExecBackend directly from
 * tests/native/_helpers.mjs, which imports it from
 * scripts/sandbox-backend-sandbox-exec.mjs. If that export ever moves or stops
 * being re-exported, the native gate crashes at module load in a Terminal.app
 * -- six test files all reporting the same SyntaxError -- while the WorkBuddy
 * unit gates stay green (npm test never loads tests/native/*).
 *
 * This test imports from the SAME module path as _helpers.mjs and proves the
 * export exists and satisfies the public backend contract. It runs without
 * sandbox-exec, so it fails early and loudly in WorkBuddy.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { SandboxExecBackend } from "../../scripts/sandbox-backend-sandbox-exec.mjs";
import { SANDBOX_BACKEND_CONTRACT } from "../../scripts/sandbox-backend.mjs";

describe("SandboxExecBackend export contract (native helper dependency)", () => {
  it("SandboxExecBackend is exported and is a constructor", () => {
    assert.ok(SandboxExecBackend, "SandboxExecBackend must be exported from sandbox-backend-sandbox-exec.mjs");
    assert.equal(typeof SandboxExecBackend, "function", "SandboxExecBackend must be a constructable class");
  });

  it("instantiates with the production kind", () => {
    const backend = new SandboxExecBackend();
    assert.equal(backend.kind, "sandbox-exec");
  });

  it("exposes every public contract member", () => {
    const backend = new SandboxExecBackend();
    for (const key of SANDBOX_BACKEND_CONTRACT) {
      assert.ok(key in backend, `backend must expose contract member: ${key}`);
      if (key === "kind") {
        assert.equal(typeof backend.kind, "string", "kind must be a string identifier");
        assert.ok(backend.kind.length > 0, "kind must be a non-empty string identifier");
      } else {
        assert.equal(typeof backend[key], "function", `contract member ${key} must be a method`);
      }
    }
  });

  it("isAvailable/versionProbe are callable and return a report (no throw)", async () => {
    const backend = new SandboxExecBackend();
    const avail = await backend.isAvailable();
    assert.ok(avail && typeof avail === "object");
    assert.ok("available" in avail, "isAvailable must report an `available` flag");
    assert.ok("failures" in avail, "isAvailable must report `failures`");
  });

  it("generateProfile + validateProfile produce a deny-by-default, network-denied profile", () => {
    const backend = new SandboxExecBackend();
    const ctx = {
      worktreeRoot: "/w",
      homeRoot: "/h",
      tmpRoot: "/t",
      realHome: "/rh",
      runtimeRoot: "/rt",
      configFilePath: "/rt/projects.json",
      nodeBinDirs: ["/opt/node/bin"]
    };
    const profile = backend.generateProfile(ctx);
    const validation = backend.validateProfile(profile);
    assert.equal(validation.ok, true, `generated profile rejected: ${validation.reason}`);
    assert.ok(profile.includes("(deny default)"), "profile must be deny-by-default");
    assert.ok(profile.includes("(deny network*)"), "profile must deny all network");
  });

  it("grants root read-traversal but keeps sensitive paths denied (no dead exec rule)", () => {
    const backend = new SandboxExecBackend();
    const ctx = {
      worktreeRoot: "/w",
      homeRoot: "/h",
      tmpRoot: "/t",
      realHome: "/rh",
      runtimeRoot: "/rt",
      configFilePath: "/rt/projects.json",
      nodeBinDirs: ["/opt/node/bin"]
    };
    const profile = backend.generateProfile(ctx);
    const rootAllow = profile.indexOf(`(allow file-read* (subpath "/"))`);
    const realHomeDeny = profile.indexOf(`(deny file-read-data (subpath "/rh"))`);
    const gitLiteral = profile.indexOf(`(deny process-exec* (literal "/usr/bin/git"))`);
    assert.ok(rootAllow >= 0, "profile must grant root read-traversal");
    assert.ok(realHomeDeny >= 0 && realHomeDeny < rootAllow, "realHome deny must precede root allow");
    assert.ok(gitLiteral >= 0, "dangerous executables must be denied via literal rule");
    assert.ok(!profile.includes(`(subpath "/usr/bin/git ")`), "dead trailing-space exec deny must be gone");
  });

  it("cleanup is callable without throwing", async () => {
    const backend = new SandboxExecBackend();
    const result = await backend.cleanup({ pgid: null, paths: [] });
    assert.ok(result && typeof result === "object");
    assert.ok("descendantsRemaining" in result, "cleanup must report descendant state");
  });
});
