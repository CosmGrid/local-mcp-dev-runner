/**
 * MockSandboxBackend — test double, never selectable in production.
 *
 * Used by the unit/test layer (which runs inside hosts where sandbox-exec
 * cannot be initialised) to exercise the policy, hashing, output and audit
 * paths end to end. It records every execution plan so tests can assert what
 * *would* have been run, without ever creating a process.
 *
 * It deliberately performs no containment: containment is proven by
 * tests/native/*, which run under the real backend on a host where
 * sandbox-exec works.
 */

import { validateSExpression } from "./sandbox-backend.mjs";

export class MockSandboxBackend {
  constructor(options = {}) {
    this.kind = "mock";
    this.available = options.available !== false;
    this.failures = options.failures ?? (this.available ? [] : ["mock backend configured as unavailable"]);
    this.result = options.result ?? {
      stdout: "mock-stdout\n",
      stderr: "",
      exitCode: 0,
      signal: null,
      timedOut: false,
      cancelled: false,
      durationMs: 1
    };
    this.calls = [];
    this.profilePrefix = ";; MOCK PROFILE (no containment)\n";
  }

  async versionProbe() {
    return {
      kind: this.kind,
      platform: process.platform,
      darwinMajor: null,
      sandboxExecPath: null,
      sandboxExecPresent: false,
      sandboxExecExecutable: false,
      nodeVersion: process.versions?.node ?? null,
      versionProbeOk: this.available,
      minimalProfileOk: this.available,
      denyProbeDenied: this.available,
      probeDetail: { note: "mock backend" }
    };
  }

  async isAvailable({ refresh = false } = {}) {
    void refresh;
    return {
      available: this.available,
      reasonCode: this.available ? null : "SANDBOX_BACKEND_UNAVAILABLE",
      failures: this.failures,
      probe: await this.versionProbe()
    };
  }

  generateProfile(context) {
    return `${this.profilePrefix}(version 1)\n(deny default)\n;; context keys: ${Object.keys(context ?? {}).join(", ")}\n`;
  }

  validateProfile(profile) {
    return validateSExpression(profile);
  }

  async execute(request) {
    if (!this.available) {
      throw new Error(`SANDBOX_BACKEND_UNAVAILABLE: ${this.failures.join("; ") || "mock unavailable"}`);
    }
    const recorded = {
      context: request?.context ?? null,
      executable: request?.executable ?? null,
      args: request?.args ?? [],
      cwd: request?.cwd ?? null,
      env: request?.env ?? null,
      timeoutMs: request?.timeoutMs ?? null
    };
    this.calls.push(recorded);

    const profile = this.generateProfile(request?.context);
    const validation = this.validateProfile(profile);
    if (!validation.ok) {
      throw new Error(`SANDBOX_BACKEND_UNAVAILABLE: generated profile rejected (${validation.reason})`);
    }

    const startedAt = new Date().toISOString();
    return {
      ...this.result,
      startedAt,
      endedAt: new Date().toISOString(),
      pid: null,
      pgid: null,
      descendantsRemaining: false,
      descendantState: "not-checked",
      profile,
      backend: this.kind
    };
  }

  async cleanup(input = {}) {
    return {
      descendantsRemaining: false,
      descendantState: "not-checked",
      removedPaths: (input?.paths ?? []).length
    };
  }
}
