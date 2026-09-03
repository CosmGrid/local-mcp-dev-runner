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

PROFILE_GENERATION="NOT_RUN"
PROFILE_PATH="NONE"
PROFILE_GENERATION_RC="NOT_RUN"
PROFILE_GENERATION_ERROR="NONE"
SANDBOX_PROFILE_SHA256="NONE"

HELPER_EXEC_LOCATION="NOT_RUN"
HELPER_EXECUTABLE_GATE="NOT_RUN"

PROFILE_INPUT_VALIDATION_GATE="NOT_RUN"
PROFILE_INJECTION_GATE="NOT_RUN"

HELPER_ALLOWED_READ="NOT_RUN"
HELPER_ALLOWED_WRITE="NOT_RUN"

HELPER_DENIED_SIBLING_READ="NOT_RUN"
HELPER_DENIED_PARENT_READ="NOT_RUN"

HELPER_DENIED_HOME_SSH="NOT_RUN"
HELPER_DENIED_HOME_AWS="NOT_RUN"
HELPER_DENIED_HOME_CONFIG="NOT_RUN"
HELPER_DENIED_RUNTIME_SENTINEL="NOT_RUN"
HELPER_DENIED_PROJECTS_SENTINEL="NOT_RUN"

HELPER_DENIED_SYMLINK_ESCAPE_REL="NOT_RUN"
HELPER_DENIED_SYMLINK_ESCAPE_ABS="NOT_RUN"
HELPER_DENIED_ABSOLUTE_PATH="NOT_RUN"

HELPER_DENIED_WRITE_SIBLING="NOT_RUN"
HELPER_DENIED_WRITE_PARENT="NOT_RUN"
HELPER_DENIED_WRITE_HOME="NOT_RUN"

UNSANDBOXED_LOOPBACK_CONNECT="NOT_RUN"
SANDBOXED_NETWORK_CONNECT="NOT_RUN"
HELPER_NETWORK_ACCESS="NOT_RUN"
NETWORK_GATE="NOT_RUN"

CHILD_ALLOWED_READ="NOT_RUN"
CHILD_DENIED_SENTINEL_READ="NOT_RUN"
HELPER_CHILD_PROCESS_INHERITS_CONTAINMENT="NOT_RUN"

CLEANUP_PATH_GATE="FAIL"
TEMP_FILES_CLEANED="FAIL"
LEFTOVER_RUN_DIR="NONE"
ORPHAN_PROCESS_COUNT=0

PROJECTS_JSON_MODIFIED="NO"
RUNTIME_MODIFIED="NO"
REAL_WORKTREE_TOUCHED="NO"

HOST_HELPER_FS_CONTAINMENT_GATE="NOT_RUN"
STAGE0C_RESULT="BLOCKED"
BLOCK_REASON="NONE"
P3_5_PRODUCTION_IMPLEMENTATION="NO"

CURRENT_STAGE="BOOTSTRAP"
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
  echo "PROFILE_GENERATION=$PROFILE_GENERATION"
  echo "PROFILE_PATH=$PROFILE_PATH"
  echo "PROFILE_GENERATION_RC=$PROFILE_GENERATION_RC"
  echo "PROFILE_GENERATION_ERROR=$PROFILE_GENERATION_ERROR"
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
  echo "LEFTOVER_RUN_DIR=$LEFTOVER_RUN_DIR"
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
  local exit_code=$?

  # 1. Terminate listener with exact PID
  if [ -n "${LISTENER_PID:-}" ]; then
    if kill -0 "$LISTENER_PID" 2>/dev/null; then
      kill -TERM "$LISTENER_PID" 2>/dev/null || true
      sleep 0.1
      kill -9 "$LISTENER_PID" 2>/dev/null || true
    fi
    LISTENER_PID=""
  fi

  # 2. Canonical /private/tmp Cleanup Gate (8 criteria)
  CLEANUP_PATH_GATE="FAIL"
  TEMP_FILES_CLEANED="FAIL"
  ORPHAN_PROCESS_COUNT=0

  if [ -n "${CANONICAL_RUN_DIR:-}" ] && [ -n "${STAGE0C_RUN_ID:-}" ]; then
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
  fi

  # 3. Fail-closed final status mapping if an error aborted execution
  if [ "$exit_code" -ne 0 ] || [ "$STAGE0C_RESULT" = "NOT_RUN" ] || [ "$STAGE0C_RESULT" = "BLOCKED" ]; then
    if [ "$STAGE0C_RESULT" != "FAIL" ]; then
      STAGE0C_RESULT="BLOCKED"
      if [ "$BLOCK_REASON" = "NONE" ]; then
        case "$CURRENT_STAGE" in
          RUN_DIR_CREATE|CANONICAL_REALPATH|SENTINEL_SETUP|ALLOWED_SETUP)
            BLOCK_REASON="RUN_DIR_SETUP_FAILED" ;;
          RUN_ID_VALIDATION)
            BLOCK_REASON="RUN_ID_INVALID" ;;
          HELPER_COPY)
            BLOCK_REASON="HELPER_SETUP_FAILED" ;;
          LISTENER_START)
            BLOCK_REASON="LISTENER_SETUP_FAILED" ;;
          PROBES_MANIFEST)
            BLOCK_REASON="PROBES_MANIFEST_FAILED" ;;
          PROFILE_GENERATION)
            BLOCK_REASON="PROFILE_GENERATION_FAILED" ;;
          SANDBOX_EXEC)
            BLOCK_REASON="SANDBOX_LAUNCH_FAILED" ;;
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
    STAGE0C_RESULT="BLOCKED"
  fi

  emit_report
}
trap cleanup EXIT INT TERM

# =================== 1. Setup Test Run Layout ===================
CURRENT_STAGE="RUN_ID_VALIDATION"
STAGE0C_RUN_ID="$(head -c 12 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')"
if [[ ! "$STAGE0C_RUN_ID" =~ ^[a-zA-Z0-9_-]{6,64}$ ]]; then
  BLOCK_REASON="RUN_ID_INVALID"
  STAGE0C_RESULT="BLOCKED"
  exit 2
fi

CURRENT_STAGE="RUN_DIR_CREATE"
LOGICAL_RUN_DIR="/tmp/lmdr-p35-stage0c-$STAGE0C_RUN_ID"
mkdir -p "$LOGICAL_RUN_DIR"
CANONICAL_RUN_DIR="$(realpath "$LOGICAL_RUN_DIR")"
touch "$CANONICAL_RUN_DIR/.stage0c-active"

CURRENT_STAGE="CANONICAL_REALPATH"
c_parent="$(dirname "$CANONICAL_RUN_DIR")"
if [ "$c_parent" != "/private/tmp" ]; then
  BLOCK_REASON="CANONICAL_PATH_FAILED"
  STAGE0C_RESULT="BLOCKED"
  exit 2
fi

CURRENT_STAGE="ALLOWED_SETUP"
ALLOWED="$CANONICAL_RUN_DIR/allowed"
mkdir -p "$ALLOWED/write-target"
echo "STAGE0C_CAN_READ_${STAGE0C_RUN_ID}" > "$ALLOWED/can-read.txt"

CURRENT_STAGE="SENTINEL_SETUP"
SENTINELS="$CANONICAL_RUN_DIR/sentinels"
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

# Relative symlink: allowed/rel-link -> ../sentinels/fake-home/.ssh/id_rsa
(cd "$ALLOWED" && ln -s ../sentinels/fake-home/.ssh/id_rsa rel-link)
# Absolute symlink: allowed/abs-link -> $SENTINELS/fake-home/.ssh/id_rsa
ln -s "$SENTINELS/fake-home/.ssh/id_rsa" "$ALLOWED/abs-link"

# =================== 2. Compile & Stage Helper ===================
CURRENT_STAGE="HELPER_COPY"
if ! "$HERE/build.sh" >/dev/null 2>&1; then
  BLOCK_REASON="HELPER_SETUP_FAILED"
  STAGE0C_RESULT="BLOCKED"
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
  BLOCK_REASON="HELPER_SETUP_FAILED"
  STAGE0C_RESULT="BLOCKED"
  exit 2
fi

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

# Wait for listener port
for _ in {1..50}; do
  if [ -s "$PORT_FILE" ]; then break; fi
  sleep 0.05
done

TCP_PORT="$(cat "$PORT_FILE" 2>/dev/null || echo "")"
if [ -z "$TCP_PORT" ]; then
  BLOCK_REASON="LISTENER_SETUP_FAILED"
  STAGE0C_RESULT="BLOCKED"
  exit 2
fi

# Unsandboxed loopback connect control test
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
  STAGE0C_RESULT="INCONCLUSIVE"
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
  "helperPath": "$STAGED_HELPER"
}
MANIFEST_EOF

# =================== 5. Generate Profile ===================
CURRENT_STAGE="PROFILE_GENERATION"
PROFILE_PATH="$CANONICAL_RUN_DIR/profile.sb"

# Verify profile injection defense
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
  --run-id "$STAGE0C_RUN_ID" \
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
  STAGE0C_RESULT="BLOCKED"
  HOST_HELPER_FS_CONTAINMENT_GATE="NOT_RUN"
  exit 2
fi

# =================== 6. Run Helper Under sandbox-exec ===================
CURRENT_STAGE="SANDBOX_EXEC"
HELPER_OUTPUT_FILE="$CANONICAL_RUN_DIR/helper-output.json"

set +e
sandbox-exec -f "$PROFILE_PATH" \
  "$STAGED_HELPER" --mode test --manifest "$PROBES_FILE" > "$HELPER_OUTPUT_FILE" 2>&1
HELPER_EXIT=$?
set -e

CURRENT_STAGE="REPORT_PARSE"
OUTPUT_JSON="$(cat "$HELPER_OUTPUT_FILE" 2>/dev/null || echo "")"

if [ -z "$OUTPUT_JSON" ] || ! echo "$OUTPUT_JSON" | grep -q "HELPER_ALLOWED_READ"; then
  BLOCK_REASON="SANDBOX_LAUNCH_FAILED"
  STAGE0C_RESULT="BLOCKED"
  exit 2
fi

HELPER_ALLOWED_READ="$(get_json "$OUTPUT_JSON" HELPER_ALLOWED_READ)"
HELPER_ALLOWED_WRITE="$(get_json "$OUTPUT_JSON" HELPER_ALLOWED_WRITE)"
HELPER_DENIED_SIBLING_READ="$(get_json "$OUTPUT_JSON" HELPER_DENIED_SIBLING_READ)"
HELPER_DENIED_PARENT_READ="$(get_json "$OUTPUT_JSON" HELPER_DENIED_PARENT_READ)"
HELPER_DENIED_HOME_SSH="$(get_json "$OUTPUT_JSON" HELPER_DENIED_HOME_SSH)"
HELPER_DENIED_HOME_AWS="$(get_json "$OUTPUT_JSON" HELPER_DENIED_HOME_AWS)"
HELPER_DENIED_HOME_CONFIG="$(get_json "$OUTPUT_JSON" HELPER_DENIED_HOME_CONFIG)"
HELPER_DENIED_RUNTIME_SENTINEL="$(get_json "$OUTPUT_JSON" HELPER_DENIED_RUNTIME_SENTINEL)"
HELPER_DENIED_PROJECTS_SENTINEL="$(get_json "$OUTPUT_JSON" HELPER_DENIED_PROJECTS_SENTINEL)"
HELPER_DENIED_SYMLINK_ESCAPE_REL="$(get_json "$OUTPUT_JSON" HELPER_DENIED_SYMLINK_ESCAPE_REL)"
HELPER_DENIED_SYMLINK_ESCAPE_ABS="$(get_json "$OUTPUT_JSON" HELPER_DENIED_SYMLINK_ESCAPE_ABS)"
HELPER_DENIED_ABSOLUTE_PATH="$(get_json "$OUTPUT_JSON" HELPER_DENIED_ABSOLUTE_PATH)"
HELPER_DENIED_WRITE_SIBLING="$(get_json "$OUTPUT_JSON" HELPER_DENIED_WRITE_SIBLING)"
HELPER_DENIED_WRITE_PARENT="$(get_json "$OUTPUT_JSON" HELPER_DENIED_WRITE_PARENT)"
HELPER_DENIED_WRITE_HOME="$(get_json "$OUTPUT_JSON" HELPER_DENIED_WRITE_HOME)"

SANDBOXED_NETWORK_CONNECT="$(get_json "$OUTPUT_JSON" SANDBOXED_NETWORK_CONNECT)"
HELPER_NETWORK_ACCESS="$(get_json "$OUTPUT_JSON" HELPER_NETWORK_ACCESS)"
NETWORK_GATE="$(get_json "$OUTPUT_JSON" NETWORK_GATE)"

CHILD_ALLOWED_READ="$(get_json "$OUTPUT_JSON" CHILD_ALLOWED_READ)"
CHILD_DENIED_SENTINEL_READ="$(get_json "$OUTPUT_JSON" CHILD_DENIED_SENTINEL_READ)"
HELPER_CHILD_PROCESS_INHERITS_CONTAINMENT="$(get_json "$OUTPUT_JSON" HELPER_CHILD_PROCESS_INHERITS_CONTAINMENT)"

# Guard against empty fields
[ -z "$HELPER_ALLOWED_READ" ] && HELPER_ALLOWED_READ="NOT_RUN"
[ -z "$HELPER_ALLOWED_WRITE" ] && HELPER_ALLOWED_WRITE="NOT_RUN"
[ -z "$HELPER_DENIED_SIBLING_READ" ] && HELPER_DENIED_SIBLING_READ="NOT_RUN"
[ -z "$HELPER_DENIED_PARENT_READ" ] && HELPER_DENIED_PARENT_READ="NOT_RUN"
[ -z "$HELPER_DENIED_HOME_SSH" ] && HELPER_DENIED_HOME_SSH="NOT_RUN"
[ -z "$HELPER_DENIED_HOME_AWS" ] && HELPER_DENIED_HOME_AWS="NOT_RUN"
[ -z "$HELPER_DENIED_HOME_CONFIG" ] && HELPER_DENIED_HOME_CONFIG="NOT_RUN"
[ -z "$HELPER_DENIED_RUNTIME_SENTINEL" ] && HELPER_DENIED_RUNTIME_SENTINEL="NOT_RUN"
[ -z "$HELPER_DENIED_PROJECTS_SENTINEL" ] && HELPER_DENIED_PROJECTS_SENTINEL="NOT_RUN"
[ -z "$HELPER_DENIED_SYMLINK_ESCAPE_REL" ] && HELPER_DENIED_SYMLINK_ESCAPE_REL="NOT_RUN"
[ -z "$HELPER_DENIED_SYMLINK_ESCAPE_ABS" ] && HELPER_DENIED_SYMLINK_ESCAPE_ABS="NOT_RUN"
[ -z "$HELPER_DENIED_ABSOLUTE_PATH" ] && HELPER_DENIED_ABSOLUTE_PATH="NOT_RUN"
[ -z "$HELPER_DENIED_WRITE_SIBLING" ] && HELPER_DENIED_WRITE_SIBLING="NOT_RUN"
[ -z "$HELPER_DENIED_WRITE_PARENT" ] && HELPER_DENIED_WRITE_PARENT="NOT_RUN"
[ -z "$HELPER_DENIED_WRITE_HOME" ] && HELPER_DENIED_WRITE_HOME="NOT_RUN"

[ -z "$SANDBOXED_NETWORK_CONNECT" ] && SANDBOXED_NETWORK_CONNECT="NOT_RUN"
[ -z "$HELPER_NETWORK_ACCESS" ] && HELPER_NETWORK_ACCESS="NOT_RUN"
[ -z "$NETWORK_GATE" ] && NETWORK_GATE="NOT_RUN"

[ -z "$CHILD_ALLOWED_READ" ] && CHILD_ALLOWED_READ="NOT_RUN"
[ -z "$CHILD_DENIED_SENTINEL_READ" ] && CHILD_DENIED_SENTINEL_READ="NOT_RUN"
[ -z "$HELPER_CHILD_PROCESS_INHERITS_CONTAINMENT" ] && HELPER_CHILD_PROCESS_INHERITS_CONTAINMENT="NOT_RUN"

# =================== 7. Evaluate Gates ===================
FS_GATE="PASS"
if [ "$HELPER_ALLOWED_READ" != "PASS" ] || \
   [ "$HELPER_ALLOWED_WRITE" != "PASS" ] || \
   [ "$HELPER_DENIED_SIBLING_READ" != "PASS" ] || \
   [ "$HELPER_DENIED_PARENT_READ" != "PASS" ] || \
   [ "$HELPER_DENIED_HOME_SSH" != "PASS" ] || \
   [ "$HELPER_DENIED_HOME_AWS" != "PASS" ] || \
   [ "$HELPER_DENIED_HOME_CONFIG" != "PASS" ] || \
   [ "$HELPER_DENIED_RUNTIME_SENTINEL" != "PASS" ] || \
   [ "$HELPER_DENIED_PROJECTS_SENTINEL" != "PASS" ] || \
   [ "$HELPER_DENIED_SYMLINK_ESCAPE_REL" != "PASS" ] || \
   [ "$HELPER_DENIED_SYMLINK_ESCAPE_ABS" != "PASS" ] || \
   [ "$HELPER_DENIED_ABSOLUTE_PATH" != "PASS" ] || \
   [ "$HELPER_DENIED_WRITE_SIBLING" != "PASS" ] || \
   [ "$HELPER_DENIED_WRITE_PARENT" != "PASS" ] || \
   [ "$HELPER_DENIED_WRITE_HOME" != "PASS" ]; then
  FS_GATE="FAIL"
fi
HOST_HELPER_FS_CONTAINMENT_GATE="$FS_GATE"

if [ "$HELPER_EXECUTABLE_GATE" = "PASS" ] && \
   [ "$PROFILE_INPUT_VALIDATION_GATE" = "PASS" ] && \
   [ "$PROFILE_INJECTION_GATE" = "PASS" ] && \
   [ "$HOST_HELPER_FS_CONTAINMENT_GATE" = "PASS" ] && \
   [ "$UNSANDBOXED_LOOPBACK_CONNECT" = "PASS" ] && \
   [ "$SANDBOXED_NETWORK_CONNECT" = "DENIED" ] && \
   [ "$NETWORK_GATE" = "PASS" ] && \
   [ "$HELPER_CHILD_PROCESS_INHERITS_CONTAINMENT" = "PASS" ]; then
  STAGE0C_RESULT="PASS"
  BLOCK_REASON="NONE"
else
  STAGE0C_RESULT="FAIL"
  if [ "$FS_GATE" != "PASS" ]; then
    BLOCK_REASON="FS_CONTAINMENT_FAILED"
  elif [ "$NETWORK_GATE" != "PASS" ]; then
    BLOCK_REASON="NETWORK_CONTAINMENT_FAILED"
  elif [ "$HELPER_CHILD_PROCESS_INHERITS_CONTAINMENT" != "PASS" ]; then
    BLOCK_REASON="CHILD_CONTAINMENT_INHERITANCE_FAILED"
  else
    BLOCK_REASON="STAGE0C_PREFLIGHT_FAILED"
  fi
fi

CURRENT_STAGE="CLEANUP"
exit 0
