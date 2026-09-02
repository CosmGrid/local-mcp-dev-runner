#!/usr/bin/env bash
#
# Stage 0B VirtioFS Isolation Prototype — NATIVE GATE ENTRY POINT.
#
# Runs ONLY in a native macOS Terminal (it starts a real Virtualization.framework
# VM). WorkBuddy must NOT invoke the VM run — it only does build/syntax/static
# checks. The user runs this script locally to produce the final VM evidence.
#
# What it does (single script run, TEMP host tree only):
#   1. preflight: cpio/gzip present (else INITRAMFS_BUILD_GATE=BLOCKED, no install)
#   2. build the Stage 0B initramfs (keep /init, add /stage0b-init)
#   3. compile + codesign the Swift helper (virtualization entitlement only)
#   4. build a /tmp/lmdr-p35-stage0b-<random>/ host tree with random fake markers
#      and symlinks (escape-link -> ../denied-sentinel, escape-link-abs -> absolute)
#   5. validate the VM config (virtiofs tag lmdr-stage0b, networkDeviceCount=0)
#   6. run the VM with --share; guest mounts virtiofs + runs IO/escape/network/HOME
#      gates and writes results back through the share
#   7. compute IO / path-escape / security gates
#   8. cleanup TEMP tree via exact realpath-validated rm; track exact PID (no pkill -f)
#   9. emit the FIXED Stage 0B native report (all required keys)
#
# Safety: no projects.json/runtime edit, no real worktree, no MCP, no run_script,
# no npm/pnpm, no network config, no sudo, no SIP, no new Linux asset, no push.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# --- report state (defaults) ---
HOST_TEST_ROOT=TEMP_ONLY
INITRAMFS_ORIGINAL_INIT_PRESERVED=UNKNOWN
INITRAMFS_BUILD_GATE=UNKNOWN
VIRTIOFS_DEVICE=""
VIRTIOFS_TAG="lmdr-stage0b"
VIRTIOFS_SHARE_MODE=""
VIRTIOFS_GUEST_SUPPORT=UNKNOWN
VIRTIOFS_MOUNT=UNKNOWN
VM_QUEUE_POLICY=UNKNOWN
VM_START=UNKNOWN
VM_RUNNING=UNKNOWN
VIRTIOFS_HOST_TO_GUEST_READ=UNKNOWN
VIRTIOFS_GUEST_TO_HOST_WRITE=UNKNOWN
GATE_A_IO=UNKNOWN
DOTDOT_ESCAPE=UNKNOWN
SYMLINK_ESCAPE_REL=UNKNOWN
SYMLINK_ESCAPE_ABS=UNKNOWN
SYMLINK_ESCAPE=UNKNOWN
ABSOLUTE_PATH_ESCAPE=UNKNOWN
VIRTIOFS_PATH_ESCAPE_GATE=UNKNOWN
HOST_HOME_EXPOSED_TO_GUEST=UNKNOWN
NETWORK_DEVICE_COUNT=UNKNOWN
GUEST_HAS_VIRTIO_NET=UNKNOWN
GATE_B_SECURITY=UNKNOWN
STAGE0B_SECURITY_GATE=UNKNOWN
VM_STOP=UNKNOWN
VM_FINAL_STATE=UNKNOWN
TEMP_FILES_CLEANED=UNKNOWN
ORPHAN_PROCESS_COUNT=0
PROJECTS_JSON_MODIFIED=NO
RUNTIME_MODIFIED=NO
REAL_WORKTREE_TOUCHED=NO
STAGE0B_RESULT=UNKNOWN
BLOCK_REASON=""
P3_5_PRODUCTION_IMPLEMENTATION=NO

STAGE0B_ROOT=""
STAGE0B_PID=""

# --- helpers ---
rand() { head -c 12 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'; }

get_json() {
  # $1=json text, $2=key  -> prints value (unquoted; true/false/null/number/string)
  printf '%s' "$1" | grep -oE "\"$2\"[ ]*:[ ]*(\"[^\"]*\"|true|false|null|-?[0-9]+)" \
    | sed -E "s/^\"$2\"[ ]*:[ ]*//; s/^\"//; s/\"$//"
}
get_kv() {
  # $1=text, $2=key  -> prints value after first 'key='
  printf '%s' "$1" | grep -E "^$2=" | head -1 | sed -E "s/^$2=//"
}
sha256_file() {
  if [ -f "$1" ]; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; else echo "MISSING"; fi
}

emit_report() {
  echo "==== STAGE 0B NATIVE GATE REPORT ===="
  echo "HOST_TEST_ROOT=$HOST_TEST_ROOT"
  echo "INITRAMFS_ORIGINAL_INIT_PRESERVED=$INITRAMFS_ORIGINAL_INIT_PRESERVED"
  echo "INITRAMFS_BUILD_GATE=$INITRAMFS_BUILD_GATE"
  echo "VIRTIOFS_DEVICE=$VIRTIOFS_DEVICE"
  echo "VIRTIOFS_TAG=$VIRTIOFS_TAG"
  echo "VIRTIOFS_SHARE_MODE=$VIRTIOFS_SHARE_MODE"
  echo "VIRTIOFS_GUEST_SUPPORT=$VIRTIOFS_GUEST_SUPPORT"
  echo "VIRTIOFS_MOUNT=$VIRTIOFS_MOUNT"
  echo "VM_QUEUE_POLICY=$VM_QUEUE_POLICY"
  echo "VM_START=$VM_START"
  echo "VM_RUNNING=$VM_RUNNING"
  echo "VIRTIOFS_HOST_TO_GUEST_READ=$VIRTIOFS_HOST_TO_GUEST_READ"
  echo "VIRTIOFS_GUEST_TO_HOST_WRITE=$VIRTIOFS_GUEST_TO_HOST_WRITE"
  echo "GATE_A_IO=$GATE_A_IO"
  echo "DOTDOT_ESCAPE=$DOTDOT_ESCAPE"
  echo "SYMLINK_ESCAPE_REL=$SYMLINK_ESCAPE_REL"
  echo "SYMLINK_ESCAPE_ABS=$SYMLINK_ESCAPE_ABS"
  echo "SYMLINK_ESCAPE=$SYMLINK_ESCAPE"
  echo "ABSOLUTE_PATH_ESCAPE=$ABSOLUTE_PATH_ESCAPE"
  echo "VIRTIOFS_PATH_ESCAPE_GATE=$VIRTIOFS_PATH_ESCAPE_GATE"
  echo "HOST_HOME_EXPOSED_TO_GUEST=$HOST_HOME_EXPOSED_TO_GUEST"
  echo "NETWORK_DEVICE_COUNT=$NETWORK_DEVICE_COUNT"
  echo "GUEST_HAS_VIRTIO_NET=$GUEST_HAS_VIRTIO_NET"
  echo "GATE_B_SECURITY=$GATE_B_SECURITY"
  echo "STAGE0B_SECURITY_GATE=$STAGE0B_SECURITY_GATE"
  echo "VM_STOP=$VM_STOP"
  echo "VM_FINAL_STATE=$VM_FINAL_STATE"
  echo "TEMP_FILES_CLEANED=$TEMP_FILES_CLEANED"
  echo "ORPHAN_PROCESS_COUNT=$ORPHAN_PROCESS_COUNT"
  echo "PROJECTS_JSON_MODIFIED=$PROJECTS_JSON_MODIFIED"
  echo "RUNTIME_MODIFIED=$RUNTIME_MODIFIED"
  echo "REAL_WORKTREE_TOUCHED=$REAL_WORKTREE_TOUCHED"
  echo "STAGE0B_RESULT=$STAGE0B_RESULT"
  [ -n "$BLOCK_REASON" ] && echo "BLOCK_REASON=$BLOCK_REASON"
  echo "P3_5_PRODUCTION_IMPLEMENTATION=$P3_5_PRODUCTION_IMPLEMENTATION"
}

# Record baseline SHA for invariants (no content read/print).
PROJ_JSON="$REPO_ROOT/runtime/projects.json"
RT_JSON="$REPO_ROOT/runtime/runtime.json"
PROJ_SHA_BEFORE="$(sha256_file "$PROJ_JSON")"
RT_SHA_BEFORE="$(sha256_file "$RT_JSON")"

# =================== cleanup trap ===================
cleanup() {
  # exact-PID orphan guard (no pkill -f / killall / pgrep -f)
  if [ -n "${STAGE0B_PID:-}" ]; then
    if kill -0 "$STAGE0B_PID" 2>/dev/null; then
      kill -TERM "$STAGE0B_PID" 2>/dev/null || true
      ORPHAN_PROCESS_COUNT=1
    fi
  fi

  # TEMP tree cleanup: only on an exact, realpath-validated /tmp/lmdr-p35-stage0b-* path.
  if [ -n "${STAGE0B_ROOT:-}" ]; then
    local rp
    rp="$(realpath "$STAGE0B_ROOT" 2>/dev/null || echo "")"
    local ok=1
    [ -z "$rp" ] && ok=0
    case "$rp" in
      /tmp/lmdr-p35-stage0b-*) : ;;
      *) ok=0 ;;
    esac
    [ "$rp" = "/tmp" ] && ok=0
    case "$rp" in *".."*) ok=0 ;; esac
    if [ "$ok" = "1" ]; then
      rm -rf "$rp" && TEMP_FILES_CLEANED=PASS || TEMP_FILES_CLEANED=FAIL
    else
      TEMP_FILES_CLEANED=FAIL
      echo "REFUSED unsafe rm of: $STAGE0B_ROOT (realpath=$rp)" >&2
    fi
  fi

  # re-check invariants after run
  local proj_after="$(sha256_file "$PROJ_JSON")"
  local rt_after="$(sha256_file "$RT_JSON")"
  [ "$proj_after" != "$PROJ_SHA_BEFORE" ] && PROJECTS_JSON_MODIFIED=YES
  [ "$rt_after" != "$RT_SHA_BEFORE" ] && RUNTIME_MODIFIED=YES

  emit_report
}
trap cleanup EXIT

# =================== 1. preflight ===================
if ! command -v cpio >/dev/null 2>&1; then INITRAMFS_BUILD_GATE=BLOCKED; BLOCK_REASON=cpio_missing; STAGE0B_RESULT=BLOCKED; exit 2; fi
if ! command -v gzip >/dev/null 2>&1; then INITRAMFS_BUILD_GATE=BLOCKED; BLOCK_REASON=gzip_missing; STAGE0B_RESULT=BLOCKED; exit 2; fi

# =================== 2. temp host tree ===================
STAGE0B_ROOT="$(mktemp -d /tmp/lmdr-p35-stage0b-XXXXXX)"
mkdir -p "$STAGE0B_ROOT/allowed" "$STAGE0B_ROOT/denied-sentinel"

HOST_READ_MARKER="LMDR_STAGE0B_HOSTREAD_$(rand)"
printf '%s' "$HOST_READ_MARKER" > "$STAGE0B_ROOT/allowed/host-read.txt"

DENIED_NAME="LMDR_STAGE0B_DENIED_$(rand)"
DENIED_SECRET="LMDR_STAGE0B_DENIED_SECRET_$(rand)"
printf '%s' "$DENIED_SECRET" > "$STAGE0B_ROOT/denied-sentinel/$DENIED_NAME"

# relative symlink: allowed/escape-link -> ../denied-sentinel
ln -s ../denied-sentinel "$STAGE0B_ROOT/allowed/escape-link"
# absolute symlink: allowed/escape-link-abs -> <root>/denied-sentinel
ln -s "$STAGE0B_ROOT/denied-sentinel" "$STAGE0B_ROOT/allowed/escape-link-abs"

# probe spec (sourced by guest). Fake marker only.
cat > "$STAGE0B_ROOT/allowed/probe-spec.sh" <<EOF
SECRET="$DENIED_SECRET"
DOTDOT="../denied-sentinel/$DENIED_NAME"
SYMLINK_REL="escape-link/$DENIED_NAME"
SYMLINK_ABS="escape-link-abs/$DENIED_NAME"
ABS_PATH="$STAGE0B_ROOT/denied-sentinel/$DENIED_NAME"
EOF

# =================== 3. build initramfs ===================
BUILD_OUT="$("$HERE/build-initramfs.sh" --out "$HERE/.build/initramfs-stage0b" 2>&1)"
INITRAMFS_BUILD_GATE="$(get_kv "$BUILD_OUT" INITRAMFS_BUILD_GATE)"
INITRAMFS_ORIGINAL_INIT_PRESERVED="$(get_kv "$BUILD_OUT" INITRAMFS_ORIGINAL_INIT_PRESERVED)"
STAGE0B_INITRAMFS="$(get_kv "$BUILD_OUT" INITRAMFS_OUT)"
if [ "$INITRAMFS_BUILD_GATE" != "PASS" ] || [ -z "$STAGE0B_INITRAMFS" ]; then
  [ -z "$BLOCK_REASON" ] && BLOCK_REASON=initramfs_build_failed
  STAGE0B_RESULT=BLOCKED
  exit 2
fi

# =================== 4. build swift tool ===================
if ! BUILD_LINE="$("$HERE/build.sh" 2>&1)"; then
  STAGE0B_RESULT=FAIL; BLOCK_REASON=swift_build_failed; exit 2
fi
VZ_TOOL="$HERE/.build/stage0b-vz-tool"

# =================== 5. validate config ===================
KERNEL="${STAGE0A_KERNEL:-/tmp/lmdr-p35-stage0a-assets/vmlinuz-virt}"
CMD="console=hvc0 rdinit=/stage0b-init"
VAL_JSON="$("$VZ_TOOL" validate --kernel "$KERNEL" --initrd "$STAGE0B_INITRAMFS" --share "$STAGE0B_ROOT/allowed" --cmdline "$CMD" 2>&1)"
VIRTIOFS_DEVICE="$(get_json "$VAL_JSON" virtiofsDevice)"
VIRTIOFS_TAG="$(get_json "$VAL_JSON" virtiofsTag)"
VIRTIOFS_SHARE_MODE="$(get_json "$VAL_JSON" virtiofsShareMode)"
NETWORK_DEVICE_COUNT="$(get_json "$VAL_JSON" networkDeviceCount)"
VAL_OK="$(get_json "$VAL_JSON" ok)"

if [ "$VAL_OK" != "true" ] || [ "$VIRTIOFS_TAG" != "lmdr-stage0b" ] || [ "$NETWORK_DEVICE_COUNT" != "0" ]; then
  STAGE0B_RESULT=FAIL; BLOCK_REASON=config_validate_failed
  echo "VALIDATE_JSON=$VAL_JSON" >&2
  exit 2
fi

# =================== 6. run VM ===================
# Launch in the background so we capture the EXACT PID (task book: track exact
# Stage 0B PID, never pkill -f / killall / pgrep -f). The orphan guard in the
# cleanup trap uses this PID.
RUN_OUT_FILE="$STAGE0B_ROOT/.run.json"
"$VZ_TOOL" run --kernel "$KERNEL" --initrd "$STAGE0B_INITRAMFS" --share "$STAGE0B_ROOT/allowed" --cmdline "$CMD" --run-seconds 25 > "$RUN_OUT_FILE" 2>&1 &
STAGE0B_PID=$!
wait "$STAGE0B_PID"
RUN_JSON="$(cat "$RUN_OUT_FILE" 2>/dev/null || echo "")"
VM_QUEUE_POLICY="$(get_json "$RUN_JSON" vmQueuePolicy)"
VM_START="$(get_json "$RUN_JSON" vmStart)"
VM_RUNNING="$(get_json "$RUN_JSON" vmRunning)"
VM_STOP="$(get_json "$RUN_JSON" vmStop)"
VM_FINAL_STATE="$(get_json "$RUN_JSON" vmFinalState)"

if [ "$VM_START" != "true" ] || [ "$VM_RUNNING" != "true" ] || [ "$VM_STOP" != "true" ]; then
  STAGE0B_RESULT=FAIL; BLOCK_REASON=vm_lifecycle_failed
  echo "RUN_JSON=$RUN_JSON" >&2
  exit 2
fi

# =================== 7. collect guest results ===================
GUEST_RESULTS="$(cat "$STAGE0B_ROOT/allowed/guest-results.txt" 2>/dev/null || echo "")"
GUEST_WRITE_FILE="$(cat "$STAGE0B_ROOT/allowed/guest-write.txt" 2>/dev/null || echo "")"

VIRTIOFS_GUEST_SUPPORT="$(get_kv "$GUEST_RESULTS" VIRTIOFS_GUEST_SUPPORT)"
VIRTIOFS_MOUNT="$(get_kv "$GUEST_RESULTS" VIRTIOFS_MOUNT)"
GUEST_READ_HOST_MARKER="$(get_kv "$GUEST_RESULTS" GUEST_READ_HOST_MARKER)"
GUEST_WRITE_MARKER="$(get_kv "$GUEST_RESULTS" GUEST_WRITE_MARKER)"
DOTDOT_ESCAPE="$(get_kv "$GUEST_RESULTS" DOTDOT_ESCAPE)"
SYMLINK_ESCAPE_REL="$(get_kv "$GUEST_RESULTS" SYMLINK_ESCAPE_REL)"
SYMLINK_ESCAPE_ABS="$(get_kv "$GUEST_RESULTS" SYMLINK_ESCAPE_ABS)"
ABSOLUTE_PATH_ESCAPE="$(get_kv "$GUEST_RESULTS" ABSOLUTE_PATH_ESCAPE)"
HOST_HOME_EXPOSED_TO_GUEST="$(get_kv "$GUEST_RESULTS" HOST_HOME_EXPOSED_TO_GUEST)"
GUEST_HAS_VIRTIO_NET="$(get_kv "$GUEST_RESULTS" GUEST_HAS_VIRTIO_NET)"

# If the guest could not mount virtiofs, the gate is BLOCKED (kernel lacks support).
if [ "$VIRTIOFS_MOUNT" != "PASS" ]; then
  STAGE0B_RESULT=BLOCKED; BLOCK_REASON=VIRTIOFS_GUEST_UNSUPPORTED
  exit 2
fi

# --- IO gate ---
if [ "$GUEST_READ_HOST_MARKER" = "$HOST_READ_MARKER" ]; then
  VIRTIOFS_HOST_TO_GUEST_READ=PASS
else
  VIRTIOFS_HOST_TO_GUEST_READ=FAIL
fi
if [ -n "$GUEST_WRITE_MARKER" ] && [ "$GUEST_WRITE_FILE" = "$GUEST_WRITE_MARKER" ]; then
  VIRTIOFS_GUEST_TO_HOST_WRITE=PASS
else
  VIRTIOFS_GUEST_TO_HOST_WRITE=FAIL
fi
if [ "$VIRTIOFS_HOST_TO_GUEST_READ" = "PASS" ] && [ "$VIRTIOFS_GUEST_TO_HOST_WRITE" = "PASS" ]; then
  GATE_A_IO=PASS
else
  GATE_A_IO=FAIL
fi

# --- symlink escape combine (explicit, no &&/|| one-liner) ---
if [ "$SYMLINK_ESCAPE_REL" = "PASS" ] && [ "$SYMLINK_ESCAPE_ABS" = "PASS" ]; then
  SYMLINK_ESCAPE=PASS
elif [ "$SYMLINK_ESCAPE_REL" = "FAIL" ] || [ "$SYMLINK_ESCAPE_ABS" = "FAIL" ]; then
  SYMLINK_ESCAPE=FAIL
else
  SYMLINK_ESCAPE=INCONCLUSIVE
fi

# --- path-escape gate (explicit) ---
if [ "$DOTDOT_ESCAPE" = "PASS" ] && [ "$SYMLINK_ESCAPE" = "PASS" ] && [ "$ABSOLUTE_PATH_ESCAPE" = "PASS" ]; then
  VIRTIOFS_PATH_ESCAPE_GATE=PASS
elif [ "$DOTDOT_ESCAPE" = "FAIL" ] || [ "$SYMLINK_ESCAPE" = "FAIL" ] || [ "$ABSOLUTE_PATH_ESCAPE" = "FAIL" ]; then
  VIRTIOFS_PATH_ESCAPE_GATE=FAIL
else
  VIRTIOFS_PATH_ESCAPE_GATE=INCONCLUSIVE
fi

# --- security gate B (explicit; never counts UNKNOWN/INCONCLUSIVE as PASS) ---
SEC_FAIL=0
SEC_INCONCLUSIVE=0
[ "$DOTDOT_ESCAPE" = "FAIL" ] && SEC_FAIL=1
[ "$SYMLINK_ESCAPE" = "FAIL" ] && SEC_FAIL=1
[ "$ABSOLUTE_PATH_ESCAPE" = "FAIL" ] && SEC_FAIL=1
[ "$HOST_HOME_EXPOSED_TO_GUEST" = "YES" ] && SEC_FAIL=1
[ "$NETWORK_DEVICE_COUNT" != "0" ] && SEC_FAIL=1
[ "$GUEST_HAS_VIRTIO_NET" = "YES" ] && SEC_FAIL=1
[ "$ORPHAN_PROCESS_COUNT" != "0" ] && SEC_FAIL=1

[ "$DOTDOT_ESCAPE" = "INCONCLUSIVE" ] && SEC_INCONCLUSIVE=1
[ "$SYMLINK_ESCAPE" = "INCONCLUSIVE" ] && SEC_INCONCLUSIVE=1
[ "$ABSOLUTE_PATH_ESCAPE" = "INCONCLUSIVE" ] && SEC_INCONCLUSIVE=1
[ "$HOST_HOME_EXPOSED_TO_GUEST" = "UNKNOWN" ] && SEC_INCONCLUSIVE=1
[ "$GUEST_HAS_VIRTIO_NET" = "UNKNOWN" ] && SEC_INCONCLUSIVE=1

if [ "$SEC_FAIL" = "1" ]; then
  GATE_B_SECURITY=FAIL
  STAGE0B_SECURITY_GATE=FAIL
elif [ "$SEC_INCONCLUSIVE" = "1" ]; then
  GATE_B_SECURITY=INCONCLUSIVE
  STAGE0B_SECURITY_GATE=INCONCLUSIVE
else
  GATE_B_SECURITY=PASS
  STAGE0B_SECURITY_GATE=PASS
fi

# =================== 8. final result ===================
if [ "$GATE_B_SECURITY" = "PASS" ] && [ "$GATE_A_IO" = "PASS" ] && [ "$VM_QUEUE_POLICY" = "PASS" ]; then
  STAGE0B_RESULT=PASS
elif [ "$GATE_B_SECURITY" = "FAIL" ] || [ "$GATE_A_IO" = "FAIL" ] || [ "$VM_QUEUE_POLICY" = "FAIL" ]; then
  STAGE0B_RESULT=FAIL
else
  STAGE0B_RESULT=INCONCLUSIVE
fi

# cleanup trap emits the report on EXIT.
exit 0
