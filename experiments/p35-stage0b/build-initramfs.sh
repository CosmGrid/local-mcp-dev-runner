#!/usr/bin/env bash
#
# Stage 0B initramfs builder.
#
# Unpacks the Stage 0A Alpine initramfs (gzip+cpio), KEEPS the original /init
# intact (does NOT overwrite it), ADDS /stage0b-init (the VirtioFS isolation
# probe shipped in guest/stage0b-init), then re-packs to a new initramfs.
#
# The guest boots with rdinit=/stage0b-init so the added entry runs as PID 1
# while Alpine's original /init remains in the image.
#
# Preflight: requires `cpio` and `gzip`. If either is missing, the build gate
# is BLOCKED and we DO NOT attempt to install tools (per Stage 0B task book).
#
# Output: writes the new initramfs to --out (default .build/initramfs-stage0b)
# and prints KEY=VALUE lines the host gate parses. Every reported gate field is
# non-empty (Stage 0B Evidence-Pipeline Repair: no empty field may ever be
# read as a verdict).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- args (with sensible defaults) ---
SRC_INITRAMFS="${STAGE0A_INITRAMFS:-/tmp/lmdr-p35-stage0a-assets/initramfs-virt}"
GUEST_INIT="$HERE/guest/stage0b-init"
OUT="$HERE/.build/initramfs-stage0b"

while [ $# -gt 0 ]; do
  case "$1" in
    --src-initramfs) SRC_INITRAMFS="$2"; shift 2;;
    --guest-init)    GUEST_INIT="$2"; shift 2;;
    --out)           OUT="$2"; shift 2;;
    *) echo "build-initramfs: unknown arg '$1'" >&2; exit 2;;
  esac
done

# The repack runs inside a subshell that cd's into the extract dir, so OUT must
# be absolute or the redirect silently targets the wrong place.
case "$OUT" in
  /*) : ;;
  *)  OUT="$HERE/$OUT" ;;
esac

BUILD_GATE=PASS
INIT_PRESERVED=UNKNOWN
STAGE0B_INIT_PRESENT=NO
STAGE0B_INIT_EXECUTABLE=NO
STAGE0B_INIT_MODE=UNKNOWN
STAGE0B_INIT_IN_IMAGE=NO

report() {
  echo "INITRAMFS_BUILD_GATE=$BUILD_GATE"
  echo "INITRAMFS_ORIGINAL_INIT_PRESERVED=$INIT_PRESERVED"
  echo "INITRAMFS_STAGE0B_INIT=$STAGE0B_INIT_IN_IMAGE"
  echo "INITRAMFS_STAGE0B_INIT_EXECUTABLE=$STAGE0B_INIT_EXECUTABLE"
  echo "INITRAMFS_OUT=$OUT"
  echo "GUEST_INIT_ADDED=$GUEST_INIT_ADDED"
  echo "STAGE0B_INIT_PRESENT=$STAGE0B_INIT_PRESENT"
  echo "STAGE0B_INIT_EXECUTABLE=$STAGE0B_INIT_EXECUTABLE"
  echo "STAGE0B_INIT_MODE=$STAGE0B_INIT_MODE"
  echo "STAGE0B_INIT_IN_IMAGE=$STAGE0B_INIT_IN_IMAGE"
}

blocked() {
  # $1 = reason
  echo "INITRAMFS_BUILD_GATE_REASON=$1"
  BUILD_GATE=BLOCKED
  report
  exit 2
}

# --- preflight: required tools ---
command -v cpio >/dev/null 2>&1 || blocked cpio_missing
command -v gzip >/dev/null 2>&1 || blocked gzip_missing

# --- source initramfs must exist ---
[ -f "$SRC_INITRAMFS" ] || blocked "src_initramfs_missing"

# --- guest init script must exist ---
[ -f "$GUEST_INIT" ] || blocked "guest_init_missing"

GUEST_INIT_ADDED=UNKNOWN
EXTRACT="$HERE/.build/initramfs-stage0b-extract"
rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"

# --- unpack (gzip+cpio) ---
if ! gzip -dc "$SRC_INITRAMFS" 2>/dev/null | (cd "$EXTRACT" && cpio -idm 2>/dev/null); then
  blocked unpack_failed
fi

# --- original /init preserved? ---
if [ -f "$EXTRACT/init" ]; then
  INIT_PRESERVED=YES
else
  INIT_PRESERVED=NO
  BUILD_GATE=BLOCKED
fi

# --- add stage0b-init (does NOT touch /init) ---
cp "$GUEST_INIT" "$EXTRACT/stage0b-init"
chmod 0755 "$EXTRACT/stage0b-init"
GUEST_INIT_ADDED="$EXTRACT/stage0b-init"

if [ -f "$EXTRACT/stage0b-init" ]; then
  STAGE0B_INIT_PRESENT=YES
  STAGE0B_INIT_MODE="$(stat -f "%Mp%Lp" "$EXTRACT/stage0b-init" 2>/dev/null || echo UNKNOWN)"
  if [ -x "$EXTRACT/stage0b-init" ]; then STAGE0B_INIT_EXECUTABLE=YES; fi
fi

# --- rebuild (cpio newc + gzip) ---
mkdir -p "$(dirname "$OUT")"
if ! (cd "$EXTRACT" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$OUT"); then
  blocked repack_failed
fi

# --- verify the entry really landed in the REPACKED image (not just the extract
#     dir). This is check #1 of the Stage 0B evidence-pipeline audit: if this is
#     NO, rdinit=/stage0b-init can never work and the guest silently never runs.
#     NOTE: BSD grep BRE has no `\|` alternation — use multiple -e flags.
if gzip -dc "$OUT" 2>/dev/null | cpio -it 2>/dev/null \
     | grep -qx -e "./stage0b-init" -e "stage0b-init"; then
  STAGE0B_INIT_IN_IMAGE=YES
fi
if [ "$STAGE0B_INIT_IN_IMAGE" != "YES" ]; then BUILD_GATE=BLOCKED; fi
if [ "$STAGE0B_INIT_PRESENT" != "YES" ] || [ "$STAGE0B_INIT_EXECUTABLE" != "YES" ]; then
  BUILD_GATE=BLOCKED
fi
if [ "$INIT_PRESERVED" != "YES" ]; then BUILD_GATE=BLOCKED; fi

report
exit 0
