/**
 * run_script audit log.
 *
 * Location: $RUNTIME_ROOT/logs/run-script.log, mode 0600, JSON lines.
 * Only metadata is recorded — never stdout/stderr bodies, never environment
 * values, never secret material.
 *
 * The log is fail-closed: if it cannot be opened, run_script refuses to start.
 * A script execution that leaves no trace is worse than no execution at all.
 */

import fs from "node:fs/promises";
import path from "node:path";

export const AUDIT_LOG_NAME = "run-script.log";
export const AUDIT_LOG_MODE = 0o600;

/** Metadata fields that are always present on an entry. */
const CORE_FIELDS = [
  "timestamp",
  "project",
  "branch",
  "script",
  "packageManager",
  "packageSha256",
  "scriptSha256",
  "network",
  "backend",
  "durationMs",
  "exitCode",
  "signal",
  "timedOut",
  "cancelled",
  "truncated",
  "decision"
];

/** Fields that must never reach the log even if a caller passes them in. */
const FORBIDDEN_FIELDS = new Set(["stdout", "stderr", "env", "environment", "command", "args"]);

export function auditLogPath(runtimeRoot) {
  return path.join(runtimeRoot, "logs", AUDIT_LOG_NAME);
}

/**
 * Open (and verify) the audit log.
 *
 * @param {string} runtimeRoot
 * @returns {Promise<{ path: string, write: (entry: object) => Promise<void>, close: () => Promise<void> }>}
 * @throws {Error} with a message containing AUDIT_LOG_INIT_FAILED
 */
export async function openAuditLog(runtimeRoot) {
  const logDir = path.join(runtimeRoot, "logs");
  const logFile = auditLogPath(runtimeRoot);
  let handle;
  try {
    await fs.mkdir(logDir, { recursive: true, mode: 0o700 });
    handle = await fs.open(logFile, "a", AUDIT_LOG_MODE);
    await fs.chmod(logFile, AUDIT_LOG_MODE).catch(() => {});
    // Prove the descriptor is actually writable before any process starts.
    await handle.write("");
  } catch (error) {
    if (handle) await handle.close().catch(() => {});
    const detail = error?.message ?? String(error);
    throw new Error(`AUDIT_LOG_INIT_FAILED: cannot write ${logFile} (${detail})`);
  }

  return {
    path: logFile,
    async write(entry) {
      const line = `${JSON.stringify(serialize(entry))}\n`;
      await handle.write(line, null, "utf8");
    },
    async close() {
      await handle.close().catch(() => {});
    }
  };
}

/** Strip anything that is not audited metadata, then fill the core fields. */
export function serialize(entry) {
  const record = { timestamp: new Date().toISOString() };
  for (const [key, value] of Object.entries(entry ?? {})) {
    if (FORBIDDEN_FIELDS.has(key)) continue;
    record[key] = value;
  }
  for (const field of CORE_FIELDS) {
    if (!(field in record)) record[field] = null;
  }
  // Stable key order keeps the log greppable and diffable.
  const ordered = {};
  for (const field of CORE_FIELDS) ordered[field] = record[field] ?? null;
  for (const [key, value] of Object.entries(record)) {
    if (!(key in ordered)) ordered[key] = value;
  }
  return ordered;
}
