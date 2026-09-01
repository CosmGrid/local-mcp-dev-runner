/**
 * The single place in this repository where a process is created for script
 * execution.
 *
 * WHY spawn() AND WHY ONLY HERE
 * -----------------------------
 * P2 needs an isolated process group so that a script's descendants can be
 * enumerated and reaped on timeout or cancellation. `execFile` has no handle on
 * the process group, so it cannot provide that guarantee. `spawn` with
 * `detached: true` can.
 *
 * The existing security tripwire forbids `spawn(` inside server.mjs. Rather
 * than weaken that tripwire, the privilege is confined to this module and paid
 * for with structural invariants that the P2 security gate asserts over the
 * source itself:
 *
 *   1. `spawn(` appears at exactly the enumerated call sites below, and
 *      nowhere else in the tracked tree. Adding a third call site is a gate
 *      failure, not a design choice.
 *   2. `shell` is never set to true and no shell binary is ever invoked.
 *   3. argv is structured: a fixed executable plus an array of strings.
 *      No string is concatenated into a command line.
 *   4. stdio is fully piped, `detached: true` is set, and stdin is closed.
 *
 * ENUMERATED CALL SITES (conflict register C2, team-lead ruling C2-B)
 * -------------------------------------------------------------------
 *   S1  sandboxed child    spawn(executable, args, ...)   the script itself
 *   S2  descendant probe   spawn("/usr/bin/pgrep", ["-g", String(pgid)], ...)
 *
 * S2 exists because macOS has no /proc, so there is no spawn-free way to
 * enumerate a process group. It is a read-only query: the executable is a
 * hardcoded absolute constant and no external input reaches its argv beyond
 * the numeric pgid. Both sites satisfy invariants 2-4.
 *
 * See scripts/check-security-policies.mjs (P2 section) and
 * tests/p2/process-runner-source.test.mjs.
 *
 * NOT USED: exec, execSync, spawnSync, shell:true, setrlimit, ulimit,
 * native helpers. P2 does not implement hard RLIMIT by design.
 */

import { spawn } from "node:child_process";

/**
 * Structural invariants asserted by the P2 security gate over this source.
 * `enumeratedSpawnCallSites` is the exact number of permitted `spawn(` call
 * sites; the gate fails on any drift in either direction.
 */
export const PROCESS_RUNNER_INVARIANTS = Object.freeze({
  enumeratedSpawnCallSites: 2,
  shellEnabled: false,
  structuredArgvOnly: true,
  detachedProcessGroup: true,
  stdinClosed: true,
  hardRlimit: false
});

/** Call site S2: read-only process-group probe. macOS has no /proc. */
export const PGREP_PATH = "/usr/bin/pgrep";

/** Grace period between SIGTERM and SIGKILL, in milliseconds. */
export const DEFAULT_KILL_GRACE_MS = 2000;
/** Wait after SIGKILL before probing the process group for survivors. */
export const DEFAULT_REAP_GRACE_MS = 200;

const PGREP_TIMEOUT_MS = 3000;

export function isProcessGroupAlive(pgid) {
  const probe = spawn(PGREP_PATH, ["-g", String(pgid)], {
    stdio: ["ignore", "pipe", "pipe"],
    shell: false,
    windowsHide: true
  });
  let output = "";
  probe.stdout.setEncoding("utf8");
  probe.stdout.on("data", (chunk) => {
    output += chunk;
  });

  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      probe.kill("SIGKILL");
      resolve({ alive: true, state: "unknown" });
    }, PGREP_TIMEOUT_MS);

    probe.on("error", () => {
      clearTimeout(timer);
      resolve({ alive: true, state: "unsupported" });
    });

    probe.on("close", (code) => {
      clearTimeout(timer);
      const pids = output
        .split("\n")
        .map((line) => line.trim())
        .filter(Boolean)
        .map(Number)
        .filter((value) => Number.isInteger(value));
      // pgrep exits 1 when nothing matched.
      if (code === 1 || pids.length === 0) resolve({ alive: false, state: "none", pids });
      else if (code === 0) resolve({ alive: true, state: "remaining", pids });
      else resolve({ alive: true, state: "unknown", pids });
    });
  });
}

/**
 * Run one command in its own process group, with timeout, cancellation and
 * descendant reaping.
 *
 * @param {object} plan
 * @param {string}   plan.executable        absolute path, resolved by the caller
 * @param {string[]} plan.args              structured argv (never a command string)
 * @param {string}   plan.cwd
 * @param {object}   plan.env
 * @param {number}   [plan.timeoutMs]
 * @param {AbortSignal} [plan.signal]
 * @param {number}   [plan.killGraceMs]
 * @param {number}   [plan.reapGraceMs]
 * @returns {Promise<{
 *   stdout: string,
 *   stderr: string,
 *   exitCode: number,
 *   signal: string|null,
 *   timedOut: boolean,
 *   cancelled: boolean,
 *   durationMs: number,
 *   startedAt: string,
 *   endedAt: string,
 *   pid: number|null,
 *   pgid: number|null,
 *   descendantsRemaining: boolean,
 *   descendantState: string
 * }>}
 */
export function runProcess(plan) {
  const {
    executable,
    args = [],
    cwd,
    env,
    timeoutMs = 0,
    signal = null,
    killGraceMs = DEFAULT_KILL_GRACE_MS,
    reapGraceMs = DEFAULT_REAP_GRACE_MS
  } = plan ?? {};

  if (typeof executable !== "string" || executable.length === 0) {
    return Promise.reject(new Error("runProcess: executable is required"));
  }
  if (!Array.isArray(args) || args.some((entry) => typeof entry !== "string")) {
    return Promise.reject(new Error("runProcess: args must be an array of strings"));
  }

  const startedAtMs = Date.now();
  const startedAt = new Date(startedAtMs).toISOString();

  let stdout = "";
  let stderr = "";
  let timedOut = false;
  let cancelled = false;
  let terminationSignal = null;
  let killEscalated = false;
  let timer = null;
  let onAbort = null;
  let settled = false;

  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawn(executable, args, {
        cwd,
        env,
        stdio: ["ignore", "pipe", "pipe"],
        detached: true,
        shell: false,
        windowsHide: true
      });
    } catch (error) {
      reject(new Error(`runProcess: cannot start ${executable} (${error?.message ?? error})`));
      return;
    }

    const stdoutStream = child.stdout;
    const stderrStream = child.stderr;
    if (stdoutStream) {
      stdoutStream.setEncoding("utf8");
      stdoutStream.on("data", (chunk) => {
        stdout += chunk;
      });
    }
    if (stderrStream) {
      stderrStream.setEncoding("utf8");
      stderrStream.on("data", (chunk) => {
        stderr += chunk;
      });
    }

    const terminate = (reason, sig) => {
      if (settled) return;
      if (sig) terminationSignal = sig;
      const pgid = child.pid;
      try {
        if (typeof pgid === "number") process.kill(-pgid, sig);
        else child.kill(sig);
      } catch {
        try {
          child.kill(sig);
        } catch {
          /* already gone */
        }
      }
      if (reason === "timeout") timedOut = true;
      if (reason === "cancel") cancelled = true;
    };

    if (timeoutMs && timeoutMs > 0) {
      timer = setTimeout(() => terminate("timeout", "SIGTERM"), timeoutMs);
    }

    if (signal) {
      if (signal.aborted) {
        cancelled = true;
        terminate("cancel", "SIGTERM");
      } else {
        onAbort = () => terminate("cancel", "SIGTERM");
        signal.addEventListener("abort", onAbort, { once: true });
      }
    }

    child.on("error", (error) => {
      cleanupListeners();
      if (settled) return;
      settled = true;
      reject(new Error(`runProcess: ${executable} failed to start (${error?.message ?? error})`));
    });

    child.on("close", async (code, sig) => {
      if (timer) clearTimeout(timer);
      if (onAbort && signal) signal.removeEventListener("abort", onAbort);
      if (settled) return;
      settled = true;

      const pgid = typeof child.pid === "number" ? child.pid : null;
      let killTimer = null;
      if ((timedOut || cancelled) && !killEscalated) {
        killEscalated = true;
        terminationSignal = "SIGKILL";
        try {
          if (pgid !== null) process.kill(-pgid, "SIGKILL");
        } catch {
          /* already gone */
        }
        await new Promise((done) => {
          killTimer = setTimeout(done, killGraceMs);
        });
        if (killTimer) clearTimeout(killTimer);
      }

      let descendantsRemaining = false;
      let descendantState = "not-checked";
      if (pgid !== null && (timedOut || cancelled || killEscalated)) {
        await new Promise((done) => setTimeout(done, reapGraceMs));
        const probe = await isProcessGroupAlive(pgid);
        descendantsRemaining = probe.alive;
        descendantState = probe.state;
      }

      resolve({
        stdout,
        stderr,
        exitCode: typeof code === "number" ? code : -1,
        signal: terminationSignal ?? (typeof sig === "string" ? sig : null),
        timedOut,
        cancelled,
        durationMs: Date.now() - startedAtMs,
        startedAt,
        endedAt: new Date().toISOString(),
        pid: typeof child.pid === "number" ? child.pid : null,
        pgid,
        descendantsRemaining,
        descendantState
      });
    });
  });

  function cleanupListeners() {
    if (timer) clearTimeout(timer);
    if (onAbort && signal) signal.removeEventListener("abort", onAbort);
  }
}

/** Exposed for tests: resolve the effective signal name for a kill request. */
export function signalFor(reason) {
  if (reason === "timeout") return "SIGTERM";
  if (reason === "cancel") return "SIGTERM";
  if (reason === "escalate") return "SIGKILL";
  return "SIGTERM";
}
