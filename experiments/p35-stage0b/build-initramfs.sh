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
BLOCK_REASON=NONE

CPIO_IMPL="UNKNOWN"
GZIP_IMPL="UNKNOWN"

INITRAMFS_EXTRACT=UNKNOWN
INITRAMFS_EXTRACT_RC=UNKNOWN

ORIGINAL_INIT_PRESENT=UNKNOWN
ORIGINAL_INIT_SHA="UNKNOWN"

STAGE0B_INIT_COPY=UNKNOWN
STAGE0B_INIT_CHMOD=UNKNOWN
STAGE0B_INIT_PRESENT=NO
STAGE0B_INIT_EXECUTABLE=NO
STAGE0B_INIT_MODE=UNKNOWN
STAGE0B_INIT_IN_IMAGE=NO

STAGE0B_BINSH_PRESENT=NO
STAGE0B_BINSH_EXECUTABLE=NO
STAGE0B_BINSH_TARGET=NONE
BUSYBOX_PRESENT=NO
BUSYBOX_EXECUTABLE=NO
BUSYBOX_MOUNT_APPLET_PRESENT=NO
STAGE0B_MOUNT_COMMAND="/bin/busybox mount"
STAGE0B_MOUNT_SYMLINK_VALID=NO

INITRAMFS_REPACK=UNKNOWN
INITRAMFS_REPACK_RC=UNKNOWN

ORIGINAL_INIT_SHA_UNCHANGED=UNKNOWN
INITRAMFS_ORIGINAL_INIT_PRESERVED=UNKNOWN
INITRAMFS_VERIFY=UNKNOWN
INITRAMFS_VERIFY_ERROR="NONE"

GUEST_INIT_ADDED=UNKNOWN

report() {
  echo "INITRAMFS_BUILD_GATE=$BUILD_GATE"
  echo "BLOCK_REASON=$BLOCK_REASON"
  echo "INITRAMFS_BUILD_GATE_REASON=$BLOCK_REASON"
  echo "CPIO_IMPLEMENTATION=$CPIO_IMPL"
  echo "GZIP_IMPLEMENTATION=$GZIP_IMPL"
  echo "INITRAMFS_EXTRACT=$INITRAMFS_EXTRACT"
  echo "INITRAMFS_EXTRACT_RC=$INITRAMFS_EXTRACT_RC"
  echo "ORIGINAL_INIT_PRESENT=$ORIGINAL_INIT_PRESENT"
  echo "ORIGINAL_INIT_SHA=$ORIGINAL_INIT_SHA"
  echo "STAGE0B_INIT_COPY=$STAGE0B_INIT_COPY"
  echo "STAGE0B_INIT_CHMOD=$STAGE0B_INIT_CHMOD"
  echo "STAGE0B_INIT_PRESENT=$STAGE0B_INIT_PRESENT"
  echo "STAGE0B_INIT_EXECUTABLE=$STAGE0B_INIT_EXECUTABLE"
  echo "STAGE0B_INIT_MODE=$STAGE0B_INIT_MODE"
  echo "STAGE0B_INIT_IN_IMAGE=$STAGE0B_INIT_IN_IMAGE"
  echo "STAGE0B_BINSH_PRESENT=$STAGE0B_BINSH_PRESENT"
  echo "STAGE0B_BINSH_EXECUTABLE=$STAGE0B_BINSH_EXECUTABLE"
  echo "STAGE0B_BINSH_TARGET=$STAGE0B_BINSH_TARGET"
  echo "BUSYBOX_PRESENT=$BUSYBOX_PRESENT"
  echo "BUSYBOX_EXECUTABLE=$BUSYBOX_EXECUTABLE"
  echo "BUSYBOX_MOUNT_APPLET_PRESENT=$BUSYBOX_MOUNT_APPLET_PRESENT"
  echo "STAGE0B_MOUNT_COMMAND=$STAGE0B_MOUNT_COMMAND"
  echo "STAGE0B_MOUNT_SYMLINK_VALID=$STAGE0B_MOUNT_SYMLINK_VALID"
  echo "INITRAMFS_REPACK=$INITRAMFS_REPACK"
  echo "INITRAMFS_REPACK_RC=$INITRAMFS_REPACK_RC"
  echo "ORIGINAL_INIT_SHA_UNCHANGED=$ORIGINAL_INIT_SHA_UNCHANGED"
  echo "INITRAMFS_ORIGINAL_INIT_PRESERVED=$INITRAMFS_ORIGINAL_INIT_PRESERVED"
  echo "INITRAMFS_STAGE0B_INIT=$STAGE0B_INIT_IN_IMAGE"
  echo "INITRAMFS_STAGE0B_INIT_EXECUTABLE=$STAGE0B_INIT_EXECUTABLE"
  echo "INITRAMFS_VERIFY=$INITRAMFS_VERIFY"
  echo "INITRAMFS_VERIFY_ERROR=$INITRAMFS_VERIFY_ERROR"
  echo "INITRAMFS_OUT=$OUT"
  echo "GUEST_INIT_ADDED=$GUEST_INIT_ADDED"
}

blocked() {
  # $1 = reason
  BLOCK_REASON="$1"
  BUILD_GATE=BLOCKED
  report
  exit 2
}

# --- preflight: tool detection & implementations ---
if ! command -v cpio >/dev/null 2>&1; then blocked "cpio_missing"; fi
if ! command -v gzip >/dev/null 2>&1; then blocked "gzip_missing"; fi
if ! command -v find >/dev/null 2>&1; then blocked "find_missing"; fi
if ! command -v shasum >/dev/null 2>&1; then blocked "shasum_missing"; fi

CPIO_IMPL="$(cpio --version 2>&1 | head -1 | tr '\n' ' ' | cut -c1-60 || echo "bsdcpio")"
GZIP_IMPL="$(gzip --version 2>&1 | head -1 | tr '\n' ' ' | cut -c1-60 || echo "apple_gzip")"

# --- source initramfs must exist ---
if [ ! -f "$SRC_INITRAMFS" ]; then
  blocked "src_initramfs_missing"
fi

# --- guest init script must exist ---
if [ ! -f "$GUEST_INIT" ]; then
  blocked "guest_init_missing"
fi

EXTRACT="$HERE/.build/initramfs-stage0b-extract"
rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"

# --- step 1: unpack (gzip + cpio) ---
EXTRACT_ERR_FILE="/tmp/lmdr-p35-extract-err.$$"
: > "$EXTRACT_ERR_FILE"

set +e
(
  gzip -dc "$SRC_INITRAMFS" 2> "$EXTRACT_ERR_FILE.gzip" \
    | (cd "$EXTRACT" && cpio -idm 2> "$EXTRACT_ERR_FILE.cpio")
)
INITRAMFS_EXTRACT_RC=$?
set -e

if [ "$INITRAMFS_EXTRACT_RC" -ne 0 ]; then
  INITRAMFS_EXTRACT=FAIL
  raw_err="$(cat "$EXTRACT_ERR_FILE.gzip" "$EXTRACT_ERR_FILE.cpio" 2>/dev/null | tr '\n' ' ' | cut -c1-120)"
  rm -f "$EXTRACT_ERR_FILE"* 2>/dev/null
  blocked "INITRAMFS_EXTRACT_FAILED: ${raw_err:-unknown}"
else
  INITRAMFS_EXTRACT=PASS
fi
rm -f "$EXTRACT_ERR_FILE"* 2>/dev/null

# --- step 2: original /init inspection and sha256 baseline ---
if [ -f "$EXTRACT/init" ]; then
  ORIGINAL_INIT_PRESENT=YES
  ORIGINAL_INIT_SHA="$(shasum -a 256 "$EXTRACT/init" 2>/dev/null | awk '{print $1}')"
else
  ORIGINAL_INIT_PRESENT=NO
  ORIGINAL_INIT_SHA="MISSING"
  blocked "ORIGINAL_INIT_MISSING"
fi

# --- step 3: copy stage0b-init (does NOT touch /init) ---
STAGE0B_INIT_SRC_SHA="$(shasum -a 256 "$GUEST_INIT" 2>/dev/null | awk '{print $1}')"

if cp -f "$GUEST_INIT" "$EXTRACT/stage0b-init" 2>/dev/null; then
  STAGE0B_INIT_COPY=PASS
  GUEST_INIT_ADDED="$EXTRACT/stage0b-init"
else
  STAGE0B_INIT_COPY=FAIL
  blocked "STAGE0B_INIT_COPY_FAILED"
fi

if chmod 0755 "$EXTRACT/stage0b-init" 2>/dev/null; then
  STAGE0B_INIT_CHMOD=PASS
else
  STAGE0B_INIT_CHMOD=FAIL
  blocked "STAGE0B_INIT_CHMOD_FAILED"
fi

if [ -f "$EXTRACT/stage0b-init" ]; then
  STAGE0B_INIT_PRESENT=YES
  STAGE0B_INIT_MODE="$(stat -f "%Mp%Lp" "$EXTRACT/stage0b-init" 2>/dev/null || echo UNKNOWN)"
else
  STAGE0B_INIT_PRESENT=NO
  blocked "STAGE0B_INIT_NOT_PRESENT"
fi

if [ -x "$EXTRACT/stage0b-init" ]; then
  STAGE0B_INIT_EXECUTABLE=YES
else
  STAGE0B_INIT_EXECUTABLE=NO
  blocked "STAGE0B_INIT_NOT_EXECUTABLE"
fi

# Create /bin/mount symlink in temporary initramfs if absent
if [ -f "$EXTRACT/bin/busybox" ] && [ ! -e "$EXTRACT/bin/mount" ] && [ ! -L "$EXTRACT/bin/mount" ]; then
  (cd "$EXTRACT/bin" && ln -s busybox mount)
fi

# --- step 4: rebuild archive with clean relative paths (no leading ./) ---
mkdir -p "$(dirname "$OUT")"

REPACK_ERR_FILE="/tmp/lmdr-p35-repack-err.$$"
: > "$REPACK_ERR_FILE"

set +e
(
  cd "$EXTRACT" && \
  find . -mindepth 1 | sed 's|^\./||' | cpio -o -H newc 2> "$REPACK_ERR_FILE.cpio" | gzip -9 > "$OUT" 2> "$REPACK_ERR_FILE.gzip"
)
INITRAMFS_REPACK_RC=$?
set -e

if [ "$INITRAMFS_REPACK_RC" -ne 0 ] || [ ! -s "$OUT" ]; then
  INITRAMFS_REPACK=FAIL
  raw_err="$(cat "$REPACK_ERR_FILE.cpio" "$REPACK_ERR_FILE.gzip" 2>/dev/null | tr '\n' ' ' | cut -c1-120)"
  rm -f "$REPACK_ERR_FILE"* 2>/dev/null
  blocked "INITRAMFS_REPACK_FAILED: ${raw_err:-unknown}"
else
  INITRAMFS_REPACK=PASS
fi
rm -f "$REPACK_ERR_FILE"* 2>/dev/null

# --- step 5: verify the repacked archive byte-for-byte in an independent unpack ---
VERIFY_DIR="$(mktemp -d /tmp/lmdr-p35-verify-XXXXXX)"
set +e
gzip -dc "$OUT" 2>/dev/null | (cd "$VERIFY_DIR" && cpio -idm 2>/dev/null)
VERIFY_UNPACK_RC=$?
set -e

if [ "$VERIFY_UNPACK_RC" -ne 0 ]; then
  INITRAMFS_VERIFY=FAIL
  INITRAMFS_VERIFY_ERROR="VERIFY_UNPACK_FAILED"
  rm -rf "$VERIFY_DIR"
  blocked "VERIFY_UNPACK_FAILED"
fi

# 5a. Verify original /init preserved byte-for-byte
if [ ! -f "$VERIFY_DIR/init" ]; then
  INITRAMFS_VERIFY=FAIL
  INITRAMFS_VERIFY_ERROR="ORIGINAL_INIT_MISSING_IN_OUTPUT"
  rm -rf "$VERIFY_DIR"
  blocked "ORIGINAL_INIT_MISSING_IN_OUTPUT"
fi

VERIFY_INIT_SHA="$(shasum -a 256 "$VERIFY_DIR/init" 2>/dev/null | awk '{print $1}')"
if [ "$VERIFY_INIT_SHA" = "$ORIGINAL_INIT_SHA" ]; then
  ORIGINAL_INIT_SHA_UNCHANGED=YES
  INITRAMFS_ORIGINAL_INIT_PRESERVED=YES
else
  ORIGINAL_INIT_SHA_UNCHANGED=NO
  INITRAMFS_ORIGINAL_INIT_PRESERVED=NO
  INITRAMFS_VERIFY=FAIL
  INITRAMFS_VERIFY_ERROR="ORIGINAL_INIT_SHA_CHANGED"
  rm -rf "$VERIFY_DIR"
  blocked "ORIGINAL_INIT_CHANGED"
fi

# 5b. Verify /stage0b-init exists, is executable, and content matches source
if [ ! -f "$VERIFY_DIR/stage0b-init" ]; then
  INITRAMFS_VERIFY=FAIL
  INITRAMFS_VERIFY_ERROR="STAGE0B_INIT_MISSING_IN_OUTPUT"
  rm -rf "$VERIFY_DIR"
  blocked "STAGE0B_INIT_NOT_IN_ARCHIVE"
fi

STAGE0B_INIT_IN_IMAGE=YES

if [ ! -x "$VERIFY_DIR/stage0b-init" ]; then
  INITRAMFS_VERIFY=FAIL
  INITRAMFS_VERIFY_ERROR="STAGE0B_INIT_NOT_EXECUTABLE_IN_OUTPUT"
  rm -rf "$VERIFY_DIR"
  blocked "STAGE0B_INIT_NOT_EXECUTABLE"
fi

VERIFY_STAGE0B_SHA="$(shasum -a 256 "$VERIFY_DIR/stage0b-init" 2>/dev/null | awk '{print $1}')"
if [ "$VERIFY_STAGE0B_SHA" != "$STAGE0B_INIT_SRC_SHA" ]; then
  INITRAMFS_VERIFY=FAIL
  INITRAMFS_VERIFY_ERROR="STAGE0B_INIT_SHA_MISMATCH"
  rm -rf "$VERIFY_DIR"
  blocked "STAGE0B_INIT_SHA_MISMATCH"
fi

# 5c. M4: Interpreter Verification (/bin/sh and /bin/busybox)
if [ -e "$VERIFY_DIR/bin/sh" ] || [ -L "$VERIFY_DIR/bin/sh" ]; then
  STAGE0B_BINSH_PRESENT=YES
  if [ -L "$VERIFY_DIR/bin/sh" ]; then
    sh_target="$(readlink "$VERIFY_DIR/bin/sh")"
    STAGE0B_BINSH_TARGET="$sh_target"
    if [[ "$sh_target" == /* ]]; then
      resolved_target="$VERIFY_DIR$sh_target"
    else
      resolved_target="$(cd "$(dirname "$VERIFY_DIR/bin/sh")" && pwd)/$sh_target"
    fi
    canonical_verify="$(realpath "$VERIFY_DIR")"
    canonical_target="$(realpath "$resolved_target" 2>/dev/null || echo "")"
    case "$canonical_target" in
      "$canonical_verify"/*)
        if [ -x "$canonical_target" ]; then
          STAGE0B_BINSH_EXECUTABLE=YES
        fi
        ;;
      *)
        STAGE0B_BINSH_EXECUTABLE=NO
        ;;
    esac
  elif [ -x "$VERIFY_DIR/bin/sh" ]; then
    STAGE0B_BINSH_EXECUTABLE=YES
    STAGE0B_BINSH_TARGET="REGULAR_FILE"
  fi
fi

if [ -f "$VERIFY_DIR/bin/busybox" ]; then
  BUSYBOX_PRESENT=YES
  if [ -x "$VERIFY_DIR/bin/busybox" ]; then
    BUSYBOX_EXECUTABLE=YES
  fi
  if (set +o pipefail; strings "$VERIFY_DIR/bin/busybox" 2>/dev/null | grep -w "mount" >/dev/null); then
    BUSYBOX_MOUNT_APPLET_PRESENT=YES
  else
    BUSYBOX_MOUNT_APPLET_PRESENT=NO
  fi
fi

if [ -L "$VERIFY_DIR/bin/mount" ] || [ -f "$VERIFY_DIR/bin/mount" ]; then
  if [ -x "$VERIFY_DIR/bin/mount" ]; then
    STAGE0B_MOUNT_SYMLINK_VALID=YES
  fi
fi

STAGE0B_MOUNT_COMMAND="/bin/busybox mount"

if [ "$STAGE0B_BINSH_PRESENT" != "YES" ] || [ "$STAGE0B_BINSH_EXECUTABLE" != "YES" ] || [ "$BUSYBOX_PRESENT" != "YES" ] || [ "$BUSYBOX_EXECUTABLE" != "YES" ]; then
  INITRAMFS_VERIFY=FAIL
  INITRAMFS_VERIFY_ERROR="STAGE0B_INTERPRETER_INVALID"
  rm -rf "$VERIFY_DIR"
  blocked "STAGE0B_INTERPRETER_INVALID"
fi

if [ "$BUSYBOX_MOUNT_APPLET_PRESENT" != "YES" ]; then
  INITRAMFS_VERIFY=FAIL
  INITRAMFS_VERIFY_ERROR="BUSYBOX_MOUNT_APPLET_MISSING"
  rm -rf "$VERIFY_DIR"
  blocked "BUSYBOX_MOUNT_APPLET_MISSING"
fi

rm -rf "$VERIFY_DIR"
INITRAMFS_VERIFY=PASS
BUILD_GATE=PASS
BLOCK_REASON=NONE

report
exit 0
