/**
 * Restricted GitHub Operations Audit Log.
 *
 * Location: $RUNTIME_ROOT/logs/github-audit.log, mode 0600, JSON lines.
 * Only non-sensitive audit metadata is recorded.
 * Token and authorization headers are strictly excluded.
 */

import fs from "node:fs/promises";
import path from "node:path";

export const GITHUB_AUDIT_LOG_NAME = "github-audit.log";
export const GITHUB_AUDIT_LOG_MODE = 0o600;

const CORE_FIELDS = [
  "timestamp",
  "operation",
  "organization",
  "repository",
  "requestedVisibility",
  "result",
  "errorCategory",
  "status"
];

const FORBIDDEN_FIELDS = new Set([
  "token",
  "authorization",
  "auth",
  "credential",
  "secret",
  "password",
  "key",
  "headers"
]);

export function githubAuditLogPath(runtimeRoot) {
  return path.join(runtimeRoot, "logs", GITHUB_AUDIT_LOG_NAME);
}

export function sanitizeAuditRecord(entry) {
  const record = {
    timestamp: new Date().toISOString()
  };
  for (const [key, value] of Object.entries(entry ?? {})) {
    const lower = key.toLowerCase();
    if (FORBIDDEN_FIELDS.has(lower)) continue;
    record[key] = value;
  }
  for (const field of CORE_FIELDS) {
    if (!(field in record)) record[field] = null;
  }
  const ordered = {};
  for (const field of CORE_FIELDS) ordered[field] = record[field] ?? null;
  for (const [key, value] of Object.entries(record)) {
    if (!(key in ordered)) ordered[key] = value;
  }
  return ordered;
}

export async function writeGithubAudit(runtimeRoot, entry) {
  const logDir = path.join(runtimeRoot, "logs");
  const logFile = githubAuditLogPath(runtimeRoot);
  const sanitized = sanitizeAuditRecord(entry);
  const line = `${JSON.stringify(sanitized)}\n`;

  let handle;
  try {
    await fs.mkdir(logDir, { recursive: true, mode: 0o700 });
    handle = await fs.open(logFile, "a", GITHUB_AUDIT_LOG_MODE);
    await fs.chmod(logFile, GITHUB_AUDIT_LOG_MODE).catch(() => {});
    await handle.write(line, null, "utf8");
  } catch (error) {
    const detail = error?.message ?? String(error);
    throw new Error(`GITHUB_AUDIT_LOG_FAILED: cannot write to audit log ${logFile} (${detail})`);
  } finally {
    if (handle) {
      await handle.close().catch(() => {});
    }
  }
}
