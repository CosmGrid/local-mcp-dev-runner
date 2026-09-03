#!/usr/bin/env bash
#
# Compile and codesign the Stage 0D host helper with virtualization entitlement.
# Output: experiments/p35-stage0d/.build/stage0d-vz-tool
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$HERE/.build"
OUT="$BUILD_DIR/stage0d-vz-tool"
ENT="$HERE/virtualization.entitlements"

mkdir -p "$BUILD_DIR"

echo "==> compiling $HERE/Sources/main.swift"
swiftc -O \
  -target x86_64-apple-macosx15.0 \
  -framework Virtualization \
  "$HERE/Sources/main.swift" -o "$OUT"

echo "==> ad-hoc codesign with virtualization entitlement"
codesign --force --entitlements "$ENT" -s - "$OUT"

echo "BUILD_OK=$OUT"
