/**
 * P2 unit tests: output-handling (output hygiene, NOT a security boundary).
 * Verifies redaction, ANSI stripping, and head/tail + line truncation.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  sanitizeOutput,
  stripAnsi,
  redact,
  REDACTION_PATTERNS,
  LINE_TRUNCATION_MARKER
} from "../../scripts/output-handling.mjs";

describe("sanitizeOutput", () => {
  it("passes through normal text", () => {
    const r = sanitizeOutput("hello world");
    assert.equal(r.truncated, false);
    assert.equal(r.text, "hello world");
  });
  it("redacts credential-shaped substrings", () => {
    const r = sanitizeOutput("token sk-1234567890abcdef1234 leaked");
    assert.match(r.text, /\[redacted:openai-key\]/);
    assert.doesNotMatch(r.text, /sk-1234567890abcdef1234/);
  });
  it("truncates oversized multi-line output head/tail", () => {
    const lines = Array.from({ length: 200 }, () => "y".repeat(2000)).join("\n");
    const r = sanitizeOutput(lines);
    assert.equal(r.truncated, true);
  });
  it("folds a single oversized line", () => {
    const r = sanitizeOutput("x".repeat(9000));
    assert.ok(r.text.includes(LINE_TRUNCATION_MARKER));
  });
});

describe("stripAnsi / redact", () => {
  it("strips ANSI escape sequences", () => {
    assert.equal(stripAnsi("\u001b[31mred\u001b[0m"), "red");
  });
  it("redact replaces matched patterns", () => {
    assert.equal(redact("key sk-1234567890abcdef1234"), "key [redacted:openai-key]");
  });
  it("REDACTION_PATTERNS is non-empty", () => {
    assert.ok(REDACTION_PATTERNS.length > 0);
  });
});
