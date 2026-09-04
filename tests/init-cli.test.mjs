import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const PROJECT_ROOT = path.resolve(import.meta.dirname, "..");
const SERVER_PATH = path.join(PROJECT_ROOT, "server.mjs");

function runCli(args, env) {
  return execFileAsync(process.execPath, [SERVER_PATH, ...args], {
    cwd: PROJECT_ROOT,
    env: {
      ...process.env,
      ...env
    }
  }).catch((err) => err);
}

describe("CLI --init behavior", () => {
  it("creates a safe minimal projects.json template when absent", async () => {
    const home = await mkdtemp(path.join(tmpdir(), "lmdr-init-test-"));
    try {
      const res = await runCli(["--init"], { HOME: home });
      assert.equal(res.code ?? 0, 0, `Expected 0 exit code: ${res.stderr || res.stdout}`);
      assert.match(res.stdout, /INIT_RESULT=CREATED/);
      assert.match(res.stdout, /CONFIG_PATH=/);

      const targetPath = path.join(home, ".config", "local-mcp-dev-runner", "projects.json");
      const content = await readFile(targetPath, "utf8");
      const parsed = JSON.parse(content);

      assert.ok(parsed.projects && typeof parsed.projects === "object");
      assert.deepEqual(Object.keys(parsed.projects), []);
      assert.match(parsed._comment, /Local MCP Dev Runner/);
      assert.ok(parsed._template);
      assert.equal(parsed._template.write, false);
      assert.equal(parsed._template.runScripts, false);
      assert.deepEqual(parsed._template.allowedScripts, []);
    } finally {
      await rm(home, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("refuses to overwrite existing config without --force", async () => {
    const home = await mkdtemp(path.join(tmpdir(), "lmdr-init-test-"));
    try {
      const configDir = path.join(home, ".config", "local-mcp-dev-runner");
      await mkdir(configDir, { recursive: true });
      const targetPath = path.join(configDir, "projects.json");
      await writeFile(targetPath, JSON.stringify({ projects: { existing: { root: "/tmp", write: false } } }) + "\n", "utf8");

      const res = await runCli(["--init"], { HOME: home });
      assert.equal(res.code, 1, "Expected exit code 1 when config already exists");
      const output = (res.stderr || "") + (res.stdout || "");
      assert.match(output, /CONFIG_ALREADY_EXISTS/);
      assert.match(output, /--force/);

      // Verify file was NOT overwritten
      const content = JSON.parse(await readFile(targetPath, "utf8"));
      assert.ok(content.projects.existing);
    } finally {
      await rm(home, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("overwrites existing config when --force is provided", async () => {
    const home = await mkdtemp(path.join(tmpdir(), "lmdr-init-test-"));
    try {
      const configDir = path.join(home, ".config", "local-mcp-dev-runner");
      await mkdir(configDir, { recursive: true });
      const targetPath = path.join(configDir, "projects.json");
      await writeFile(targetPath, JSON.stringify({ projects: { existing: { root: "/tmp", write: false } } }) + "\n", "utf8");

      const res = await runCli(["--init", "--force"], { HOME: home });
      assert.equal(res.code ?? 0, 0, `Expected 0 exit code: ${res.stderr || res.stdout}`);
      assert.match(res.stdout, /INIT_RESULT=OVERWRITTEN/);

      const content = JSON.parse(await readFile(targetPath, "utf8"));
      assert.deepEqual(Object.keys(content.projects), []);
    } finally {
      await rm(home, { recursive: true, force: true }).catch(() => {});
    }
  });
});

describe("CLI --health-check behavior", () => {
  it("reports configuration and runtime status", async () => {
    const home = await mkdtemp(path.join(tmpdir(), "lmdr-health-test-"));
    try {
      const res = await runCli(["--health-check"], { HOME: home });
      assert.equal(res.code ?? 0, 0, `Expected 0 exit code: ${res.stderr || res.stdout}`);
      assert.match(res.stdout, /PROJECTS_CONFIG=WARN/);
      assert.match(res.stdout, /REGISTERED_PROJECTS=0/);
      assert.match(res.stdout, /WORKTREE_BASE=PASS/);
      assert.match(res.stdout, /SANDBOX_BACKEND=(AVAILABLE|UNAVAILABLE)/);
    } finally {
      await rm(home, { recursive: true, force: true }).catch(() => {});
    }
  });
});
