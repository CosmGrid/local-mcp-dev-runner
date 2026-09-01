/**
 * SandboxBackend abstraction.
 *
 * server.mjs never talks to /usr/bin/sandbox-exec directly. Every execution
 * goes through a backend that implements this contract:
 *
 *   versionProbe()    -> environment/capability report (read-only, never throws)
 *   isAvailable()     -> whether this backend can actually enforce on this host
 *   generateProfile() -> the policy text for one execution context
 *   validateProfile() -> structural check of generated policy text
 *   execute()         -> run one command under the policy
 *   cleanup()         -> release resources and confirm the process group is gone
 *
 * v2.0 ships exactly one real implementation: SandboxExecBackend (macOS
 * sandbox-exec + SBPL). A MockSandboxBackend exists for unit tests only and is
 * never selectable in production.
 *
 * FAIL-CLOSED: when no backend is available, callers must refuse to execute.
 * There is no unsandboxed fallback — not partial, not opt-in, not logged-only.
 */

import { SandboxExecBackend } from "./sandbox-backend-sandbox-exec.mjs";

export const BACKEND_KINDS = Object.freeze({
  SANDBOX_EXEC: "sandbox-exec",
  MOCK: "mock"
});

/** Default backend for v2.0. Overridable only in tests. */
export const DEFAULT_BACKEND_KIND = BACKEND_KINDS.SANDBOX_EXEC;

const REGISTRY = new Map();

/**
 * Register a backend implementation. Tests use this to install a mock; nothing
 * in the production path calls it.
 *
 * @param {string} kind
 * @param {() => object} factory
 */
export function registerBackend(kind, factory) {
  REGISTRY.set(kind, factory);
}

/**
 * Create a backend instance.
 *
 * @param {string} [kind]   defaults to the production backend
 * @param {object} [options]
 * @returns {object}
 */
export function createBackend(kind = DEFAULT_BACKEND_KIND, options = {}) {
  const factory = REGISTRY.get(kind) ?? (kind === BACKEND_KINDS.SANDBOX_EXEC ? () => new SandboxExecBackend(options) : null);
  if (!factory) throw new Error(`Unknown sandbox backend: ${kind}`);
  return factory(options);
}

registerBackend(BACKEND_KINDS.SANDBOX_EXEC, (options) => new SandboxExecBackend(options));

/**
 * Structural check shared by every backend: SBPL (and our mock policy) is a
 * parenthesised S-expression, so balanced parentheses outside string literals
 * is the minimum bar for "this text might compile".
 *
 * @param {string} profile
 * @returns {{ ok: boolean, reason: string|null }}
 */
export function validateSExpression(profile) {
  const text = String(profile ?? "");
  if (text.trim().length === 0) return { ok: false, reason: "profile is empty" };

  let depth = 0;
  let inString = false;
  let escaped = false;
  for (const char of text) {
    if (inString) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') inString = false;
      continue;
    }
    if (char === '"') inString = true;
    else if (char === "(") depth += 1;
    else if (char === ")") {
      depth -= 1;
      if (depth < 0) return { ok: false, reason: "unbalanced closing parenthesis" };
    }
  }
  if (inString) return { ok: false, reason: "unterminated string literal" };
  if (depth !== 0) return { ok: false, reason: `unbalanced parentheses (depth ${depth})` };
  return { ok: true, reason: null };
}

/**
 * Reference contract for backend implementations. Not an enforced base class —
 * JavaScript structural typing is enough here and keeps the backends trivially
 * testable — but every backend must expose these members.
 */
export const SANDBOX_BACKEND_CONTRACT = Object.freeze([
  "kind",
  "versionProbe",
  "isAvailable",
  "generateProfile",
  "validateProfile",
  "execute",
  "cleanup"
]);
