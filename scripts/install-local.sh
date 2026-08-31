#!/usr/bin/env bash
#
# First-time install of the Local MCP Dev Runner onto this machine.
#
# This is bootstrap only. The actual deploy is delegated to update-runtime.sh,
# so install and update can never drift apart.
#
# What it does:
#   1. verifies the source build (syntax + 22-tool inventory)
#   2. creates ~/.config/local-mcp-dev-runner if needed
#   3. seeds projects.json FROM config/projects.example.json ONLY IF ABSENT
#      (an existing registered-projects file is never overwritten)
#   4. deploys to RUNTIME_ROOT via update-runtime.sh
#
# What it never does:
#   * overwrite ~/.config/local-mcp-dev-runner/projects.json
#   * start the MCP tunnel
#   * read, write or print any API key or tunnel credential
#
# Usage:
#   bash scripts/install-local.sh
#   DRY_RUN=1 bash scripts/install-local.sh
#   RUNTIME_ROOT=/tmp/lmdr-drill bash scripts/install-local.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="${SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/local-mcp-dev-runner}"
CONFIG_FILE="$CONFIG_DIR/projects.json"
DRY_RUN="${DRY_RUN:-0}"

log()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

log "install-local: SOURCE_ROOT=$SOURCE_ROOT"
[ "$DRY_RUN" = "1" ] && log "install-local: DRY_RUN=1 (no changes will be made)"

# ---------------------------------------------------------------------------
# 1. Source tree must be complete and healthy
# ---------------------------------------------------------------------------
for f in server.mjs package.json package-lock.json config/projects.example.json; do
  [ -f "$SOURCE_ROOT/$f" ] || fail "missing source file: $SOURCE_ROOT/$f"
done

NODE_BIN="${NODE:-$(command -v node || true)}"
[ -n "$NODE_BIN" ] || fail "node not found on PATH"

(cd "$SOURCE_ROOT" && "$NODE_BIN" --check server.mjs) || fail "syntax check failed"
"$NODE_BIN" "$SOURCE_ROOT/scripts/check-inventory.mjs" --server "$SOURCE_ROOT/server.mjs" \
  || fail "source build failed the 22-tool inventory gate"
log "install-local: source build verified"

# ---------------------------------------------------------------------------
# 2. Config directory
# ---------------------------------------------------------------------------
if [ -d "$CONFIG_DIR" ]; then
  log "install-local: config directory already exists: $CONFIG_DIR"
else
  if [ "$DRY_RUN" = "1" ]; then
    log "install-local: would create $CONFIG_DIR (mode 700)"
  else
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    log "install-local: created $CONFIG_DIR (mode 700)"
  fi
fi

if [ -f "$CONFIG_FILE" ]; then
  log "install-local: existing projects.json detected - leaving it untouched"
  log "install-local:   $CONFIG_FILE"
else
  if [ "$DRY_RUN" = "1" ]; then
    log "install-local: would seed projects.json from config/projects.example.json"
  else
    cp "$SOURCE_ROOT/config/projects.example.json" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    log "install-local: seeded $CONFIG_FILE from the example (mode 600)"
    log "install-local: ACTION REQUIRED - replace every <PLACEHOLDER> before use."
  fi
fi

if [ "$DRY_RUN" = "1" ]; then
  log ""
  log "install-local: DRY RUN complete. No changes were made."
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Deploy
# ---------------------------------------------------------------------------
log ""
exec bash "$SCRIPT_DIR/update-runtime.sh"
