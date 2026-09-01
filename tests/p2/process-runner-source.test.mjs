/**
 * P2 unit tests: sandbox-process-runner source invariants (conflict C2 ruling).
 *
 * Mirror of the static security-gate assertion, expressed as a unit test so the
 * invariant is covered even when the gate script is not run. spawn() is permitted
 * at exactly TWO enumerated call sites (main child + pgrep descendant probe),
 * never a third; the pgrep probe uses the hardcoded PGREP_PATH constant; there
 * is no shell:true and no hard RLIMIT.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { PROCESS_RUNNER_INVARIANTS, PGREP_PATH } from "../../scripts/sandbox-process-runner.mjs";

const RUNNER = path.resolve(import.meta.dirname, "../../scripts/sandbox-process-runner.mjs");
const src = readFileSync(RUNNER, "utf8");

/** Strip // and /* *​/ comments so spawn() counting is not fooled by prose. */
function stripComments(s) {
  const out = [];
  let inBlock = false;
  for (const rawLine of s.split("\n")) {
    let line = rawLine;
    let result = "";
    let i = 0;
    while (i < line.length) {
      if (inBlock) {
        const end = line.indexOf("*/", i);
        if (end === -1) break;
        i = end + 2;
        inBlock = false;
      } else {
        const block = line.indexOf("/*", i);
        const slash = line.indexOf("//", i);
        if (block !== -1 && (slash === -1 || block < slash)) {
          result += line.slice(i, block);
          const end = line.indexOf("*/", block + 2);
          if (end === -1) {
            inBlock = true;
            break;
          }
          i = end + 2;
        } else if (slash !== -1) {
          result += line.slice(i, slash);
          break;
        } else {
          result += line.slice(i);
          break;
        }
      }
    }
    out.push(result);
  }
  return out.join("\n");
}

describe("sandbox-process-runner source invariants", () => {
  it("counts exactly 2 enumerated spawn call sites", () => {
    const stripped = stripComments(src);
    const count = (stripped.match(/\bspawn\s*\(/g) || []).length;
    assert.equal(count, 2, "exactly 2 enumerated spawn sites (main child + pgrep probe)");
    assert.equal(PROCESS_RUNNER_INVARIANTS.enumeratedSpawnCallSites, 2);
  });
  it("uses the PGREP_PATH constant for the descendant probe", () => {
    assert.equal(PGREP_PATH, "/usr/bin/pgrep");
    assert.ok(/spawn\(\s*PGREP_PATH/.test(src), "pgrep must be spawned via the constant");
  });
  it("never enables a shell and never sets a hard RLIMIT", () => {
    assert.equal(PROCESS_RUNNER_INVARIANTS.shellEnabled, false);
    assert.equal(PROCESS_RUNNER_INVARIANTS.hardRlimit, false);
    const stripped = stripComments(src);
    assert.ok(!/shell\s*:\s*true/.test(stripped), "no shell:true in the runner");
  });
});
