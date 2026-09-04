#!/usr/bin/env bash
#
# Deploy SOURCE_ROOT -> RUNTIME_ROOT.
#
# This is the deploy engine. install-local.sh calls it after bootstrap; it can
# also be run directly to push a new build.
#
# Safety properties
# -----------------
#   * Copies server.mjs, package.json, package-lock.json and the scripts/ tree
#     (server.mjs imports runtime modules from ./scripts at startup, so the
#     v2.0.0 build cannot boot without it). Never .git, tests, docs, config,
#     secrets or caches.
#   * Builds the new runtime in a staging directory on the same filesystem, then
#     swaps it in with a single rename, so RUNTIME_ROOT is never half-installed.
#   * Preserves runtime state (sandbox/, worktrees/, logs/) across the swap.
#   * Never writes ~/.config/local-mcp-dev-runner/projects.json.
#     The config hash is captured before and after and compared.
#   * Verifies the staged build (syntax + 22-tool inventory) before swapping.
#   * Rolls the previous runtime back into place if the swap fails.
#   * Never starts the tunnel and never touches any credential.
#   * Exits non-zero on any failure.
#
# Usage:
#   bash scripts/update-runtime.sh
#   DRY_RUN=1 bash scripts/update-runtime.sh
#   RUNTIME_ROOT=/tmp/lmdr-drill bash scripts/update-runtime.sh
#   SKIP_DEPS=1 bash scripts/update-runtime.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="${SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUNTIME_ROOT="${RUNTIME_ROOT:-$HOME/.local/share/local-mcp-dev-runner}"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.config/local-mcp-dev-runner/projects.json}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_DEPS="${SKIP_DEPS:-0}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"

TS="$(date +%Y%m%d-%H%M%S)"
RUNTIME_PARENT="$(dirname "$RUNTIME_ROOT")"
STAGING=""
BACKUP=""
SWAPPED=0

log()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ "$SWAPPED" -eq 0 ] && [ -n "$BACKUP" ] && [ -d "$BACKUP" ] && [ ! -d "$RUNTIME_ROOT" ]; then
    log "rollback: restoring $BACKUP -> $RUNTIME_ROOT"
    mv "$BACKUP" "$RUNTIME_ROOT" || true
  fi
  if [ -n "$STAGING" ] && [ -d "$STAGING" ]; then
    rm -rf "$STAGING"
  fi
}
trap cleanup EXIT

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    echo "no-hash-tool"
  fi
}

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------
log "update-runtime: SOURCE_ROOT=$SOURCE_ROOT"
log "update-runtime: RUNTIME_ROOT=$RUNTIME_ROOT"
[ "$DRY_RUN" = "1" ] && log "update-runtime: DRY_RUN=1 (no changes will be made)"

NODE_BIN="${NODE:-$(command -v node || true)}"
[ -n "$NODE_BIN" ] || fail "node not found on PATH"
log "update-runtime: node=$NODE_BIN ($("$NODE_BIN" --version))"

for f in server.mjs package.json package-lock.json; do
  [ -f "$SOURCE_ROOT/$f" ] || fail "missing source file: $SOURCE_ROOT/$f"
done
[ -d "$SOURCE_ROOT/scripts" ] || fail "missing source directory: $SOURCE_ROOT/scripts"

[ -d "$RUNTIME_PARENT" ] || fail "runtime parent does not exist: $RUNTIME_PARENT"
[ -w "$RUNTIME_PARENT" ] || fail "runtime parent is not writable: $RUNTIME_PARENT"

# ---------------------------------------------------------------------------
# 1. Verify the build we are about to deploy
# ---------------------------------------------------------------------------
log "update-runtime: verifying source build"
(cd "$SOURCE_ROOT" && "$NODE_BIN" --check server.mjs) || fail "syntax check failed for server.mjs"

INVENTORY="$SOURCE_ROOT/scripts/check-inventory.mjs"
if [ -f "$INVENTORY" ]; then
  "$NODE_BIN" "$INVENTORY" --server "$SOURCE_ROOT/server.mjs" \
    || fail "source build failed the inventory gate"
else
  log "update-runtime: WARNING inventory gate not found; skipping (not fatal)"
fi

SOURCE_SHA="$(hash_file "$SOURCE_ROOT/server.mjs")"
CONFIG_BEFORE="absent"
[ -f "$CONFIG_FILE" ] && CONFIG_BEFORE="$(hash_file "$CONFIG_FILE")"
log "update-runtime: config snapshot before = $CONFIG_BEFORE"

# ---------------------------------------------------------------------------
# 2. Stage the new runtime on the same filesystem as RUNTIME_ROOT
# ---------------------------------------------------------------------------
STAGING="$(mktemp -d "$RUNTIME_PARENT/.lmdr-staging-XXXXXXXX")" \
  || fail "could not create staging directory under $RUNTIME_PARENT"
log "update-runtime: staging=$STAGING"

cp -p "$SOURCE_ROOT/server.mjs" "$STAGING/server.mjs"
cp -p "$SOURCE_ROOT/package.json" "$STAGING/package.json"
cp -p "$SOURCE_ROOT/package-lock.json" "$STAGING/package-lock.json"
cp -Rp "$SOURCE_ROOT/scripts" "$STAGING/scripts"

STAGED_SHA="$(hash_file "$STAGING/server.mjs")"
[ "$STAGED_SHA" = "$SOURCE_SHA" ] \
  || fail "staged server.mjs hash differs from source ($STAGED_SHA != $SOURCE_SHA)"

# ---------------------------------------------------------------------------
# 3. Dependencies
# ---------------------------------------------------------------------------
if [ "$SKIP_DEPS" = "1" ]; then
  log "update-runtime: SKIP_DEPS=1, staging without node_modules"
else
  NPM_BIN="${NPM:-$(command -v npm || true)}"
  [ -n "$NPM_BIN" ] || fail "npm not found on PATH"
  log "update-runtime: installing dependencies with npm ci"
  if ! (cd "$STAGING" && "$NPM_BIN" ci --omit=dev --no-audit --no-fund); then
    if [ -d "$RUNTIME_ROOT/node_modules" ]; then
      log "update-runtime: npm ci failed; reusing node_modules from the existing runtime"
      cp -R "$RUNTIME_ROOT/node_modules" "$STAGING/node_modules"
    else
      fail "npm ci failed and there is no existing node_modules to fall back on"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4. Verify the staged build before it is allowed anywhere near RUNTIME_ROOT
# ---------------------------------------------------------------------------
log "update-runtime: verifying staged build"
(cd "$STAGING" && "$NODE_BIN" --check server.mjs) || fail "staged server.mjs failed syntax check"
if [ -f "$INVENTORY" ]; then
  "$NODE_BIN" "$INVENTORY" --server "$STAGING/server.mjs" \
    || fail "staged build failed the 22-tool inventory gate"
fi

# Runtime state directories. Preserved across the swap on update, created empty
# on a fresh install, because the registry may already point at sandbox/.
for d in sandbox worktrees logs; do
  mkdir -p "$STAGING/$d"
done

if [ "$DRY_RUN" = "1" ]; then
  log ""
  log "update-runtime: DRY RUN complete. Staged build verified at:"
  log "  $STAGING"
  log "update-runtime: would replace $RUNTIME_ROOT (backup: $RUNTIME_ROOT.bak-$TS)"
  log "update-runtime: no changes were made."
  STAGING_COPY="$STAGING"
  STAGING=""
  rm -rf "$STAGING_COPY"
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Atomic swap
# ---------------------------------------------------------------------------
if [ -d "$RUNTIME_ROOT" ]; then
  BACKUP="$RUNTIME_ROOT.bak-$TS"
  log "update-runtime: backing up existing runtime -> $BACKUP"
  mv "$RUNTIME_ROOT" "$BACKUP"

  # Carry runtime state into the new tree.
  for d in sandbox worktrees logs; do
    if [ -d "$BACKUP/$d" ]; then
      rm -rf "$STAGING/$d"
      mv "$BACKUP/$d" "$STAGING/$d"
      log "update-runtime: preserving runtime state: $d/"
    fi
  done
fi

if ! mv "$STAGING" "$RUNTIME_ROOT"; then
  fail "atomic swap failed"
fi
STAGING=""
SWAPPED=1
log "update-runtime: swapped new runtime into $RUNTIME_ROOT"

chmod 755 "$RUNTIME_ROOT" 2>/dev/null || true
chmod 644 "$RUNTIME_ROOT/server.mjs" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. Post-deploy verification
# ---------------------------------------------------------------------------
CONFIG_AFTER="absent"
[ -f "$CONFIG_FILE" ] && CONFIG_AFTER="$(hash_file "$CONFIG_FILE")"
if [ "$CONFIG_BEFORE" != "$CONFIG_AFTER" ]; then
  log "ERROR: the registered-projects config changed during deploy" >&2
  log "ERROR: before=$CONFIG_BEFORE after=$CONFIG_AFTER" >&2
  exit 1
fi
log "update-runtime: config unchanged ($CONFIG_AFTER)"

"$NODE_BIN" "$INVENTORY" --server "$RUNTIME_ROOT/server.mjs" \
  || fail "deployed runtime failed the inventory gate"

# Rotate old backups. Names embed a sortable timestamp, so ascending order is
# oldest-first. BSD head has no `head -n -N`, so remove by explicit count.
if [ "$KEEP_BACKUPS" -ge 0 ]; then
  BACKUP_LIST="$(mktemp)"
  ls -1d "$RUNTIME_ROOT".bak-* 2>/dev/null | sort > "$BACKUP_LIST" || true
  total="$(wc -l < "$BACKUP_LIST" | tr -d '[:space:]')"
  if [ "${total:-0}" -gt "$KEEP_BACKUPS" ]; then
    remove_count=$((total - KEEP_BACKUPS))
    head -n "$remove_count" "$BACKUP_LIST" | while IFS= read -r old; do
      [ -n "$old" ] || continue
      log "update-runtime: removing old backup $old"
      rm -rf "$old"
    done
  fi
  rm -f "$BACKUP_LIST"
fi

log ""
log "update-runtime: SUCCESS"
log "  runtime  : $RUNTIME_ROOT"
log "  backup   : ${BACKUP:-<none, fresh install>}"
log "  server   : $(hash_file "$RUNTIME_ROOT/server.mjs")"
log ""
log "update-runtime: the tunnel was NOT started and no credential was touched."
log "update-runtime: restart the MCP runner process to pick up the new build."
