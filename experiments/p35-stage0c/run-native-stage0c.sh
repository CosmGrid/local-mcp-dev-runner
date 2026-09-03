#!/usr/bin/env bash
#
# P3.5 Stage 0C — Host Helper Filesystem Containment Native Gate Runner
#
# Verifies OS-enforced filesystem containment via macOS Seatbelt (sandbox-exec):
# 1. Helper is copied to and executed strictly from the per-run ALLOWED directory.
# 2. Probes manifest is placed inside ALLOWED.
# 3. Denies sibling, parent, fake-home, symlink escape, absolute path (/etc/hosts).
# 4. Denies denied writes.
# 5. Loopback network gate: active unsandboxed control vs sandboxed denied.
# 6. Child process inherits containment.
# 7. Canonical /private/tmp cleanup gate.
#
# This script does NOT touch production runtime, projects.json, or any managed worktree.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Report variables with fail-closed defaults ---
STAGE0C_RUN_ID=""
SANDBOX_BACKEND="sandbox-exec"
SANDBOX_PROFILE_SHA256="NONE"

HELPER_EXEC_LOCATION="UNKNOWN"
HELPER_EXECUTABLE_GATE="UNKNOWN"

PROFILE_INPUT_VALIDATION_GATE="UNKNOWN"
PROFILE_INJECTION_GATE="UNKNOWN"

HELPER_ALLOWED_READ="UNKNOWN"
HELPER_ALLOWED_WRITE="UNKNOWN"

HELPER_DENIED_SIBLING_READ="UNKNOWN"
HELPER_DENIED_PARENT_READ="UNKNOWN"

HELPER_DENIED_HOME_SSH="UNKNOWN"
HELPER_DENIED_HOME_AWS="UNKNOWN"
HELPER_DENIED_HOME_CONFIG="UNKNOWN"
HELPER_DENIED_RUNTIME_SENTINEL="UNKNOWN"
HELPER_DENIED_PROJECTS_SENTINEL="UNKNOWN"

HELPER_DENIED_SYMLINK_ESCAPE_REL="UNKNOWN"
HELPER_DENIED_SYMLINK_ESCAPE_ABS="UNKNOWN"
HELPER_DENIED_ABSOLUTE_PATH="UNKNOWN"

HELPER_DENIED_WRITE_SIBLING="UNKNOWN"
HELPER_DENIED_WRITE_PARENT="UNKNOWN"
HELPER_DENIED_WRITE_HOME="UNKNOWN"

UNSANDBOXED_LOOPBACK_CONNECT="UNKNOWN"
SANDBOXED_NETWORK_CONNECT="UNKNOWN"
HELPER_NETWORK_ACCESS="UNKNOWN"
NETWORK_GATE="UNKNOWN"

CHILD_ALLOWED_READ="UNKNOWN"
CHILD_DENIED_SENTINEL_READ="UNKNOWN"
HELPER_CHILD_PROCESS_INHERITS_CONTAINMENT="UNKNOWN"

CLEANUP_PATH_GATE="UNKNOWN"
TEMP_FILES_CLEANED="UNKNOWN"
ORPHAN_PROCESS_COUNT=0

PROJECTS_JSON_MODIFIED="NO"
RUNTIME_MODIFIED="NO"
REAL_WORKTREE_TOUCHED="NO"

HOST_HELPER_FS_CONTAINMENT_GATE="UNKNOWN"
STAGE0C_RESULT="UNKNOWN"
BLOCK_REASON="NONE"
P3_5_PRODUCTION_IMPLEMENTATION="NO"

LOGICAL_RUN_DIR=""
CANONICAL_RUN_DIR=""
LISTENER_PID=""
HELPER_PID=""

# --- helpers ---
get_json() {
  # $1=json text, $2=key
  printf '%s' "$1" | grep -oE "\"$2\"[ ]*:[ ]*(\"[^\"]*\"|true|false|null|-?[0-9]+)" \
    | sed -E "s/^\"$2\"[ ]*:[ ]*//; s/^\"//; s/\"$//"
}

emit_report() {
  [ -z "$BLOCK_REASON" ] && BLOCK_REASON="NONE"
  [ -z "$STAGE0C_RUN_ID" ] && STAGE0C_RUN_ID="UNKNOWN"

  echo "==== STAGE 0C NATIVE GATE REPORT ===="
  echo "STAGE0C_RUN_ID=$STAGE0C_RUN_ID"
  echo "SANDBOX_BACKEND=$SANDBOX_BACKEND"
  echo "SANDBOX_PROFILE_SHA256=$SANDBOX_PROFILE_SHA256"
  echo "HELPER_EXEC_LOCATION=$HELPER_EXEC_LOCATION"
  echo "HELPER_EXECUTABLE_GATE=$HELPER_EXECUTABLE_GATE"
  echo "PROFILE_INPUT_VALIDATION_GATE=$PROFILE_INPUT_VALIDATION_GATE"
  echo "PROFILE_INJECTION_GATE=$PROFILE_INJECTION_GATE"
  echo "HELPER_ALLOWED_READ=$HELPER_ALLOWED_READ"
  echo "HELPER_ALLOWED_WRITE=$HELPER_ALLOWED_WRITE"
  echo "HELPER_DENIED_SIBLING_READ=$HELPER_DENIED_SIBLING_READ"
  echo "HELPER_DENIED_PARENT_READ=$HELPER_DENIED_PARENT_READ"
  echo "HELPER_DENIED_HOME_SSH=$HELPER_DENIED_HOME_SSH"
  echo "HELPER_DENIED_HOME_AWS=$HELPER_DENIED_HOME_AWS"
  echo "HELPER_DENIED_HOME_CONFIG=$HELPER_DENIED_HOME_CONFIG"
  echo "HELPER_DENIED_RUNTIME_SENTINEL=$HELPER_DENIED_RUNTIME_SENTINEL"
  echo "HELPER_DENIED_PROJECTS_SENTINEL=$HELPER_DENIED_PROJECTS_SENTINEL"
  echo "HELPER_DENIED_SYMLINK_ESCAPE_REL=$HELPER_DENIED_SYMLINK_ESCAPE_REL"
  echo "HELPER_DENIED_SYMLINK_ESCAPE_ABS=$HELPER_DENIED_SYMLINK_ESCAPE_ABS"
  echo "HELPER_DENIED_ABSOLUTE_PATH=$HELPER_DENIED_ABSOLUTE_PATH"
  echo "HELPER_DENIED_WRITE_SIBLING=$HELPER_DENIED_WRITE_SIBLING"
  echo "HELPER_DENIED_WRITE_PARENT=$HELPER_DENIED_WRITE_PARENT"
  echo "HELPER_DENIED_WRITE_HOME=$HELPER_DENIED_WRITE_HOME"
  echo "UNSANDBOXED_LOOPBACK_CONNECT=$UNSANDBOXED_LOOPBACK_CONNECT"
  echo "SANDBOXED_NETWORK_CONNECT=$SANDBOXED_NETWORK_CONNECT"
  echo "HELPER_NETWORK_ACCESS=$HELPER_NETWORK_ACCESS"
  echo "NETWORK_GATE=$NETWORK_GATE"
  echo "CHILD_ALLOWED_READ=$CHILD_ALLOWED_READ"
  echo "CHILD_DENIED_SENTINEL_READ=$CHILD_DENIED_SENTINEL_READ"
  echo "HELPER_CHILD_PROCESS_INHERITS_CONTAINMENT=$HELPER_CHILD_PROCESS_INHERITS_CONTAINMENT"
  echo "CLEANUP_PATH_GATE=$CLEANUP_PATH_GATE"
  echo "TEMP_FILES_CLEANED=$TEMP_FILES_CLEANED"
  echo "ORPHAN_PROCESS_COUNT=$ORPHAN_PROCESS_COUNT"
  echo "PROJECTS_JSON_MODIFIED=$PROJECTS_JSON_MODIFIED"
  echo "RUNTIME_MODIFIED=$RUNTIME_MODIFIED"
  echo "REAL_WORKTREE_TOUCHED=$REAL_WORKTREE_TOUCHED"
  echo "HOST_HELPER_FS_CONTAINMENT_GATE=$HOST_HELPER_FS_CONTAINMENT_GATE"
  echo "STAGE0C_RESULT=$STAGE0C_RESULT"
  echo "BLOCK_REASON=$BLOCK_REASON"
  echo "P3_5_PRODUCTION_IMPLEMENTATION=$P3_5_PRODUCTION_IMPLEMENTATION"
}

cleanup() {
  # 1. Terminate listener with exact PID
  if [ -n "${LISTENER_PID:-}" ]; then
    if kill -0 "$LISTENER_PID" 2>/dev/null; then
      kill -TERM "$LISTENER_PID" 2>/dev/null || true
      sleep 0.1
      kill -9 "$LISTENER_PID" 2>/dev/null || true
    fi
    LISTENER_PID=""
  fi

  # 2. Canonical /private/tmp Cleanup Gate
  CLEANUP_PATH_GATE="FAIL"
  TEMP_FILES_CLEANED="FAIL"
  ORPHAN_PROCESS_COUNT=0

  if [ -n "${CANONICAL_RUN_DIR:-}" ] && [ -n "${STAGE0C_RUN_ID:-}" ]; then
    local l_base="$(basename "$LOGICAL_RUN_DIR" 2>/dev/null || echo "")"
    local c_base="$(basename "$CANONICAL_RUN_DIR" 2>/dev/null || echo "")"
    local c_parent="$(dirname "$CANONICAL_RUN_DIR" 2>/dev/null || echo "")"
    local c_verify="$(realpath "$CANONICAL_RUN_DIR" 2>/dev/null || echo "")"

    local c1=0 c2=0 c3=0 c4=0 c5=0 c6=0 c7=0 c8=0
    [ -n "$STAGE0C_RUN_ID" ] && c1=1
    case "$l_base" in "lmdr-p35-stage0c-"*) c2=1;; esac
    [ "$c_parent" = "/private/tmp" ] && c3=1
    [ "$c_base" = "lmdr-p35-stage0c-$STAGE0C_RUN_ID" ] && c4=1
    [ "$CANONICAL_RUN_DIR" != "/tmp" ] && [ "$CANONICAL_RUN_DIR" != "/private/tmp" ] && c5=1
    case "$CANONICAL_RUN_DIR" in *".."*) c6=0;; *) c6=1;; esac
    [ "$c_verify" = "$CANONICAL_RUN_DIR" ] && c7=1
    [ -f "$CANONICAL_RUN_DIR/allowed/probes.json" ] || [ -f "$CANONICAL_RUN_DIR/profile.sb" ] && c8=1

    if [ "$c1" -eq 1 ] && [ "$c2" -eq 1 ] && [ "$c3" -eq 1 ] && [ "$c4" -eq 1 ] && \
       [ "$c5" -eq 1 ] && [ "$c6" -eq 1 ] && [ "$c7" -eq 1 ] && [ "$c8" -eq 1 ]; then
      CLEANUP_PATH_GATE="PASS"
      rm -rf -- "$CANONICAL_RUN_DIR" 2>/dev/null || true
      if [ ! -e "$CANONICAL_RUN_DIR" ]; then
        TEMP_FILES_CLEANED="PASS"
      fi
    fi
  fi

  emit_report
}
trap cleanup EXIT INT TERM

# =================== 1. Setup Test Run Layout ===================
STAGE0C_RUN_ID="$(head -c 12 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')"
LOGICAL_RUN_DIR="/tmp/lmdr-p35-stage0c-$STAGE0C_RUN_ID"
mkdir -p "$LOGICAL_RUN_DIR"
CANONICAL_RUN_DIR="$(realpath "$LOGICAL_RUN_DIR")"

ALLOWED="$CANONICAL_RUN_DIR/allowed"
SENTINELS="$CANONICAL_RUN_DIR/sentinels"
mkdir -p "$ALLOWED/write-target"
mkdir -p "$SENTINELS/fake-home/.ssh"
mkdir -p "$SENTINELS/fake-home/.aws"
mkdir -p "$SENTINELS/fake-home/.config"
mkdir -p "$SENTINELS/fake-home/.local/share/local-mcp-dev-runner/runtime"
mkdir -p "$SENTINELS/sibling-dir"
mkdir -p "$SENTINELS/parent-denied"

# Populate FAKE sentinel files
FAKE_SSH_SECRET="FAKE_SSH_STAGE0C_${STAGE0C_RUN_ID}_$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FAKE_AWS_SECRET="FAKE_AWS_STAGE0C_${STAGE0C_RUN_ID}_$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FAKE_CONFIG_SECRET="FAKE_CONFIG_STAGE0C_${STAGE0C_RUN_ID}_$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FAKE_RUNTIME_SECRET="FAKE_RUNTIME_STAGE0C_${STAGE0C_RUN_ID}_$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FAKE_ROOT_PROJECTS_SECRET="FAKE_ROOT_PROJECTS_STAGE0C_${STAGE0C_RUN_ID}_$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FAKE_SIBLING_SECRET="FAKE_SIBLING_STAGE0C_${STAGE0C_RUN_ID}_$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
FAKE_PARENT_SECRET="FAKE_PARENT_STAGE0C_${STAGE0C_RUN_ID}_$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"

echo "$FAKE_SSH_SECRET" > "$SENTINELS/fake-home/.ssh/id_rsa"
echo "$FAKE_AWS_SECRET" > "$SENTINELS/fake-home/.aws/credentials"
echo "$FAKE_CONFIG_SECRET" > "$SENTINELS/fake-home/.config/projects.json"
echo "$FAKE_RUNTIME_SECRET" > "$SENTINELS/fake-home/.local/share/local-mcp-dev-runner/runtime/projects.json"
echo "$FAKE_ROOT_PROJECTS_SECRET" > "$SENTINELS/fake-home/projects.json"
echo "$FAKE_SIBLING_SECRET" > "$SENTINELS/sibling-dir/sibling.txt"
echo "$FAKE_PARENT_SECRET" > "$SENTINELS/parent-denied/parent.txt"

# Populate ALLOWED files
echo "STAGE0C_CAN_READ_${STAGE0C_RUN_ID}" > "$ALLOWED/can-read.txt"

# Relative symlink: allowed/rel-link -> ../sentinels/fake-home/.ssh/id_rsa
(cd "$ALLOWED" && ln -s ../sentinels/fake-home/.ssh/id_rsa rel-link)
# Absolute symlink: allowed/abs-link -> $SENTINELS/fake-home/.ssh/id_rsa
ln -s "$SENTINELS/fake-home/.ssh/id_rsa" "$ALLOWED/abs-link"

# =================== 2. Compile & Stage Helper ===================
if ! "$HERE/build.sh" >/dev/null 2>&1; then
  BLOCK_REASON="HELPER_BUILD_FAILED"
  STAGE0C_RESULT="FAIL"
  exit 2
fi

BUILD_HELPER="$HERE/.build/p35-stage0c-helper"
STAGED_HELPER="$ALLOWED/p35-stage0c-helper"
cp -f "$BUILD_HELPER" "$STAGED_HELPER"
chmod 0755 "$STAGED_HELPER"

if [ -x "$STAGED_HELPER" ]; then
  HELPER_EXEC_LOCATION="ALLOWED"
  HELPER_EXECUTABLE_GATE="PASS"
else
  HELPER_EXEC_LOCATION="MISSING"
  HELPER_EXECUTABLE_GATE="FAIL"
  BLOCK_REASON="HELPER_STAGING_FAILED"
  STAGE0C_RESULT="FAIL"
  exit 2
fi

# =================== 3. Local Ephemeral TCP Listener ===================
LISTENER_LOG="$CANONICAL_RUN_DIR/listener.log"
PORT_FILE="$CANONICAL_RUN_DIR/listener.port"

node - <<EOF >/dev/null 2>&1 &
import net from 'node:net';
import fs from 'node:fs';

const server = net.createServer((socket) => {
  socket.on('data', () => {});
});

server.listen(0, '127.0.0.1', () => {
  const p = server.address().port;
  fs.writeFileSync('$PORT_FILE', String(p), 'utf8');
});
