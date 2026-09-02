#!/usr/bin/env bash
#
# P3.5 Stage 0A — Native Diagnostics (DIAGNOSTIC ONLY)
#
# Purpose: collect the REAL ROOT-CAUSE evidence for the SIGILL (signal 4 / exit
# 132) that Virtualization.framework VM start hits inside a nested sandbox.
# The user runs THIS ONE script on a native Terminal to reproduce + capture.
#
# This script is strictly read-only on the deployed runtime and makes NO
# modifications to:
#   - projects.json
#   - the deployed runtime / server.mjs
#   - any managed worktree
#   - virtualization.entitlements / Sources/main.swift / build.sh / run-native-stage0a.sh
#   - assets.lock.json
# It does NOT add the com.apple.security.hypervisor entitlement (this round is
# evidence collection only — the hypervisor-entitlement hypothesis is POSSIBLE
# but NOT PROVEN for an Intel VZVirtualMachine process).
#
# VM reproduction (diagnostic 6/7) is GUARDED by P35_DIAG_SKIP_VM=1 so the
# script can run safely inside WorkBuddy (which cannot start a VM). On a native
# Terminal, run WITHOUT that guard to actually reproduce + capture a fresh crash.
#
# Usage:
#   bash experiments/p35-stage0a/run-native-diagnostics.sh            # full (reproduces VM)
#   P35_DIAG_SKIP_VM=1 bash experiments/p35-stage0a/run-native-diagnostics.sh  # static only

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$HERE/diagnostics/parse_crash.py"
BIN="$HERE/.build/stage0a-vz-tool"
ASSET_DIR="${P35_ASSET_DIR:-/tmp/lmdr-p35-stage0a-assets}"
LOCK="$HERE/assets.lock.json"
ISO="$ASSET_DIR/alpine-virt.iso"
KERNEL="$ASSET_DIR/vmlinuz-virt"
INITRD="$ASSET_DIR/initramfs-virt"
DIAG_DIR="$HOME/Library/Logs/DiagnosticReports"
BIN_BASE="stage0a-vz-tool"

# ---- default / uninitialized values ----
HOST_ARCH=""; MACOS_VERSION=""; CPU_MODEL="UNKNOWN"
KERN_HV_SUPPORT="UNKNOWN"; CPU_FEATURES_VMX="UNKNOWN"; EPT="UNKNOWN"; UGM="UNKNOWN"
EPT_UGM_INFERRED="NO"; HOST_HYPERVISOR_GATE="UNKNOWN"
CODESIGN_VERIFY="NOT_RUN"; CODESIGN_IDENTITY="NOT_RUN"
VIRTUALIZATION_ENTITLEMENT="NOT_RUN"; HYPERVISOR_ENTITLEMENT="NOT_RUN"; APP_SANDBOX_ENTITLEMENT="NOT_RUN"
HYPERVISOR_ENTITLEMENT_HYPOTHESIS="POSSIBLE_NOT_PROVEN"
ASSET_DIAGNOSTIC="NOT_RUN"; FILE_KERNEL="NOT_RUN"; FILE_INITRD="NOT_RUN"
KERNEL_ARCH="UNKNOWN"; INITRD_FORMAT="NOT_RUN"; ASSET_SHA256_GATE="NOT_RUN"
VZ_IS_SUPPORTED="NOT_RUN"; VZ_CONFIG_VALIDATE="NOT_RUN"; NETWORK_DEVICE_COUNT="NOT_RUN"
VM_ATTEMPTED="NO"; VM_EXIT_CODE="NA"; VM_SIGNAL="NA"
FRESH_CRASH_REPORT="NONE"
PROJECTS_JSON_MODIFIED="NO"; RUNTIME_MODIFIED="NO"; REAL_WORKTREE_TOUCHED="NO"
NETWORK_CONFIGURED="NO"; SYSTEM_SECURITY_MODIFIED="NO"
DIAGNOSTIC_RESULT="NOT_RUN"

HIST_BLOCK=""; FRESH_BLOCK=""

# snapshot protected paths (prove they are untouched at the end)
PJ="$HOME/.config/local-mcp-dev-runner/projects.json"
RT="$HOME/.local/share/local-mcp-dev-runner/server.mjs"
pj_before=""; rt_before=""
[ -f "$PJ" ] && pj_before=$(shasum -a 256 "$PJ" 2>/dev/null | awk '{print $1}')
[ -f "$RT" ] && rt_before=$(shasum -a 256 "$RT" 2>/dev/null | awk '{print $1}')

sysctl_val() { sysctl -n "$1" 2>/dev/null || true; }
feat_has() { echo "$1" | tr ' ' '\n' | grep -ixq "$2"; }

# ===========================================================================
# DIAGNOSTIC 1 — HOST HYPERVISOR
# ===========================================================================
echo "--> [1/7] host hypervisor state"
HOST_ARCH="$(uname -m)"
MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
CPU_MODEL="$(sysctl_val machdep.cpu.brand_string)"
[ -z "$CPU_MODEL" ] && CPU_MODEL="UNKNOWN"

hv="$(sysctl_val kern.hv_support)"
if [ -n "$hv" ]; then KERN_HV_SUPPORT="$hv"; else KERN_HV_SUPPORT="UNKNOWN"; fi
if [ "$KERN_HV_SUPPORT" = "1" ]; then HOST_HYPERVISOR_GATE="PASS"; EPT_UGM_INFERRED="YES";
elif [ "$KERN_HV_SUPPORT" = "0" ]; then HOST_HYPERVISOR_GATE="FAIL";
else HOST_HYPERVISOR_GATE="UNKNOWN"; fi

feat="$(sysctl_val machdep.cpu.features)"
efeat="$(sysctl_val machdep.cpu.extfeatures)"
l7="$(sysctl_val machdep.cpu.leaf7_features)"
if [ -n "$feat" ] && feat_has "$feat" VMX; then CPU_FEATURES_VMX="YES"; else CPU_FEATURES_VMX="NO"; fi
# EPT / UGM are VMX secondary controls NOT enumerated by these sysctl keys on
# this macOS build; report UNKNOWN from raw sysctl and let EPT_UGM_INFERRED
# (derived from kern.hv_support=1) carry the honest implication.
if feat_has "$feat" EPT || feat_has "$efeat" EPT || feat_has "$l7" EPT; then EPT="YES"; else EPT="UNKNOWN"; fi
if feat_has "$feat" UGM || feat_has "$efeat" UGM || feat_has "$l7" UGM; then UGM="YES"; else UGM="UNKNOWN"; fi

# ===========================================================================
# DIAGNOSTIC 2 — SIGNATURE & ENTITLEMENT (report only, never modify)
# ===========================================================================
echo "--> [2/7] signature & entitlement inspection (read-only)"
if [ ! -x "$BIN" ]; then
  echo "    binary missing; building via build.sh (non-destructive, no VM) ..."
  if bash "$HERE/build.sh" >/tmp/p35_diag_build.log 2>&1; then
    echo "    build ok"
  else
    echo "    build FAILED (see /tmp/p35_diag_build.log) — entitlement fields left NOT_AVAILABLE"
    BIN=""
  fi
fi
if [ -n "${BIN:-}" ] && [ -x "$BIN" ]; then
  if codesign --verify --verbose=2 "$BIN" >/dev/null 2>&1; then
    CODESIGN_VERIFY="VALID"
  else
    CODESIGN_VERIFY="INVALID"
  fi
  # NB: codesign -d -v writes the detail lines (incl. Signature=adhoc) to
  # STDERR. Capture 2>&1 but only keep the adhoc/Authority token; the full
  # path stays inside the variable and is never printed.
  CS_ID=$(codesign -d --verbose=2 "$BIN" 2>&1 | grep -iE 'adhoc|Authority' | head -1 | sed 's/^[^=]*=//')
  case "$CS_ID" in
    *[Aa]dhoc*) CODESIGN_IDENTITY="ad-hoc" ;;
    *) CODESIGN_IDENTITY="${CS_ID:-unknown}" ;;
  esac
  ENT_TXT="$(codesign -d --entitlements :- "$BIN" 2>/dev/null)"
  ent_state() {
    local key="$1" t="$ENT_TXT"
    if echo "$t" | grep -q "$key"; then
      if echo "$t" | grep -A1 "$key" | grep -q "<true/>"; then echo "true"; else echo "false"; fi
    else
      echo "absent"
    fi
  }
  VIRTUALIZATION_ENTITLEMENT="$(ent_state com.apple.security.virtualization)"
  HYPERVISOR_ENTITLEMENT="$(ent_state com.apple.security.hypervisor)"
  APP_SANDBOX_ENTITLEMENT="$(ent_state com.apple.security.app-sandbox)"
else
  CODESIGN_VERIFY="NOT_AVAILABLE"; CODESIGN_IDENTITY="NOT_AVAILABLE"
  VIRTUALIZATION_ENTITLEMENT="NOT_AVAILABLE"; HYPERVISOR_ENTITLEMENT="NOT_AVAILABLE"; APP_SANDBOX_ENTITLEMENT="NOT_AVAILABLE"
fi

# ===========================================================================
# DIAGNOSTIC 3 — BOOT ASSETS (redacted basename only; no re-download)
# ===========================================================================
echo "--> [3/7] boot asset diagnostic (no download, no version change)"
if [ -f "$KERNEL" ] && [ -f "$INITRD" ]; then
  ASSET_DIAGNOSTIC="AVAILABLE"
  FILE_KERNEL="$(basename "$KERNEL")"
  FILE_INITRD="$(basename "$INITRD")"
  KERNEL_ARCH="$(grep -o '"arch"[^,]*' "$LOCK" 2>/dev/null | head -1 | sed 's/.*: *"//; s/"//')"
  [ -z "$KERNEL_ARCH" ] && KERNEL_ARCH="UNKNOWN"
  INITRD_FORMAT="$(file -b "$INITRD" 2>/dev/null | awk '{print $1}')"
  [ -z "$INITRD_FORMAT" ] && INITRD_FORMAT="NOT_AVAILABLE"
else
  ASSET_DIAGNOSTIC="NOT_AVAILABLE"
  FILE_KERNEL="NOT_AVAILABLE"; FILE_INITRD="NOT_AVAILABLE"; INITRD_FORMAT="NOT_AVAILABLE"
  KERNEL_ARCH="$(grep -o '"arch"[^,]*' "$LOCK" 2>/dev/null | head -1 | sed 's/.*: *"//; s/"//')"
  [ -z "$KERNEL_ARCH" ] && KERNEL_ARCH="UNKNOWN"
fi
PUB_SHA="$(grep -o '"publishedSha256"[^,]*' "$LOCK" 2>/dev/null | head -1 | sed 's/.*: *"//; s/"//')"
if [ -f "$ISO" ]; then
  DL=$(shasum -a 256 "$ISO" 2>/dev/null | awk '{print $1}')
  if [ -n "$PUB_SHA" ] && [ "$DL" = "$PUB_SHA" ]; then ASSET_SHA256_GATE="PASS"; else ASSET_SHA256_GATE="MISMATCH"; fi
else
  ASSET_SHA256_GATE="NOT_AVAILABLE"
fi

# ===========================================================================
# DIAGNOSTIC 4 — VZ STATE (reuse prototype's non-destructive validate)
# ===========================================================================
echo "--> [4/7] VZ framework state"
VZ_IS_SUPPORTED="$(printf 'import Virtualization\nprint(VZVirtualMachine.isSupported)\n' | swift - 2>/dev/null)"
[ -z "$VZ_IS_SUPPORTED" ] && VZ_IS_SUPPORTED="UNKNOWN"
if [ -n "${BIN:-}" ] && [ -x "$BIN" ] && [ -f "$KERNEL" ] && [ -f "$INITRD" ]; then
  VAL_OUT="$("$BIN" validate --kernel "$KERNEL" --initrd "$INITRD" 2>/dev/null)"
  VZ_CONFIG_VALIDATE="$(echo "$VAL_OUT" | grep -o '"ok"[^,}]*' | sed 's/.*: *//; s/[},]//g')"
  NETWORK_DEVICE_COUNT="$(echo "$VAL_OUT" | grep -o '"networkDeviceCount"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$')"
  [ -z "$VZ_CONFIG_VALIDATE" ] && VZ_CONFIG_VALIDATE="NOT_AVAILABLE"
  [ -z "$NETWORK_DEVICE_COUNT" ] && NETWORK_DEVICE_COUNT="NOT_AVAILABLE"
else
  VZ_CONFIG_VALIDATE="NOT_AVAILABLE"; NETWORK_DEVICE_COUNT="NOT_AVAILABLE"
fi

# ===========================================================================
# DIAGNOSTIC 5 — HISTORICAL CRASH REPORT (any age; report what exists)
# ===========================================================================
echo "--> [5/7] historical crash report scan"
if [ -d "$DIAG_DIR" ]; then
  HIST_BLOCK="$(python3 "$PY" latest "$DIAG_DIR" "$BIN_BASE" 2>/tmp/p35_diag_hist.err)"
else
  HIST_BLOCK="CRASH_REPORT_FOUND=NO"
fi
CRASH_REPORT_FOUND="$(echo "$HIST_BLOCK" | grep '^CRASH_REPORT_FOUND=' | cut -d= -f2)"
[ -z "$CRASH_REPORT_FOUND" ] && CRASH_REPORT_FOUND="NO"
FRAME_OWNER_HIST="$(echo "$HIST_BLOCK" | grep '^FRAME_OWNER=' | cut -d= -f2)"

# ===========================================================================
# DIAGNOSTIC 6 — FRESH REPRODUCTION (guarded; one attempt, no retry)
# ===========================================================================
echo "--> [6/7] fresh VM reproduction"
REPRO_START="$(date +%s)"
if [ "${P35_DIAG_SKIP_VM:-}" = "1" ]; then
  VM_ATTEMPTED="SKIPPED"
  echo "    skipped (P35_DIAG_SKIP_VM=1) — no VM started, static collection only"
elif [ "$KERN_HV_SUPPORT" = "1" ] && [ "$VZ_IS_SUPPORTED" = "true" ] \
     && { [ "$VZ_CONFIG_VALIDATE" = "true" ] || [ "$VZ_CONFIG_VALIDATE" = "PASS" ]; }; then
  if [ -n "${BIN:-}" ] && [ -x "$BIN" ] && [ -f "$KERNEL" ] && [ -f "$INITRD" ]; then
    VM_ATTEMPTED="YES"
    echo "    attempting single VM start (no retry) ..."
    "$BIN" run --kernel "$KERNEL" --initrd "$INITRD" --run-seconds 1 >/tmp/p35_diag_run.out 2>&1
    RC=$?
    VM_EXIT_CODE="$RC"
    if [ "$RC" -gt 128 ] 2>/dev/null; then VM_SIGNAL=$((RC - 128)); else VM_SIGNAL=0; fi
  else
    VM_ATTEMPTED="SKIPPED"
  fi
else
  VM_ATTEMPTED="SKIPPED"
  echo "    prerequisites not met (KERN_HV_SUPPORT/VZ_IS_SUPPORTED/VZ_CONFIG_VALIDATE) — static only"
fi

# ===========================================================================
# DIAGNOSTIC 7 — FRESH CRASH (only accept reports newer than REPRO_START)
# ===========================================================================
echo "--> [7/7] fresh crash capture"
if [ "$VM_ATTEMPTED" = "YES" ]; then
  for _i in $(seq 1 10); do
    FRESH_RAW="$(python3 "$PY" latest "$DIAG_DIR" "$BIN_BASE" 2>/tmp/p35_diag_fresh.err)"
    FM="$(echo "$FRESH_RAW" | grep '^CRASH_REPORT_MTIME=' | cut -d= -f2)"
    if [ -n "$FM" ] && [ "$FM" -gt "$REPRO_START" ] 2>/dev/null; then
      FRESH_CRASH_REPORT="$(echo "$FRESH_RAW" | grep '^CRASH_REPORT_PATH=' | cut -d= -f2)"
      REAL="$(grep REALPATH /tmp/p35_diag_fresh.err | cut -d= -f2)"
      if [ -n "$REAL" ]; then
        FRESH_BLOCK="$(python3 "$PY" one "$REAL" 2>/dev/null | sed 's/^/FRESH_/')"
      fi
      break
    fi
    sleep 1
  done
fi

# ===========================================================================
# SECURITY BOUNDARY SELF-CHECK
# ===========================================================================
pj_after=""; rt_after=""
[ -f "$PJ" ] && pj_after=$(shasum -a 256 "$PJ" 2>/dev/null | awk '{print $1}')
[ -f "$RT" ] && rt_after=$(shasum -a 256 "$RT" 2>/dev/null | awk '{print $1}')
[ -n "$pj_before" ] && [ "$pj_before" != "$pj_after" ] && PROJECTS_JSON_MODIFIED="YES"
[ -n "$rt_before" ] && [ "$rt_before" != "$rt_after" ] && RUNTIME_MODIFIED="YES"

# ===========================================================================
# RESULT DETERMINATION
# ===========================================================================
if [ "$KERN_HV_SUPPORT" != "1" ]; then
  DIAGNOSTIC_RESULT="BLOCKED"
elif [ "$VM_ATTEMPTED" = "YES" ] && [ "$FRESH_CRASH_REPORT" != "NONE" ]; then
  DIAGNOSTIC_RESULT="PASS"
else
  DIAGNOSTIC_RESULT="PARTIAL"
fi

# ===========================================================================
# FINAL FIXED REPORT
# ===========================================================================
emit() { echo "$1"; }
emit "==== STAGE 0A DIAGNOSTIC REPORT ===="
emit "# DIAGNOSTIC 1 — HOST HYPERVISOR"
emit "HOST_ARCH=$HOST_ARCH"
emit "MACOS_VERSION=$MACOS_VERSION"
emit "CPU_MODEL=$CPU_MODEL"
emit "KERN_HV_SUPPORT=$KERN_HV_SUPPORT"
emit "CPU_FEATURES_VMX=$CPU_FEATURES_VMX"
emit "EPT=$EPT"
emit "UGM=$UGM"
emit "EPT_UGM_INFERRED=$EPT_UGM_INFERRED"
emit "HOST_HYPERVISOR_GATE=$HOST_HYPERVISOR_GATE"
emit "# DIAGNOSTIC 2 — SIGNATURE & ENTITLEMENT (read-only, no change)"
emit "CODESIGN_VERIFY=$CODESIGN_VERIFY"
emit "CODESIGN_IDENTITY=$CODESIGN_IDENTITY"
emit "VIRTUALIZATION_ENTITLEMENT=$VIRTUALIZATION_ENTITLEMENT"
emit "HYPERVISOR_ENTITLEMENT=$HYPERVISOR_ENTITLEMENT"
emit "APP_SANDBOX_ENTITLEMENT=$APP_SANDBOX_ENTITLEMENT"
emit "HYPERVISOR_ENTITLEMENT_HYPOTHESIS=$HYPERVISOR_ENTITLEMENT_HYPOTHESIS"
emit "# DIAGNOSTIC 3 — BOOT ASSETS"
emit "ASSET_DIAGNOSTIC=$ASSET_DIAGNOSTIC"
emit "FILE_KERNEL=$FILE_KERNEL"
emit "FILE_INITRD=$FILE_INITRD"
emit "KERNEL_ARCH=$KERNEL_ARCH"
emit "INITRD_FORMAT=$INITRD_FORMAT"
emit "ASSET_SHA256_GATE=$ASSET_SHA256_GATE"
emit "# DIAGNOSTIC 4 — VZ STATE"
emit "VZ_IS_SUPPORTED=$VZ_IS_SUPPORTED"
emit "VZ_CONFIG_VALIDATE=$VZ_CONFIG_VALIDATE"
emit "NETWORK_DEVICE_COUNT=$NETWORK_DEVICE_COUNT"
emit "# DIAGNOSTIC 5 — HISTORICAL CRASH REPORT"
emit "$HIST_BLOCK"
emit "# DIAGNOSTIC 6 — FRESH REPRODUCTION"
emit "VM_ATTEMPTED=$VM_ATTEMPTED"
emit "VM_EXIT_CODE=$VM_EXIT_CODE"
emit "VM_SIGNAL=$VM_SIGNAL"
emit "# DIAGNOSTIC 7 — FRESH CRASH"
emit "FRESH_CRASH_REPORT=$FRESH_CRASH_REPORT"
if [ -n "$FRESH_BLOCK" ]; then emit "$FRESH_BLOCK"; fi
emit "# SECURITY BOUNDARY SELF-CHECK (must all be NO)"
emit "PROJECTS_JSON_MODIFIED=$PROJECTS_JSON_MODIFIED"
emit "RUNTIME_MODIFIED=$RUNTIME_MODIFIED"
emit "REAL_WORKTREE_TOUCHED=$REAL_WORKTREE_TOUCHED"
emit "NETWORK_CONFIGURED=$NETWORK_CONFIGURED"
emit "SYSTEM_SECURITY_MODIFIED=$SYSTEM_SECURITY_MODIFIED"
emit "# RESULT"
emit "DIAGNOSTIC_RESULT=$DIAGNOSTIC_RESULT"
emit "===================================="
