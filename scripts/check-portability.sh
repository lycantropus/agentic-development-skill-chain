#!/usr/bin/env bash
# Lint guard: GNU-only tools and flags may appear in production helpers only inside compat.sh
# (which carries the macOS fallbacks). Comment-only lines are ignored. Called from validate.sh.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

# command position: line start, after ; & | $( or if/then/else/do/!
CMD='(^|[;&|]|\$\(|\b(if|then|else|do|!)[[:space:]])[[:space:]]*'
PATTERN="${CMD}(timeout|gtimeout|flock|setsid)[[:space:]]|realpath -m|realpath --relative|date \+%s%|date -I|date -d|etimes|sha1sum|sha256sum|md5sum|sort -[a-zA-Z]*V|readlink -f|sed -i|spawn(Sync)?\('timeout'"

files=$(ls claude/skills/*/scripts/* runner/run-phase.sh 2>/dev/null | grep -vE '/compat\.sh$|/merge-project-settings\.sh$|/(sonar-issues|supabase-local-dev)/' || true)
hits=$(grep -nE "$PATTERN" $files /dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//)' || true)
if [ -n "$hits" ]; then
  echo "check-portability: GNU-only usage outside compat.sh (use TIMEOUT_BIN, SETSID_BIN, lock_acquire, now_iso, now_ms, abspath, relpath, proc_age_seconds):" >&2
  echo "$hits" >&2
  exit 1
fi
echo "check-portability: ok"
