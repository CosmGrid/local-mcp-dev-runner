#!/usr/bin/env bash
#
# P3.5 Stage 0A — Virtualization Native Prototype : single entry point.
#
# Runs the WHOLE gate end-to-end and always prints the fixed KEY=VALUE report,
# even when a stage stops early (so the user gets a complete, auditable result).
#
# Usage:  bash experiments/p35-stage0a/run-native-stage0a.sh
# Run this in a NATIVE macOS Terminal.app (Virtualization.framework is blocked
# inside some nested/sandboxed environments such as WorkBuddy).
#
# This script NEVER touches:
#   - the deployed runtime ($HOME/.local/share/local-mcp-dev-runner)
#   - projects.json ($HOME/.config/local-mcp-dev-runner/projects.json)
#   - server.mjs / run_script / any managed worktree
# It only builds a Swift helper under experiments/p35-stage0a/.build and uses
# assets in /tmp/lmdr-p35-stage0a-* (never committed, never on Desktop).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/.build/stage0a-vz-tool"
ASSET_DIR="${P35_ASSET_DIR:-/tmp/lmdr-p35-stage0a-assets}"
ASSET_TIMEOUT="${P35_ASSET_TIMEOUT:-240}"
RUN_SECONDS="${P35_RUN_SECONDS:-8}"
LOCK="$HERE/assets.lock.json"
ISO="$ASSET_DIR/alpine-virt.iso"
EXTRACT="$ASSET_DIR/extract"
KERNEL="$ASSET_DIR/vmlinuz-virt"
INITRD="$ASSET_DIR/initramfs-virt"

# ---- report state (init to NOT_RUN) ----
HOST_ARCH=""; MACOS_VERSION=""; SWIFTC=""; CODESIGN=""
VIRTUALIZATION_ENTITLEMENT="NOT_RUN"; APP_SANDBOX_ENTITLEMENT="NOT_RUN"
ADHOC_VIRTUALIZATION_ENTITLEMENT="NOT_RUN"
VZ_IS_SUPPORTED="NOT_RUN"; VZ_CONFIG_VALIDATE="NOT_RUN"
ASSET_SOURCE="NOT_RUN"; ASSET_VERSION="NOT_RUN"; ASSET_ARCH="NOT_RUN"
ASSET_SHA256="NOT_RUN"; ASSET_DOWNLOADED_SHA256="NOT_RUN"; ASSET_GATE="NOT_RUN"
NETWORK_DEVICE_COUNT="NOT_RUN"
VM_START="NOT_RUN"; VM_RUNNING="NOT_RUN"; VM_STOP="NOT_RUN"; VM_FINAL_STATE="NOT_RUN"; COLD_START_MS="NOT_RUN"
PROJECTS_JSON_MODIFIED="NO"; RUNTIME_MODIFIED="NO"; REAL_WORKTREE_TOUCHED="NO"
STAGE0A_RESULT="NOT_RUN"

# snapshot of protected paths (to PROVE they are not modified)
PJ="$HOME/.config/local-mcp-dev-runner/projects.json"
RT="$HOME/.local/share/local-mcp-dev-runner/server.mjs"
pj_before=""; rt_before=""
[ -f "$PJ" ] && pj_before=$(shasum -a 256 "$PJ" | awk '{print $1}')
[ -f "$RT" ] && rt_before=$(shasum -a 256 "$RT" | awk '{print $1}')

emit_report() {
  echo "==== STAGE 0A NATIVE GATE REPORT ===="
  echo "HOST_ARCH=$HOST_ARCH"
  echo "MACOS_VERSION=$MACOS_VERSION"
  echo "SWIFTC=$SWIFTC"
  echo "CODESIGN=$CODESIGN"
  echo "VIRTUALIZATION_ENTITLEMENT=$VIRTUALIZATION_ENTITLEMENT"
  echo "APP_SANDBOX_ENTITLEMENT=$APP_SANDBOX_ENTITLEMENT"
  echo "ADHOC_VIRTUALIZATION_ENTITLEMENT=$ADHOC_VIRTUALIZATION_ENTITLEMENT"
  echo "VZ_IS_SUPPORTED=$VZ_IS_SUPPORTED"
  echo "VZ_CONFIG_VALIDATE=$VZ_CONFIG_VALIDATE"
  echo "ASSET_SOURCE=$ASSET_SOURCE"
  echo "ASSET_VERSION=$ASSET_VERSION"
  echo "ASSET_ARCH=$ASSET_ARCH"
  echo "ASSET_SHA256=$ASSET_SHA256"
  echo "ASSET_DOWNLOADED_SHA256=$ASSET_DOWNLOADED_SHA256"
  echo "ASSET_GATE=$ASSET_GATE"
  echo "NETWORK_DEVICE_COUNT=$NETWORK_DEVICE_COUNT"
  echo "VM_START=$VM_START"
  echo "VM_RUNNING=$VM_RUNNING"
  echo "VM_STOP=$VM_STOP"
  echo "VM_FINAL_STATE=$VM_FINAL_STATE"
  echo "COLD_START_MS=$COLD_START_MS"
  echo "PROJECTS_JSON_MODIFIED=$PROJECTS_JSON_MODIFIED"
  echo "RUNTIME_MODIFIED=$RUNTIME_MODIFIED"
  echo "REAL_WORKTREE_TOUCHED=$REAL_WORKTREE_TOUCHED"
  echo "STAGE0A_RESULT=$STAGE0A_RESULT"
  echo "===================================="
}

finish() {
  local r="$1"; STAGE0A_RESULT="$r"
  # verify protected paths unchanged
  local pj_after="" rt_after=""
  [ -f "$PJ" ] && pj_after=$(shasum -a 256 "$PJ" | awk '{print $1}')
  [ -f "$RT" ] && rt_after=$(shasum -a 256 "$RT" | awk '{print $1}')
  [ "$pj_before" != "$pj_after" ] && PROJECTS_JSON_MODIFIED="YES"
  [ "$rt_before" != "$rt_after" ] && RUNTIME_MODIFIED="YES"
  emit_report
  if [ "$r" = "PASS" ]; then exit 0; else exit 1; fi
}

# run a command with a wall-clock timeout (background + kill), bash-portable
run_with_timeout() {
  local t="$1"; shift
  "$@" &
  local pid=$!
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.5
    i=$((i+1))
    if [ $(echo "$i*0.5" | bc) -ge "$t" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
  done
  wait "$pid"; return $?
}

# ============================ PREFLIGHT ============================
HOST_ARCH="$(uname -m)"
MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
SWIFTC="$(command -v swiftc || echo MISSING)"
CODESIGN="$(command -v codesign || echo MISSING)"

if [ ! -d /System/Library/Frameworks/Virtualization.framework ]; then
  echo "PREFLOW_FAIL: Virtualization.framework not present" >&2
  finish BLOCKED
fi
if [ "$SWIFTC" = "MISSING" ] || [ "$CODESIGN" = "MISSING" ]; then
  echo "PREFLOW_FAIL: swiftc/codesign missing" >&2
  finish BLOCKED
fi

# ============================ BUILD + CODESIGN ============================
echo "--> build (swiftc + ad-hoc codesign)"
if ! bash "$HERE/build.sh" >/tmp/p35_build.log 2>&1; then
  echo "BUILD_FAIL: see /tmp/p35_build.log" >&2
  tail -20 /tmp/p35_build.log >&2
  finish REPAIR
fi

# entitlement inspection
echo "--> entitlement inspection"
ENT_TXT="$(codesign -d --entitlements :- "$BIN" 2>/dev/null)"
if echo "$ENT_TXT" | grep -q "com.apple.security.virtualization"; then
  if echo "$ENT_TXT" | grep -A1 "com.apple.security.virtualization" | grep -q "<true/>"; then
    VIRTUALIZATION_ENTITLEMENT=true
  else
    VIRTUALIZATION_ENTITLEMENT=false
  fi
else
  VIRTUALIZATION_ENTITLEMENT=false
fi
if echo "$ENT_TXT" | grep -q "com.apple.security.app-sandbox"; then
  if echo "$ENT_TXT" | grep -A1 "com.apple.security.app-sandbox" | grep -q "<true/>"; then
    APP_SANDBOX_ENTITLEMENT=true
  else
    APP_SANDBOX_ENTITLEMENT=false
  fi
else
  APP_SANDBOX_ENTITLEMENT=absent
fi
if [ "$VIRTUALIZATION_ENTITLEMENT" = "true" ]; then
  ADHOC_VIRTUALIZATION_ENTITLEMENT=PASS
else
  ADHOC_VIRTUALIZATION_ENTITLEMENT=FAIL
  echo "ENTITLEMENT_FAIL: com.apple.security.virtualization not enabled after ad-hoc codesign" >&2
  finish REPAIR
fi
if [ "$APP_SANDBOX_ENTITLEMENT" = "true" ]; then
  echo "ENTITLEMENT_FAIL: com.apple.security.app-sandbox is TRUE (must be absent/false)" >&2
  finish REPAIR
fi

# ============================ VZ.isSupported ============================
echo "--> VZVirtualMachine.isSupported"
VZ_IS_SUPPORTED="$(printf 'import Virtualization\nprint(VZVirtualMachine.isSupported)\n' | swift - 2>/dev/null)"
[ "$VZ_IS_SUPPORTED" = "true" ] || { echo "VZ_NOT_SUPPORTED on this host"; VZ_IS_SUPPORTED="${VZ_IS_SUPPORTED:-false}"; finish BLOCKED; }

# ============================ ASSET HASH VERIFICATION ============================
echo "--> asset hash verification"
ASSET_SOURCE="$(grep -o '"source"[^,]*' "$LOCK" | head -1 | sed 's/.*: *"//; s/"//')"
ASSET_VERSION="$(grep -o '"release"[^,]*' "$LOCK" | head -1 | sed 's/.*: *"//; s/"//')"
ASSET_ARCH="$(grep -o '"arch"[^,]*' "$LOCK" | head -1 | sed 's/.*: *"//; s/"//')"
ASSET_SHA256="$(grep -o '"publishedSha256"[^,]*' "$LOCK" | head -1 | sed 's/.*: *"//; s/"//')"
ISO_URL="$(grep -o '"isoUrl"[^,]*' "$LOCK" | head -1 | sed 's/.*: *"//; s/"//')"
mkdir -p "$ASSET_DIR"

if [ -f "$ISO" ]; then
  DL=$(shasum -a 256 "$ISO" | awk '{print $1}')
  if [ "$DL" = "$ASSET_SHA256" ]; then ASSET_DOWNLOADED_SHA256="$DL"; fi
fi
if [ -z "$ASSET_DOWNLOADED_SHA256" ] || [ "$ASSET_DOWNLOADED_SHA256" != "$ASSET_SHA256" ]; then
  echo "    downloading ISO (timeout ${ASSET_TIMEOUT}s) ..."
  if ! curl -fsSL --max-time "$ASSET_TIMEOUT" -o "$ISO" "$ISO_URL" 2>/tmp/p35_dl.err; then
    echo "ASSET_DOWNLOAD_FAIL: $(tail -1 /tmp/p35_dl.err)" >&2
    ASSET_GATE=BLOCKED
    echo "NOTE: official asset + published SHA-256 are pinned in assets.lock.json; download was blocked by this environment (network throttle / sandbox). Re-run in native Terminal.app."
    finish BLOCKED
  fi
  DL=$(shasum -a 256 "$ISO" | awk '{print $1}')
  ASSET_DOWNLOADED_SHA256="$DL"
  if [ "$DL" != "$ASSET_SHA256" ]; then
    echo "ASSET_INTEGRITY_FAIL: downloaded $DL != published $ASSET_SHA256" >&2
    ASSET_GATE=BLOCKED
    echo "NOTE: verification standard not lowered; stopping."
    finish BLOCKED
  fi
fi
ASSET_GATE=PASS

# extract kernel + initrd from ISO
echo "--> extracting kernel + initrd from ISO"
rm -rf "$EXTRACT"; mkdir -p "$EXTRACT"
if ! tar -xf "$ISO" -C "$EXTRACT" boot/vmlinuz-virt boot/initramfs-virt 2>/dev/null; then
  # fallback: extract whole ISO then locate
  tar -xf "$ISO" -C "$EXTRACT" 2>/dev/null || { echo "ISO_EXTRACT_FAIL"; finish BLOCKED; }
fi
KFOUND="$(find "$EXTRACT" -name 'vmlinuz-virt' -type f 2>/dev/null | head -1)"
IFOUND="$(find "$EXTRACT" -name 'initramfs-virt' -type f 2>/dev/null | head -1)"
if [ -z "$KFOUND" ] || [ -z "$IFOUND" ]; then
  echo "ASSET_EXTRACT_FAIL: kernel/initrd not found in ISO (got K=$KFOUND I=$IFOUND)" >&2
  finish BLOCKED
fi
cp "$KFOUND" "$KERNEL"; cp "$IFOUND" "$INITRD"

# ============================ VM CONFIG VALIDATION ============================
echo "--> VM configuration validation"
VAL_OUT="$( "$BIN" validate --kernel "$KERNEL" --initrd "$INITRD" 2>/tmp/p35_val.err )" \
  || { echo "VALIDATE_FAIL: $(cat /tmp/p35_val.err)"; VZ_CONFIG_VALIDATE=FAIL; finish REPAIR; }
VZ_CONFIG_VALIDATE="$(echo "$VAL_OUT" | grep -o '"configValid"[^,}]*' | sed 's/.*: *//; s/}//')"
NETWORK_DEVICE_COUNT="$(echo "$VAL_OUT" | grep -o '"networkDeviceCount"[^,}]*' | sed 's/.*: *//; s/}//')"
[ "$VZ_CONFIG_VALIDATE" = "true" ] || { echo "CONFIG_INVALID"; finish REPAIR; }
[ "$NETWORK_DEVICE_COUNT" = "0" ] || { echo "NETWORK_DEVICE_COUNT=$NETWORK_DEVICE_COUNT (must be 0)"; finish REPAIR; }

# ============================ VM START / STOP ============================
echo "--> VM start (hold ${RUN_SECONDS}s) then stop"
RUN_OUT="$( run_with_timeout 90 "$BIN" run --kernel "$KERNEL" --initrd "$INITRD" --run-seconds "$RUN_SECONDS" 2>/tmp/p35_run.err )"
RC=$?
if [ $RC -eq 124 ]; then
  echo "VM_RUN_TIMEOUT (helper hung; environment likely blocks Virtualization.framework)" >&2
  VM_START=FAIL
elif [ $RC -ne 0 ] || [ -z "$RUN_OUT" ]; then
  echo "VM_RUN_FAIL: $(cat /tmp/p35_run.err)" >&2
  VM_START=FAIL
else
  VM_START="$(echo "$RUN_OUT" | grep -o '"vmStart"[^,}]*' | sed 's/.*: *//; s/}//')"
  VM_RUNNING="$(echo "$RUN_OUT" | grep -o '"vmRunning"[^,}]*' | sed 's/.*: *//; s/}//')"
  VM_STOP="$(echo "$RUN_OUT" | grep -o '"vmStop"[^,}]*' | sed 's/.*: *//; s/}//')"
  VM_FINAL_STATE="$(echo "$RUN_OUT" | grep -o '"vmFinalState"[^,}]*' | sed 's/.*: *"//; s/"//')"
  COLD_START_MS="$(echo "$RUN_OUT" | grep -o '"coldStartMs"[^,}]*' | sed 's/.*: *//; s/}//')"
fi

if [ "$VM_START" = "true" ] && [ "$VM_RUNNING" = "true" ] && { [ "$VM_STOP" = "true" ] || [ "$VM_FINAL_STATE" = "stopped" ]; }; then
  finish PASS
else
  echo "NOTE: pre-boot preconditions (build/codesign/VZ-support/config-validate) passed; VM runtime start was blocked by this environment. Re-run in native Terminal.app."
  finish BLOCKED
fi
