#!/usr/bin/env bash
#
# Stage 0D initramfs builder.
# Unpacks the Stage 0A Alpine initramfs, preserves original /init,
# adds /stage0d-init, and re-packs to --out (default .build/initramfs-stage0d).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRC_INITRAMFS="${STAGE0A_INITRAMFS:-/tmp/lmdr-p35-stage0a-assets/initramfs-virt}"
GUEST_INIT="$HERE/guest/stage0d-init"
OUT="$HERE/.build/initramfs-stage0d"

while [ $# -gt 0 ]; do
  case "$1" in
    --src-initramfs) SRC_INITRAMFS="$2"; shift 2;;
    --guest-init)    GUEST_INIT="$2"; shift 2;;
    --out)           OUT="$2"; shift 2;;
    *) echo "build-initramfs: unknown arg '$1'" >&2; exit 2;;
  esac
done

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
STAGE0D_INIT_COPY=UNKNOWN
STAGE0D_INIT_CHMOD=UNKNOWN
STAGE0D_INIT_PRESENT=NO
STAGE0D_INIT_EXECUTABLE=NO
STAGE0D_INIT_MODE=UNKNOWN
STAGE0D_INIT_IN_IMAGE=NO
STAGE0D_BINSH_PRESENT=NO
STAGE0D_BINSH_EXECUTABLE=NO
STAGE0D_BINSH_TARGET=UNKNOWN
BUSYBOX_PRESENT=NO
BUSYBOX_EXECUTABLE=NO
BUSYBOX_MOUNT_APPLET_PRESENT=NO
STAGE0D_MOUNT_COMMAND=UNKNOWN
STAGE0D_MOUNT_SYMLINK_VALID=NO
INITRAMFS_REPACK=UNKNOWN
INITRAMFS_REPACK_RC=UNKNOWN
ORIGINAL_INIT_SHA_UNCHANGED=UNKNOWN
INITRAMFS_ORIGINAL_INIT_PRESERVED=UNKNOWN
INITRAMFS_STAGE0D_INIT=UNKNOWN
INITRAMFS_STAGE0D_INIT_EXECUTABLE=UNKNOWN
INITRAMFS_VERIFY=UNKNOWN
INITRAMFS_VERIFY_ERROR=NONE

emit_report() {
  echo "INITRAMFS_BUILD_GATE=$BUILD_GATE"
  echo "BLOCK_REASON=$BLOCK_REASON"
  echo "INITRAMFS_BUILD_GATE_REASON=$BLOCK_REASON"
  echo "CPIO_IMPLEMENTATION=$CPIO_IMPL"
  echo "GZIP_IMPLEMENTATION=$GZIP_IMPL"
  echo "INITRAMFS_EXTRACT=$INITRAMFS_EXTRACT"
  echo "INITRAMFS_EXTRACT_RC=$INITRAMFS_EXTRACT_RC"
  echo "ORIGINAL_INIT_PRESENT=$ORIGINAL_INIT_PRESENT"
  echo "ORIGINAL_INIT_SHA=$ORIGINAL_INIT_SHA"
  echo "STAGE0D_INIT_COPY=$STAGE0D_INIT_COPY"
  echo "STAGE0D_INIT_CHMOD=$STAGE0D_INIT_CHMOD"
  echo "STAGE0D_INIT_PRESENT=$STAGE0D_INIT_PRESENT"
  echo "STAGE0D_INIT_EXECUTABLE=$STAGE0D_INIT_EXECUTABLE"
  echo "STAGE0D_INIT_MODE=$STAGE0D_INIT_MODE"
  echo "STAGE0D_INIT_IN_IMAGE=$STAGE0D_INIT_IN_IMAGE"
  echo "STAGE0D_BINSH_PRESENT=$STAGE0D_BINSH_PRESENT"
  echo "STAGE0D_BINSH_EXECUTABLE=$STAGE0D_BINSH_EXECUTABLE"
  echo "STAGE0D_BINSH_TARGET=$STAGE0D_BINSH_TARGET"
  echo "BUSYBOX_PRESENT=$BUSYBOX_PRESENT"
  echo "BUSYBOX_EXECUTABLE=$BUSYBOX_EXECUTABLE"
  echo "BUSYBOX_MOUNT_APPLET_PRESENT=$BUSYBOX_MOUNT_APPLET_PRESENT"
  echo "STAGE0D_MOUNT_COMMAND=$STAGE0D_MOUNT_COMMAND"
  echo "STAGE0D_MOUNT_SYMLINK_VALID=$STAGE0D_MOUNT_SYMLINK_VALID"
  echo "INITRAMFS_REPACK=$INITRAMFS_REPACK"
  echo "INITRAMFS_REPACK_RC=$INITRAMFS_REPACK_RC"
  echo "ORIGINAL_INIT_SHA_UNCHANGED=$ORIGINAL_INIT_SHA_UNCHANGED"
  echo "INITRAMFS_ORIGINAL_INIT_PRESERVED=$INITRAMFS_ORIGINAL_INIT_PRESERVED"
  echo "INITRAMFS_STAGE0D_INIT=$INITRAMFS_STAGE0D_INIT"
  echo "INITRAMFS_STAGE0D_INIT_EXECUTABLE=$INITRAMFS_STAGE0D_INIT_EXECUTABLE"
  echo "INITRAMFS_VERIFY=$INITRAMFS_VERIFY"
  echo "INITRAMFS_VERIFY_ERROR=$INITRAMFS_VERIFY_ERROR"
  echo "INITRAMFS_OUT=$OUT"
  echo "GUEST_INIT_ADDED=$GUEST_INIT"
}

if ! command -v cpio >/dev/null 2>&1; then
  BUILD_GATE=BLOCKED; BLOCK_REASON="cpio_missing"; emit_report; exit 2
fi
if ! command -v gzip >/dev/null 2>&1; then
  BUILD_GATE=BLOCKED; BLOCK_REASON="gzip_missing"; emit_report; exit 2
fi
if [ ! -f "$SRC_INITRAMFS" ]; then
  BUILD_GATE=BLOCKED; BLOCK_REASON="source_initramfs_missing"; emit_report; exit 2
fi
if [ ! -f "$GUEST_INIT" ]; then
  BUILD_GATE=BLOCKED; BLOCK_REASON="guest_init_source_missing"; emit_report; exit 2
fi

CPIO_IMPL=$(cpio --version 2>&1 | head -n 1 || echo "unknown")
GZIP_IMPL=$(gzip --version 2>&1 | head -n 1 || echo "unknown")

WORK="$HERE/.build/initramfs-stage0d-extract"
rm -rf "$WORK"
mkdir -p "$WORK" "$(dirname "$OUT")"

set +e
(cd "$WORK" && gzip -dc "$SRC_INITRAMFS" | cpio -idmu >/dev/null 2>&1)
INITRAMFS_EXTRACT_RC=$?
set -e

if [ "$INITRAMFS_EXTRACT_RC" -ne 0 ]; then
  BUILD_GATE=BLOCKED
  BLOCK_REASON="initramfs_extract_failed"
  INITRAMFS_EXTRACT=FAIL
  emit_report
  exit 2
fi
INITRAMFS_EXTRACT=PASS

if [ ! -f "$WORK/init" ]; then
  BUILD_GATE=BLOCKED
  BLOCK_REASON="original_init_missing"
  ORIGINAL_INIT_PRESENT=NO
  emit_report
  exit 2
fi
ORIGINAL_INIT_PRESENT=YES
ORIGINAL_INIT_SHA=$(shasum -a 256 "$WORK/init" | awk '{print $1}')

cp -f "$GUEST_INIT" "$WORK/stage0d-init"
STAGE0D_INIT_COPY=PASS

chmod 0755 "$WORK/stage0d-init"
STAGE0D_INIT_CHMOD=PASS

if [ -f "$WORK/stage0d-init" ]; then STAGE0D_INIT_PRESENT=YES; fi
if [ -x "$WORK/stage0d-init" ]; then STAGE0D_INIT_EXECUTABLE=YES; fi
STAGE0D_INIT_MODE=$(stat -f "%OLp" "$WORK/stage0d-init" 2>/dev/null || stat -c "%a" "$WORK/stage0d-init" 2>/dev/null || echo "UNKNOWN")

if [ -f "$WORK/bin/sh" ] || [ -L "$WORK/bin/sh" ]; then
  STAGE0D_BINSH_PRESENT=YES
  [ -x "$WORK/bin/sh" ] && STAGE0D_BINSH_EXECUTABLE=YES
  STAGE0D_BINSH_TARGET=$(readlink "$WORK/bin/sh" 2>/dev/null || echo "DIRECT")
fi

if [ -x "$WORK/bin/busybox" ]; then
  BUSYBOX_PRESENT=YES
  BUSYBOX_EXECUTABLE=YES
  if (set +o pipefail; strings "$WORK/bin/busybox" 2>/dev/null | grep -E '^mount$' >/dev/null 2>&1); then
    BUSYBOX_MOUNT_APPLET_PRESENT=YES
    STAGE0D_MOUNT_COMMAND="/bin/busybox mount"
  fi
fi

if [ ! -e "$WORK/bin/mount" ] && [ "$BUSYBOX_MOUNT_APPLET_PRESENT" = "YES" ]; then
  (cd "$WORK/bin" && ln -s busybox mount 2>/dev/null || true)
fi

if [ -L "$WORK/bin/mount" ] && [ "$(readlink "$WORK/bin/mount" 2>/dev/null)" = "busybox" ]; then
  STAGE0D_MOUNT_SYMLINK_VALID=YES
fi

# Repack
set +e
(cd "$WORK" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$OUT")
INITRAMFS_REPACK_RC=$?
set -e

if [ "$INITRAMFS_REPACK_RC" -ne 0 ] || [ ! -s "$OUT" ]; then
  BUILD_GATE=BLOCKED
  BLOCK_REASON="initramfs_repack_failed"
  INITRAMFS_REPACK=FAIL
  emit_report
  exit 2
fi
INITRAMFS_REPACK=PASS

# Verification
VERIFY_WORK="$HERE/.build/initramfs-stage0d-verify"
rm -rf "$VERIFY_WORK"
mkdir -p "$VERIFY_WORK"

set +e
(cd "$VERIFY_WORK" && gzip -dc "$OUT" | cpio -idmu >/dev/null 2>&1)
VERIFY_RC=$?
set -e

if [ "$VERIFY_RC" -ne 0 ]; then
  BUILD_GATE=BLOCKED
  BLOCK_REASON="initramfs_verify_unpack_failed"
  INITRAMFS_VERIFY=FAIL
  INITRAMFS_VERIFY_ERROR="extract_failed"
  emit_report
  exit 2
fi

CURR_INIT_SHA=$(shasum -a 256 "$VERIFY_WORK/init" 2>/dev/null | awk '{print $1}')
if [ "$CURR_INIT_SHA" = "$ORIGINAL_INIT_SHA" ]; then
  ORIGINAL_INIT_SHA_UNCHANGED=YES
  INITRAMFS_ORIGINAL_INIT_PRESERVED=YES
else
  ORIGINAL_INIT_SHA_UNCHANGED=NO
  INITRAMFS_ORIGINAL_INIT_PRESERVED=NO
fi

if [ -f "$VERIFY_WORK/stage0d-init" ]; then
  INITRAMFS_STAGE0D_INIT=YES
  STAGE0D_INIT_IN_IMAGE=YES
fi

if [ -x "$VERIFY_WORK/stage0d-init" ]; then
  INITRAMFS_STAGE0D_INIT_EXECUTABLE=YES
fi

rm -rf "$VERIFY_WORK"

if [ "$INITRAMFS_ORIGINAL_INIT_PRESERVED" = "YES" ] && \
   [ "$INITRAMFS_STAGE0D_INIT" = "YES" ] && \
   [ "$INITRAMFS_STAGE0D_INIT_EXECUTABLE" = "YES" ]; then
  INITRAMFS_VERIFY=PASS
  INITRAMFS_VERIFY_ERROR=NONE
  BUILD_GATE=PASS
  BLOCK_REASON=NONE
else
  BUILD_GATE=BLOCKED
  BLOCK_REASON="verification_checks_failed"
  INITRAMFS_VERIFY=FAIL
  INITRAMFS_VERIFY_ERROR="corrupted_or_missing_files"
fi

emit_report
exit 0
