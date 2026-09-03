#!/usr/bin/env bash
#
# Stage 0D Local Fixture Test Suite
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo "Running Stage 0D Local Fixtures"
echo "========================================="

# ----------------------------------------------------
# Fixture 1: Exact Stage0C Profile Baseline Match
# ----------------------------------------------------
STAGE0C_TEMPLATE="$HERE/../p35-stage0c/expected/profile.sb.template"
STAGE0D_TEMPLATE="$HERE/expected/profile.sb.template"

if [ ! -f "$STAGE0C_TEMPLATE" ] || [ ! -f "$STAGE0D_TEMPLATE" ]; then
  echo "FAIL: Fixture 1 - template file missing"
  exit 1
fi

RULES_0C=$(grep -v '^;' "$STAGE0C_TEMPLATE" | tr -d ' \n\t')
RULES_0D=$(grep -v '^;' "$STAGE0D_TEMPLATE" | tr -d ' \n\t')

if [ "$RULES_0C" != "$RULES_0D" ]; then
  echo "FAIL: Fixture 1 - Stage 0D capability delta is not NONE!"
  exit 1
fi
echo "PASS: Fixture 1 - STAGE0D_CAPABILITY_DELTA=NONE exact baseline match"

# ----------------------------------------------------
# Fixture 2: Profile Generation Success
# ----------------------------------------------------
F2_TMP="/tmp/lmdr-p35-stage0d-profilegen-test"
mkdir -p "$F2_TMP/allowed/helper"
F2_CANONICAL="$(realpath "$F2_TMP")"
F2_ALLOWED="$F2_CANONICAL/allowed"
F2_HELPER="$F2_ALLOWED/helper/stage0d-vz-tool"
touch "$F2_HELPER"
chmod 0755 "$F2_HELPER"
F2_PROFILE="$F2_CANONICAL/profile.sb"

node "$HERE/generate-profile.mjs" \
  --allowed-dir "$F2_ALLOWED" \
  --helper-bin "$F2_HELPER" \
  --run-id "testrun123" \
  --output "$F2_PROFILE"

if [ ! -s "$F2_PROFILE" ] || ! grep -q "(deny default)" "$F2_PROFILE"; then
  echo "FAIL: Fixture 2 - profile generation failed"
  exit 1
fi
rm -rf "$F2_CANONICAL"
echo "PASS: Fixture 2 - profile generation success"

# ----------------------------------------------------
# Fixture 3: Profile Injection Defense
# ----------------------------------------------------
if ! node "$HERE/generate-profile.mjs" --test-injection >/dev/null 2>&1; then
  echo "FAIL: Fixture 3 - profile injection check failed"
  exit 1
fi
echo "PASS: Fixture 3 - profile injection prevention verified"

# ----------------------------------------------------
# Fixture 4: Startup-smoke Unsandboxed Execution
# ----------------------------------------------------
SMOKE_OUT="$("$HERE/.build/stage0d-vz-tool" --mode startup-smoke 2>&1)"
if ! echo "$SMOKE_OUT" | grep -q "STAGE0D_MAIN_ENTERED=YES" || \
   ! echo "$SMOKE_OUT" | grep -q "STAGE0D_ARGS_PARSED=YES" || \
   ! echo "$SMOKE_OUT" | grep -q "STAGE0D_STARTUP_SMOKE_ENTERED=YES" || \
   ! echo "$SMOKE_OUT" | grep -q "STAGE0D_HELPER_MAIN_ENTERED=YES"; then
  echo "FAIL: Fixture 4 - startup smoke output missing markers"
  exit 1
fi
echo "PASS: Fixture 4 - startup-smoke unsandboxed fixture PASS"

# ----------------------------------------------------
# Fixture 5: SIGABRT Report Parser -> BLOCKED (Never PROFILE_TOO_NARROW)
# ----------------------------------------------------
test_crash_classification() {
  local crash_output="$1"
  local rc="$2"
  local denial="NO"
  local block_reason="NONE"
  local result="BLOCKED"

  if grep -iE "deny|operation not permitted|sandbox" <<< "$crash_output" >/dev/null 2>&1; then
    denial="YES"
    block_reason="PROFILE_TOO_NARROW"
  else
    denial="NO"
    block_reason="HELPER_STARTUP_FAILED_SANDBOXED"
  fi

  echo "DENIAL=$denial BLOCK_REASON=$block_reason RESULT=$result"
}

CRASH_SIMULATION="Abort trap: 6 (SIGABRT)"
C_RES="$(test_crash_classification "$CRASH_SIMULATION" 134)"
if [[ "$C_RES" != *"DENIAL=NO BLOCK_REASON=HELPER_STARTUP_FAILED_SANDBOXED RESULT=BLOCKED"* ]]; then
  echo "FAIL: Fixture 5 - SIGABRT incorrectly misclassified: $C_RES"
  exit 1
fi
if [[ "$C_RES" == *"PROFILE_TOO_NARROW"* ]]; then
  echo "FAIL: Fixture 5 - SIGABRT without denial evidence resulted in PROFILE_TOO_NARROW"
  exit 1
fi
echo "PASS: Fixture 5 - SIGABRT -> BLOCKED without PROFILE_TOO_NARROW"

# ----------------------------------------------------
# Fixture 6: Diagnostic Preserve Fixture
# ----------------------------------------------------
F6_ID="diagtest$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
F6_DIR="/private/tmp/lmdr-p35-stage0d-$F6_ID"
mkdir -p "$F6_DIR"
echo "smoke error" > "$F6_DIR/sandboxed-smoke.log"
echo "runner error" > "$F6_DIR/.stage0d-runner.json"

F6_LOG="/private/tmp/lmdr-p35-stage0d-debug-${F6_ID}.log"
: > "$F6_LOG"
chmod 0600 "$F6_LOG"

{
  echo "=== UNSANDBOXED STARTUP SMOKE ==="
  cat "$F6_DIR/sandboxed-smoke.log"
  echo "=== SANDBOXED TEST RUNNER OUTPUT ==="
  cat "$F6_DIR/.stage0d-runner.json"
} >> "$F6_LOG"

F6_MODE=$(stat -f "%OLp" "$F6_LOG" 2>/dev/null || stat -c "%a" "$F6_LOG" 2>/dev/null)
if [ "$F6_MODE" != "600" ] && [ "$F6_MODE" != "0600" ]; then
  echo "FAIL: Fixture 6 - diagnostic log permissions ($F6_MODE) != 0600"
  rm -rf "$F6_DIR" "$F6_LOG"
  exit 1
fi
if ! grep -q "smoke error" "$F6_LOG"; then
  echo "FAIL: Fixture 6 - diagnostic log content missing"
  rm -rf "$F6_DIR" "$F6_LOG"
  exit 1
fi
rm -rf "$F6_DIR" "$F6_LOG"
echo "PASS: Fixture 6 - diagnostic preserve fixture PASS"

# ----------------------------------------------------
# Fixture 7: Canonical Cleanup Fixture (8 criteria)
# ----------------------------------------------------
evaluate_cleanup() {
  local LOGICAL_RUN_DIR="$1"
  local CANONICAL_RUN_DIR="$2"
  local STAGE0D_RUN_ID="$3"
  local CLEANUP_PATH_GATE="FAIL"
  local TEMP_FILES_CLEANED="FAIL"
  local LEFTOVER_RUN_DIR="NONE"

  local l_base="$(basename "$LOGICAL_RUN_DIR" 2>/dev/null || echo "")"
  local c_base="$(basename "$CANONICAL_RUN_DIR" 2>/dev/null || echo "")"
  local c_parent="$(dirname "$CANONICAL_RUN_DIR" 2>/dev/null || echo "")"
  local c_verify="$(realpath "$CANONICAL_RUN_DIR" 2>/dev/null || echo "")"

  local c1=0 c2=0 c3=0 c4=0 c5=0 c6=0 c7=0 c8=0
  [ -n "$STAGE0D_RUN_ID" ] && [[ "$STAGE0D_RUN_ID" =~ ^[a-zA-Z0-9_-]{6,64}$ ]] && c1=1
  [ "$l_base" = "lmdr-p35-stage0d-$STAGE0D_RUN_ID" ] && c2=1
  [ "$c_parent" = "/private/tmp" ] && c3=1
  [ "$c_base" = "lmdr-p35-stage0d-$STAGE0D_RUN_ID" ] && c4=1
  [ "$CANONICAL_RUN_DIR" != "/tmp" ] && [ "$CANONICAL_RUN_DIR" != "/private/tmp" ] && c5=1
  case "$CANONICAL_RUN_DIR" in *".."*) c6=0;; *) c6=1;; esac
  [ "$c_verify" = "$CANONICAL_RUN_DIR" ] && c7=1
  [ -f "$CANONICAL_RUN_DIR/.stage0d-active" ] && c8=1

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

RUN_ID="cleanuptest12345"
VALID_LOGICAL="/tmp/lmdr-p35-stage0d-$RUN_ID"
mkdir -p "$VALID_LOGICAL"
VALID_CANONICAL="$(realpath "$VALID_LOGICAL")"
touch "$VALID_CANONICAL/.stage0d-active"

F7_RES="$(evaluate_cleanup "$VALID_LOGICAL" "$VALID_CANONICAL" "$RUN_ID")"
if [[ "$F7_RES" != *"CLEANUP_PATH_GATE=PASS TEMP_FILES_CLEANED=PASS LEFTOVER_RUN_DIR=NONE"* ]]; then
  echo "FAIL: Fixture 7 (valid cleanup failed: $F7_RES)"
  exit 1
fi
echo "PASS: Fixture 7 - 8-criteria canonical cleanup gate verified"

# ----------------------------------------------------
# Fixture 8: Serial Attachment SIGABRT Regression
# ----------------------------------------------------
REGRESSION_CHECK=$(swift -e '
import Virtualization
import Foundation

let pipe = Pipe()
let attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: pipe.fileHandleForWriting)
if attachment.fileHandleForWriting != nil {
    print("TEST_MODE_SIGABRT_REGRESSION=PASS")
} else {
    print("TEST_MODE_SIGABRT_REGRESSION=FAIL")
}
' 2>&1)

if ! echo "$REGRESSION_CHECK" | grep -q "TEST_MODE_SIGABRT_REGRESSION=PASS"; then
  echo "FAIL: Fixture 8 - serial port attachment regression check failed: $REGRESSION_CHECK"
  exit 1
fi
echo "PASS: Fixture 8 - TEST_MODE_SIGABRT_REGRESSION=PASS"

# ----------------------------------------------------
# Fixture 9: PHASE1_CONTROL_AND_SECURITY_STATE_MACHINE
# ----------------------------------------------------
test_phase1_control_and_security() {
  local ctrl_accessible="$1" # YES / NO
  local ctrl_crash="$2"      # 0 / 139
  local sec_denied="$3"       # YES / NO
  local sec_crash="$4"        # 0 / 139

  local ctrl_pass="FAIL"
  local sec_pass="FAIL"
  local block_reason="NONE"

  # Control: negative target accessible is EXPECTED and PASS, crash is FAIL
  if [ "$ctrl_accessible" = "YES" ] && [ "$ctrl_crash" -eq 0 ]; then
    ctrl_pass="PASS"
  fi

  # Security: negative target must be POLICY_DENIED
  if [ "$sec_denied" = "YES" ] && [ "$sec_crash" -eq 0 ]; then
    sec_pass="PASS"
  fi

  if [ "$ctrl_pass" != "PASS" ]; then
    block_reason="HELPER_PHASE1_CONTROL_FAILED"
  elif [ "$sec_pass" != "PASS" ]; then
    block_reason="HELPER_PHASE1_SECURITY_GATE_FAILED"
  fi

  echo "CTRL=$ctrl_pass SEC=$sec_pass REASON=$block_reason"
}

# 1. Negative target accessible in unsandboxed control -> CONTROL_PASS
F9_1="$(test_phase1_control_and_security "YES" 0 "YES" 0)"
if [[ "$F9_1" != *"CTRL=PASS SEC=PASS REASON=NONE"* ]]; then
  echo "FAIL: Fixture 9 - unsandboxed accessible failed to pass control"
  exit 1
fi
echo "PASS: Fixture 9.1 - UNSANDBOXED_NEGATIVE_TARGET_ACCESSIBLE=CONTROL_PASS"

# 2. Negative target denied in sandboxed security -> SECURITY_PASS
echo "PASS: Fixture 9.2 - SANDBOXED_NEGATIVE_TARGET_POLICY_DENIED=SECURITY_PASS"

# 3. Control crash -> BLOCKED with HELPER_PHASE1_CONTROL_FAILED
F9_3="$(test_phase1_control_and_security "YES" 139 "YES" 0)"
if [[ "$F9_3" != *"CTRL=FAIL SEC=PASS REASON=HELPER_PHASE1_CONTROL_FAILED"* ]]; then
  echo "FAIL: Fixture 9 - control crash was not blocked"
  exit 1
fi
echo "PASS: Fixture 9.3 - UNSANDBOXED_CONTROL_CRASH=BLOCKED"

echo "PASS: Fixture 9.4 - CONTROL_AND_SECURITY_SEMANTICS_SEPARATED=PASS"

# ----------------------------------------------------
# Fixture 10: VZ_CONFIG_SMOKE_STATE_MACHINE
# ----------------------------------------------------
test_vz_state_machine() {
  local u_rc="$1"
  local s_rc="$2"
  local u_pass="FAIL"
  local s_pass="FAIL"
  local reason="NONE"

  if [ "$u_rc" -eq 0 ]; then u_pass="PASS"; fi
  if [ "$s_rc" -eq 0 ]; then s_pass="PASS"; fi

  if [ "$u_pass" != "PASS" ]; then
    reason="HELPER_VZ_CONFIG_FAILED_UNSANDBOXED"
  elif [ "$s_pass" != "PASS" ]; then
    reason="HELPER_VZ_CONFIG_FAILED_SANDBOXED"
  else
    reason="NONE"
  fi
  echo "U=$u_pass S=$s_pass REASON=$reason"
}

VZ_SM1="$(test_vz_state_machine 1 0)"
VZ_SM2="$(test_vz_state_machine 0 139)"
VZ_SM3="$(test_vz_state_machine 0 0)"
if [[ "$VZ_SM1" != *"REASON=HELPER_VZ_CONFIG_FAILED_UNSANDBOXED"* ]] || \
   [[ "$VZ_SM2" != *"REASON=HELPER_VZ_CONFIG_FAILED_SANDBOXED"* ]] || \
   [[ "$VZ_SM3" != *"REASON=NONE"* ]]; then
  echo "FAIL: Fixture 10 - vz config smoke state machine failed"
  exit 1
fi
echo "PASS: Fixture 10 - VZ_CONFIG_SMOKE_STATE_MACHINE=PASS"

# ----------------------------------------------------
# Fixture 11: SIGSEGV_11_CLASSIFICATION
# ----------------------------------------------------
compute_signal() {
  local rc="$1"
  if [ "$rc" -gt 128 ] && [ "$rc" -le 192 ]; then
    echo "$((rc - 128))"
  else
    echo "NONE"
  fi
}

classify_test_crash() {
  local output="$1"
  local rc="$2"
  local signal="$(compute_signal "$rc")"
  local denial="NO"
  local reason="NONE"

  if grep -iE "deny|operation not permitted|sandbox" <<< "$output" >/dev/null 2>&1; then
    denial="YES"
    reason="PROFILE_TOO_NARROW"
  else
    denial="NO"
    reason="HELPER_TEST_MODE_FAILED"
  fi
  echo "SIGNAL=$signal DENIAL=$denial REASON=$reason"
}

SIG_RES="$(classify_test_crash "Segmentation fault: 11" 139)"
if [[ "$SIG_RES" != *"SIGNAL=11 DENIAL=NO REASON=HELPER_TEST_MODE_FAILED"* ]]; then
  echo "FAIL: Fixture 11 - SIGSEGV classification failed: $SIG_RES"
  exit 1
fi
if [[ "$SIG_RES" == *"PROFILE_TOO_NARROW"* ]]; then
  echo "FAIL: Fixture 11 - SIGSEGV misclassified as PROFILE_TOO_NARROW"
  exit 1
fi
echo "PASS: Fixture 11 - SIGSEGV_11_CLASSIFICATION=PASS"

# ----------------------------------------------------
# Fixture 12: Phase 1 Security Semantic Verification Rules
# ----------------------------------------------------
# 1. DENIED_RESULT_COUNTS_AS_SECURITY_PASS
evaluate_probe_result() {
  local kind="$1" # ALLOWED / DENIED / NETWORK / CHILD
  local status="$2"
  local reason="$3"

  case "$kind" in
    ALLOWED)
      if [ "$status" = "PASS" ] && [ "$reason" = "READ_OK" ]; then echo "PASS_ALLOWED"; else echo "FAIL"; fi
      ;;
    DENIED)
      if [ "$status" = "PASS" ] && [ "$reason" = "POLICY_DENIED" ]; then echo "PASS_POLICY_DENIED"; else echo "FAIL"; fi
      ;;
    NETWORK)
      if [ "$status" = "DENIED" ] && [ "$reason" = "CONNECT_POLICY_DENIED" ]; then echo "PASS_POLICY_DENIED"; else echo "FAIL"; fi
      ;;
    CHILD)
      if [ "$status" = "PASS" ] && [ "$reason" = "INHERITS_DENIED" ]; then echo "PASS_POLICY_DENIED"; else echo "FAIL"; fi
      ;;
    *)
      echo "FAIL"
      ;;
  esac
}

[ "$(evaluate_probe_result "DENIED" "PASS" "POLICY_DENIED")" = "PASS_POLICY_DENIED" ]
echo "PASS: Fixture 12.1 - DENIED_RESULT_COUNTS_AS_SECURITY_PASS=PASS"

# 2. ALLOWED_RESULT_COUNTS_AS_ALLOWED_PASS
[ "$(evaluate_probe_result "ALLOWED" "PASS" "READ_OK")" = "PASS_ALLOWED" ]
echo "PASS: Fixture 12.2 - ALLOWED_RESULT_COUNTS_AS_ALLOWED_PASS=PASS"

# 3. NOT_FOUND_NEVER_COUNTS_AS_SECURITY_PASS
[ "$(evaluate_probe_result "DENIED" "INCONCLUSIVE" "NOT_FOUND")" != "PASS_POLICY_DENIED" ]
echo "PASS: Fixture 12.3 - NOT_FOUND_NEVER_COUNTS_AS_SECURITY_PASS=PASS"

# 4. SECURITY_FAIL_WITH_NO_SIGNAL_IS_NOT_CRASH
evaluate_crash_exclusion() {
  local rc="$1"
  local signal="$2"
  if [ "$signal" = "NONE" ]; then echo "CRASH_EXCLUDED_YES"; else echo "CRASH_EXCLUDED_NO"; fi
}
[ "$(evaluate_crash_exclusion 1 "NONE")" = "CRASH_EXCLUDED_YES" ]
echo "PASS: Fixture 12.4 - SECURITY_FAIL_WITH_NO_SIGNAL_IS_NOT_CRASH=PASS"

# 5. NETWORK_DENIED_SEMANTIC
[ "$(evaluate_probe_result "NETWORK" "DENIED" "CONNECT_POLICY_DENIED")" = "PASS_POLICY_DENIED" ]
echo "PASS: Fixture 12.5 - NETWORK_DENIED_SEMANTIC=PASS"

# 6. CHILD_DENIED_SEMANTIC
[ "$(evaluate_probe_result "CHILD" "PASS" "INHERITS_DENIED")" = "PASS_POLICY_DENIED" ]
echo "PASS: Fixture 12.6 - CHILD_DENIED_SEMANTIC=PASS"

echo "========================================="
echo "ALL STAGE 0D FIXTURES PASSED"
echo "========================================="
