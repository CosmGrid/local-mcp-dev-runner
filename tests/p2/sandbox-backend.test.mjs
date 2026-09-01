/**
 * P2 unit tests: sandbox-backend abstractions.
 * Validates the S-expression checker, the real backend's profile generation
 * (deny-by-default, network denied, per-path allow, literal deny), parentsOf,
 * and the MockSandboxBackend contract/behavior.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { validateSExpression, SANDBOX_BACKEND_CONTRACT } from "../../scripts/sandbox-backend.mjs";
import {
  SandboxExecBackend,
  parentsOf,
  DENIED_EXECUTABLES,
  EXEC_RULE_ORDER,
  DEFAULT_EXEC_RULE_ORDER
} from "../../scripts/sandbox-backend-sandbox-exec.mjs";
import { MockSandboxBackend } from "../../scripts/sandbox-backend-mock.mjs";

describe("validateSExpression", () => {
  it("accepts balanced SBPL", () => {
    assert.equal(validateSExpression("(version 1)(deny default)").ok, true);
  });
  it("rejects unbalanced parentheses", () => {
    assert.equal(validateSExpression("(version 1)(deny default").ok, false);
  });
  it("rejects an unterminated string literal", () => {
    assert.equal(validateSExpression('(allow (literal "x)').ok, false);
  });
});

describe("SandboxExecBackend.generateProfile", () => {
  const ctx = {
    worktreeRoot: "/w",
    homeRoot: "/h",
    tmpRoot: "/t",
    realHome: "/rh",
    runtimeRoot: "/rt",
    configFilePath: "/rt/projects.json",
    nodeBinDirs: ["/opt/node/bin"]
  };
  const profile = new SandboxExecBackend().generateProfile(ctx);

  it("is deny-by-default with network denied", () => {
    assert.ok(profile.includes("(deny default)"));
    assert.ok(profile.includes("(deny network*)"));
  });
  it("allows only the declared write paths", () => {
    for (const p of ["/w", "/h", "/t"]) {
      assert.ok(profile.includes(`(allow file-write* (subpath "${p}")`));
    }
  });
  it("denies every dangerous executable literally", () => {
    for (const bin of DENIED_EXECUTABLES) {
      assert.ok(profile.includes(`(deny process-exec* (literal "${bin}")`));
    }
  });
  it("uses the ALLOW_THEN_DENY rule order by default", () => {
    assert.equal(new SandboxExecBackend().execRuleOrder, EXEC_RULE_ORDER.ALLOW_THEN_DENY);
    assert.equal(DEFAULT_EXEC_RULE_ORDER, EXEC_RULE_ORDER.ALLOW_THEN_DENY);
  });
});

describe("parentsOf", () => {
  it("returns strict ancestors up to (excluding) a non-ancestor stopAt", () => {
    assert.deepEqual(parentsOf("/a/b/c/d", "/x"), ["/a/b/c", "/a/b", "/a"]);
  });
  it("returns empty when the immediate parent is already under stopAt", () => {
    // The worktree lives under HOME, so no sibling-sealing ancestors remain.
    assert.deepEqual(parentsOf("/a/b/c/d", "/a"), []);
  });
  it("returns empty for a non-absolute target", () => {
    assert.deepEqual(parentsOf("relative"), []);
  });
});

describe("MockSandboxBackend", () => {
  it("records executions and records the plan", async () => {
    const m = new MockSandboxBackend();
    await m.execute({ context: { a: 1 }, executable: "/bin/echo", args: ["x"], cwd: "/w", env: {}, timeoutMs: 1000 });
    assert.equal(m.calls.length, 1);
    assert.equal(m.calls[0].executable, "/bin/echo");
  });
  it("throws when configured unavailable", async () => {
    const m = new MockSandboxBackend({ available: false });
    await assert.rejects(
      () => m.execute({ context: {}, executable: "/x", args: [], cwd: "/w", env: {}, timeoutMs: 1 }),
      /SANDBOX_BACKEND_UNAVAILABLE/
    );
  });
  it("satisfies the backend contract", () => {
    const m = new MockSandboxBackend();
    for (const key of SANDBOX_BACKEND_CONTRACT) assert.ok(key in m, `mock must expose ${key}`);
  });
});
