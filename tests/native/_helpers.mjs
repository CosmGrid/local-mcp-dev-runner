/**
 * Shared helpers for the P2 native (real-sandbox) test suite.
 *
 * This file is NOT a *.test.mjs, so `node --test tests/native/*.test.mjs` never
 * runs it as a test. It builds an isolated throwaway world and a real
 * SandboxExecBackend configured to execute commands under a macOS Seatbelt
 * profile.
 *
 * These tests only pass on a host where `sandbox-exec` can apply a profile --
 * i.e. a NATIVE macOS Terminal.app. Inside a nested sandbox (WorkBuddy) they
 * fail, which is the intended fail-closed posture.
 */

import os from "node:os";
import path from "node:path";
import fs from "node:fs/promises";
import { mkdtemp } from "node:fs/promises";
import { SandboxExecBackend } from "../../scripts/sandbox-backend-sandbox-exec.mjs";
import { buildSandboxEnv } from "../../scripts/sandbox-env.mjs";
import { nodeBinDirsFor } from "../../scripts/script-execution.mjs";

/**
 * Build an isolated world: a worktree, a per-run HOME/TMP, a fake "real home"
 * (which must be denied to the sandbox), and a backend + context + env.
 *
 * @returns {Promise<{
 *   tmp: string, worktreeRoot: string, homeRoot: string, tmpRoot: string,
 *   realHome: string, runtimeRoot: string,
 *   backend: SandboxExecBackend, context: object, env: Record<string,string>,
 *   nodeBinDirs: string[]
 * }>}
 */
export async function makeWorld() {
  const tmp = await mkdtemp(path.join(os.tmpdir(), "lmdr-native-"));
  const worktreeRoot = path.join(tmp, "worktree");
  const homeRoot = path.join(tmp, "home");
  const tmpRoot = path.join(tmp, "tmp");
  const realHome = path.join(tmp, "realhome");
  const runtimeRoot = path.join(tmp, "runtime");

  for (const dir of [worktreeRoot, homeRoot, tmpRoot, realHome, runtimeRoot]) {
    await fs.mkdir(dir, { recursive: true, mode: 0o700 });
  }

  const backend = new SandboxExecBackend();
  const nodeBinDirs = nodeBinDirsFor(process.execPath, []);

  const context = {
    worktreeRoot,
    homeRoot,
    tmpRoot,
    realHome,
    runtimeRoot,
    configFilePath: path.join(runtimeRoot, "projects.json"),
    nodeBinDirs
  };

  const parentEnv = { ...process.env, HOME: realHome };
  const env = buildSandboxEnv({ parentEnv, homeRoot, tmpRoot, worktreeRoot, nodeBinDirs });

  return { tmp, worktreeRoot, homeRoot, tmpRoot, realHome, runtimeRoot, backend, context, env, nodeBinDirs };
}

/** Run a short node -e snippet inside the sandbox. */
export async function runNode(world, code, timeoutMs = 15000) {
  return world.backend.execute({
    context: world.context,
    executable: process.execPath,
    args: ["-e", code],
    env: world.env,
    cwd: world.worktreeRoot,
    timeoutMs
  });
}
