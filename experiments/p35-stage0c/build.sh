#!/usr/bin/env bash
#
# Compile and codesign the Stage 0C host helper.
# Output: experiments/p35-stage0c/.build/p35-stage0c-helper
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$HERE/.build"
OUT="$BUILD_DIR/p35-stage0c-helper"
ENT="$HERE/virtualization.entitlements"

mkdir -p "$BUILD_DIR"

echo "==> compiling $HERE/Sources/main.swift"
swiftc -O "$HERE/Sources/main.swift" -o "$OUT"

echo "==> ad-hoc codesign"
codesign --force --entitlements "$ENT" -s - "$OUT"

echo "BUILD_OK=$OUT"
