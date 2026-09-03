#!/usr/bin/env bash
#
# P3.5 Stage 0D — Host Helper Filesystem Containment + VirtioFS Isolation Prototype Runner
#
# Diagnostic Matrix:
# 1. Startup smoke:
#    - UNSANDBOXED_STARTUP_SMOKE
#    - SANDBOXED_STARTUP_SMOKE
# 2. Phase 1 Host containment:
#    - UNSANDBOXED_PHASE1_CONTROL (control mode: proves probe logic works & sentinels exist)
#    - SANDBOXED_PHASE1_SECURITY_GATE (security gate: strictly requires POLICY_DENIED)
# 3. VZ configuration smoke:
#    - UNSANDBOXED_VZ_CONFIG_SMOKE
#    - SANDBOXED_VZ_CONFIG_SMOKE
# 4. VM start smoke matrix:
#    - UNSANDBOXED_VM_START_SMOKE
#    - SANDBOXED_VM_START_SMOKE
# 5. Formal VM test (runs after control, security gate, VZ config smoke, and VM start smoke pass)
# 6. Canonical /private/tmp 8-criteria cleanup gate
#
# Does NOT touch production runtime, projects.json, or any managed worktree.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Report variables with fail-closed defaults ---
STAGE0D_RUN_ID=""
SANDBOX_BACKEND="sandbox-exec"
STAGE0D_CAPABILITY_DELTA="FUSE_EXTENSION_ONLY"

PROFILE_GENERATION="NOT_RUN"
PROFILE_PATH="NONE"
PROFILE_GENERATION_RC="NOT_RUN"
PROFILE_GENERATION_ERROR="NONE"
SANDBOX_PROFILE_SHA256="NONE"

HELPER_EXEC_LOCATION="NOT_RUN"
HELPER_EXECUTABLE_GATE="NOT_RUN"
VIRTIOFS_SHARE_ROOT="ALLOWED/SHARE"
HELPER_OUTPUT_MODEL="STDOUT_ONLY"

PROFILE_INPUT_VALIDATION_GATE="NOT_RUN"
PROFILE_INJECTION_GATE="NOT_RUN"

UNSANDBOXED_STARTUP_SMOKE="NOT_RUN"
UNSANDBOXED_STARTUP_RC="NOT_RUN"
SANDBOXED_STARTUP_SMOKE="NOT_RUN"
SANDBOXED_STARTUP_RC="NOT_RUN"
SANDBOXED_STARTUP_SIGNAL="NONE"

UNSANDBOXED_PHASE1_CONTROL="NOT_RUN"
UNSANDBOXED_PHASE1_CONTROL_RC="NOT_RUN"
UNSANDBOXED_PHASE1_CONTROL_SIGNAL="NONE"

SANDBOXED_PHASE1_SECURITY_GATE="NOT_RUN"
SANDBOXED_PHASE1_RC="NOT_RUN"
SANDBOXED_PHASE1_SIGNAL="NONE"
PHASE1_CRASH_EXCLUDED="UNKNOWN"

UNSANDBOXED_VZ_CONFIG_SMOKE="NOT_RUN"
UNSANDBOXED_VZ_CONFIG_RC="NOT_RUN"
UNSANDBOXED_VZ_CONFIG_SIGNAL="NONE"
SANDBOXED_VZ_CONFIG_SMOKE="NOT_RUN"
SANDBOXED_VZ_CONFIG_RC="NOT_RUN"
SANDBOXED_VZ_CONFIG_SIGNAL="NONE"
LAST_VZ_CONFIG_MARKER="NONE"

UNSANDBOXED_VM_START_SMOKE="NOT_RUN"
UNSANDBOXED_VM_START_RC="NOT_RUN"
UNSANDBOXED_VM_START_SIGNAL="NONE"
SANDBOXED_VM_START_SMOKE="NOT_RUN"
SANDBOXED_VM_START_RC="NOT_RUN"
SANDBOXED_VM_START_SIGNAL="NONE"

SANDBOXED_TEST_RC="NOT_RUN"
SANDBOXED_TEST_SIGNAL="NONE"

HOST_CONTAINMENT_PRE_VM="NOT_RUN"

VM_CONFIG_VALIDATE="NOT_RUN"
VM_START="NOT_RUN"
VM_RUNNING="NOT_RUN"
VIRTIOFS_MOUNT="NOT_RUN"

GUEST_HOST_TO_GUEST_READ="NOT_RUN"
GUEST_GUEST_TO_HOST_WRITE="NOT_RUN"
GUEST_DOTDOT_ESCAPE="NOT_RUN"
GUEST_SYMLINK_ESCAPE_REL="NOT_RUN"
GUEST_SYMLINK_ESCAPE_ABS="NOT_RUN"
GUEST_ABSOLUTE_PATH_ESCAPE="NOT_RUN"
GUEST_HOST_HOME_EXPOSED="NOT_RUN"
GUEST_HAS_VIRTIO_NET="NOT_RUN"

VM_STOP="NOT_RUN"
VM_FINAL_STATE="NOT_RUN"

VIRTIOFS_GUEST_ISOLATION="NOT_RUN"
VIRTUALIZATION_VM_LIFECYCLE="NOT_RUN"

HOST_CONTAINMENT_POST_VM="NOT_RUN"
HOST_CONTAINMENT_DELTA="NOT_RUN"

UNSANDBOXED_LOOPBACK_CONNECT="NOT_RUN"
HOST_NETWORK_GATE="NOT_RUN"
GUEST_NETWORK_GATE="NOT_RUN"

FRAMEWORK_WORKER_TRUST_BOUNDARY="TRUSTED_OS_SERVICE_OUTSIDE_HELPER_SEATBELT"

SANDBOX_DENIAL_EVIDENCE="NO"
DENIAL_OPERATION="NONE"
DENIAL_PATH_OR_SERVICE="NONE"
FAILED_OPERATION="NONE"
FAILED_SERVICE_OR_PATH="NONE"

DIAGNOSTIC_LOG_PRESERVED="NO"
DIAGNOSTIC_LOG_PATH="NONE"
DIAGNOSTIC_LOG_SHA256="NONE"
DIAGNOSTIC_LOG_BYTES=0

CLEANUP_PATH_GATE="FAIL"
TEMP_FILES_CLEANED="FAIL"
LEFTOVER_RUN_DIR="NONE"
ORPHAN_PROCESS_COUNT=0

PROJECTS_JSON_MODIFIED="NO"
RUNTIME_MODIFIED="NO"
REAL_WORKTREE_TOUCHED="NO"

SEATBELT_HELPER_CONTAINMENT="NOT_RUN"
STAGE0D_RESULT="BLOCKED"
BLOCK_REASON="NONE"
P3_5_PRODUCTION_IMPLEMENTATION="NO"

CURRENT_STAGE="BOOTSTRAP"
LOGICAL_RUN_DIR=""
CANONICAL_RUN_DIR=""
LISTENER_PID=""

# --- helpers ---
get_json() {
  printf '%s' "$1" | grep -oE "\"$2\"[ ]*:[ ]*(\"[^\"]*\"|true|false|null|-?[0-9]+)" \
    | sed -E "s/^\"$2\"[ ]*:[ ]*//; s/^\"//; s/\"$//"
}

compute_signal() {
  local rc="$1"
  if [ "$rc" -gt 128 ] && [ "$rc" -le 192 ]; then
    echo "$((rc - 128))"
  else
    echo "NONE"
  fi
}

emit_report() {
  [ -z "$BLOCK_REASON" ] && BLOCK_REASON="NONE"
  [ -z "$STAGE0D_RUN_ID" ] && STAGE0D_RUN_ID="UNKNOWN"

  echo "==== STAGE 0D NATIVE GATE REPORT ===="
  echo "STAGE0D_RUN_ID=$STAGE0D_RUN_ID"
  echo "SANDBOX_BACKEND=$SANDBOX_BACKEND"
  echo "STAGE0D_CAPABILITY_DELTA=$STAGE0D_CAPABILITY_DELTA"
  echo "PROFILE_GENERATION=$PROFILE_GENERATION"
  echo "PROFILE_PATH=$PROFILE_PATH"
  echo "PROFILE_GENERATION_RC=$PROFILE_GENERATION_RC"
  echo "PROFILE_GENERATION_ERROR=$PROFILE_GENERATION_ERROR"
  echo "SANDBOX_PROFILE_SHA256=$SANDBOX_PROFILE_SHA256"
  echo "HELPER_EXEC_LOCATION=$HELPER_EXEC_LOCATION"
  echo "HELPER_EXECUTABLE_GATE=$HELPER_EXECUTABLE_GATE"
  echo "VIRTIOFS_SHARE_ROOT=$VIRTIOFS_SHARE_ROOT"
  echo "HELPER_OUTPUT_MODEL=$HELPER_OUTPUT_MODEL"
  echo "PROFILE_INPUT_VALIDATION_GATE=$PROFILE_INPUT_VALIDATION_GATE"
  echo "PROFILE_INJECTION_GATE=$PROFILE_INJECTION_GATE"
  echo "UNSANDBOXED_STARTUP_SMOKE=$UNSANDBOXED_STARTUP_SMOKE"
  echo "UNSANDBOXED_STARTUP_RC=$UNSANDBOXED_STARTUP_RC"
  echo "SANDBOXED_STARTUP_SMOKE=$SANDBOXED_STARTUP_SMOKE"
  echo "SANDBOXED_STARTUP_RC=$SANDBOXED_STARTUP_RC"
  echo "SANDBOXED_STARTUP_SIGNAL=$SANDBOXED_STARTUP_SIGNAL"
  echo "UNSANDBOXED_PHASE1_CONTROL=$UNSANDBOXED_PHASE1_CONTROL"
  echo "UNSANDBOXED_PHASE1_CONTROL_RC=$UNSANDBOXED_PHASE1_CONTROL_RC"
  echo "UNSANDBOXED_PHASE1_CONTROL_SIGNAL=$UNSANDBOXED_PHASE1_CONTROL_SIGNAL"
  echo "SANDBOXED_PHASE1_SECURITY_GATE=$SANDBOXED_PHASE1_SECURITY_GATE"
  echo "SANDBOXED_PHASE1_RC=$SANDBOXED_PHASE1_RC"
  echo "SANDBOXED_PHASE1_SIGNAL=$SANDBOXED_PHASE1_SIGNAL"
  echo "PHASE1_CRASH_EXCLUDED=$PHASE1_CRASH_EXCLUDED"
  echo "UNSANDBOXED_VZ_CONFIG_SMOKE=$UNSANDBOXED_VZ_CONFIG_SMOKE"
  echo "UNSANDBOXED_VZ_CONFIG_RC=$UNSANDBOXED_VZ_CONFIG_RC"
  echo "UNSANDBOXED_VZ_CONFIG_SIGNAL=$UNSANDBOXED_VZ_CONFIG_SIGNAL"
  echo "SANDBOXED_VZ_CONFIG_SMOKE=$SANDBOXED_VZ_CONFIG_SMOKE"
  echo "SANDBOXED_VZ_CONFIG_RC=$SANDBOXED_VZ_CONFIG_RC"
  echo "SANDBOXED_VZ_CONFIG_SIGNAL=$SANDBOXED_VZ_CONFIG_SIGNAL"
  echo "LAST_VZ_CONFIG_MARKER=$LAST_VZ_CONFIG_MARKER"
  echo "UNSANDBOXED_VM_START_SMOKE=$UNSANDBOXED_VM_START_SMOKE"
  echo "UNSANDBOXED_VM_START_RC=$UNSANDBOXED_VM_START_RC"
  echo "UNSANDBOXED_VM_START_SIGNAL=$UNSANDBOXED_VM_START_SIGNAL"
  echo "SANDBOXED_VM_START_SMOKE=$SANDBOXED_VM_START_SMOKE"
  echo "SANDBOXED_VM_START_RC=$SANDBOXED_VM_START_RC"
  echo "SANDBOXED_VM_START_SIGNAL=$SANDBOXED_VM_START_SIGNAL"
  echo "SANDBOXED_TEST_RC=$SANDBOXED_TEST_RC"
  echo "SANDBOXED_TEST_SIGNAL=$SANDBOXED_TEST_SIGNAL"
  echo "HOST_CONTAINMENT_PRE_VM=$HOST_CONTAINMENT_PRE_VM"
  echo "VM_CONFIG_VALIDATE=$VM_CONFIG_VALIDATE"
  echo "VM_START=$VM_START"
  echo "VM_RUNNING=$VM_RUNNING"
  echo "VIRTIOFS_MOUNT=$VIRTIOFS_MOUNT"
  echo "GUEST_HOST_TO_GUEST_READ=$GUEST_HOST_TO_GUEST_READ"
  echo "GUEST_GUEST_TO_HOST_WRITE=$GUEST_GUEST_TO_HOST_WRITE"
  echo "GUEST_DOTDOT_ESCAPE=$GUEST_DOTDOT_ESCAPE"
  echo "GUEST_SYMLINK_ESCAPE_REL=$GUEST_SYMLINK_ESCAPE_REL"
  echo "GUEST_SYMLINK_ESCAPE_ABS=$GUEST_SYMLINK_ESCAPE_ABS"
  echo "GUEST_ABSOLUTE_PATH_ESCAPE=$GUEST_ABSOLUTE_PATH_ESCAPE"
  echo "GUEST_HOST_HOME_EXPOSED=$GUEST_HOST_HOME_EXPOSED"
  echo "GUEST_HAS_VIRTIO_NET=$GUEST_HAS_VIRTIO_NET"
  echo "VM_STOP=$VM_STOP"
  echo "VM_FINAL_STATE=$VM_FINAL_STATE"
  echo "VIRTIOFS_GUEST_ISOLATION=$VIRTIOFS_GUEST_ISOLATION"
  echo "VIRTUALIZATION_VM_LIFECYCLE=$VIRTUALIZATION_VM_LIFECYCLE"
  echo "HOST_CONTAINMENT_POST_VM=$HOST_CONTAINMENT_POST_VM"
  echo "HOST_CONTAINMENT_DELTA=$HOST_CONTAINMENT_DELTA"
  echo "UNSANDBOXED_LOOPBACK_CONNECT=$UNSANDBOXED_LOOPBACK_CONNECT"
  echo "HOST_NETWORK_GATE=$HOST_NETWORK_GATE"
  echo "GUEST_NETWORK_GATE=$GUEST_NETWORK_GATE"
  echo "FRAMEWORK_WORKER_TRUST_BOUNDARY=$FRAMEWORK_WORKER_TRUST_BOUNDARY"
  echo "SANDBOX_DENIAL_EVIDENCE=$SANDBOX_DENIAL_EVIDENCE"
  echo "DENIAL_OPERATION=$DENIAL_OPERATION"
  echo "DENIAL_PATH_OR_SERVICE=$DENIAL_PATH_OR_SERVICE"
  echo "FAILED_OPERATION=$FAILED_OPERATION"
  echo "FAILED_SERVICE_OR_PATH=$FAILED_SERVICE_OR_PATH"
  echo "DIAGNOSTIC_LOG_PRESERVED=$DIAGNOSTIC_LOG_PRESERVED"
  echo "DIAGNOSTIC_LOG_PATH=$DIAGNOSTIC_LOG_PATH"
  echo "DIAGNOSTIC_LOG_SHA256=$DIAGNOSTIC_LOG_SHA256"
  echo "DIAGNOSTIC_LOG_BYTES=$DIAGNOSTIC_LOG_BYTES"
  echo "CLEANUP_PATH_GATE=$CLEANUP_PATH_GATE"
  echo "TEMP_FILES_CLEANED=$TEMP_FILES_CLEANED"
  echo "LEFTOVER_RUN_DIR=$LEFTOVER_RUN_DIR"
  echo "ORPHAN_PROCESS_COUNT=$ORPHAN_PROCESS_COUNT"
  echo "PROJECTS_JSON_MODIFIED=$PROJECTS_JSON_MODIFIED"
  echo "RUNTIME_MODIFIED=$RUNTIME_MODIFIED"
  echo "REAL_WORKTREE_TOUCHED=$REAL_WORKTREE_TOUCHED"
  echo "SEATBELT_HELPER_CONTAINMENT=$SEATBELT_HELPER_CONTAINMENT"
  echo "STAGE0D_RESULT=$STAGE0D_RESULT"
  echo "BLOCK_REASON=$BLOCK_REASON"
  echo "P3_5_PRODUCTION_IMPLEMENTATION=$P3_5_PRODUCTION_IMPLEMENTATION"
}

cleanup() {
  local exit_code=$?

  if [ -n "${LISTENER_PID:-}" ]; then
    if kill -0 "$LISTENER_PID" 2>/dev/null; then
      kill -TERM "$LISTENER_PID" 2>/dev/null || true
      sleep 0.1
      kill -9 "$LISTENER_PID" 2>/dev/null || true
    fi
    LISTENER_PID=""
  fi

  # Preserve diagnostic log if requested: PRESERVE_STAGE0D_DIAGNOSTICS=1
  if [ "${PRESERVE_STAGE0D_DIAGNOSTICS:-0}" = "1" ] && [ -n "${CANONICAL_RUN_DIR:-}" ] && [ -n "${STAGE0D_RUN_ID:-}" ]; then
    local dbg_log="/private/tmp/lmdr-p35-stage0d-debug-${STAGE0D_RUN_ID}.log"
    : > "$dbg_log" 2>/dev/null || true
    chmod 0600 "$dbg_log" 2>/dev/null || true

    {
      echo "=== UNSANDBOXED STARTUP SMOKE ==="
      cat "$CANONICAL_RUN_DIR/unsandboxed-smoke.log" 2>/dev/null || echo "(no log)"
      echo "=== SANDBOXED STARTUP SMOKE ==="
      cat "$CANONICAL_RUN_DIR/sandboxed-smoke.log" 2>/dev/null || echo "(no log)"
      echo "=== UNSANDBOXED PHASE1 CONTROL ==="
      cat "$CANONICAL_RUN_DIR/unsandboxed-phase1.log" 2>/dev/null || echo "(no log)"
      echo "=== SANDBOXED PHASE1 SECURITY GATE ==="
      cat "$CANONICAL_RUN_DIR/sandboxed-phase1.log" 2>/dev/null || echo "(no log)"
      echo "=== UNSANDBOXED VZ CONFIG SMOKE ==="
      cat "$CANONICAL_RUN_DIR/unsandboxed-vz-config.log" 2>/dev/null || echo "(no log)"
      echo "=== SANDBOXED VZ CONFIG SMOKE ==="
      cat "$CANONICAL_RUN_DIR/sandboxed-vz-config.log" 2>/dev/null || echo "(no log)"
      echo "=== UNSANDBOXED VM START SMOKE ==="
      cat "$CANONICAL_RUN_DIR/unsandboxed-vm-start.log" 2>/dev/null || echo "(no log)"
      echo "=== SANDBOXED VM START SMOKE ==="
      cat "$CANONICAL_RUN_DIR/sandboxed-vm-start.log" 2>/dev/null || echo "(no log)"
      echo "=== SANDBOXED TEST RUNNER OUTPUT ==="
      cat "$CANONICAL_RUN_DIR/.stage0d-runner.json" 2>/dev/null || echo "(no log)"
    } >> "$dbg_log" 2>/dev/null || true

    if [ -s "$dbg_log" ]; then
      DIAGNOSTIC_LOG_PRESERVED="YES"
      DIAGNOSTIC_LOG_PATH="$dbg_log"
      DIAGNOSTIC_LOG_SHA256="$(shasum -a 256 "$dbg_log" 2>/dev/null | awk '{print $1}')"
      DIAGNOSTIC_LOG_BYTES="$(stat -f "%z" "$dbg_log" 2>/dev/null || wc -c < "$dbg_log" 2>/dev/null || echo 0)"
    fi
  fi

  CLEANUP_PATH_GATE="FAIL"
  TEMP_FILES_CLEANED="FAIL"
  ORPHAN_PROCESS_COUNT=0

  if [ -n "${CANONICAL_RUN_DIR:-}" ] && [ -n "${STAGE0D_RUN_ID:-}" ]; then
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
  fi

  if [ "$exit_code" -ne 0 ] || [ "$STAGE0D_RESULT" = "NOT_RUN" ]; then
    if [ "$STAGE0D_RESULT" != "FAIL" ] && [ "$STAGE0D_RESULT" != "BLOCKED" ]; then
      STAGE0D_RESULT="BLOCKED"
      if [ "$BLOCK_REASON" = "NONE" ]; then
        case "$CURRENT_STAGE" in
          RUN_DIR_CREATE|CANONICAL_REALPATH|SENTINEL_SETUP|ALLOWED_SETUP)
            BLOCK_REASON="RUN_DIR_SETUP_FAILED" ;;
          RUN_ID_VALIDATION)
            BLOCK_REASON="RUN_ID_INVALID" ;;
          HELPER_COPY|ASSETS_COPY)
            BLOCK_REASON="HELPER_SETUP_FAILED" ;;
          LISTENER_START)
            BLOCK_REASON="LISTENER_SETUP_FAILED" ;;
          PROBES_MANIFEST)
            BLOCK_REASON="PROBES_MANIFEST_FAILED" ;;
          PROFILE_GENERATION)
            BLOCK_REASON="PROFILE_GENERATION_FAILED" ;;
          UNSANDBOXED_SMOKE)
            BLOCK_REASON="HELPER_STARTUP_FAILED_UNSANDBOXED" ;;
          SANDBOXED_SMOKE)
            BLOCK_REASON="HELPER_STARTUP_FAILED_SANDBOXED" ;;
          UNSANDBOXED_PHASE1)
            BLOCK_REASON="HELPER_PHASE1_CONTROL_FAILED" ;;
          SANDBOXED_PHASE1)
            BLOCK_REASON="HELPER_PHASE1_SECURITY_GATE_FAILED" ;;
          UNSANDBOXED_VZ_CONFIG)
            BLOCK_REASON="HELPER_VZ_CONFIG_FAILED_UNSANDBOXED" ;;
          SANDBOXED_VZ_CONFIG)
            BLOCK_REASON="HELPER_VZ_CONFIG_FAILED_SANDBOXED" ;;
          UNSANDBOXED_VM_START)
            BLOCK_REASON="HELPER_VM_START_FAILED_UNSANDBOXED" ;;
          SANDBOXED_VM_START)
            BLOCK_REASON="HELPER_VM_START_FAILED_SANDBOXED" ;;
          SANDBOX_EXEC)
            if [ "$SANDBOXED_TEST_SIGNAL" = "4" ]; then
              BLOCK_REASON="VM_START_SIGILL"
            elif [ "$SANDBOXED_TEST_SIGNAL" = "11" ]; then
              BLOCK_REASON="VM_START_SIGSEGV"
            else
              BLOCK_REASON="HELPER_TEST_MODE_FAILED"
            fi
            ;;
          REPORT_PARSE)
            BLOCK_REASON="REPORT_PARSE_FAILED" ;;
          *)
            BLOCK_REASON="OTHER" ;;
        esac
      fi
    fi
  fi

  if [ "$CLEANUP_PATH_GATE" = "FAIL" ] && [ "$BLOCK_REASON" = "NONE" ]; then
    BLOCK_REASON="CLEANUP_GATE_FAILED"
    STAGE0D_RESULT="BLOCKED"
  fi

  emit_report
}
trap cleanup EXIT INT TERM

# =================== 1. Setup Test Run Layout ===================
CURRENT_STAGE="RUN_ID_VALIDATION"
STAGE0D_RUN_ID="$(head -c 12 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')"
if [[ ! "$STAGE0D_RUN_ID" =~ ^[a-zA-Z0-9_-]{6,64}$ ]]; then
  BLOCK_REASON="RUN_ID_INVALID"
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

CURRENT_STAGE="RUN_DIR_CREATE"
LOGICAL_RUN_DIR="/tmp/lmdr-p35-stage0d-$STAGE0D_RUN_ID"
mkdir -p "$LOGICAL_RUN_DIR"
CANONICAL_RUN_DIR="$(realpath "$LOGICAL_RUN_DIR")"
touch "$CANONICAL_RUN_DIR/.stage0d-active"

CURRENT_STAGE="CANONICAL_REALPATH"
c_parent="$(dirname "$CANONICAL_RUN_DIR")"
if [ "$c_parent" != "/private/tmp" ]; then
  BLOCK_REASON="CANONICAL_PATH_FAILED"
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

CURRENT_STAGE="ALLOWED_SETUP"
ALLOWED="$CANONICAL_RUN_DIR/allowed"
mkdir -p "$ALLOWED/helper"
mkdir -p "$ALLOWED/assets"
mkdir -p "$ALLOWED/share/write-target"
mkdir -p "$ALLOWED/write-target"
echo "STAGE0D_CAN_READ_${STAGE0D_RUN_ID}" > "$ALLOWED/can-read.txt"
echo "STAGE0D_HOST_READ_${STAGE0D_RUN_ID}" > "$ALLOWED/share/host-read.txt"

CURRENT_STAGE="SENTINEL_SETUP"
SENTINELS="$CANONICAL_RUN_DIR/sentinels"
mkdir -p "$SENTINELS/fake-home/.ssh"
mkdir -p "$SENTINELS/fake-home/.aws"
mkdir -p "$SENTINELS/fake-home/.config"
mkdir -p "$SENTINELS/fake-home/.local/share/local-mcp-dev-runner/runtime"
mkdir -p "$SENTINELS/sibling-dir"
mkdir -p "$SENTINELS/parent-denied"

FAKE_SSH_SECRET="FAKE_SSH_STAGE0D_${STAGE0D_RUN_ID}_$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FAKE_AWS_SECRET="FAKE_AWS_STAGE0D_${STAGE0D_RUN_ID}_$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FAKE_CONFIG_SECRET="FAKE_CONFIG_STAGE0D_${STAGE0D_RUN_ID}_$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FAKE_RUNTIME_SECRET="FAKE_RUNTIME_STAGE0D_${STAGE0D_RUN_ID}_$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FAKE_ROOT_PROJECTS_SECRET="FAKE_ROOT_PROJECTS_STAGE0D_${STAGE0D_RUN_ID}_$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FAKE_SIBLING_SECRET="FAKE_SIBLING_STAGE0D_${STAGE0D_RUN_ID}_$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FAKE_PARENT_SECRET="FAKE_PARENT_STAGE0D_${STAGE0D_RUN_ID}_$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"

echo "$FAKE_SSH_SECRET" > "$SENTINELS/fake-home/.ssh/id_rsa"
echo "$FAKE_AWS_SECRET" > "$SENTINELS/fake-home/.aws/credentials"
echo "$FAKE_CONFIG_SECRET" > "$SENTINELS/fake-home/.config/projects.json"
echo "$FAKE_RUNTIME_SECRET" > "$SENTINELS/fake-home/.local/share/local-mcp-dev-runner/runtime/projects.json"
echo "$FAKE_ROOT_PROJECTS_SECRET" > "$SENTINELS/fake-home/projects.json"
echo "$FAKE_SIBLING_SECRET" > "$SENTINELS/sibling-dir/sibling.txt"
echo "$FAKE_PARENT_SECRET" > "$SENTINELS/parent-denied/parent.txt"

# Host symlinks inside allowed
(cd "$ALLOWED" && ln -s ../sentinels/fake-home/.ssh/id_rsa rel-link)
ln -s "$SENTINELS/fake-home/.ssh/id_rsa" "$ALLOWED/abs-link"

# Guest symlinks & probe spec inside allowed/share
(cd "$ALLOWED/share" && ln -s ../../sentinels/fake-home/.ssh escape-link)
ln -s "$SENTINELS/fake-home/.ssh" "$ALLOWED/share/escape-link-abs"

cat <<PROBE_SPEC_EOF > "$ALLOWED/share/probe-spec.sh"
SECRET="$FAKE_SSH_SECRET"
DOTDOT="../../sentinels/fake-home/.ssh/id_rsa"
SYMLINK_REL="escape-link/id_rsa"
SYMLINK_ABS="escape-link-abs/id_rsa"
ABS_PATH="$SENTINELS/fake-home/.ssh/id_rsa"
PROBE_SPEC_EOF

# =================== 2. Compile & Stage Helper + Assets ===================
CURRENT_STAGE="HELPER_COPY"
if ! "$HERE/build.sh" >/dev/null 2>&1; then
  BLOCK_REASON="HELPER_SETUP_FAILED"
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

BUILD_HELPER="$HERE/.build/stage0d-vz-tool"
STAGED_HELPER="$ALLOWED/helper/stage0d-vz-tool"
cp -f "$BUILD_HELPER" "$STAGED_HELPER"
chmod 0755 "$STAGED_HELPER"

if [ -x "$STAGED_HELPER" ]; then
  HELPER_EXEC_LOCATION="ALLOWED/HELPER"
  HELPER_EXECUTABLE_GATE="PASS"
else
  HELPER_EXEC_LOCATION="MISSING"
  HELPER_EXECUTABLE_GATE="FAIL"
  BLOCK_REASON="HELPER_SETUP_FAILED"
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

CURRENT_STAGE="ASSETS_COPY"
if ! "$HERE/build-initramfs.sh" >/dev/null 2>&1; then
  BLOCK_REASON="ASSETS_SETUP_FAILED"
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

SRC_KERNEL="/tmp/lmdr-p35-stage0a-assets/vmlinuz-virt"
SRC_INITRD="$HERE/.build/initramfs-stage0d"

if [ ! -f "$SRC_KERNEL" ] || [ ! -f "$SRC_INITRD" ]; then
  BLOCK_REASON="ASSETS_SETUP_FAILED"
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

cp -f "$SRC_KERNEL" "$ALLOWED/assets/vmlinuz-virt"
cp -f "$SRC_INITRD" "$ALLOWED/assets/initramfs-stage0d"

# =================== 3. Local Ephemeral TCP Listener ===================
CURRENT_STAGE="LISTENER_START"
PORT_FILE="$CANONICAL_RUN_DIR/listener.port"

node -e '
import net from "node:net";
import fs from "node:fs";
const server = net.createServer((s) => s.on("data", () => {}));
server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(process.argv[1], String(server.address().port), "utf8");
});
' "$PORT_FILE" >/dev/null 2>&1 &
LISTENER_PID=$!

for _ in {1..50}; do
  if [ -s "$PORT_FILE" ]; then break; fi
  sleep 0.05
done

TCP_PORT="$(cat "$PORT_FILE" 2>/dev/null || echo "")"
if [ -z "$TCP_PORT" ]; then
  BLOCK_REASON="LISTENER_SETUP_FAILED"
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

if node -e '
import net from "node:net";
const s = net.connect('$TCP_PORT', "127.0.0.1", () => {
  s.end();
  process.exit(0);
});
s.on("error", () => process.exit(1));
' 2>/dev/null; then
  UNSANDBOXED_LOOPBACK_CONNECT="PASS"
else
  UNSANDBOXED_LOOPBACK_CONNECT="FAIL"
  BLOCK_REASON="LISTENER_SETUP_FAILED"
  STAGE0D_RESULT="INCONCLUSIVE"
  exit 2
fi

# =================== 4. Create Probes Manifest ===================
CURRENT_STAGE="PROBES_MANIFEST"
PROBES_FILE="$ALLOWED/probes.json"
cat <<MANIFEST_EOF > "$PROBES_FILE"
{
  "allowedRead": "$ALLOWED/can-read.txt",
  "allowedWriteTarget": "$ALLOWED/write-target/test-write.txt",
  "deniedSiblingRead": "$SENTINELS/sibling-dir/sibling.txt",
  "deniedParentRead": "$SENTINELS/parent-denied/parent.txt",
  "deniedHomeSsh": "$SENTINELS/fake-home/.ssh/id_rsa",
  "deniedHomeAws": "$SENTINELS/fake-home/.aws/credentials",
  "deniedHomeConfig": "$SENTINELS/fake-home/.config/projects.json",
  "deniedRuntimeSentinel": "$SENTINELS/fake-home/.local/share/local-mcp-dev-runner/runtime/projects.json",
  "deniedProjectsSentinel": "$SENTINELS/fake-home/projects.json",
  "deniedSymlinkEscapeRel": "$ALLOWED/rel-link",
  "deniedSymlinkEscapeAbs": "$ALLOWED/abs-link",
  "deniedAbsolutePath": "/etc/hosts",
  "deniedWriteSibling": "$SENTINELS/sibling-dir/test-write.txt",
  "deniedWriteParent": "$SENTINELS/parent-denied/test-write.txt",
  "deniedWriteHome": "$SENTINELS/fake-home/test-write.txt",
  "tcpPort": $TCP_PORT,
  "helperPath": "$STAGED_HELPER",
  "kernelPath": "$ALLOWED/assets/vmlinuz-virt",
  "initrdPath": "$ALLOWED/assets/initramfs-stage0d",
  "sharePath": "$ALLOWED/share",
  "virtiofsTag": "lmdr-stage0d"
}
MANIFEST_EOF

# =================== 5. Generate Profile ===================
CURRENT_STAGE="PROFILE_GENERATION"
PROFILE_PATH="$CANONICAL_RUN_DIR/profile.sb"

if "$HERE/generate-profile.mjs" --test-injection >/dev/null 2>&1; then
  PROFILE_INJECTION_GATE="PASS"
else
  PROFILE_INJECTION_GATE="FAIL"
fi

GEN_OUT=""
set +e
GEN_OUT="$("$HERE/generate-profile.mjs" \
  --allowed-dir "$ALLOWED" \
  --helper-bin "$STAGED_HELPER" \
  --run-id "$STAGE0D_RUN_ID" \
  --output "$PROFILE_PATH" 2>&1)"
PROFILE_GENERATION_RC=$?
set -e

if [ "$PROFILE_GENERATION_RC" -eq 0 ] && [ -f "$PROFILE_PATH" ]; then
  PROFILE_GENERATION="PASS"
  PROFILE_GENERATION_ERROR="NONE"
  PROFILE_INPUT_VALIDATION_GATE="PASS"
  SANDBOX_PROFILE_SHA256="$(shasum -a 256 "$PROFILE_PATH" 2>/dev/null | awk '{print $1}')"
else
  PROFILE_GENERATION="FAIL"
  PROFILE_GENERATION_ERROR="${GEN_OUT:-PROFILE_GEN_ERROR}"
  PROFILE_INPUT_VALIDATION_GATE="FAIL"
  SANDBOX_PROFILE_SHA256="NONE"
  BLOCK_REASON="PROFILE_GENERATION_FAILED"
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

# =================== 6. Startup Diagnostics Matrix ===================
CURRENT_STAGE="UNSANDBOXED_SMOKE"
UNSANDBOXED_SMOKE_LOG="$CANONICAL_RUN_DIR/unsandboxed-smoke.log"
set +e
"$STAGED_HELPER" --mode startup-smoke > "$UNSANDBOXED_SMOKE_LOG" 2>&1
UNSANDBOXED_STARTUP_RC=$?
set -e

if [ "$UNSANDBOXED_STARTUP_RC" -eq 0 ] && grep -q "STAGE0D_HELPER_MAIN_ENTERED=YES" "$UNSANDBOXED_SMOKE_LOG"; then
  UNSANDBOXED_STARTUP_SMOKE="PASS"
else
  UNSANDBOXED_STARTUP_SMOKE="FAIL"
  BLOCK_REASON="HELPER_STARTUP_FAILED_UNSANDBOXED"
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

CURRENT_STAGE="SANDBOXED_SMOKE"
SANDBOXED_SMOKE_LOG="$CANONICAL_RUN_DIR/sandboxed-smoke.log"
set +e
sandbox-exec -f "$PROFILE_PATH" \
  "$STAGED_HELPER" --mode startup-smoke > "$SANDBOXED_SMOKE_LOG" 2>&1
SANDBOXED_STARTUP_RC=$?
set -e

SANDBOXED_STARTUP_SIGNAL="$(compute_signal "$SANDBOXED_STARTUP_RC")"

if [ "$SANDBOXED_STARTUP_RC" -eq 0 ] && grep -q "STAGE0D_HELPER_MAIN_ENTERED=YES" "$SANDBOXED_SMOKE_LOG"; then
  SANDBOXED_STARTUP_SMOKE="PASS"
else
  SANDBOXED_STARTUP_SMOKE="FAIL"
  if grep -iE "deny|operation not permitted|sandbox" "$SANDBOXED_SMOKE_LOG" >/dev/null 2>&1; then
    SANDBOX_DENIAL_EVIDENCE="YES"
    DENIAL_OPERATION="sandbox-exec:startup-smoke"
    DENIAL_PATH_OR_SERVICE="system-service"
    BLOCK_REASON="PROFILE_TOO_NARROW"
  else
    SANDBOX_DENIAL_EVIDENCE="NO"
    BLOCK_REASON="HELPER_STARTUP_FAILED_SANDBOXED"
  fi
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

# =================== 7. Phase 1 Host Containment Control & Security Gate ===================
CURRENT_STAGE="UNSANDBOXED_PHASE1"
UNSANDBOXED_PHASE1_LOG="$CANONICAL_RUN_DIR/unsandboxed-phase1.log"
set +e
"$STAGED_HELPER" --mode phase1-control --manifest "$PROBES_FILE" > "$UNSANDBOXED_PHASE1_LOG" 2>&1
UNSANDBOXED_PHASE1_CONTROL_RC=$?
set -e
UNSANDBOXED_PHASE1_CONTROL_SIGNAL="$(compute_signal "$UNSANDBOXED_PHASE1_CONTROL_RC")"

if [ "$UNSANDBOXED_PHASE1_CONTROL_RC" -eq 0 ] && grep -q '"PHASE1_CONTROL_RESULT"' "$UNSANDBOXED_PHASE1_LOG"; then
  UNSANDBOXED_PHASE1_CONTROL="PASS"
else
  UNSANDBOXED_PHASE1_CONTROL="FAIL"
  BLOCK_REASON="HELPER_PHASE1_CONTROL_FAILED"
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

CURRENT_STAGE="SANDBOXED_PHASE1"
SANDBOXED_PHASE1_LOG="$CANONICAL_RUN_DIR/sandboxed-phase1.log"
set +e
sandbox-exec -f "$PROFILE_PATH" \
  "$STAGED_HELPER" --mode phase1-smoke --manifest "$PROBES_FILE" > "$SANDBOXED_PHASE1_LOG" 2>&1
SANDBOXED_PHASE1_RC=$?
set -e
SANDBOXED_PHASE1_SIGNAL="$(compute_signal "$SANDBOXED_PHASE1_RC")"

if [ "$SANDBOXED_PHASE1_SIGNAL" = "NONE" ]; then
  PHASE1_CRASH_EXCLUDED="YES"
else
  PHASE1_CRASH_EXCLUDED="NO"
fi

if [ "$SANDBOXED_PHASE1_RC" -eq 0 ] && grep -q '"HOST_CONTAINMENT_PRE_VM" : "PASS"' "$SANDBOXED_PHASE1_LOG"; then
  SANDBOXED_PHASE1_SECURITY_GATE="PASS"
else
  SANDBOXED_PHASE1_SECURITY_GATE="FAIL"
  if grep -iE "deny|operation not permitted|sandbox" "$SANDBOXED_PHASE1_LOG" >/dev/null 2>&1; then
    SANDBOX_DENIAL_EVIDENCE="YES"
    DENIAL_OPERATION="sandbox-exec:phase1-smoke"
    DENIAL_PATH_OR_SERVICE="filesystem-or-network"
    BLOCK_REASON="PROFILE_TOO_NARROW"
  else
    SANDBOX_DENIAL_EVIDENCE="NO"
    BLOCK_REASON="HELPER_PHASE1_SECURITY_GATE_FAILED"
  fi
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

# =================== 8. VZ Config Smoke Matrix ===================
CURRENT_STAGE="UNSANDBOXED_VZ_CONFIG"
UNSANDBOXED_VZ_LOG="$CANONICAL_RUN_DIR/unsandboxed-vz-config.log"
set +e
"$STAGED_HELPER" --mode vz-config-smoke --manifest "$PROBES_FILE" > "$UNSANDBOXED_VZ_LOG" 2>&1
UNSANDBOXED_VZ_CONFIG_RC=$?
set -e
UNSANDBOXED_VZ_CONFIG_SIGNAL="$(compute_signal "$UNSANDBOXED_VZ_CONFIG_RC")"

if [ "$UNSANDBOXED_VZ_CONFIG_RC" -eq 0 ] && grep -q "STAGE0D_VZ_CONFIG_SMOKE_RESULT=PASS" "$UNSANDBOXED_VZ_LOG"; then
  UNSANDBOXED_VZ_CONFIG_SMOKE="PASS"
else
  UNSANDBOXED_VZ_CONFIG_SMOKE="FAIL"
  BLOCK_REASON="HELPER_VZ_CONFIG_FAILED_UNSANDBOXED"
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

CURRENT_STAGE="SANDBOXED_VZ_CONFIG"
SANDBOXED_VZ_LOG="$CANONICAL_RUN_DIR/sandboxed-vz-config.log"
set +e
sandbox-exec -f "$PROFILE_PATH" \
  "$STAGED_HELPER" --mode vz-config-smoke --manifest "$PROBES_FILE" > "$SANDBOXED_VZ_LOG" 2>&1
SANDBOXED_VZ_CONFIG_RC=$?
set -e
SANDBOXED_VZ_CONFIG_SIGNAL="$(compute_signal "$SANDBOXED_VZ_CONFIG_RC")"

LAST_VZ_CONFIG_MARKER="$(grep -oE "VZ_[A-Z_]+" "$SANDBOXED_VZ_LOG" 2>/dev/null | tail -n 1 || echo "NONE")"

if [ "$SANDBOXED_VZ_CONFIG_RC" -eq 0 ] && grep -q "STAGE0D_VZ_CONFIG_SMOKE_RESULT=PASS" "$SANDBOXED_VZ_LOG"; then
  SANDBOXED_VZ_CONFIG_SMOKE="PASS"
else
  SANDBOXED_VZ_CONFIG_SMOKE="FAIL"
  if grep -iE "deny|operation not permitted|sandbox" "$SANDBOXED_VZ_LOG" >/dev/null 2>&1; then
    SANDBOX_DENIAL_EVIDENCE="YES"
    DENIAL_OPERATION="sandbox-exec:vz-config-smoke"
    DENIAL_PATH_OR_SERVICE="virtualization-config"
    BLOCK_REASON="PROFILE_TOO_NARROW"
  else
    SANDBOX_DENIAL_EVIDENCE="NO"
    BLOCK_REASON="HELPER_VZ_CONFIG_FAILED_SANDBOXED"
  fi
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

# =================== 9. VM Start Smoke Matrix ===================
CURRENT_STAGE="UNSANDBOXED_VM_START"
UNSANDBOXED_VM_START_LOG="$CANONICAL_RUN_DIR/unsandboxed-vm-start.log"
set +e
"$STAGED_HELPER" --mode vm-start-smoke --manifest "$PROBES_FILE" > "$UNSANDBOXED_VM_START_LOG" 2>&1
UNSANDBOXED_VM_START_RC=$?
set -e
UNSANDBOXED_VM_START_SIGNAL="$(compute_signal "$UNSANDBOXED_VM_START_RC")"

if [ "$UNSANDBOXED_VM_START_RC" -eq 0 ] && grep -q "STAGE0D_VM_START_SMOKE_RESULT=PASS" "$UNSANDBOXED_VM_START_LOG"; then
  UNSANDBOXED_VM_START_SMOKE="PASS"
else
  UNSANDBOXED_VM_START_SMOKE="FAIL"
  BLOCK_REASON="HELPER_VM_START_FAILED_UNSANDBOXED"
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

CURRENT_STAGE="SANDBOXED_VM_START"
SANDBOXED_VM_START_LOG="$CANONICAL_RUN_DIR/sandboxed-vm-start.log"
set +e
sandbox-exec -f "$PROFILE_PATH" \
  "$STAGED_HELPER" --mode vm-start-smoke --manifest "$PROBES_FILE" > "$SANDBOXED_VM_START_LOG" 2>&1
SANDBOXED_VM_START_RC=$?
set -e
SANDBOXED_VM_START_SIGNAL="$(compute_signal "$SANDBOXED_VM_START_RC")"

if [ "$SANDBOXED_VM_START_RC" -eq 0 ] && grep -q "STAGE0D_VM_START_SMOKE_RESULT=PASS" "$SANDBOXED_VM_START_LOG"; then
  SANDBOXED_VM_START_SMOKE="PASS"
else
  SANDBOXED_VM_START_SMOKE="FAIL"
  if grep -iE "deny|operation not permitted|sandbox" "$SANDBOXED_VM_START_LOG" >/dev/null 2>&1; then
    SANDBOX_DENIAL_EVIDENCE="YES"
    DENIAL_OPERATION="sandbox-exec:vm-start-smoke"
    DENIAL_PATH_OR_SERVICE="virtualization-runtime"
    BLOCK_REASON="PROFILE_TOO_NARROW"
  else
    SANDBOX_DENIAL_EVIDENCE="NO"
    if [ "$SANDBOXED_VM_START_SIGNAL" = "4" ]; then
      BLOCK_REASON="VM_START_SIGILL"
    else
      BLOCK_REASON="HELPER_VM_START_FAILED_SANDBOXED"
    fi
  fi
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

# =================== 10. Formal Test Mode Under sandbox-exec ===================
CURRENT_STAGE="SANDBOX_EXEC"
RUNNER_OUTPUT_FILE="$CANONICAL_RUN_DIR/.stage0d-runner.json"

set +e
sandbox-exec -f "$PROFILE_PATH" \
  "$STAGED_HELPER" --mode test --manifest "$PROBES_FILE" > "$RUNNER_OUTPUT_FILE" 2>&1
SANDBOXED_TEST_RC=$?
set -e

SANDBOXED_TEST_SIGNAL="$(compute_signal "$SANDBOXED_TEST_RC")"

CURRENT_STAGE="REPORT_PARSE"
OUTPUT_JSON="$(cat "$RUNNER_OUTPUT_FILE" 2>/dev/null || echo "")"

if [ -z "$OUTPUT_JSON" ] || ! echo "$OUTPUT_JSON" | grep -q "HOST_CONTAINMENT_PRE_VM"; then
  if grep -iE "deny|operation not permitted|sandbox" "$RUNNER_OUTPUT_FILE" >/dev/null 2>&1; then
    SANDBOX_DENIAL_EVIDENCE="YES"
    DENIAL_OPERATION="sandbox-exec:test-mode"
    DENIAL_PATH_OR_SERVICE="system-service"
    BLOCK_REASON="PROFILE_TOO_NARROW"
  else
    SANDBOX_DENIAL_EVIDENCE="NO"
    if [ "$SANDBOXED_TEST_SIGNAL" = "4" ]; then
      BLOCK_REASON="VM_START_SIGILL"
    elif [ "$SANDBOXED_TEST_SIGNAL" = "11" ]; then
      BLOCK_REASON="VM_START_SIGSEGV"
    else
      BLOCK_REASON="HELPER_TEST_MODE_FAILED"
    fi
  fi
  STAGE0D_RESULT="BLOCKED"
  exit 2
fi

HOST_CONTAINMENT_PRE_VM="$(get_json "$OUTPUT_JSON" HOST_CONTAINMENT_PRE_VM)"
VM_CONFIG_VALIDATE="$(get_json "$OUTPUT_JSON" VM_CONFIG_VALIDATE)"
VM_START="$(get_json "$OUTPUT_JSON" VM_START)"
VM_RUNNING="$(get_json "$OUTPUT_JSON" VM_RUNNING)"
VM_STOP="$(get_json "$OUTPUT_JSON" VM_STOP)"
VM_FINAL_STATE="$(get_json "$OUTPUT_JSON" VM_FINAL_STATE)"

VIRTIOFS_MOUNT="$(get_json "$OUTPUT_JSON" VIRTIOFS_MOUNT)"
GUEST_HOST_TO_GUEST_READ="$(get_json "$OUTPUT_JSON" GUEST_HOST_TO_GUEST_READ)"
GUEST_GUEST_TO_HOST_WRITE="$(get_json "$OUTPUT_JSON" GUEST_GUEST_TO_HOST_WRITE)"
GUEST_DOTDOT_ESCAPE="$(get_json "$OUTPUT_JSON" GUEST_DOTDOT_ESCAPE)"
GUEST_SYMLINK_ESCAPE_REL="$(get_json "$OUTPUT_JSON" GUEST_SYMLINK_ESCAPE_REL)"
GUEST_SYMLINK_ESCAPE_ABS="$(get_json "$OUTPUT_JSON" GUEST_SYMLINK_ESCAPE_ABS)"
GUEST_ABSOLUTE_PATH_ESCAPE="$(get_json "$OUTPUT_JSON" GUEST_ABSOLUTE_PATH_ESCAPE)"
GUEST_HOST_HOME_EXPOSED="$(get_json "$OUTPUT_JSON" GUEST_HOST_HOME_EXPOSED)"
GUEST_HAS_VIRTIO_NET="$(get_json "$OUTPUT_JSON" GUEST_HAS_VIRTIO_NET)"

VIRTIOFS_GUEST_ISOLATION="$(get_json "$OUTPUT_JSON" VIRTIOFS_GUEST_ISOLATION)"
VIRTUALIZATION_VM_LIFECYCLE="$(get_json "$OUTPUT_JSON" VIRTUALIZATION_VM_LIFECYCLE)"

HOST_CONTAINMENT_POST_VM="$(get_json "$OUTPUT_JSON" HOST_CONTAINMENT_POST_VM)"
HOST_CONTAINMENT_DELTA="$(get_json "$OUTPUT_JSON" HOST_CONTAINMENT_DELTA)"

HOST_NETWORK_GATE="$(get_json "$OUTPUT_JSON" PRE_VM_NETWORK_GATE)"
GUEST_NETWORK_GATE="PASS"
if [ "$GUEST_HAS_VIRTIO_NET" != "NO" ]; then GUEST_NETWORK_GATE="FAIL"; fi

SANDBOX_DENIAL_EVIDENCE="$(get_json "$OUTPUT_JSON" SANDBOX_DENIAL_EVIDENCE)"
FAILED_OPERATION="$(get_json "$OUTPUT_JSON" FAILED_OPERATION)"
FAILED_SERVICE_OR_PATH="$(get_json "$OUTPUT_JSON" FAILED_SERVICE_OR_PATH)"

STAGE0D_RESULT="$(get_json "$OUTPUT_JSON" STAGE0D_RESULT)"
BLOCK_REASON="$(get_json "$OUTPUT_JSON" BLOCK_REASON)"

if [ "$HOST_CONTAINMENT_PRE_VM" = "PASS" ] && [ "$HOST_CONTAINMENT_POST_VM" = "PASS" ] && [ "$HOST_CONTAINMENT_DELTA" = "PASS" ]; then
  SEATBELT_HELPER_CONTAINMENT="PASS"
else
  SEATBELT_HELPER_CONTAINMENT="FAIL"
fi

CURRENT_STAGE="CLEANUP"
exit 0
