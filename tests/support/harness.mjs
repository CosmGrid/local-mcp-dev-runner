/**
 * Test harness for the Local MCP Dev Runner.
 *
 * Isolation strategy
 * ------------------
 * server.mjs resolves every runtime path from `os.homedir()` (which honours the
 * HOME environment variable on POSIX) and from `process.env.XDG_CONFIG_HOME`:
 *
 *   CONFIG_FILE    -> $HOME/.config/local-mcp-dev-runner/projects.json
 *   WORKTREE_BASE  -> $HOME/.local/share/local-mcp-dev-runner/worktrees
 *   user git attrs -> $XDG_CONFIG_HOME/git/attributes  and  $HOME/.gitattributes
 *
 * By spawning the real server process with HOME / XDG_CONFIG_HOME / GIT_CONFIG_*
 * pointed at a throwaway directory, each test gets a fully isolated runner:
 * its own project registry, its own worktree base, its own global git config.
 *
 * Consequence: server.mjs needs no test-only code paths. The file shipped to
 * RUNTIME_ROOT is byte-for-byte the file under test.
 *
 * The real registry (~/.config/local-mcp-dev-runner/projects.json) and the real
 * business repositories are never read or written by this suite.
 */

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const execFileAsync = promisify(execFile);

export const PROJECT_ROOT = path.resolve(import.meta.dirname, "..", "..");
export const SERVER_PATH = path.join(PROJECT_ROOT, "server.mjs");

export const BASE_GITCONFIG = [
  "[user]",
  "\tname = Local MCP Test",
  "\temail = test@example.invalid",
  "[init]",
  "\tdefaultBranch = main",
  "[core]",
  "\tautocrlf = false",
  "[commit]",
  "\tgpgSign = false",
  "[advice]",
  "\tdetachedHead = false",
  ""
].join("\n");

/** Environment that keeps git and node fully away from the developer's real state. */
function isolatedEnv(home) {
  return {
    HOME: home,
    XDG_CONFIG_HOME: path.join(home, ".config"),
    GIT_CONFIG_GLOBAL: path.join(home, ".gitconfig"),
    GIT_CONFIG_SYSTEM: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_TERMINAL_PROMPT: "0",
    GIT_AUTHOR_NAME: "Local MCP Test",
    GIT_AUTHOR_EMAIL: "test@example.invalid",
    GIT_COMMITTER_NAME: "Local MCP Test",
    GIT_COMMITTER_EMAIL: "test@example.invalid",
    LANG: "en_US.UTF-8",
    PATH: process.env.PATH,
    TMPDIR: tmpdir()
  };
}

export async function git(cwd, env, args) {
  const { stdout = "", stderr = "" } = await execFileAsync("git", args, {
    cwd,
    env,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    timeout: 120000
  });
  return { stdout, stderr };
}

export function sha256(value) {
  return createHash("sha256").update(Buffer.from(value, "utf8")).digest("hex");
}

/**
 * Build a throwaway runner world.
 *
 * @param {object}  [options]
 * @param {object}  [options.projects]        extra registry entries merged into the defaults
 * @param {string}  [options.globalGitConfig] contents of the fake $HOME/.gitconfig.
 *                                            "{{ROOT}}" is replaced with the fixture root,
 *                                            which is how core.attributesfile is exercised.
 * @param {Array}   [options.sourceFiles]     extra [relativePath, content] pairs for the source repo
 * @param {Array}   [options.rootFiles]       extra [relativePath, content] pairs under the fixture root
 * @param {Array}   [options.extraProjectDirs] extra [{ key, write, git }] dirs to create and register
 * @param {boolean} [options.initSourceGit]   default true
 */
export async function createFixture(options = {}) {
  const {
    projects = {},
    globalGitConfig = BASE_GITCONFIG,
    sourceFiles = [],
    rootFiles = [],
    extraProjectDirs = [],
    initSourceGit = true
  } = options;

  const root = await mkdtemp(path.join(tmpdir(), "lmdr-fixture-"));
  const home = path.join(root, "home");
  const sourceDir = path.join(root, "source");
  const sandboxDir = path.join(root, "sandbox");
  const outsideDir = path.join(root, "outside");
  const configDir = path.join(home, ".config", "local-mcp-dev-runner");
  const registryPath = path.join(configDir, "projects.json");
  const worktreeBase = path.join(home, ".local", "share", "local-mcp-dev-runner", "worktrees");

  for (const dir of [home, configDir, sourceDir, sandboxDir, outsideDir]) {
    await mkdir(dir, { recursive: true });
  }

  const env = isolatedEnv(home);
  await writeFile(path.join(home, ".gitconfig"), globalGitConfig.replaceAll("{{ROOT}}", root), "utf8");

  for (const [rel, content] of rootFiles) {
    const target = path.join(root, rel);
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, content, "utf8");
  }

  // --- fixture "original repository" (registered READ_ONLY) -----------------
  await writeFile(path.join(sourceDir, "README.md"), "# fixture source\n");
  await writeFile(path.join(sourceDir, "app.js"), "export const value = 1;\n");
  await mkdir(path.join(sourceDir, "src"), { recursive: true });
  await writeFile(path.join(sourceDir, "src", "index.js"), "console.log('fixture');\n");
  for (const [rel, content] of sourceFiles) {
    const target = path.join(sourceDir, rel);
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, content, "utf8");
  }
  if (initSourceGit) {
    await git(sourceDir, env, ["init", "-b", "main"]);
    await git(sourceDir, env, ["add", "-A"]);
    await git(sourceDir, env, ["commit", "-m", "fixture: initial commit"]);
  }

  // --- fixture "sandbox" (registered READ_WRITE, not a git repo) ------------
  await writeFile(path.join(sandboxDir, "notes.txt"), "hello sandbox\n");
  // planted so the .env block is proven against a file that really exists
  await writeFile(path.join(sandboxDir, ".env"), "PLANTED_SECRET=not-a-real-secret\n");
  await writeFile(path.join(outsideDir, "outside-secret.txt"), "outside the project\n");

  // --- optional extra registered project directories ------------------------
  const extraProjects = {};
  for (const entry of extraProjectDirs) {
    const dir = path.join(root, entry.key);
    await mkdir(dir, { recursive: true });
    await writeFile(path.join(dir, "README.md"), `# ${entry.key}\n`);
    if (entry.git !== false) {
      await git(dir, env, ["init", "-b", "main"]);
      await git(dir, env, ["add", "-A"]);
      await git(dir, env, ["commit", "-m", `fixture: ${entry.key} initial commit`]);
    }
    extraProjects[entry.key] = { root: dir, write: entry.write === true };
  }

  const registry = {
    projects: {
      "fixture-source": { root: sourceDir, write: false },
      "fixture-sandbox": {
        root: sandboxDir,
        write: true,
        runScripts: false,
        allowedScripts: []
      },
      ...extraProjects,
      ...projects
    }
  };
  await writeRegistry(registryPath, registry);

  const fixture = {
    root,
    home,
    env,
    sourceDir,
    sandboxDir,
    outsideDir,
    configDir,
    registryPath,
    worktreeBase,
    extraDirs: Object.fromEntries(extraProjectDirs.map((entry) => [entry.key, path.join(root, entry.key)])),
    git: (args) => git(sourceDir, env, args),
    gitAt: (cwd, args) => git(cwd, env, args),
    async readRegistry() {
      return JSON.parse(await readFile(registryPath, "utf8"));
    },
    async writeRegistry(next) {
      await writeRegistry(registryPath, next);
    },
    /** Create a symlink inside the sandbox that points outside of it. */
    async linkOutside(linkName, targetName = "outside-secret.txt") {
      await symlink(path.join(outsideDir, targetName), path.join(sandboxDir, linkName));
    },
    async linkDirOutside(linkName) {
      await symlink(outsideDir, path.join(sandboxDir, linkName));
    },
    /**
     * Create a symlink that stays inside the sandbox (target is a sibling directory).
     * This reaches the "writes through symlinked directories" guard rather than the
     * earlier "parent path escapes" guard.
     */
    async linkDirInside(linkName, targetDirName = "realdir") {
      const target = path.join(sandboxDir, targetDirName);
      await mkdir(target, { recursive: true });
      await symlink(target, path.join(sandboxDir, linkName));
    },
    async exists(relativeToSandbox) {
      try {
        await readFile(path.join(sandboxDir, relativeToSandbox));
        return true;
      } catch {
        return false;
      }
    },
    async cleanup() {
      await rm(root, { recursive: true, force: true, maxRetries: 3 }).catch(() => {});
    }
  };

  return fixture;
}

async function writeRegistry(registryPath, registry) {
  await mkdir(path.dirname(registryPath), { recursive: true });
  await writeFile(registryPath, JSON.stringify(registry, null, 2) + "\n", {
    encoding: "utf8",
    mode: 0o600
  });
}

/**
 * Spawn the real server against a fixture and hand the caller a connected MCP client.
 * The server process is always torn down, including on assertion failure.
 */
export async function withRunner(fixture, fn) {
  const client = new Client({ name: "lmdr-test-client", version: "1.0.0" }, { capabilities: {} });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [SERVER_PATH],
    cwd: PROJECT_ROOT,
    env: fixture.env,
    stderr: "pipe"
  });

  await client.connect(transport);
  try {
    return await fn(client);
  } finally {
    await client.close().catch(() => {});
    await transport.close().catch(() => {});
  }
}

/**
 * Spawn the real server against a fixture and return a live handle.
 * Use when several ordered assertions must share one server process.
 * Callers are responsible for closing the handle.
 */
export async function openRunner(fixture) {
  const client = new Client({ name: "lmdr-test-client", version: "1.0.0" }, { capabilities: {} });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [SERVER_PATH],
    cwd: PROJECT_ROOT,
    env: fixture.env,
    stderr: "pipe"
  });
  await client.connect(transport);
  return {
    client,
    async close() {
      await client.close().catch(() => {});
      await transport.close().catch(() => {});
    }
  };
}

/** Full lifecycle helper: build fixture -> run -> clean up. */
export async function withFixtureAndRunner(options, fn) {
  const fixture = await createFixture(options);
  try {
    return await withRunner(fixture, (client) => fn(client, fixture));
  } finally {
    await fixture.cleanup();
  }
}

export function resultText(result) {
  return (result.content ?? []).map((entry) => entry.text ?? "").join("\n");
}

export function resultJson(result) {
  return JSON.parse(resultText(result));
}

/** Assert the tool was refused, and that the refusal message matches `matcher`. */
export function assertDenied(result, matcher) {
  assert.equal(
    result.isError,
    true,
    `expected the call to be denied, but it succeeded: ${resultText(result)}`
  );
  const message = resultText(result);
  assert.match(message, matcher);
  return message;
}

/** Assert the tool succeeded and return its parsed JSON payload. */
export function assertOk(result) {
  assert.notEqual(
    result.isError,
    true,
    `expected the call to succeed, but it was denied: ${resultText(result)}`
  );
  return resultJson(result);
}

export async function callToolRaw(client, name, args = {}) {
  return client.callTool({ name, arguments: args });
}
