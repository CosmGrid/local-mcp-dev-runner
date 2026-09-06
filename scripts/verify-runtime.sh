#!/usr/bin/env bash
#
# Verify a deployed runtime. Read-only: never modifies RUNTIME_ROOT, the
# registered-projects config, or the tunnel.
#
# Checks:
#   1. RUNTIME_ROOT exists with server.mjs / package.json / package-lock.json
#   2. server.mjs parses
#   3. dependencies are present
#   4. the deployed build exposes exactly the 24 tools
#      (booted under a throwaway HOME, so the real config is never read)
#   5. the registered-projects config exists and is valid JSON
#      (contents are never printed)
#   6. runtime state directories exist
#   7. drift between SOURCE_ROOT and RUNTIME_ROOT (WARN, or FAIL under STRICT=1)
#
# Usage:
#   bash scripts/verify-runtime.sh
#   STRICT=1 bash scripts/verify-runtime.sh
#   RUNTIME_ROOT=/tmp/lmdr-drill bash scripts/verify-runtime.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="${SOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUNTIME_ROOT="${RUNTIME_ROOT:-$HOME/.local/share/local-mcp-dev-runner}"
CONFIG_FILE="${CONFIG_FILE:-$HOME/.config/local-mcp-dev-runner/projects.json}"
STRICT="${STRICT:-0}"

fails=0
warns=0

log()  { printf '%s\n' "$*"; }
ok()   { printf 'ok    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; warns=$((warns + 1)); }
bad()  { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    echo "no-hash-tool"
  fi
}

NODE_BIN="${NODE:-$(command -v node || true)}"
if [ -z "$NODE_BIN" ]; then
  bad "node not found on PATH"
  exit 1
fi

log "verify-runtime: RUNTIME_ROOT=$RUNTIME_ROOT"
log "verify-runtime: SOURCE_ROOT=$SOURCE_ROOT"
log ""

# 1. layout
if [ -d "$RUNTIME_ROOT" ]; then
  ok "runtime directory exists"
else
  bad "runtime directory missing: $RUNTIME_ROOT"
fi

for f in server.mjs package.json package-lock.json; do
  if [ -f "$RUNTIME_ROOT/$f" ]; then ok "$f present"; else bad "$f missing"; fi
done

# 2. syntax
if [ -f "$RUNTIME_ROOT/server.mjs" ]; then
  if (cd "$RUNTIME_ROOT" && "$NODE_BIN" --check server.mjs 2>/dev/null); then
    ok "server.mjs parses"
  else
    bad "server.mjs failed syntax check"
  fi
fi

# 3. dependencies
if [ -d "$RUNTIME_ROOT/node_modules/@modelcontextprotocol" ]; then
  ok "dependencies installed"
else
  bad "dependencies missing (node_modules/@modelcontextprotocol)"
fi

# 4. tool inventory (isolated HOME; real config is never read)
if [ -f "$RUNTIME_ROOT/server.mjs" ] && [ -d "$RUNTIME_ROOT/node_modules/@modelcontextprotocol" ]; then
  if "$NODE_BIN" "$SOURCE_ROOT/scripts/check-inventory.mjs" --server "$RUNTIME_ROOT/server.mjs" >/tmp/lmdr-verify-inventory.$$ 2>&1; then
    ok "deployed build exposes the 24 tools"
    rm -f "/tmp/lmdr-verify-inventory.$$"
  else
    bad "deployed build failed the inventory gate"
    sed 's/^/      /' "/tmp/lmdr-verify-inventory.$$" || true
    rm -f "/tmp/lmdr-verify-inventory.$$"
  fi
fi

# 5. config exists and is valid JSON (contents never printed)
if [ -f "$CONFIG_FILE" ]; then
  ok "registered-projects config exists"
  mode="$(stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null || stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo '?')"
  if [ "$mode" = "600" ] || [ "$mode" = "700" ]; then
    ok "config permissions are restrictive (mode $mode)"
  else
    warn "config permissions are permissive (mode $mode); 600 recommended"
  fi
  if "$NODE_BIN" -e '
    const fs = require("fs");
    const parsed = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const names = Object.keys(parsed.projects || {});
    process.stdout.write(String(names.length));
  ' "$CONFIG_FILE" >/tmp/lmdr-verify-config.$$ 2>/dev/null; then
    ok "config is valid JSON ($(cat "/tmp/lmdr-verify-config.$$") registered project(s))"
    rm -f "/tmp/lmdr-verify-config.$$"
  else
    bad "config is not valid JSON"
    rm -f "/tmp/lmdr-verify-config.$$"
  fi
else
  bad "registered-projects config missing: $CONFIG_FILE"
fi

# 6. runtime state directories
for d in sandbox worktrees logs; do
  if [ -d "$RUNTIME_ROOT/$d" ]; then ok "runtime state dir present: $d/"; else warn "runtime state dir missing: $d/"; fi
done

# 7. drift
if [ -f "$SOURCE_ROOT/server.mjs" ] && [ -f "$RUNTIME_ROOT/server.mjs" ]; then
  src="$(hash_file "$SOURCE_ROOT/server.mjs")"
  rt="$(hash_file "$RUNTIME_ROOT/server.mjs")"
  if [ "$src" = "$rt" ]; then
    ok "runtime matches source (no drift)"
  else
    warn "runtime differs from source (drift)"
    printf '      source : %s\n' "$src"
    printf '      runtime: %s\n' "$rt"
    printf '      run: bash scripts/update-runtime.sh\n'
  fi
fi

log ""
if [ "$fails" -gt 0 ]; then
  log "verify-runtime: FAIL ($fails failure(s), $warns warning(s))"
  exit 1
fi

if [ "$STRICT" = "1" ] && [ "$warns" -gt 0 ]; then
  log "verify-runtime: FAIL ($warns warning(s) under STRICT=1)"
  exit 1
fi

log "verify-runtime: PASS (0 failures, $warns warning(s))"
