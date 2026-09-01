/**
 * P2 unit tests: sensitive-worktree scanner.
 * Verifies classification (sensitive vs example), the .aws/config onlyIn rule,
 * and that node_modules / .git subtrees are skipped during a real scan.
 */

import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import fs from "node:fs/promises";
import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import { classifyFileName, scanWorktreeForSensitiveFiles } from "../../scripts/sensitive-worktree.mjs";

describe("classifyFileName", () => {
  it("flags sensitive patterns", () => {
    assert.equal(classifyFileName(".env").sensitive, true);
    assert.equal(classifyFileName("id_rsa").sensitive, true);
    assert.equal(classifyFileName("config", ".aws").sensitive, true);
    assert.equal(classifyFileName("config").sensitive, false);
  });
  it("allows example/template files", () => {
    assert.equal(classifyFileName(".env.example").sensitive, false);
    assert.equal(classifyFileName("sample.env").sensitive, false);
  });
});

describe("scanWorktreeForSensitiveFiles", () => {
  let dir;
  after(async () => {
    if (dir) await rm(dir, { recursive: true, force: true });
  });
  it("detects sensitive files but not examples, and skips node_modules/.git", async () => {
    dir = await mkdtemp(path.join(os.tmpdir(), "lmdr-sensitive-"));
    await writeFile(path.join(dir, ".env"), "SECRET=1");
    await writeFile(path.join(dir, "id_rsa"), "key");
    await writeFile(path.join(dir, ".env.example"), "safe");
    await mkdir(path.join(dir, ".aws"), { recursive: true });
    await writeFile(path.join(dir, ".aws", "config"), "[default]");
    await mkdir(path.join(dir, "node_modules"), { recursive: true });
    await writeFile(path.join(dir, "node_modules", ".env"), "should-be-ignored");

    const res = await scanWorktreeForSensitiveFiles(dir);
    assert.ok(res.sensitiveFiles.includes(".env"));
    assert.ok(res.sensitiveFiles.includes("id_rsa"));
    assert.ok(res.sensitiveFiles.includes(path.join(".aws", "config")));
    assert.ok(!res.sensitiveFiles.includes(".env.example"), "example file must not be flagged");
    assert.ok(!res.sensitiveFiles.includes(path.join("node_modules", ".env")), "node_modules must be skipped");
  });
});
