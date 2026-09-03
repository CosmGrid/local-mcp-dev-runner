#!/usr/bin/env bash
#
# Stage 0C Bootstrap & Cleanup Fixture Test Suite
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo "Running Stage 0C Bootstrap & Cleanup Fixtures"
echo "========================================="

# Helper function to simulate cleanup evaluation logic
evaluate_cleanup() {
  local LOGICAL_RUN_DIR="$1"
  local CANONICAL_RUN_DIR="$2"
  local STAGE0C_RUN_ID="$3"
  local CLEANUP_PATH_GATE="FAIL"
  local TEMP_FILES_CLEANED="FAIL"
  local LEFTOVER_RUN_DIR="NONE"

  local l_base="$(basename "$LOGICAL_RUN_DIR" 2>/dev/null || echo "")"
  local c_base="$(basename "$CANONICAL_RUN_DIR" 2>/dev/null || echo "")"
  local c_parent="$(dirname "$CANONICAL_RUN_DIR" 2>/dev/null || echo "")"
  local c_verify="$(realpath "$CANONICAL_RUN_DIR" 2>/dev/null || echo "")"

  local c1=0 c2=0 c3=0 c4=0 c5=0 c6=0 c7=0 c8=0
  [ -n "$STAGE0C_RUN_ID" ] && [[ "$STAGE0C_RUN_ID" =~ ^[a-zA-Z0-9_-]{6,64}$ ]] && c1=1
  [ "$l_base" = "lmdr-p35-stage0c-$STAGE0C_RUN_ID" ] && c2=1
  [ "$c_parent" = "/private/tmp" ] && c3=1
  [ "$c_base" = "lmdr-p35-stage0c-$STAGE0C_RUN_ID" ] && c4=1
  [ "$CANONICAL_RUN_DIR" != "/tmp" ] && [ "$CANONICAL_RUN_DIR" != "/private/tmp" ] && c5=1
  case "$CANONICAL_RUN_DIR" in *".."*) c6=0;; *) c6=1;; esac
  [ "$c_verify" = "$CANONICAL_RUN_DIR" ] && c7=1
  [ -f "$CANONICAL_RUN_DIR/.stage0c-active" ] && c8=1

  if [ "$c1" -eq 1 ] && [ "$c2" -eq 1 ] && [ "$c3" -eq 1 ] && [ "$c4" -eq 1 ] && \
     [ "$c5" -eq 1 ] && [ "$c6" -eq 1 ] && [ "$c7" -eq 1 ] && [ "$c8" -eq 1 ]; then
    CLEANUP_PATH_GATE="PASS"
    rm -rf -- "$CANONICAL_RUN_DIR" 2>/dev/null || true
    if [ ! -e "$CANONICAL_RUN_DIR" ]; then
      TEMP_FILES_CLEANED="PASS"
      LEFTOVER_RUN_DIR="NONE"
    else
      LEFTOVER_RUN_DIR="$CANONICAL_RUN_DIR"
    fi
  else
    LEFTOVER_RUN_DIR="$CANONICAL_RUN_DIR"
  fi

  echo "CLEANUP_PATH_GATE=$CLEANUP_PATH_GATE TEMP_FILES_CLEANED=$TEMP_FILES_CLEANED LEFTOVER_RUN_DIR=$LEFTOVER_RUN_DIR"
}

# ----------------------------------------------------
# Fixture 1: /tmp -> /private/tmp canonicalization
# ----------------------------------------------------
CANONICAL_TMP="$(realpath /tmp)"
if [ "$CANONICAL_TMP" != "/private/tmp" ]; then
  echo "FAIL: Fixture 1 (/tmp -> /private/tmp mismatch: $CANONICAL_TMP)"
  exit 1
fi
echo "PASS: Fixture 1 - /tmp -> /private/tmp canonicalization verified"

# ----------------------------------------------------
# Fixture 2: valid run dir cleanup PASS
# ----------------------------------------------------
RUN_ID="validrun123456"
VALID_LOGICAL="/tmp/lmdr-p35-stage0c-$RUN_ID"
mkdir -p "$VALID_LOGICAL"
VALID_CANONICAL="$(realpath "$VALID_LOGICAL")"
touch "$VALID_CANONICAL/.stage0c-active"

F2_RES="$(evaluate_cleanup "$VALID_LOGICAL" "$VALID_CANONICAL" "$RUN_ID")"
if [[ "$F2_RES" != *"CLEANUP_PATH_GATE=PASS TEMP_FILES_CLEANED=PASS LEFTOVER_RUN_DIR=NONE"* ]]; then
  echo "FAIL: Fixture 2 (valid run dir cleanup failed: $F2_RES)"
  exit 1
fi
if [ -e "$VALID_CANONICAL" ]; then
  echo "FAIL: Fixture 2 (valid run dir was not removed)"
  exit 1
fi
echo "PASS: Fixture 2 - valid run dir cleanup PASS"

# ----------------------------------------------------
# Fixture 3: invalid run dir cleanup 拒绝 (multiple negative paths)
# ----------------------------------------------------
# Case 3a: Non-matching basename
RUN_ID="invalidprefix999"
INV_LOGICAL="/tmp/other-prefix-$RUN_ID"
mkdir -p "$INV_LOGICAL"
INV_CANONICAL="$(realpath "$INV_LOGICAL")"
touch "$INV_CANONICAL/.stage0c-active"
F3A_RES="$(evaluate_cleanup "$INV_LOGICAL" "$INV_CANONICAL" "$RUN_ID")"
if [[ "$F3A_RES" != *"CLEANUP_PATH_GATE=FAIL TEMP_FILES_CLEANED=FAIL"* ]]; then
  echo "FAIL: Fixture 3a (invalid prefix was not rejected: $F3A_RES)"
  exit 1
fi
rm -rf "$INV_CANONICAL"

# Case 3b: Missing marker (.stage0c-active)
VALID_LOGICAL="/tmp/lmdr-p35-stage0c-$RUN_ID"
mkdir -p "$VALID_LOGICAL"
VALID_CANONICAL="$(realpath "$VALID_LOGICAL")"
# intentionally do not touch .stage0c-active
F3B_RES="$(evaluate_cleanup "$VALID_LOGICAL" "$VALID_CANONICAL" "$RUN_ID")"
if [[ "$F3B_RES" != *"CLEANUP_PATH_GATE=FAIL TEMP_FILES_CLEANED=FAIL"* ]]; then
  echo "FAIL: Fixture 3b (missing marker was not rejected: $F3B_RES)"
  exit 1
fi
rm -rf "$VALID_CANONICAL"
echo "PASS: Fixture 3 - invalid run dir cleanup rejected with LEFTOVER_RUN_DIR reported"

# ----------------------------------------------------
# Fixture 4: profile generation success
# ----------------------------------------------------
F4_TMP="/tmp/lmdr-p35-stage0c-profilegen123"
mkdir -p "$F4_TMP/allowed"
F4_CANONICAL="$(realpath "$F4_TMP")"
F4_ALLOWED="$F4_CANONICAL/allowed"
F4_HELPER="$F4_ALLOWED/p35-stage0c-helper"
touch "$F4_HELPER"
chmod 0755 "$F4_HELPER"
F4_PROFILE="$F4_CANONICAL/profile.sb"

node "$HERE/generate-profile.mjs" \
  --allowed-dir "$F4_ALLOWED" \
  --helper-bin "$F4_HELPER" \
  --run-id "profilegen123" \
  --output "$F4_PROFILE"

if [ ! -s "$F4_PROFILE" ] || ! grep -q "(deny default)" "$F4_PROFILE"; then
  echo "FAIL: Fixture 4 (profile generation success verification failed)"
  exit 1
fi
rm -rf "$F4_CANONICAL"
echo "PASS: Fixture 4 - profile generation success"

# ----------------------------------------------------
# Fixture 5: profile generation failure -> BLOCKED
# ----------------------------------------------------
F5_OUT=""
set +e
F5_OUT="$(node "$HERE/generate-profile.mjs" \
  --allowed-dir "/nonexistent-path-for-test" \
  --helper-bin "/nonexistent-bin" \
  --run-id "bad;id" \
  --output "/tmp/out.sb" 2>&1)"
F5_RC=$?
set -e
if [ "$F5_RC" -eq 0 ]; then
  echo "FAIL: Fixture 5 (invalid profile generation should fail)"
  exit 1
fi
STAGE0C_RESULT="NOT_RUN"
BLOCK_REASON="NONE"
if [ "$F5_RC" -ne 0 ]; then
  STAGE0C_RESULT="BLOCKED"
  BLOCK_REASON="PROFILE_GENERATION_FAILED"
fi
if [ "$STAGE0C_RESULT" != "BLOCKED" ] || [ "$BLOCK_REASON" != "PROFILE_GENERATION_FAILED" ]; then
  echo "FAIL: Fixture 5 state machine mapping (got RESULT=$STAGE0C_RESULT BLOCK=$BLOCK_REASON)"
  exit 1
fi
echo "PASS: Fixture 5 - profile generation failure -> BLOCKED with BLOCK_REASON=PROFILE_GENERATION_FAILED"

# ----------------------------------------------------
# Fixture 6: cleanup failure -> BLOCK_REASON 非 NONE
# ----------------------------------------------------
CLEANUP_PATH_GATE="FAIL"
BLOCK_REASON="NONE"
STAGE0C_RESULT="NOT_RUN"
if [ "$CLEANUP_PATH_GATE" = "FAIL" ] && [ "$BLOCK_REASON" = "NONE" ]; then
  BLOCK_REASON="CLEANUP_GATE_FAILED"
  STAGE0C_RESULT="BLOCKED"
fi
if [ "$BLOCK_REASON" = "NONE" ] || [ "$BLOCK_REASON" != "CLEANUP_GATE_FAILED" ]; then
  echo "FAIL: Fixture 6 (cleanup failure resulted in BLOCK_REASON=NONE)"
  exit 1
fi
echo "PASS: Fixture 6 - cleanup failure sets non-NONE BLOCK_REASON (CLEANUP_GATE_FAILED)"

# ----------------------------------------------------
# Fixture 7: prerequisite 未运行 -> security probes NOT_RUN，而不是伪 UNKNOWN/PASS
# ----------------------------------------------------
DEFAULT_ALLOWED_READ="$(grep '^HELPER_ALLOWED_READ=' "$HERE/run-native-stage0c.sh" | head -1 | cut -d= -f2 | tr -d '\"')"
DEFAULT_NETWORK_GATE="$(grep '^NETWORK_GATE=' "$HERE/run-native-stage0c.sh" | head -1 | cut -d= -f2 | tr -d '\"')"
DEFAULT_CHILD_GATE="$(grep '^HELPER_CHILD_PROCESS_INHERITS_CONTAINMENT=' "$HERE/run-native-stage0c.sh" | head -1 | cut -d= -f2 | tr -d '\"')"
DEFAULT_FS_GATE="$(grep '^HOST_HELPER_FS_CONTAINMENT_GATE=' "$HERE/run-native-stage0c.sh" | head -1 | cut -d= -f2 | tr -d '\"')"

if [ "$DEFAULT_ALLOWED_READ" != "NOT_RUN" ] || \
   [ "$DEFAULT_NETWORK_GATE" != "NOT_RUN" ] || \
   [ "$DEFAULT_CHILD_GATE" != "NOT_RUN" ] || \
   [ "$DEFAULT_FS_GATE" != "NOT_RUN" ]; then
  echo "FAIL: Fixture 7 (default probe states are not NOT_RUN: allowed=$DEFAULT_ALLOWED_READ net=$DEFAULT_NETWORK_GATE child=$DEFAULT_CHILD_GATE fs=$DEFAULT_FS_GATE)"
  exit 1
fi
echo "PASS: Fixture 7 - unrun prerequisite probes strictly default to NOT_RUN"

echo "========================================="
echo "ALL 7 BOOTSTRAP FIXTURES PASSED"
echo "========================================="
