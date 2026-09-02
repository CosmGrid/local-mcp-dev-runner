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
# and prints KEY=VALUE lines the host gate parses.
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

BUILD_GATE=PASS

# --- preflight: required tools ---
if ! command -v cpio >/dev/null 2>&1; then
  echo "INITRAMFS_BUILD_GATE=BLOCKED"
  echo "INITRAMFS_BUILD_GATE_REASON=cpio_missing"
  echo "INITRAMFS_ORIGINAL_INIT_PRESERVED=UNKNOWN"
  exit 2
fi
if ! command -v gzip >/dev/null 2>&1; then
  echo "INITRAMFS_BUILD_GATE=BLOCKED"
  echo "INITRAMFS_BUILD_GATE_REASON=gzip_missing"
  echo "INITRAMFS_ORIGINAL_INIT_PRESERVED=UNKNOWN"
  exit 2
fi

# --- source initramfs must exist ---
if [ ! -f "$SRC_INITRAMFS" ]; then
  echo "INITRAMFS_BUILD_GATE=BLOCKED"
  echo "INITRAMFS_BUILD_GATE_REASON=src_initramfs_missing($SRC_INITRAMFS)"
  echo "INITRAMFS_ORIGINAL_INIT_PRESERVED=UNKNOWN"
  exit 2
fi

# --- guest init script must exist ---
if [ ! -f "$GUEST_INIT" ]; then
  echo "INITRAMFS_BUILD_GATE=BLOCKED"
  echo "INITRAMFS_BUILD_GATE_REASON=guest_init_missing($GUEST_INIT)"
  echo "INITRAMFS_ORIGINAL_INIT_PRESERVED=UNKNOWN"
  exit 2
fi

EXTRACT="$HERE/.build/initramfs-stage0b-extract"
rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"

# --- unpack (gzip+cpio) ---
if ! gzip -dc "$SRC_INITRAMFS" 2>/dev/null | (cd "$EXTRACT" && cpio -idm 2>/dev/null); then
  echo "INITRAMFS_BUILD_GATE=BLOCKED"
  echo "INITRAMFS_BUILD_GATE_REASON=unpack_failed"
  echo "INITRAMFS_ORIGINAL_INIT_PRESERVED=UNKNOWN"
  exit 2
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

# --- rebuild (cpio newc + gzip) ---
mkdir -p "$(dirname "$OUT")"
if ! (cd "$EXTRACT" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$OUT"); then
  echo "INITRAMFS_BUILD_GATE=BLOCKED"
  echo "INITRAMFS_BUILD_GATE_REASON=repack_failed"
  echo "INITRAMFS_ORIGINAL_INIT_PRESERVED=$INIT_PRESERVED"
  exit 2
fi

# --- report ---
echo "INITRAMFS_BUILD_GATE=$BUILD_GATE"
echo "INITRAMFS_ORIGINAL_INIT_PRESERVED=$INIT_PRESERVED"
echo "INITRAMFS_OUT=$OUT"
echo "GUEST_INIT_ADDED=$EXTRACT/stage0b-init"
exit 0
