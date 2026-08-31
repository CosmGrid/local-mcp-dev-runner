#!/usr/bin/env bash
#
# Secret scan gate.
#
# Scans the files that would actually be committed (git ls-files) for secrets,
# machine-identifying absolute paths and credential material. Fails if anything
# is found.
#
# Read-only. Exits non-zero on any finding.
# Compatible with the bash 3.2 that ships with macOS.
#
# Usage:
#   bash scripts/secret-scan.sh
#
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.." || exit 1

echo "secret-scan: scanning tracked files"
echo

# ---------------------------------------------------------------------------
# Build the file list. Prefer git ls-files: it is exactly what would be committed.
# Fall back to a filesystem walk when this tree is not a git repository.
# ---------------------------------------------------------------------------
FILES=()
while IFS= read -r line; do
  [ -n "$line" ] && FILES+=("$line")
done < <(git ls-files 2>/dev/null)

if [ "${#FILES[@]}" -eq 0 ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && FILES+=("$line")
  done < <(find . -type f \
    -not -path "./node_modules/*" \
    -not -path "./.git/*" \
    -not -path "./coverage/*" | sed 's|^\./||')
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "secret-scan: no files to scan; refusing to pass vacuously" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Tracked-path rules: some files must never be tracked at all.
# ---------------------------------------------------------------------------
BAD_PATH_PATTERN='(^|/)(\.env|\.env\..*|projects\.json|\.npmrc|\.netrc|credentials.*|.*service[-_]?account.*\.json|.*secrets?\.json|id_rsa.*|id_ed25519.*|.*\.(pem|key|p12|pfx|jks|keystore))$'

path_findings=0
for file in "${FILES[@]}"; do
  if printf '%s' "$file" | grep -Eq "$BAD_PATH_PATTERN"; then
    echo "FAIL  tracked forbidden path: $file"
    path_findings=$((path_findings + 1))
  fi
done

# ---------------------------------------------------------------------------
# 2. Content rules. All are matched case-insensitively with BSD-compatible ERE.
# ---------------------------------------------------------------------------
CONTENT_RULES=(
  "OpenAI-style API key|sk-[A-Za-z0-9_-]{20,}"
  "GitHub token|gh[pousr]_[A-Za-z0-9]{16,}"
  "GitHub fine-grained token|github_pat_[A-Za-z0-9_]{20,}"
  "AWS access key id|AKIA[0-9A-Z]{16}"
  "Slack token|xox[baprs]-[A-Za-z0-9-]{10,}"
  "private key block|-----BEGIN [A-Z ]*PRIVATE KEY-----"
  "npm auth token|_authToken[[:space:]]*="
  "generic credential assignment|(api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|password|passwd)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9/+=_-]{16,}"
  "absolute home path of a real user|/Users/[A-Za-z0-9._-]+/"
  "current OS username in tracked content|$(id -un)"
  "runner tunnel credential reference|tunnel[_-]?api[_-]?key[[:space:]]*[:=]"
)

content_findings=0
for file in "${FILES[@]}"; do
  [ -f "$file" ] || continue
  # Skip binary files.
  if ! grep -Iq . "$file" 2>/dev/null; then
    continue
  fi
  for rule in "${CONTENT_RULES[@]}"; do
    label="${rule%%|*}"
    pattern="${rule#*|}"
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      echo "FAIL  ${label}: ${file}:${hit}"
      content_findings=$((content_findings + 1))
    done < <(grep -nEi "$pattern" "$file" 2>/dev/null | cut -d: -f1)
  done
done

total=$((path_findings + content_findings))

if [ "$total" -gt 0 ]; then
  echo
  echo "secret-scan: ${total} finding(s) across ${#FILES[@]} file(s) - FAIL"
  exit 1
fi

echo "secret-scan: clean - ${#FILES[@]} file(s) scanned, 0 findings"
