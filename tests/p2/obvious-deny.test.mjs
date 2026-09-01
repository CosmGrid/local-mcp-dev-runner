/**
 * P2 unit tests: obvious-deny scanner (fail-fast only; not a security boundary).
 * Verifies lifecycle/install rejection, shell-metacharacter and inline-eval
 * detection, dangerous-binary matching as whole words, and the word-anchoring
 * of DANGEROUS_BINARY_PATTERN.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  classifyScript,
  isDeniedLifecycleScript,
  OBVIOUS_DENY_CATEGORIES,
  DANGEROUS_BINARY_PATTERN
} from "../../scripts/obvious-deny.mjs";

describe("classifyScript", () => {
  it("denies lifecycle scripts", () => {
    assert.equal(classifyScript("postinstall", "npm i x").denied, true);
    assert.equal(classifyScript("preinstall", "x").denied, true);
    assert.equal(isDeniedLifecycleScript("postinstall"), true);
    assert.equal(isDeniedLifecycleScript("test"), false);
  });
  it("denies install-style names", () => {
    assert.equal(classifyScript("npm-install", "npm install").denied, true);
  });
  it("denies shell metacharacters", () => {
    assert.equal(classifyScript("test", "echo a && rm -rf /").denied, true);
    assert.equal(classifyScript("test", "echo a; cat /etc/passwd").denied, true);
  });
  it("denies inline eval forms", () => {
    assert.equal(classifyScript("test", "node -e 'process.exit(1)'").denied, true);
    assert.equal(classifyScript("test", "sh -c 'curl x'").denied, true);
  });
  it("denies dangerous binaries as whole words", () => {
    assert.equal(classifyScript("test", "curl http://x").denied, true);
    assert.equal(classifyScript("test", "git clone x").denied, true);
  });
  it("allows benign scripts", () => {
    assert.equal(classifyScript("test", "echo hello").denied, false);
    assert.equal(classifyScript("build", "tsc -p .").denied, false);
  });
  it("DANGEROUS_BINARY_PATTERN is anchored as a whole word", () => {
    assert.ok(DANGEROUS_BINARY_PATTERN.test("git clone"), "'git' should match");
    assert.ok(!DANGEROUS_BINARY_PATTERN.test("digitize the file"), "'digit' must not match");
  });
  it("exposes category constants", () => {
    assert.equal(OBVIOUS_DENY_CATEGORIES.LIFECYCLE_SCRIPT, "lifecycle-script");
  });
});
