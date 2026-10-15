#!/usr/bin/env bash
# chain check conflicts (delivery.sh probe): verdicts none / trivial / semantic, no side effects
# on real branches, usage and missing-branch exits. (The poll half is covered by test-worktree.sh.)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "test-delivery: $*" >&2; exit 1; }

git_in() { git -C "$REPO" -c user.name=T -c user.email=t@example.invalid "$@"; }
new_repo() { # name -> $REPO with main holding app.txt and package-lock.json
  REPO="$TMP/$1"; mkdir -p "$REPO"; git init -q -b main "$REPO"
  printf 'base\n' >"$REPO/app.txt"; printf '{"v":1}\n' >"$REPO/package-lock.json"
  git_in add -A; git_in commit -qm base; git_in branch proj/PROJ-1
}
probe() { (cd "$REPO" && bash "$CHAIN" check conflicts 1 demo "$@"); }

for provider in claude codex; do
  CHAIN="$ROOT/$provider/skills/5_executing/scripts/chain"

  new_repo "$provider-none"
  git_in checkout -q proj/PROJ-1; printf 'feature\n' >"$REPO/new.txt"; git_in add -A; git_in commit -qm feat; git_in checkout -q main
  [ "$(probe | jq -r .verdict)" = none ] || fail "$provider: clean branch should be verdict none"

  new_repo "$provider-trivial"
  git_in checkout -q proj/PROJ-1; printf '{"v":2}\n' >"$REPO/package-lock.json"; git_in commit -qam lock; git_in checkout -q main
  printf '{"v":3}\n' >"$REPO/package-lock.json"; git_in commit -qam lock-main
  out="$(probe)"; [ "$(jq -r .verdict <<<"$out")" = trivial ] && [ "$(jq -r '.conflicts[0].file' <<<"$out")" = package-lock.json ] || fail "$provider: lockfile conflict should be trivial: $out"

  new_repo "$provider-semantic"
  git_in checkout -q proj/PROJ-1; printf 'proj\n' >"$REPO/app.txt"; git_in commit -qam proj; git_in checkout -q main
  printf 'main\n' >"$REPO/app.txt"; git_in commit -qam main-side
  head_before="$(git_in rev-parse main proj/PROJ-1)"
  out="$(probe)"; [ "$(jq -r .verdict <<<"$out")" = semantic ] || fail "$provider: source conflict should be semantic: $out"
  [ "$(git_in rev-parse main proj/PROJ-1)" = "$head_before" ] || fail "$provider: probe moved a real branch"
  [ -z "$(git_in status --porcelain)" ] || fail "$provider: probe dirtied the checkout"
  [ "$(git_in worktree list | wc -l | tr -d " ")" = 1 ] || fail "$provider: probe left its worktree behind"

  rc=0; probe nobranch >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ] || fail "$provider: missing target should exit 1, got $rc"
  git_in branch -q -D proj/PROJ-1; rc=0; probe >/dev/null 2>&1 || rc=$?; [ "$rc" = 1 ] || fail "$provider: missing PROJ branch should exit 1, got $rc"
  rc=0; (cd "$REPO" && bash "$CHAIN" check conflicts) >/dev/null 2>&1 || rc=$?; [ "$rc" = 64 ] || fail "$provider: usage should exit 64, got $rc"
  rc=0; (cd "$REPO" && bash "$CHAIN" check ci) >/dev/null 2>&1 || rc=$?; [ "$rc" = 64 ] || fail "$provider: poll usage should exit 64, got $rc"
done
echo "test-delivery: ok"
