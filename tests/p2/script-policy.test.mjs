/**
 * P2 unit tests: script-policy (pure, deterministic policy layer).
 * Covers package-manager detection, hash pinning, and every evaluation layer
 * of evaluateScriptPolicy (C -> allowlist -> obvious-deny -> A -> B).
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  REASON,
  SUPPORTED_PACKAGE_MANAGERS,
  detectPackageManager,
  packageSha256,
  scriptSha256,
  evaluateScriptPolicy,
  deniedScriptsFor,
  checkWorktreeEligibility,
  packageManagerCommand
} from "../../scripts/script-policy.mjs";

describe("detectPackageManager", () => {
  it("supports npm and pnpm only", () => {
    assert.deepEqual([...SUPPORTED_PACKAGE_MANAGERS], ["npm", "pnpm"]);
  });
  it("reads packageManager field when supported", () => {
    const r = detectPackageManager({ packageManager: "pnpm@9.0.0" }, []);
    assert.equal(r.packageManager, "pnpm");
    assert.equal(r.supported, true);
  });
  it("rejects an unsupported packageManager field", () => {
    const r = detectPackageManager({ packageManager: "yarn@1.22.0" }, []);
    assert.equal(r.supported, false);
    assert.equal(r.reasonCode, REASON.PACKAGE_MANAGER_UNSUPPORTED);
  });
  it("falls back to lockfiles", () => {
    assert.equal(detectPackageManager({}, ["package-lock.json"]).packageManager, "npm");
    assert.equal(detectPackageManager({}, ["pnpm-lock.yaml"]).packageManager, "pnpm");
    assert.equal(detectPackageManager({}, ["yarn.lock"]).supported, false);
    assert.equal(detectPackageManager({}, ["bun.lockb"]).supported, false);
  });
  it("unknown when nothing matches", () => {
    const r = detectPackageManager({}, []);
    assert.equal(r.supported, false);
    assert.equal(r.reasonCode, REASON.PACKAGE_MANAGER_UNKNOWN);
  });
});

describe("packageSha256 / scriptSha256", () => {
  it("packageSha256 is a 64-char hex digest", () => {
    assert.match(packageSha256('{"name":"x"}'), /^[0-9a-f]{64}$/);
  });
  it("scriptSha256 separates name and value with a NUL byte", () => {
    const a = scriptSha256("build", "echo a");
    const b = scriptSha256("build", "echo b");
    const c = scriptSha256("xbuild", "echo a");
    assert.notEqual(a, b, "different values => different hash");
    assert.notEqual(a, c, "different names => different hash (NUL separation prevents rearrangement)");
  });
});

describe("evaluateScriptPolicy", () => {
  const scripts = { test: "echo ok", build: "echo build" };
  const allowed = ["test"];
  const okHash = scriptSha256("test", "echo ok");
  const approved = { test: okHash };
  const pkgSha = packageSha256("...");

  it("rejects a caller-supplied SHA mismatch (TOCTOU layer C)", () => {
    const r = evaluateScriptPolicy({
      script: "test",
      scripts,
      allowedScripts: allowed,
      scriptHashes: approved,
      expectedPackageSha256: "deadbeef",
      packageSha256: pkgSha
    });
    assert.equal(r.ok, false);
    assert.equal(r.reasonCode, REASON.CALLER_SHA_MISMATCH);
  });
  it("rejects a script not on the allowlist", () => {
    const r = evaluateScriptPolicy({
      script: "build",
      scripts,
      allowedScripts: allowed,
      scriptHashes: approved,
      packageSha256: pkgSha
    });
    assert.equal(r.ok, false);
    assert.equal(r.reasonCode, REASON.SCRIPT_NOT_ALLOWLISTED);
  });
  it("rejects a script absent from the manifest", () => {
    const r = evaluateScriptPolicy({
      script: "nope",
      scripts,
      allowedScripts: allowed,
      scriptHashes: approved,
      packageSha256: pkgSha
    });
    assert.equal(r.ok, false);
    assert.equal(r.reasonCode, REASON.SCRIPT_NOT_ALLOWLISTED);
  });
  it("rejects an obvious-deny script value", () => {
    const r = evaluateScriptPolicy({
      script: "test",
      scripts: { test: "rm -rf /" },
      allowedScripts: allowed,
      scriptHashes: approved,
      packageSha256: pkgSha
    });
    assert.equal(r.ok, false);
    assert.equal(r.reasonCode, REASON.EXECUTABLE_OBVIOUS_DENY);
  });
  it("rejects when no approved hash exists (TOCTOU layer A)", () => {
    const r = evaluateScriptPolicy({
      script: "test",
      scripts,
      allowedScripts: allowed,
      scriptHashes: {},
      packageSha256: pkgSha
    });
    assert.equal(r.ok, false);
    assert.equal(r.reasonCode, REASON.SCRIPT_NOT_APPROVED);
  });
  it("rejects when the script value changed (TOCTOU layer B)", () => {
    const r = evaluateScriptPolicy({
      script: "test",
      scripts: { test: "echo changed" },
      allowedScripts: allowed,
      scriptHashes: approved,
      packageSha256: pkgSha
    });
    assert.equal(r.ok, false);
    assert.equal(r.reasonCode, REASON.SCRIPT_VALUE_CHANGED);
  });
  it("approves a hash-pinned, allowlisted, unchanged script", () => {
    const r = evaluateScriptPolicy({
      script: "test",
      scripts,
      allowedScripts: allowed,
      scriptHashes: approved,
      packageSha256: pkgSha
    });
    assert.equal(r.ok, true);
    assert.equal(r.scriptSha256, okHash);
  });
});

describe("deniedScriptsFor", () => {
  it("flags lifecycle and dangerous scripts", () => {
    const denied = deniedScriptsFor({ test: "echo ok", postinstall: "npm i x", pwn: "curl evil" });
    const names = denied.map((d) => d.script).sort();
    assert.deepEqual(names, ["postinstall", "pwn"]);
    assert.equal(denied.find((d) => d.script === "postinstall").reasonCode, REASON.INSTALL_DENIED);
  });
});

describe("checkWorktreeEligibility", () => {
  const base = "/home/u/.local/share/local-mcp-dev-runner/worktrees";
  it("requires a managed, writable mcp/* worktree within the base", () => {
    const spec = { managedWorktree: true, write: true, sourceProject: "src", branch: "mcp/feat", root: base + "/feat" };
    assert.equal(checkWorktreeEligibility(spec, { branch: "mcp/feat" }, base).ok, true);
  });
  it("rejects an unmanaged project", () => {
    const spec = { managedWorktree: false, write: true, sourceProject: "src", branch: "mcp/feat", root: base + "/feat" };
    const r = checkWorktreeEligibility(spec, { branch: "mcp/feat" }, base);
    assert.equal(r.ok, false);
    assert.equal(r.reasonCode, REASON.WORKTREE_NOT_MANAGED);
  });
  it("rejects a non-mcp branch", () => {
    const spec = { managedWorktree: true, write: true, sourceProject: "src", branch: "main", root: base + "/feat" };
    const r = checkWorktreeEligibility(spec, { branch: "main" }, base);
    assert.equal(r.ok, false);
    assert.equal(r.reasonCode, REASON.WORKTREE_BRANCH_NOT_MCP);
  });
  it("rejects a worktree outside the base", () => {
    const spec = { managedWorktree: true, write: true, sourceProject: "src", branch: "mcp/feat", root: "/elsewhere/feat" };
    const r = checkWorktreeEligibility(spec, { branch: "mcp/feat" }, base);
    assert.equal(r.ok, false);
    assert.equal(r.reasonCode, REASON.WORKTREE_OUTSIDE_BASE);
  });
  it("rejects a detached worktree", () => {
    const spec = { managedWorktree: true, write: true, sourceProject: "src", branch: "mcp/feat", root: base + "/feat" };
    const r = checkWorktreeEligibility(spec, { branch: "mcp/feat", detached: true }, base);
    assert.equal(r.ok, false);
    assert.equal(r.reasonCode, REASON.WORKTREE_DETACHED);
  });
});

describe("packageManagerCommand", () => {
  it("builds structured argv", () => {
    assert.deepEqual(packageManagerCommand("npm", "test"), ["run", "test"]);
    assert.deepEqual(packageManagerCommand("pnpm", "build"), ["run", "build"]);
  });
  it("throws for unsupported managers", () => {
    assert.throws(() => packageManagerCommand("yarn", "test"));
  });
});
