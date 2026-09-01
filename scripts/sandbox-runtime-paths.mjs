/**
 * Runtime path constants shared by server.mjs and the P2 sandbox modules.
 *
 * Kept in one place so the sandbox policy (which denies these paths) and the
 * server (which reads them) can never drift apart.
 *
 * Everything derives from os.homedir() / XDG_CONFIG_HOME at call time rather
 * than at import time, so tests can redirect the whole world by pointing HOME
 * at a throwaway directory.
 */

import os from "node:os";
import path from "node:path";

export const RUNNER_DIR_NAME = "local-mcp-dev-runner";

/** Registry of projects (never writable by a sandboxed process). */
export function configFilePath() {
  return path.join(os.homedir(), ".config", RUNNER_DIR_NAME, "projects.json");
}

/** Runner state root: worktrees, sandbox scratch space, logs, kill switch. */
export function runtimeRoot() {
  return path.join(os.homedir(), ".local", "share", RUNNER_DIR_NAME);
}

export function worktreeBase() {
  return path.join(runtimeRoot(), "worktrees");
}

/** Per-run scratch space: $RUNTIME_ROOT/sandbox/run-<uuid>/{home,tmp} */
export function sandboxRoot() {
  return path.join(runtimeRoot(), "sandbox");
}

export function logsDir() {
  return path.join(runtimeRoot(), "logs");
}

/** File kill switch. Presence (any content) means permanent DENY. */
export function killSwitchPath() {
  return path.join(runtimeRoot(), "run-script.kill");
}

/** Environment kill switch. Value "on" (case-insensitive) means permanent DENY. */
export const KILL_SWITCH_ENV_VAR = "RUN_SCRIPT_KILL_SWITCH";
