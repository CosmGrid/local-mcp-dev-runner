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

# Compare normalized rule sets (ignoring comments)
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
# Fixture 4: Report Parser Fixture
# ----------------------------------------------------
get_json() {
  printf '%s' "$1" | grep -oE "\"$2\"[ ]*:[ ]*(\"[^\"]*\"|true|false|null|-?[0-9]+)" \
    | sed -E "s/^\"$2\"[ ]*:[ ]*//; s/^\"//; s/\"$//"
}

SAMPLE_JSON=$(cat << 'SAMPLE_EOF'
{
  "HOST_CONTAINMENT_PRE_VM": "PASS",
  "VM_CONFIG_VALIDATE": "PASS",
  "VM_START": "PASS",
  "VM_RUNNING": "PASS",
  "VIRTIOFS_MOUNT": "PASS",
  "GUEST_HOST_TO_GUEST_READ": "PASS",
  "GUEST_GUEST_TO_HOST_WRITE": "PASS",
  "GUEST_DOTDOT_ESCAPE": "PASS",
  "GUEST_SYMLINK_ESCAPE_REL": "PASS",
  "GUEST_SYMLINK_ESCAPE_ABS": "PASS",
  "GUEST_ABSOLUTE_PATH_ESCAPE": "PASS",
  "GUEST_HOST_HOME_EXPOSED": "NO",
  "GUEST_HAS_VIRTIO_NET": "NO",
  "VM_STOP": "PASS",
  "VM_FINAL_STATE": "stopped",
  "VIRTIOFS_GUEST_ISOLATION": "PASS",
  "VIRTUALIZATION_VM_LIFECYCLE": "PASS",
  "HOST_CONTAINMENT_POST_VM": "PASS",
  "HOST_CONTAINMENT_DELTA": "PASS",
  "PRE_VM_NETWORK_GATE": "PASS",
  "STAGE0D_RESULT": "PASS",
  "BLOCK_REASON": "NONE"
}
SAMPLE_EOF
)

[ "$(get_json "$SAMPLE_JSON" HOST_CONTAINMENT_PRE_VM)" = "PASS" ]
[ "$(get_json "$SAMPLE_JSON" VIRTIOFS_GUEST_ISOLATION)" = "PASS" ]
[ "$(get_json "$SAMPLE_JSON" HOST_CONTAINMENT_DELTA)" = "PASS" ]
[ "$(get_json "$SAMPLE_JSON" STAGE0D_RESULT)" = "PASS" ]
echo "PASS: Fixture 4 - report parser logic verified"

# ----------------------------------------------------
# Fixture 5: Canonical Cleanup Fixture (8 criteria)
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

RUN_ID="cleanupvalid123"
VALID_LOGICAL="/tmp/lmdr-p35-stage0d-$RUN_ID"
mkdir -p "$VALID_LOGICAL"
VALID_CANONICAL="$(realpath "$VALID_LOGICAL")"
touch "$VALID_CANONICAL/.stage0d-active"

F5_RES="$(evaluate_cleanup "$VALID_LOGICAL" "$VALID_CANONICAL" "$RUN_ID")"
if [[ "$F5_RES" != *"CLEANUP_PATH_GATE=PASS TEMP_FILES_CLEANED=PASS LEFTOVER_RUN_DIR=NONE"* ]]; then
  echo "FAIL: Fixture 5 (valid cleanup failed: $F5_RES)"
  exit 1
fi
echo "PASS: Fixture 5 - 8-criteria canonical cleanup gate verified"

# ----------------------------------------------------
# Fixture 6: Helper Validate Mode
# ----------------------------------------------------
VAL_OUT="$("$HERE/.build/stage0d-vz-tool" --mode validate \
  --kernel /tmp/lmdr-p35-stage0a-assets/vmlinuz-virt \
  --initrd "$HERE/.build/initramfs-stage0d" \
  --share "$HERE")"
if ! echo "$VAL_OUT" | grep -q '"isSupported":true'; then
  echo "FAIL: Fixture 6 - helper validate mode failed"
  exit 1
fi
echo "PASS: Fixture 6 - helper validate mode verified"

echo "========================================="
echo "ALL STAGE 0D FIXTURES PASSED"
echo "========================================="
