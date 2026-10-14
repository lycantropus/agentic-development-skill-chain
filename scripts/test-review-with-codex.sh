#!/usr/bin/env bash
# Codex cross-review adapter protocol controls against a PATH-shimmed codex:
# identical findings collapse, review-clean may not coexist with a finding, and
# sandbox noise next to a finding never counts as a review.
set -euo pipefail
export SKILLCHAIN_POLL_SECONDS=0.1 # stubs return instantly; production default stays

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/codex/skills/cross-review/scripts/review-with-codex.sh"
CASE="$(mktemp -d)"
trap 'rm -rf "$CASE"' EXIT
die() { echo "review-with-codex: $*" >&2; exit 1; }

printf 'prompt\n' >"$CASE/prompt.txt"
stub() { printf '#!/bin/sh\n[ "$1" = login ] && exit 0\n%s\n' "$1" >"$CASE/codex"; chmod +x "$CASE/codex"; }
run() { PATH="$CASE:$PATH" bash "$SCRIPT" --prompt "$CASE/prompt.txt" --timeout 10 "$@"; }
F='{"severity":"medium","category":"%s","file":"docs/ARCHITECTURE.md","line":2,"summary":"%s"}'

stub "echo '$(printf "$F" duplicate "same finding")'; echo '$(printf "$F" duplicate "same finding")'"
[ "$(run 2>/dev/null | grep -c '^{')" -eq 1 ] || die 'identical findings must collapse into one'

stub "echo '{\"severity\":\"low\",\"category\":\"review-clean\",\"summary\":\"clean\"}'; echo '$(printf "$F" contradiction "not clean")'"
! out="$(run 2>&1)" && grep -q 'appeared together' <<<"$out" || die 'review-clean plus a finding must be rejected'

stub "echo 'bubblewrap: user namespaces unavailable'; echo '$(printf "$F" false-success "must not pass")'"
! out="$(run 2>&1)" && grep -q 'sandbox/infrastructure failure' <<<"$out" || die 'sandbox false-success output must be rejected'

echo "review-with-codex: ok"
