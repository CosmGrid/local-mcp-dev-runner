#!/usr/bin/env bash
#
# Stage 0B build: compile the Swift helper and ad-hoc codesign it with the
# virtualization entitlement (only com.apple.security.virtualization). No
# app-sandbox, no hypervisor entitlement — matches the Stage 0A security boundary.
#
# This script does NOT start a VM and does NOT touch the deployed runtime,
# projects.json, or any managed worktree.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/Sources/main.swift"
OUT="$HERE/.build/stage0b-vz-tool"
ENT="$HERE/virtualization.entitlements"

mkdir -p "$HERE/.build"

echo "==> compiling $SRC"
swiftc -O \
  -target x86_64-apple-macosx15.0 \
  -framework Virtualization \
  "$SRC" -o "$OUT"

echo "==> ad-hoc codesign with virtualization entitlement"
codesign --force --entitlements "$ENT" -s - "$OUT"

echo "BUILD_OK=$OUT"
