import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createHash } from "node:crypto";

// P2 — sandboxed run_script execution. All execution flows through a backend
// that implements the SandboxBackend contract; there is no unsandboxed path.
import { createBackend } from "./scripts/sandbox-backend.mjs";
import { executeScript, killSwitchStatus, projectScriptReport } from "./scripts/script-execution.mjs";
import { REASON } from "./scripts/script-policy.mjs";

// Restricted GitHub repository management
import { GitHubApiClient } from "./scripts/github-client.mjs";
import { getRepositoryInfo, createRepository } from "./scripts/github-manager.mjs";

// Trusted Workspace — Git repository auto-discovery (READ_ONLY, runScripts=false)
import { buildDiscoveryIndex, resolveDiscoveredProject } from "./scripts/workspace-discovery.mjs";

const CONFIG_FILE = path.join(os.homedir(), ".config", "local-mcp-dev-runner", "projects.json");
const WORKTREE_BASE = path.join(os.homedir(), ".local", "share", "local-mcp-dev-runner", "worktrees");
const MAX_FILE_BYTES = 200 * 1024;
const MAX_WRITE_FILE_BYTES = 500 * 1024;
const MAX_SEARCH_FILE_BYTES = 512 * 1024;
const MAX_DIRECTORY_ENTRIES = 500;
const MAX_SEARCH_RESULTS = 200;
const MAX_GIT_OUTPUT_BYTES = 200 * 1024;
const MAX_DIFF_FILES = 100;
const MAX_COMMIT_FILES = 500;
const execFileAsync = promisify(execFile);

const SECRET_PATTERNS = [
  /^\.git$/i,
  /^\.env(?:\.|$)/i,
  /^\.ssh$/i,
  /^\.gnupg$/i,
  /^\.aws$/i,
  /^\.netrc$/i,
  /^id_rsa$/i,
  /^id_ed25519$/i,
  /^credentials$/i,
  /^credentials\.json$/i,
  /^secrets?\.json$/i,
  /^service[-_]?account.*\.json$/i,
  /^\.npmrc$/i,
  /^\.pypirc$/i,
  /\.pem$/i,
  /\.key$/i,
  /\.p12$/i,
  /\.pfx$/i,
  /\.jks$/i,
  /\.keystore$/i
];

const SEARCH_IGNORED_DIRS = new Set([
  "node_modules",
  "dist",
  "build",
  "coverage",
  ".next",
  ".cache",
  "vendor",
  "target"
]);

const DEFAULT_PROTECTED_BRANCHES = new Set(["main", "master"]);

function text(value) {
  return {
    content: [{
      type: "text",
      text: typeof value === "string" ? value : JSON.stringify(value, null, 2)
    }]
  };
}

function structured(value, textValue) {
  const textResult = text(textValue ?? value);
  return { ...textResult, structuredContent: value };
}

function sha256Buffer(value) {
  return createHash("sha256").update(value).digest("hex");
}

function clipText(value = "", maxBytes = MAX_GIT_OUTPUT_BYTES) {
  const buffer = Buffer.from(value, "utf8");
  if (buffer.length <= maxBytes) return value;
  return buffer.subarray(0, maxBytes).toString("utf8") + "\n...[output truncated]";
}

function isBinaryBuffer(buffer) {
  return buffer.includes(0);
}

function pathParts(value) {
  return String(value || "").split(/[\\/]/).filter(Boolean);
}

function isSensitiveRelativePath(relativePath) {
  return pathParts(relativePath).some((part) =>
    SECRET_PATTERNS.some((pattern) => pattern.test(part))
  );
}

function assertNotSensitive(relativePath) {
  for (const part of pathParts(relativePath)) {
    if (SECRET_PATTERNS.some((pattern) => pattern.test(part))) {
      throw new Error(`Sensitive path is blocked: ${part}`);
    }
  }
}

function assertSafeRelativeLexical(requestedPath, { allowDot = true } = {}) {
  const value = requestedPath || ".";
  if (value.includes("\0")) throw new Error("Path contains NUL byte");
  if (path.isAbsolute(value)) throw new Error("Absolute paths are not allowed");
  const parts = pathParts(value);
  if (parts.includes("..")) throw new Error("Path escapes registered project root");
  if (!allowDot && (value === "." || parts.length === 0)) {
    throw new Error("A non-root path is required");
  }
  assertNotSensitive(value);
  return value;
}

function formatUserError(code, what, next) {
  return `${code}: ${what} (Next step: ${next})`;
}

async function loadRegistry() {
  let raw;
  try {
    raw = await fs.readFile(CONFIG_FILE, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      throw new Error(
        formatUserError(
          "CONFIG_NOT_FOUND",
          `Configuration file does not exist at ${CONFIG_FILE}`,
          "Run 'node server.mjs --init' to generate a template configuration."
        )
      );
    }
    throw error;
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new Error(
      formatUserError(
        "CONFIG_JSON_PARSE_ERROR",
        `Failed to parse JSON registry at ${CONFIG_FILE} (${error?.message || "syntax error"})`,
        "Check syntax of projects.json or re-initialize with 'node server.mjs --init --force'."
      )
    );
  }
  if (!parsed.projects || typeof parsed.projects !== "object") {
    throw new Error("Invalid projects registry");
  }
  return parsed;
}

async function saveRegistry(registry) {
  await fs.mkdir(path.dirname(CONFIG_FILE), { recursive: true });
  const temp = `${CONFIG_FILE}.tmp-${process.pid}-${Date.now()}`;
  await fs.writeFile(temp, JSON.stringify(registry, null, 2) + "\n", {
    encoding: "utf8",
    mode: 0o600,
    flag: "wx"
  });
  try {
    await fs.rename(temp, CONFIG_FILE);
    await fs.chmod(CONFIG_FILE, 0o600).catch(() => {});
  } catch (error) {
    await fs.rm(temp, { force: true }).catch(() => {});
    throw error;
  }
}

/**
 * Materialise an explicitly configured project. Identical semantics to the
 * pre-discovery behaviour: explicit configuration is authoritative and may
 * legitimately declare write/runScripts.
 */
async function materializeConfiguredProject(name, raw) {
  const root = await fs.realpath(raw.root);
  return {
    name,
    root,
    write: raw.write === true,
    managedWorktree: raw.managedWorktree === true,
    sourceProject: raw.sourceProject || null,
    branch: raw.branch || null,
    protectedBranches: Array.isArray(raw.protectedBranches) ? raw.protectedBranches : [],
    runScripts: raw.runScripts === true,
    allowedScripts: Array.isArray(raw.allowedScripts) ? raw.allowedScripts : [],
    scriptHashes: raw.scriptHashes && typeof raw.scriptHashes === "object" ? { ...raw.scriptHashes } : {},
    packageManager: typeof raw.packageManager === "string" ? raw.packageManager : null,
    discovered: false,
    workspace: null
  };
}

/**
 * Materialise an auto-discovered workspace project. Permissions are taken from
 * the discovery layer, which hard-codes write=false and runScripts=false; the
 * root is re-realpath'd here so discovery can never hand out a stale or
 * redirected path. All downstream guards (sensitive path, permission, worktree,
 * runScripts, branch protection) apply unchanged.
 */
async function materializeDiscoveredProject(entry) {
  const root = await fs.realpath(entry.root);
  return {
    name: entry.name,
    root,
    write: false,
    managedWorktree: false,
    sourceProject: null,
    branch: null,
    protectedBranches: [],
    runScripts: false,
    allowedScripts: [],
    scriptHashes: {},
    packageManager: null,
    discovered: true,
    workspace: entry.workspace
  };
}

async function resolveProject(projectName) {
  const registry = await loadRegistry();
  const raw = registry.projects[projectName];
  if (raw) return materializeConfiguredProject(projectName, raw);

  // Not explicitly registered: fall back to trusted-workspace discovery.
  // Configurations without trustedWorkspaces return an empty index without
  // touching the filesystem, so pre-existing behaviour is unchanged.
  const index = await buildDiscoveryIndex(registry);
  const match = resolveDiscoveredProject(index, projectName);

  if (match.ambiguous) {
    throw new Error(
      `Ambiguous project: ${projectName}. ${match.candidates.length} auto-discovered repositories share this name: ` +
      `${match.candidates.join(", ")}. ` +
      `Use the fully qualified id (workspaceAlias/path/to/repo) instead. Run list_projects to see available projects.`
    );
  }
  if (match.found) return materializeDiscoveredProject(match.project);

  const known = [...Object.keys(registry.projects || {}), ...index.entries.map((entry) => entry.name)].sort();
  const hint = known.length > 0 ? `Known projects: ${known.join(", ")}` : "No projects registered in projects.json yet";
  throw new Error(
    `Unknown project: ${projectName}. ${hint}. Run list_projects to see registered projects.`
  );
}

/**
 * Lazily-constructed singleton sandbox backend. A3 runs in a nested sandbox
 * (WorkBuddy) where /usr/bin/sandbox-exec returns EPERM 71; in that environment
 * the backend reports itself unavailable and run_script refuses rather than
 * degrading to an unsandboxed execution. Real sandbox verification happens in a
 * native macOS Terminal.app via scripts/run-native-sandbox-gate.sh.
 */
let sandboxBackend = null;
function getSandboxBackend() {
  if (!sandboxBackend) sandboxBackend = createBackend();
  return sandboxBackend;
}

async function resolveInsideProject(projectName, requestedPath = ".") {
  const project = await resolveProject(projectName);
  const relativePath = assertSafeRelativeLexical(requestedPath);
  const candidate = path.resolve(project.root, relativePath);
  if (candidate !== project.root && !candidate.startsWith(project.root + path.sep)) {
    throw new Error("Path escapes registered project root");
  }

  let real;
  try {
    real = await fs.realpath(candidate);
  } catch {
    throw new Error(`Path does not exist: ${relativePath}`);
  }

  if (real !== project.root && !real.startsWith(project.root + path.sep)) {
    throw new Error("Path escapes registered project root");
  }

  const realRelative = path.relative(project.root, real) || ".";
  assertNotSensitive(realRelative);

  return {
    ...project,
    requestedPath: relativePath,
    relativePath: realRelative,
    absolutePath: real,
    requestedAbsolutePath: candidate,
    hasSymlink: path.normalize(candidate) !== path.normalize(real)
  };
}

async function execGitAt(root, args, { timeout = 20000, allowFailure = false } = {}) {
  const safeArgs = [
    "-c", "core.hooksPath=/dev/null",
    "-c", "core.fsmonitor=false",
    "-c", "credential.helper=",
    "-c", "commit.gpgSign=false",
    "-C", root,
    ...args
  ];

  const options = {
    timeout,
    maxBuffer: 4 * 1024 * 1024,
    encoding: "utf8",
    env: {
      ...process.env,
      GIT_OPTIONAL_LOCKS: "0",
      GIT_TERMINAL_PROMPT: "0",
      GIT_PAGER: "cat",
      GIT_EDITOR: "false"
    }
  };

  try {
    const { stdout = "", stderr = "" } = await execFileAsync("git", safeArgs, options);
    return { stdout, stderr, exitCode: 0 };
  } catch (error) {
    if (allowFailure) {
      return {
        stdout: error.stdout || "",
        stderr: error.stderr || "",
        exitCode: Number.isInteger(error.code) ? error.code : 1
      };
    }
    throw new Error(`Git command failed: ${error.stderr || error.message}`);
  }
}

async function runGit(projectName, args, options) {
  const project = await resolveProject(projectName);
  const result = await execGitAt(project.root, args, options);
  return {
    project: projectName,
    root: project.root,
    stdout: clipText(result.stdout),
    stderr: clipText(result.stderr),
    exitCode: result.exitCode
  };
}

async function getGitState(project) {
  const inside = await execGitAt(project.root, ["rev-parse", "--is-inside-work-tree"], { allowFailure: true });
  if (inside.exitCode !== 0 || inside.stdout.trim() !== "true") {
    return { isGit: false, topLevel: null, branch: null, detached: false };
  }
  const topResult = await execGitAt(project.root, ["rev-parse", "--show-toplevel"], { allowFailure: true });
  let topLevel = null;
  if (topResult.exitCode === 0 && topResult.stdout.trim()) {
    topLevel = await fs.realpath(topResult.stdout.trim()).catch(() => topResult.stdout.trim());
  }
  const branchResult = await execGitAt(project.root, ["symbolic-ref", "--quiet", "--short", "HEAD"], { allowFailure: true });
  if (branchResult.exitCode !== 0) {
    return { isGit: true, topLevel, branch: null, detached: true };
  }
  return { isGit: true, topLevel, branch: branchResult.stdout.trim(), detached: false };
}

async function assertProjectWriteAllowed(project) {
  if (!project.write) throw new Error(`Project is read-only: ${project.name}`);
  const git = await getGitState(project);
  if (!git.isGit) return;
  if (git.topLevel && path.normalize(git.topLevel) !== path.normalize(project.root)) {
    throw new Error("Writable project nested inside another Git worktree is blocked");
  }
  if (git.detached) throw new Error("Writes are blocked on detached HEAD");

  const protectedBranches = new Set([
    ...DEFAULT_PROTECTED_BRANCHES,
    ...project.protectedBranches
  ]);
  if (protectedBranches.has(git.branch)) {
    throw new Error(`Writes are blocked on protected branch: ${git.branch}`);
  }
  if (project.managedWorktree && !git.branch.startsWith("mcp/")) {
    throw new Error("Managed worktree writes require an mcp/* branch");
  }
}

async function resolveNewFileTarget(projectName, requestedPath) {
  const project = await resolveProject(projectName);
  await assertProjectWriteAllowed(project);
  const relativePath = assertSafeRelativeLexical(requestedPath, { allowDot: false });
  const candidate = path.resolve(project.root, relativePath);
  if (!candidate.startsWith(project.root + path.sep)) {
    throw new Error("Path escapes registered project root");
  }

  const parentCandidate = path.dirname(candidate);
  let realParent;
  try {
    realParent = await fs.realpath(parentCandidate);
  } catch {
    throw new Error("Parent directory does not exist");
  }

  if (realParent !== project.root && !realParent.startsWith(project.root + path.sep)) {
    throw new Error("Parent path escapes registered project root");
  }
  if (path.normalize(realParent) !== path.normalize(parentCandidate)) {
    throw new Error("Writes through symlinked directories are blocked");
  }
  assertNotSensitive(path.relative(project.root, realParent));

  try {
    await fs.lstat(candidate);
    throw new Error("Target file already exists");
  } catch (error) {
    if (error?.message === "Target file already exists") throw error;
    if (error?.code !== "ENOENT") throw error;
  }

  return { ...project, relativePath, absolutePath: candidate };
}

async function resolveWritableExistingFile(projectName, requestedPath) {
  const resolved = await resolveInsideProject(projectName, requestedPath);
  await assertProjectWriteAllowed(resolved);
  if (resolved.hasSymlink) throw new Error("Writes through symlinks are blocked");
  const stat = await fs.stat(resolved.absolutePath);
  if (!stat.isFile()) throw new Error("Requested path is not a file");
  if (stat.size > MAX_WRITE_FILE_BYTES) {
    throw new Error(`File exceeds safe edit limit of ${MAX_WRITE_FILE_BYTES} bytes`);
  }
  return { resolved, stat };
}

async function readTextFile(projectName, requestedPath, maxBytes = MAX_FILE_BYTES) {
  const resolved = await resolveInsideProject(projectName, requestedPath);
  const stat = await fs.stat(resolved.absolutePath);
  if (!stat.isFile()) throw new Error("Requested path is not a file");
  if (stat.size > maxBytes) throw new Error(`File exceeds read limit of ${maxBytes} bytes`);
  const buffer = await fs.readFile(resolved.absolutePath);
  if (isBinaryBuffer(buffer)) throw new Error("Binary files are not supported");
  return { resolved, stat, buffer, content: buffer.toString("utf8") };
}

async function createDirectorySafely(projectName, requestedPath) {
  const project = await resolveProject(projectName);
  await assertProjectWriteAllowed(project);
  const relativePath = assertSafeRelativeLexical(requestedPath, { allowDot: false });
  const parts = pathParts(relativePath).filter((part) => part !== ".");
  let current = project.root;

  for (const part of parts) {
    if (SECRET_PATTERNS.some((pattern) => pattern.test(part))) {
      throw new Error(`Sensitive path is blocked: ${part}`);
    }
    current = path.join(current, part);
    if (!current.startsWith(project.root + path.sep)) {
      throw new Error("Path escapes registered project root");
    }
    try {
      const stat = await fs.lstat(current);
      if (stat.isSymbolicLink()) throw new Error("Directory creation through symlinks is blocked");
      if (!stat.isDirectory()) throw new Error(`Path component is not a directory: ${part}`);
    } catch (error) {
      if (error?.code === "ENOENT") {
        await fs.mkdir(current, { mode: 0o755 });
      } else {
        throw error;
      }
    }
  }

  return { project: project.name, path: relativePath, created: true };
}

function validateRef(value) {
  if (typeof value !== "string" || value.length < 1 || value.length > 200) {
    throw new Error("Invalid Git ref");
  }
  if (value.startsWith("-") || value.includes("..") || !/^[A-Za-z0-9._/-]+$/.test(value)) {
    throw new Error("Unsafe Git ref");
  }
  return value;
}

async function validateMcpBranch(project, branch) {
  if (!branch.startsWith("mcp/")) throw new Error("Branch must start with mcp/");
  if (branch.length > 120) throw new Error("Branch name is too long");
  const result = await execGitAt(project.root, ["check-ref-format", "--branch", branch], { allowFailure: true });
  if (result.exitCode !== 0) throw new Error("Invalid Git branch name");
  return branch;
}

async function assertSafeCheckoutConfig(project) {
  const hasActiveFilterRule = (content) =>
    content.split(/\r?\n/).some((line) => {
      const trimmed = line.trim();

      if (!trimmed || trimmed.startsWith("#")) {
        return false;
      }

      return /(?:^|\s)(?:filter(?:=[^\s]+)?|-filter|!filter)(?=\s|$)/i.test(trimmed);
    });

  const inspectAttributeFile = async (filePath, label) => {
    try {
      const stat = await fs.lstat(filePath);

      if (!stat.isFile()) {
        throw new Error(
          `Git attributes source is not a regular file: ${label}`
        );
      }

      const content = await fs.readFile(filePath, "utf8");

      if (hasActiveFilterRule(content)) {
        throw new Error(
          `Repository uses a Git filter via ${label}; checkout/staging is blocked until reviewed`
        );
      }
    } catch (error) {
      if (error?.code === "ENOENT") {
        return;
      }

      throw error;
    }
  };

  const attributesResult = await execGitAt(
    project.root,
    [
      "ls-files",
      "-z",
      "--cached",
      "--others",
      "--exclude-standard",
      "--",
      ":(literal).gitattributes",
      ":(glob)**/.gitattributes"
    ],
    { allowFailure: true }
  );

  const attributeFiles = [
    ...new Set(
      attributesResult.stdout
        .split("\0")
        .filter(Boolean)
    )
  ];

  for (const relativePath of attributeFiles) {
    const candidate = path.resolve(
      project.root,
      relativePath
    );

    if (
      candidate !== project.root &&
      !candidate.startsWith(project.root + path.sep)
    ) {
      throw new Error(
        "Git attributes path escapes registered project root"
      );
    }

    await inspectAttributeFile(
      candidate,
      `repository ${relativePath}`
    );
  }

  const infoResult = await execGitAt(
    project.root,
    ["rev-parse", "--git-path", "info/attributes"],
    { allowFailure: true }
  );

  const infoValue = infoResult.stdout.trim();

  if (infoValue) {
    const infoPath = path.isAbsolute(infoValue)
      ? infoValue
      : path.resolve(project.root, infoValue);

    await inspectAttributeFile(
      infoPath,
      "repository info/attributes"
    );
  }

  const configuredGlobal = await execGitAt(
    project.root,
    ["config", "--path", "--get", "core.attributesfile"],
    { allowFailure: true }
  );

  const configuredValue =
    configuredGlobal.stdout.trim();

  if (configuredValue) {
    const configuredPath = path.isAbsolute(
      configuredValue
    )
      ? configuredValue
      : path.resolve(
          os.homedir(),
          configuredValue
        );

    await inspectAttributeFile(
      configuredPath,
      "core.attributesFile"
    );
  } else {
    const xdgHome =
      process.env.XDG_CONFIG_HOME ||
      path.join(os.homedir(), ".config");

    await inspectAttributeFile(
      path.join(
        xdgHome,
        "git",
        "attributes"
      ),
      "user Git attributes"
    );

    await inspectAttributeFile(
      path.join(
        os.homedir(),
        ".gitattributes"
      ),
      "legacy user Git attributes"
    );
  }
}
function literalPathspec(relativePath) {
  return `:(literal)${relativePath}`;
}

async function validateGitRelativePath(project, requestedPath) {
  const relativePath = assertSafeRelativeLexical(requestedPath, { allowDot: false });
  if (relativePath.startsWith(":")) throw new Error("Git pathspec magic is not allowed");
  const candidate = path.resolve(project.root, relativePath);
  if (!candidate.startsWith(project.root + path.sep)) throw new Error("Path escapes registered project root");
  try {
    const real = await fs.realpath(candidate);
    if (real !== project.root && !real.startsWith(project.root + path.sep)) {
      throw new Error("Path escapes registered project root");
    }
    assertNotSensitive(path.relative(project.root, real));
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  return relativePath;
}

async function gitNameList(project, args) {
  const result = await execGitAt(project.root, [...args, "-z"]);
  return result.stdout.split("\0").filter(Boolean);
}

async function getSafeDiffFiles(project, revisionArgs, staged) {
  const args = ["diff", "--name-only", "--no-ext-diff", "--no-textconv", "--no-renames"];
  if (staged) args.push("--cached");
  args.push(...revisionArgs);
  const files = await gitNameList(project, args);
  const safeFiles = files.filter((value) => !isSensitiveRelativePath(value));
  return {
    safeFiles,
    excludedSensitiveFiles: files.length - safeFiles.length
  };
}

function statusLineSensitive(line) {
  if (!line || line.startsWith("##")) return false;
  const value = line.length > 3 ? line.slice(3) : line;
  return value.split(" -> ").some((part) => isSensitiveRelativePath(part.replace(/^"|"$/g, "")));
}

function slugify(value) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48) || "worktree";
}

async function pathExists(value) {
  try {
    await fs.lstat(value);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function collectFiles(root, startAbsolute, startRelative, { nameContains = "", maxResults = 100 }) {
  const results = [];
  const needle = nameContains.toLowerCase();

  async function walk(dir, relativeDir, depth) {
    if (results.length >= maxResults || depth > 12) return;
    const entries = await fs.readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (results.length >= maxResults) break;
      if (isSensitiveRelativePath(entry.name)) continue;
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory() && SEARCH_IGNORED_DIRS.has(entry.name)) continue;
      const absolute = path.join(dir, entry.name);
      const relative = path.join(relativeDir, entry.name);
      if (!needle || entry.name.toLowerCase().includes(needle)) {
        results.push({
          path: relative,
          type: entry.isDirectory() ? "directory" : entry.isFile() ? "file" : "other"
        });
      }
      if (entry.isDirectory()) await walk(absolute, relative, depth + 1);
    }
  }

  await walk(startAbsolute, startRelative === "." ? "" : startRelative, 0);
  return results;
}

async function searchText(projectName, requestedPath, query, caseSensitive, maxResults) {
  const resolved = await resolveInsideProject(projectName, requestedPath || ".");
  if (resolved.hasSymlink) throw new Error("Searching through symlinked paths is blocked");
  const stat = await fs.stat(resolved.absolutePath);
  const results = [];
  const needle = caseSensitive ? query : query.toLowerCase();

  async function scanFile(absolute, relative) {
    if (results.length >= maxResults) return;
    const fileStat = await fs.stat(absolute);
    if (!fileStat.isFile() || fileStat.size > MAX_SEARCH_FILE_BYTES) return;
    const buffer = await fs.readFile(absolute);
    if (isBinaryBuffer(buffer)) return;
    const lines = buffer.toString("utf8").split(/\r?\n/);
    for (let i = 0; i < lines.length && results.length < maxResults; i++) {
      const haystack = caseSensitive ? lines[i] : lines[i].toLowerCase();
      const index = haystack.indexOf(needle);
      if (index !== -1) {
        results.push({
          path: relative,
          line: i + 1,
          column: index + 1,
          preview: lines[i].slice(0, 300)
        });
      }
    }
  }

  async function walk(dir, relativeDir, depth) {
    if (results.length >= maxResults || depth > 12) return;
    const entries = await fs.readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (results.length >= maxResults) break;
      if (isSensitiveRelativePath(entry.name)) continue;
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory() && SEARCH_IGNORED_DIRS.has(entry.name)) continue;
      const absolute = path.join(dir, entry.name);
      const relative = path.join(relativeDir, entry.name);
      if (entry.isDirectory()) await walk(absolute, relative, depth + 1);
      else if (entry.isFile()) await scanFile(absolute, relative);
    }
  }

  if (stat.isFile()) {
    await scanFile(resolved.absolutePath, resolved.relativePath);
  } else if (stat.isDirectory()) {
    await walk(resolved.absolutePath, resolved.relativePath === "." ? "" : resolved.relativePath, 0);
  } else {
    throw new Error("Search path must be a file or directory");
  }

  return results;
}

async function packageScriptsFor(projectName) {
  const project = await resolveProject(projectName);
  const backend = getSandboxBackend();
  const killSwitch = await killSwitchStatus();
  const report = await projectScriptReport({ spec: project, backend, killSwitch });

  // Preserve the v1.0 contract fields, then append the P2 additions (design §5).
  return {
    project: report.project,
    packageManager: report.packageManager,
    scripts: report.scripts,
    allowedScripts: report.allowedScripts,
    executionEnabled: report.executionEnabled,
    reason: report.reason,
    packageSha256: report.packageSha256,
    deniedScripts: report.deniedScripts,
    executionSupported: report.executionSupported,
    killSwitchActive: report.killSwitchActive,
    scriptHashes: report.scriptHashes,
    hashMatches: report.hashMatches,
    sensitiveFilesInWorktree: report.sensitiveFilesInWorktree
  };
}

const server = new McpServer({
  name: "local-mcp-dev-runner",
  version: "2.1.0"
});

server.registerTool(
  "list_projects",
  {
    title: "List registered projects",
    description: "List projects registered with the local MCP runner and their access mode. Auto-discovered repositories from trusted workspaces are included as READ_ONLY.",
    inputSchema: z.object({}),
    outputSchema: z.object({
      projects: z.array(z.object({
        name: z.string(),
        mode: z.enum(["READ_ONLY", "READ_WRITE"]),
        managedWorktree: z.boolean(),
        sourceProject: z.string().nullable(),
        branch: z.string().nullable(),
        source: z.enum(["explicit", "workspace"]),
        workspace: z.string().nullable()
      }))
    })
  },
  async () => {
    const registry = await loadRegistry();
    const index = await buildDiscoveryIndex(registry);

    const explicit = Object.entries(registry.projects).map(([name, project]) => ({
      name,
      mode: project.write === true ? "READ_WRITE" : "READ_ONLY",
      managedWorktree: project.managedWorktree === true,
      sourceProject: project.sourceProject || null,
      branch: project.branch || null,
      source: "explicit",
      workspace: null
    }));

    // Discovery never overrides an explicit entry and never duplicates one.
    const discovered = index.entries.map((entry) => ({
      name: entry.name,
      mode: "READ_ONLY",
      managedWorktree: false,
      sourceProject: null,
      branch: null,
      source: "workspace",
      workspace: entry.workspace
    }));

    const projects = [...explicit, ...discovered].sort((a, b) =>
      a.name < b.name ? -1 : a.name > b.name ? 1 : 0
    );
    return structured({ projects }, projects);
  }
);

server.registerTool(
  "project_info",
  {
    title: "Project information",
    description: "Return project root, access mode, managed-worktree metadata, and Git branch state.",
    inputSchema: z.object({ project: z.string().min(1) }),
    outputSchema: z.object({
      project: z.string(),
      root: z.string(),
      mode: z.enum(["READ_ONLY", "READ_WRITE"]),
      managedWorktree: z.boolean(),
      sourceProject: z.string().nullable(),
      configuredBranch: z.string().nullable(),
      git: z.object({
        isGit: z.boolean(),
        topLevel: z.string().nullable(),
        branch: z.string().nullable(),
        detached: z.boolean()
      })
    })
  },
  async ({ project }) => {
    const resolved = await resolveProject(project);
    const git = await getGitState(resolved);
    return structured({
      project,
      root: resolved.root,
      mode: resolved.write ? "READ_WRITE" : "READ_ONLY",
      managedWorktree: resolved.managedWorktree,
      sourceProject: resolved.sourceProject,
      configuredBranch: resolved.branch,
      git
    });
  }
);

server.registerTool(
  "list_directory",
  {
    title: "List project directory",
    description: "List one directory inside a registered project while hiding sensitive paths.",
    inputSchema: z.object({
      project: z.string().min(1),
      path: z.string().default(".")
    }),
    outputSchema: z.object({
      project: z.string(),
      path: z.string(),
      entries: z.array(z.object({
        name: z.string(),
        type: z.enum(["directory", "file", "symlink", "other"])
      })),
      truncated: z.boolean()
    })
  },
  async ({ project, path: requestedPath }) => {
    const resolved = await resolveInsideProject(project, requestedPath);
    const stat = await fs.stat(resolved.absolutePath);
    if (!stat.isDirectory()) throw new Error("Requested path is not a directory");
    const entries = await fs.readdir(resolved.absolutePath, { withFileTypes: true });
    const safeEntries = entries
      .filter((entry) => !isSensitiveRelativePath(entry.name))
      .slice(0, MAX_DIRECTORY_ENTRIES)
      .map((entry) => ({
        name: entry.name,
        type: entry.isDirectory() ? "directory" : entry.isFile() ? "file" : entry.isSymbolicLink() ? "symlink" : "other"
      }));
    return structured({
      project,
      path: resolved.relativePath,
      entries: safeEntries,
      truncated: entries.length > MAX_DIRECTORY_ENTRIES
    });
  }
);

server.registerTool(
  "find_files",
  {
    title: "Find files",
    description: "Recursively find files/directories by name substring without traversing sensitive paths, symlinks, or dependency/build directories.",
    inputSchema: z.object({
      project: z.string().min(1),
      path: z.string().default("."),
      nameContains: z.string().default(""),
      maxResults: z.number().int().min(1).max(MAX_SEARCH_RESULTS).default(100)
    }),
    outputSchema: z.object({
      project: z.string(),
      path: z.string(),
      results: z.array(z.object({
        path: z.string(),
        type: z.enum(["directory", "file", "other"])
      })),
      truncated: z.boolean()
    })
  },
  async ({ project, path: requestedPath, nameContains, maxResults }) => {
    const resolved = await resolveInsideProject(project, requestedPath);
    if (resolved.hasSymlink) throw new Error("Finding through symlinked paths is blocked");
    const stat = await fs.stat(resolved.absolutePath);
    if (!stat.isDirectory()) throw new Error("Requested path is not a directory");
    const results = await collectFiles(project, resolved.absolutePath, resolved.relativePath, { nameContains, maxResults });
    return structured({ project, path: resolved.relativePath, results, truncated: results.length >= maxResults });
  }
);

server.registerTool(
  "search_text",
  {
    title: "Search project text",
    description: "Search for a fixed text string in project files with bounded output; regex and shell execution are not used.",
    inputSchema: z.object({
      project: z.string().min(1),
      path: z.string().default("."),
      query: z.string().min(1),
      caseSensitive: z.boolean().default(false),
      maxResults: z.number().int().min(1).max(MAX_SEARCH_RESULTS).default(100)
    }),
    outputSchema: z.object({
      project: z.string(),
      query: z.string(),
      results: z.array(z.object({
        path: z.string(),
        line: z.number().int(),
        column: z.number().int(),
        preview: z.string()
      })),
      truncated: z.boolean()
    })
  },
  async ({ project, path: requestedPath, query, caseSensitive, maxResults }) => {
    const results = await searchText(project, requestedPath, query, caseSensitive, maxResults);
    return structured({ project, query, results, truncated: results.length >= maxResults });
  }
);

server.registerTool(
  "read_file",
  {
    title: "Read project file",
    description: "Read one UTF-8 text file inside a registered project.",
    inputSchema: z.object({
      project: z.string().min(1),
      path: z.string().min(1)
    }),
    outputSchema: z.object({
      project: z.string(),
      path: z.string(),
      content: z.string()
    })
  },
  async ({ project, path: requestedPath }) => {
    const result = await readTextFile(project, requestedPath);
    return structured({ project, path: result.resolved.relativePath, content: result.content });
  }
);

server.registerTool(
  "read_files",
  {
    title: "Read multiple project files",
    description: "Read up to 20 UTF-8 text files from one registered project.",
    inputSchema: z.object({
      project: z.string().min(1),
      paths: z.array(z.string().min(1)).min(1).max(20)
    }),
    outputSchema: z.object({
      project: z.string(),
      files: z.array(z.object({
        path: z.string(),
        content: z.string()
      }))
    })
  },
  async ({ project, paths }) => {
    const files = [];
    let totalBytes = 0;
    for (const requestedPath of paths) {
      const result = await readTextFile(project, requestedPath);
      totalBytes += result.buffer.length;
      if (totalBytes > 1024 * 1024) throw new Error("Combined read exceeds 1 MiB limit");
      files.push({ path: result.resolved.relativePath, content: result.content });
    }
    return structured({ project, files });
  }
);

server.registerTool(
  "file_info",
  {
    title: "File information",
    description: "Return size and SHA-256 for an existing text file.",
    inputSchema: z.object({
      project: z.string().min(1),
      path: z.string().min(1)
    }),
    outputSchema: z.object({
      project: z.string(),
      path: z.string(),
      bytes: z.number().int(),
      sha256: z.string()
    })
  },
  async ({ project, path: requestedPath }) => {
    const result = await readTextFile(project, requestedPath, MAX_WRITE_FILE_BYTES);
    return structured({
      project,
      path: result.resolved.relativePath,
      bytes: result.buffer.length,
      sha256: sha256Buffer(result.buffer)
    });
  }
);

server.registerTool(
  "create_directory",
  {
    title: "Create project directory",
    description: "Create a directory path only in a write-enabled non-protected project/worktree; symlink traversal is blocked.",
    inputSchema: z.object({
      project: z.string().min(1),
      path: z.string().min(1)
    }),
    outputSchema: z.object({
      project: z.string(),
      path: z.string(),
      created: z.boolean()
    })
  },
  async ({ project, path: requestedPath }) => structured(await createDirectorySafely(project, requestedPath))
);

server.registerTool(
  "create_file",
  {
    title: "Create new project file",
    description: "Create a new UTF-8 file in a write-enabled project. Existing files are never overwritten.",
    inputSchema: z.object({
      project: z.string().min(1),
      path: z.string().min(1),
      content: z.string()
    }),
    outputSchema: z.object({
      project: z.string(),
      path: z.string(),
      created: z.boolean(),
      bytes: z.number().int(),
      sha256: z.string()
    })
  },
  async ({ project, path: requestedPath, content }) => {
    const buffer = Buffer.from(content, "utf8");
    if (buffer.length > MAX_WRITE_FILE_BYTES) {
      throw new Error(`Content exceeds safe write limit of ${MAX_WRITE_FILE_BYTES} bytes`);
    }
    const resolved = await resolveNewFileTarget(project, requestedPath);
    await fs.writeFile(resolved.absolutePath, buffer, { flag: "wx", mode: 0o644 });
    return structured({
      project,
      path: resolved.relativePath,
      created: true,
      bytes: buffer.length,
      sha256: sha256Buffer(buffer)
    });
  }
);

server.registerTool(
  "replace_text",
  {
    title: "Safely replace text",
    description: "Replace exactly one text block in an existing file using an expected SHA-256 concurrency guard.",
    inputSchema: z.object({
      project: z.string().min(1),
      path: z.string().min(1),
      expectedSha256: z.string().regex(/^[a-fA-F0-9]{64}$/),
      oldText: z.string().min(1),
      newText: z.string()
    }),
    outputSchema: z.object({
      project: z.string(),
      path: z.string(),
      replaced: z.boolean(),
      previousSha256: z.string(),
      sha256: z.string(),
      bytes: z.number().int()
    })
  },
  async ({ project, path: requestedPath, expectedSha256, oldText, newText }) => {
    const { resolved, stat } = await resolveWritableExistingFile(project, requestedPath);
    const current = await fs.readFile(resolved.absolutePath);
    if (isBinaryBuffer(current)) throw new Error("Binary files are not supported");
    const currentHash = sha256Buffer(current);
    if (currentHash.toLowerCase() !== expectedSha256.toLowerCase()) {
      throw new Error("SHA-256 mismatch: file changed since it was inspected");
    }

    const currentText = current.toString("utf8");
    let count = 0;
    let offset = 0;
    while (true) {
      const index = currentText.indexOf(oldText, offset);
      if (index === -1) break;
      count += 1;
      offset = index + oldText.length;
    }
    if (count === 0) throw new Error("oldText was not found");
    if (count !== 1) throw new Error(`oldText must match exactly once; found ${count} matches`);

    const index = currentText.indexOf(oldText);
    const updatedText = currentText.slice(0, index) + newText + currentText.slice(index + oldText.length);
    const updated = Buffer.from(updatedText, "utf8");
    if (updated.length > MAX_WRITE_FILE_BYTES) {
      throw new Error(`Updated file exceeds safe edit limit of ${MAX_WRITE_FILE_BYTES} bytes`);
    }

    const tempPath = `${resolved.absolutePath}.local-mcp-tmp-${process.pid}-${Date.now()}`;
    try {
      await fs.writeFile(tempPath, updated, { flag: "wx", mode: stat.mode & 0o777 });
      const latest = await fs.readFile(resolved.absolutePath);
      if (sha256Buffer(latest).toLowerCase() !== expectedSha256.toLowerCase()) {
        throw new Error("SHA-256 mismatch: file changed during edit");
      }
      await fs.rename(tempPath, resolved.absolutePath);
    } catch (error) {
      await fs.rm(tempPath, { force: true }).catch(() => {});
      throw error;
    }

    return structured({
      project,
      path: resolved.relativePath,
      replaced: true,
      previousSha256: currentHash,
      sha256: sha256Buffer(updated),
      bytes: updated.length
    });
  }
);

server.registerTool(
  "delete_file",
  {
    title: "Safely delete file",
    description: "Delete one existing file only when the caller supplies its exact current SHA-256.",
    inputSchema: z.object({
      project: z.string().min(1),
      path: z.string().min(1),
      expectedSha256: z.string().regex(/^[a-fA-F0-9]{64}$/)
    }),
    outputSchema: z.object({
      project: z.string(),
      path: z.string(),
      deleted: z.boolean()
    })
  },
  async ({ project, path: requestedPath, expectedSha256 }) => {
    const { resolved } = await resolveWritableExistingFile(project, requestedPath);
    const current = await fs.readFile(resolved.absolutePath);
    if (sha256Buffer(current).toLowerCase() !== expectedSha256.toLowerCase()) {
      throw new Error("SHA-256 mismatch: file changed since it was inspected");
    }
    await fs.unlink(resolved.absolutePath);
    return structured({ project, path: resolved.relativePath, deleted: true });
  }
);

server.registerTool(
  "git_status",
  {
    title: "Git status",
    description: "Return safe Git status while omitting sensitive-path entries.",
    inputSchema: z.object({ project: z.string().min(1) }),
    outputSchema: z.object({
      project: z.string(),
      status: z.string()
    })
  },
  async ({ project }) => {
    const result = await runGit(project, ["status", "--short", "--branch", "--untracked-files=normal"]);
    const lines = result.stdout.split("\n").filter((line) => !statusLineSensitive(line));
    return structured({ project, status: lines.join("\n") });
  }
);

server.registerTool(
  "git_diff",
  {
    title: "Git diff",
    description: "Return a bounded diff excluding sensitive files. Supports working-tree, staged, or ref-to-ref diffs.",
    inputSchema: z.object({
      project: z.string().min(1),
      staged: z.boolean().default(false),
      path: z.string().optional(),
      baseRef: z.string().optional(),
      headRef: z.string().optional()
    }),
    outputSchema: z.object({
      project: z.string(),
      diff: z.string(),
      excludedSensitiveFiles: z.number().int(),
      truncatedFiles: z.number().int()
    })
  },
  async ({ project, staged, path: requestedPath, baseRef, headRef }) => {
    const resolvedProject = await resolveProject(project);
    if (staged && (baseRef || headRef)) throw new Error("staged cannot be combined with ref-to-ref diff");
    const revisionArgs = [];
    if (baseRef) revisionArgs.push(validateRef(baseRef));
    if (headRef) revisionArgs.push(validateRef(headRef));
    if (!baseRef && headRef) throw new Error("headRef requires baseRef");

    let safeFiles;
    let excludedSensitiveFiles = 0;
    if (requestedPath) {
      safeFiles = [await validateGitRelativePath(resolvedProject, requestedPath)];
    } else {
      const discovered = await getSafeDiffFiles(resolvedProject, revisionArgs, staged);
      safeFiles = discovered.safeFiles;
      excludedSensitiveFiles = discovered.excludedSensitiveFiles;
    }

    const limited = safeFiles.slice(0, MAX_DIFF_FILES);
    if (limited.length === 0) {
      return structured({ project, diff: "", excludedSensitiveFiles, truncatedFiles: 0 });
    }

    const args = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames"];
    if (staged) args.push("--cached");
    args.push(...revisionArgs, "--", ...limited.map(literalPathspec));
    const result = await execGitAt(resolvedProject.root, args);
    return structured({
      project,
      diff: clipText(result.stdout),
      excludedSensitiveFiles,
      truncatedFiles: Math.max(0, safeFiles.length - limited.length)
    });
  }
);

server.registerTool(
  "git_log",
  {
    title: "Git log",
    description: "Return recent commit metadata, optionally scoped to one safe path.",
    inputSchema: z.object({
      project: z.string().min(1),
      limit: z.number().int().min(1).max(50).default(10),
      path: z.string().optional()
    }),
    outputSchema: z.object({
      project: z.string(),
      log: z.string()
    })
  },
  async ({ project, limit, path: requestedPath }) => {
    const resolvedProject = await resolveProject(project);
    const args = [
      "log",
      `-${limit}`,
      "--date=short",
      "--pretty=format:%h%x09%ad%x09%an%x09%s"
    ];
    if (requestedPath) {
      const safePath = await validateGitRelativePath(resolvedProject, requestedPath);
      args.push("--", literalPathspec(safePath));
    }
    const result = await execGitAt(resolvedProject.root, args);
    return structured({ project, log: clipText(result.stdout) });
  }
);

server.registerTool(
  "git_branch_list",
  {
    title: "List Git branches",
    description: "List local Git branches and the current branch.",
    inputSchema: z.object({ project: z.string().min(1) }),
    outputSchema: z.object({
      project: z.string(),
      branches: z.string()
    })
  },
  async ({ project }) => {
    const result = await runGit(project, ["branch", "--format=%(HEAD)%09%(refname:short)%09%(objectname:short)%09%(subject)"]);
    return structured({ project, branches: result.stdout });
  }
);

server.registerTool(
  "git_create_branch",
  {
    title: "Create safe Git branch",
    description: "Create an mcp/* branch without checking it out. main/master and arbitrary branch names are not permitted.",
    inputSchema: z.object({
      project: z.string().min(1),
      branch: z.string().min(1),
      baseRef: z.string().default("HEAD")
    }),
    outputSchema: z.object({
      project: z.string(),
      branch: z.string(),
      baseRef: z.string(),
      created: z.boolean(),
      checkedOut: z.boolean()
    })
  },
  async ({ project, branch, baseRef }) => {
    const resolvedProject = await resolveProject(project);
    if (resolvedProject.managedWorktree) throw new Error("Create branches from the source project, not a managed worktree");
    await validateMcpBranch(resolvedProject, branch);
    validateRef(baseRef);
    const exists = await execGitAt(resolvedProject.root, ["show-ref", "--verify", "--quiet", `refs/heads/${branch}`], { allowFailure: true });
    if (exists.exitCode === 0) throw new Error(`Branch already exists: ${branch}`);
    await execGitAt(resolvedProject.root, ["rev-parse", "--verify", "--quiet", `${baseRef}^{commit}`]);
    await execGitAt(resolvedProject.root, ["branch", branch, baseRef]);
    return structured({ project, branch, baseRef, created: true, checkedOut: false });
  }
);

server.registerTool(
  "git_worktree_create",
  {
    title: "Create managed Git worktree",
    description: "Create/register an isolated writable worktree on an mcp/* branch under the runner worktree directory.",
    inputSchema: z.object({
      project: z.string().min(1),
      branch: z.string().min(1),
      baseRef: z.string().default("HEAD")
    }),
    outputSchema: z.object({
      sourceProject: z.string(),
      project: z.string(),
      branch: z.string(),
      root: z.string(),
      mode: z.enum(["READ_WRITE"]),
      created: z.boolean()
    })
  },
  async ({ project, branch, baseRef }) => {
    const source = await resolveProject(project);
    if (source.managedWorktree) throw new Error("Nested managed worktrees are not allowed");
    await validateMcpBranch(source, branch);
    validateRef(baseRef);
    await assertSafeCheckoutConfig(source);
    await execGitAt(source.root, ["rev-parse", "--verify", "--quiet", `${baseRef}^{commit}`]);

    const hash = createHash("sha256").update(`${project}:${branch}`).digest("hex").slice(0, 8);
    const managedName = `${slugify(project)}--${slugify(branch.replace(/^mcp\//, ""))}--${hash}`;
    const target = path.join(WORKTREE_BASE, managedName);
    await fs.mkdir(WORKTREE_BASE, { recursive: true, mode: 0o700 });
    if (await pathExists(target)) throw new Error(`Managed worktree path already exists: ${managedName}`);

    const registry = await loadRegistry();
    if (registry.projects[managedName]) throw new Error(`Managed project already exists: ${managedName}`);

    const branchExists = await execGitAt(source.root, ["show-ref", "--verify", "--quiet", `refs/heads/${branch}`], { allowFailure: true });
    if (branchExists.exitCode === 0) {
      await execGitAt(source.root, ["worktree", "add", target, branch], { timeout: 120000 });
    } else {
      await execGitAt(source.root, ["worktree", "add", "-b", branch, target, baseRef], { timeout: 120000 });
    }

    try {
      const realTarget = await fs.realpath(target);
      const realBase = await fs.realpath(WORKTREE_BASE);
      if (!realTarget.startsWith(realBase + path.sep)) throw new Error("Managed worktree escaped worktree base");
      registry.projects[managedName] = {
        root: realTarget,
        write: true,
        managedWorktree: true,
        sourceProject: project,
        branch,
        runScripts: false,
        allowedScripts: []
      };
      await saveRegistry(registry);
    } catch (error) {
      await execGitAt(source.root, ["worktree", "remove", target], { allowFailure: true, timeout: 120000 }).catch(() => {});
      throw error;
    }

    return structured({
      sourceProject: project,
      project: managedName,
      branch,
      root: target,
      mode: "READ_WRITE",
      created: true
    });
  }
);

server.registerTool(
  "git_worktree_remove",
  {
    title: "Remove managed Git worktree",
    description: "Remove a clean runner-managed worktree and unregister it. Dirty worktrees are refused; the branch is retained.",
    inputSchema: z.object({ project: z.string().min(1) }),
    outputSchema: z.object({
      project: z.string(),
      sourceProject: z.string(),
      branch: z.string().nullable(),
      removed: z.boolean(),
      branchRetained: z.boolean()
    })
  },
  async ({ project }) => {
    const registry = await loadRegistry();
    const entry = registry.projects[project];
    if (!entry) throw new Error(`Unknown project: ${project}`);
    if (entry.managedWorktree !== true || !entry.sourceProject) {
      throw new Error("Only runner-managed worktrees can be removed");
    }

    const target = await fs.realpath(entry.root);
    const realBase = await fs.realpath(WORKTREE_BASE);
    if (!target.startsWith(realBase + path.sep)) throw new Error("Managed worktree path is outside worktree base");
    const source = await resolveProject(entry.sourceProject);
    const status = await execGitAt(target, ["status", "--porcelain=v1", "--untracked-files=normal"]);
    if (status.stdout.trim()) throw new Error("Managed worktree is dirty; refusing removal");

    await execGitAt(source.root, ["worktree", "remove", target], { timeout: 120000 });
    delete registry.projects[project];
    await saveRegistry(registry);
    return structured({ project, sourceProject: entry.sourceProject, branch: entry.branch || null, removed: true, branchRetained: true });
  }
);

server.registerTool(
  "git_commit",
  {
    title: "Commit managed worktree changes",
    description: "Stage and commit only non-sensitive changes in a writable runner-managed mcp/* worktree. Hooks and GPG signing are disabled; push is not available.",
    inputSchema: z.object({
      project: z.string().min(1),
      message: z.string().min(1).max(2000)
    }),
    outputSchema: z.object({
      project: z.string(),
      branch: z.string().nullable(),
      commit: z.string(),
      output: z.string()
    })
  },
  async ({ project, message }) => {
    if (message.includes("\0")) throw new Error("Commit message contains NUL byte");
    const worktree = await resolveProject(project);
    if (!worktree.managedWorktree) throw new Error("git_commit is allowed only in runner-managed worktrees");
    await assertProjectWriteAllowed(worktree);
    await assertSafeCheckoutConfig(worktree);

    const stagedBefore = await gitNameList(worktree, ["diff", "--cached", "--name-only", "--no-renames"]);
    const sensitiveStaged = stagedBefore.filter(isSensitiveRelativePath);
    if (sensitiveStaged.length) throw new Error("Sensitive files are already staged; refusing commit");

    const unstaged = await gitNameList(worktree, ["diff", "--name-only", "--no-renames"]);
    const untracked = await gitNameList(worktree, ["ls-files", "--others", "--exclude-standard"]);
    const candidates = [...new Set([...stagedBefore, ...unstaged, ...untracked])]
      .filter((value) => !isSensitiveRelativePath(value));
    if (candidates.length === 0) throw new Error("No safe changes to commit");
    if (candidates.length > MAX_COMMIT_FILES) throw new Error(`Too many changed files to commit safely: ${candidates.length}`);

    await execGitAt(worktree.root, ["add", "-A", "--", ...candidates.map(literalPathspec)], { timeout: 120000 });
    const stagedAfter = await gitNameList(worktree, ["diff", "--cached", "--name-only", "--no-renames"]);
    if (stagedAfter.some(isSensitiveRelativePath)) throw new Error("Sensitive file reached staging area; refusing commit");
    if (stagedAfter.length === 0) throw new Error("No staged changes after safe staging");

    const result = await execGitAt(worktree.root, ["commit", "--no-verify", "-m", message], { timeout: 120000 });
    const head = await execGitAt(worktree.root, ["rev-parse", "--short", "HEAD"]);
    return structured({ project, branch: (await getGitState(worktree)).branch, commit: head.stdout.trim(), output: clipText(result.stdout + result.stderr) });
  }
);

server.registerTool(
  "project_scripts",
  {
    title: "List project scripts",
    description:
      "List package.json scripts and report whether sandboxed execution is supported for this project. " +
      "executionSupported answers 'can this environment run scripts at all'; executionEnabled folds in the kill switch.",
    inputSchema: z.object({ project: z.string().min(1) }),
    outputSchema: z
      .object({
        project: z.string(),
        packageManager: z.string().nullable(),
        scripts: z.array(z.string()),
        allowedScripts: z.array(z.string()).optional(),
        executionEnabled: z.boolean(),
        reason: z.string().nullable().optional(),
        packageSha256: z.string().nullable(),
        deniedScripts: z.array(z.any()),
        executionSupported: z.boolean(),
        killSwitchActive: z.boolean(),
        scriptHashes: z.record(z.string(), z.string()),
        hashMatches: z.boolean(),
        sensitiveFilesInWorktree: z.array(z.string())
      })
      .strict()
  },
  async ({ project }) => structured(await packageScriptsFor(project))
);

server.registerTool(
  "run_script",
  {
    title: "Run project script",
    description:
      "Execute an allowlisted, hash-pinned npm/pnpm script inside a macOS Seatbelt sandbox. " +
      "network is always 'none'; script execution is confined to a runner-managed READ_WRITE mcp/* worktree. " +
      "A non-zero script exit code is a successful MCP call (the script ran; the test failed).",
    inputSchema: z
      .object({
        project: z.string().min(1),
        script: z.string().min(1),
        expectedPackageSha256: z.string().regex(/^[0-9a-f]{64}$/i).optional(),
        network: z.string().optional(),
        timeoutSeconds: z.number().int().min(1).max(600).optional()
      })
      .strict(),
    outputSchema: z
      .object({
        project: z.string(),
        script: z.string(),
        packageManager: z.string(),
        packageSha256: z.string(),
        scriptSha256: z.string(),
        network: z.literal("none"),
        startedAt: z.string(),
        endedAt: z.string(),
        durationMs: z.number().int(),
        exitCode: z.number().int().nullable(),
        signal: z.string().nullable(),
        timedOut: z.boolean(),
        cancelled: z.boolean(),
        stdout: z.string(),
        stderr: z.string(),
        stdoutTruncated: z.boolean(),
        stderrTruncated: z.boolean(),
        decision: z.string(),
        reason: z.string().nullable(),
        timeoutSeconds: z.number().int(),
        descendantsRemaining: z.boolean(),
        descendantState: z.string()
      })
      .strict()
  },
  async ({ project, script, expectedPackageSha256 = null, network = "none", timeoutSeconds = null }) => {
    // P2 safety invariant: a denial or an unavailable backend is the only outcome.
    // zero arbitrary shell API: the input schema is strict() and rejects any
    // command/args/shell/exec/cwd/env/binary/executable field. There is
    // deliberately no unsandboxed fallback path — executeScript refuses when the
    // backend cannot enforce the sandbox instead of degrading to a bare spawn.
    if (network !== "none") {
      throw new Error(
        `${REASON.NETWORK_NOT_NONE}: network access is never granted (received ${JSON.stringify(network)})`
      );
    }

    const spec = await resolveProject(project);
    const gitState = await getGitState(spec).catch(() => null);
    const result = await executeScript({
      spec,
      gitState,
      script,
      expectedPackageSha256,
      network,
      timeoutSeconds,
      backend: getSandboxBackend()
    });

    if (result.isError) {
      const detail = result.detail != null ? `: ${JSON.stringify(result.detail)}` : "";
      throw new Error(`${result.decision}${detail}`);
    }

    const payload = {
      project: result.project,
      script: result.script,
      packageManager: result.packageManager,
      packageSha256: result.packageSha256,
      scriptSha256: result.scriptSha256,
      network: result.network,
      startedAt: result.startedAt,
      endedAt: result.endedAt,
      durationMs: result.durationMs,
      exitCode: result.exitCode,
      signal: result.signal,
      timedOut: result.timedOut,
      cancelled: result.cancelled,
      stdout: result.stdout,
      stderr: result.stderr,
      stdoutTruncated: result.stdoutTruncated,
      stderrTruncated: result.stderrTruncated,
      decision: result.decision,
      reason: result.timedOut ? "TIMEOUT" : result.cancelled ? "CANCELLED" : null,
      timeoutSeconds: result.timeoutSeconds,
      descendantsRemaining: result.descendantsRemaining,
      descendantState: result.descendantState
    };

    const summary =
      `run_script ${result.project}/${result.script} ` +
      `decision=${result.decision} exitCode=${String(result.exitCode)} durationMs=${result.durationMs}\n` +
      `stdout:${result.stdoutTruncated ? "[truncated] " : " "}${result.stdout}\n` +
      `stderr:${result.stderrTruncated ? "[truncated] " : " "}${result.stderr}`;

    return structured(payload, summary);
  }
);

const GITHUB_KEYCHAIN_SERVICE = "local-mcp-dev-runner-github-api-token";

async function readKeychainToken() {
  try {
    const { stdout } = await execFileAsync("/usr/bin/security", [
      "find-generic-password",
      "-s", GITHUB_KEYCHAIN_SERVICE,
      "-w"
    ], {
      timeout: 5000,
      encoding: "utf8"
    });
    const token = stdout.trim();
    if (!token) {
      throw new Error("Empty credential in keychain");
    }
    return token;
  } catch (error) {
    throw new Error(
      formatUserError(
        "GITHUB_CREDENTIAL_MISSING",
        `GitHub API credential missing in macOS Keychain for service "${GITHUB_KEYCHAIN_SERVICE}"`,
        `Store token with: security add-generic-password -s "${GITHUB_KEYCHAIN_SERVICE}" -a "github" -w "<TOKEN>"`
      )
    );
  }
}

const githubClient = new GitHubApiClient();

server.registerTool(
  "github_repository_info",
  {
    title: "Get GitHub repository information",
    description:
      "Query metadata for a GitHub repository under an allowlisted organization. " +
      "Returns existence, owner, visibility, default branch, fork/archived flags, and repository URL.",
    inputSchema: z
      .object({
        organization: z.string().min(1).describe("Allowlisted GitHub organization name (e.g. CosmGrid)"),
        repository: z.string().min(1).describe("Repository name to query")
      })
      .strict(),
    outputSchema: z
      .object({
        exists: z.boolean(),
        owner: z.string().nullable(),
        name: z.string().nullable(),
        visibility: z.string().nullable(),
        defaultBranch: z.string().nullable(),
        fork: z.boolean().nullable(),
        archived: z.boolean().nullable(),
        repositoryUrl: z.string().nullable()
      })
      .strict()
  },
  async ({ organization, repository }) => {
    const registry = await loadRegistry();
    const runtimeRoot = path.join(os.homedir(), ".local", "share", "local-mcp-dev-runner");
    const result = await getRepositoryInfo({
      registry,
      organization,
      repository,
      tokenReader: readKeychainToken,
      client: githubClient,
      runtimeRoot
    });
    const summary = result.exists
      ? `github_repository_info: ${result.owner}/${result.name} exists (${result.visibility}, default branch: ${result.defaultBranch || "none"})`
      : `github_repository_info: ${result.owner}/${result.name} does not exist`;
    return structured(result, summary);
  }
);

server.registerTool(
  "github_repository_create",
  {
    title: "Create GitHub repository",
    description:
      "Create a new repository under an allowlisted GitHub organization with specified visibility (public or private). " +
      "Idempotent: returns ALREADY_EXISTS if repository already exists with matching visibility. " +
      "Does NOT initialize with README/license/gitignore, does NOT push code, does NOT configure remotes.",
    inputSchema: z
      .object({
        organization: z.string().min(1).describe("Allowlisted GitHub organization name (e.g. CosmGrid)"),
        name: z.string().min(1).describe("Repository name"),
        visibility: z.enum(["public", "private"]).describe("Repository visibility: public or private"),
        description: z.string().max(350).optional().describe("Optional repository description")
      })
      .strict(),
    outputSchema: z
      .object({
        created: z.boolean(),
        status: z.enum(["CREATED", "ALREADY_EXISTS"]),
        owner: z.string(),
        name: z.string(),
        visibility: z.string(),
        repositoryUrl: z.string(),
        cloneUrl: z.string(),
        defaultBranch: z.string().nullable()
      })
      .strict()
  },
  async ({ organization, name, visibility, description }) => {
    const registry = await loadRegistry();
    const runtimeRoot = path.join(os.homedir(), ".local", "share", "local-mcp-dev-runner");
    const result = await createRepository({
      registry,
      organization,
      name,
      visibility,
      description,
      tokenReader: readKeychainToken,
      client: githubClient,
      runtimeRoot
    });
    const summary = result.created
      ? `github_repository_create: created ${result.owner}/${result.name} (${result.visibility}) at ${result.repositoryUrl}`
      : `github_repository_create: repository ${result.owner}/${result.name} already exists (${result.visibility}) at ${result.repositoryUrl}`;
    return structured(result, summary);
  }
);

async function handleCliInit() {
  const args = process.argv.slice(2);
  const isInit = args.includes("--init");
  if (!isInit) return false;

  const force = args.includes("--force");
  let exists = false;
  try {
    await fs.access(CONFIG_FILE);
    exists = true;
  } catch {
    exists = false;
  }

  if (exists && !force) {
    console.error(`INIT_RESULT=CONFIG_ALREADY_EXISTS`);
    console.error(`Existing configuration file found at: ${CONFIG_FILE}`);
    console.error(`Refusing to overwrite without --force. Use: node server.mjs --init --force`);
    process.exit(1);
  }

  const template = {
    _comment: [
      "Local MCP Dev Runner — Registered Projects",
      "Documentation: docs/QUICKSTART.md",
      "Add project entries under 'projects' below.",
      "Projects default to read-only (write=false). To make changes, use git_worktree_create."
    ].join(" "),
    github: {
      enabled: false,
      allowedOrganizations: [
        "CosmGrid"
      ]
    },
    projects: {},
    trustedWorkspaces: {},
    _template: {
      _doc: "Copy this block into projects.<name> and fill in the absolute root path.",
      root: "<ABSOLUTE_PATH_TO_PROJECT_ROOT>",
      write: false,
      runScripts: false,
      allowedScripts: []
    }
  };

  await fs.mkdir(path.dirname(CONFIG_FILE), { recursive: true });
  await fs.writeFile(CONFIG_FILE, JSON.stringify(template, null, 2) + "\n", {
    encoding: "utf8",
    mode: 0o600
  });

  const status = exists ? "OVERWRITTEN" : "CREATED";
  console.log(`INIT_RESULT=${status}`);
  console.log(`CONFIG_PATH=${CONFIG_FILE}`);
  console.log(`Initialized projects registry successfully with mode 0600.`);
  process.exit(0);
}

async function runStartupHealthCheck() {
  const checks = [];

  // Check 1: CONFIG_FILE exists and parses cleanly
  let configOk = true;
  let parsedRegistry = null;
  try {
    const raw = await fs.readFile(CONFIG_FILE, "utf8");
    parsedRegistry = JSON.parse(raw);
    if (!parsedRegistry.projects || typeof parsedRegistry.projects !== "object") {
      checks.push("PROJECTS_CONFIG=FAIL (missing 'projects' object in projects.json)");
      configOk = false;
    } else {
      checks.push("PROJECTS_CONFIG=PASS");
      const projectCount = Object.keys(parsedRegistry.projects).length;
      checks.push(`REGISTERED_PROJECTS=${projectCount}`);
    }
  } catch (error) {
    configOk = false;
    if (error?.code === "ENOENT") {
      checks.push("PROJECTS_CONFIG=WARN (projects.json not found; run 'node server.mjs --init' to generate template)");
    } else {
      checks.push(`PROJECTS_CONFIG=FAIL (failed to parse: ${error?.message || "unknown error"})`);
    }
    checks.push("REGISTERED_PROJECTS=0");
  }

  // Check 2: WORKTREE_BASE directory readiness
  try {
    await fs.mkdir(WORKTREE_BASE, { recursive: true });
    checks.push("WORKTREE_BASE=PASS");
  } catch (error) {
    checks.push(`WORKTREE_BASE=FAIL (${error?.message || "cannot create or access worktree base directory"})`);
  }

  // Check 3: SANDBOX_BACKEND availability
  try {
    const backend = getSandboxBackend();
    const probe = await backend.isAvailable();
    checks.push(`SANDBOX_BACKEND=${probe.available ? "AVAILABLE" : "UNAVAILABLE"}`);
  } catch {
    checks.push("SANDBOX_BACKEND=UNKNOWN");
  }

  // Check 4: GITHUB capability
  if (parsedRegistry?.github?.enabled === true) {
    const orgs = parsedRegistry.github.allowedOrganizations || [];
    checks.push(`GITHUB_CAPABILITY=ENABLED (allowed: ${orgs.join(", ") || "none"})`);
  } else {
    checks.push("GITHUB_CAPABILITY=DISABLED");
  }

  // Check 5: GITHUB Keychain credential
  try {
    const probe = await execFileAsync("/usr/bin/security", [
      "find-generic-password",
      "-s", GITHUB_KEYCHAIN_SERVICE
    ], { timeout: 3000 }).then(() => true).catch(() => false);
    checks.push(`GITHUB_KEYCHAIN_CREDENTIAL=${probe ? "PRESENT" : "MISSING"}`);
  } catch {
    checks.push("GITHUB_KEYCHAIN_CREDENTIAL=UNKNOWN");
  }

  return checks;
}

if (process.argv.includes("--init")) {
  await handleCliInit();
}

if (process.argv.includes("--health-check") || process.argv.includes("--check-health")) {
  const results = await runStartupHealthCheck();
  for (const line of results) {
    console.log(line);
  }
  process.exit(0);
}

const transport = new StdioServerTransport();
await server.connect(transport);
