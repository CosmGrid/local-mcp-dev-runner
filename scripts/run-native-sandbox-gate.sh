#!/usr/bin/env bash
#
# P2 real-sandbox gate (fail-closed).
#
# This gate PROVES the macOS Seatbelt sandbox actually enforces the P2
# invariants: filesystem isolation, network:none, executable allow/deny,
# environment isolation, and process-group reaping. It MUST run in a NATIVE
# macOS Terminal.app.
#
# WorkBuddy / any nested-sandbox host cannot apply a Seatbelt profile
# (sandbox_apply: Operation not permitted, exit 71). On such hosts this script
# aborts with a non-zero status and a clear instruction -- it NEVER reports PASS.
#
# Exit codes:
#   0   all real-sandbox tests passed (SKIP = 0)
#   71  nested sandbox detected -- run in a native Terminal.app instead
#   N   native test failures (N = node --test exit code, non-zero)

set -u
# Drop any inherited NODE_OPTIONS (e.g. WorkBuddy's safe-delete shim) so the
# native gate runs the real node, not a wrapped one.
unset NODE_OPTIONS

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

echo "[native-gate] P2 real-sandbox gate"
echo "[native-gate] repo: $REPO_ROOT"

# 1. Baseline probe: can a Seatbelt profile even be applied in this process tree?
PROBE_PROFILE='(version 1)(allow default)'
if ! sandbox-exec -p "$PROBE_PROFILE" /bin/echo sandbox-probe-ok >/dev/null 2>&1; then
  echo "[native-gate] FAIL: cannot apply a sandbox profile in this process context."
  echo "[native-gate] sandbox-exec returned non-zero (nested sandbox / EPERM 71)."
  echo "[native-gate] This gate must run in a NATIVE macOS Terminal.app, not inside"
  echo "[native-gate] WorkBuddy or any other already-sandboxed host."
  echo "[native-gate] P2 real-sandbox verification: NOT PASSED."
  exit 71
fi
echo "[native-gate] baseline sandbox-exec probe: OK (profile applied)"

# 2. Platform guard.
if [ "$(uname)" != "Darwin" ]; then
  echo "[native-gate] FAIL: this gate requires macOS (sandbox-exec)."
  exit 1
fi

# 3. Run the real-sandbox test suite. node --test exits non-zero on any failure.
echo "[native-gate] running tests/native/* (real sandbox-exec)..."
node --test --test-concurrency=1 tests/native/*.test.mjs
TEST_RC=$?
if [ "$TEST_RC" -ne 0 ]; then
  echo "[native-gate] FAIL: native sandbox tests reported failures (rc=$TEST_RC)."
  echo "[native-gate] P2 real-sandbox verification: NOT PASSED."
  exit "$TEST_RC"
fi

echo "[native-gate] PASS: all real-sandbox tests passed (SKIP=0)."
echo "[native-gate] P2 sandbox execution is PROVEN on this host."
exit 0
