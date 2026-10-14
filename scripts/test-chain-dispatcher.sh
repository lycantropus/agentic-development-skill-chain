#!/usr/bin/env bash
# Every verb in the chain dispatcher must reach a real script, in all three
# layouts it runs from (source tree, installed skill tree, synchronized repo),
# and must pass arguments, stdin and the exit code through unchanged.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "test-chain-dispatcher: $*" >&2; exit 1; }

for provider in claude codex; do
  CHAIN="$ROOT/$provider/skills/5_executing/scripts/chain"
  [ -x "$CHAIN" ] || fail "$provider chain is missing or not executable"
  mapfile -t rows < <(bash "$CHAIN" --list)
  [ "${#rows[@]}" -ge 20 ] || fail "$provider table looks truncated (${#rows[@]} rows)"

  # 1. source tree and installed tree (what install-*.sh produces): every row resolves to a file
  inst="$TMP/$provider-installed"; mkdir -p "$inst"
  cp -R "$ROOT/$provider/skills" "$inst/skills"; cp -R "$ROOT/runner" "$inst/skills/5_executing/runner"
  # 2. synchronized repo: everything the sync inventory copies sits flat next to chain
  repo="$TMP/$provider-repo"; mkdir -p "$repo"; git init -q "$repo"
  node "$inst/skills/5_executing/scripts/sync-framework.mjs" --target "$repo" >/dev/null || fail "$provider sync failed"
  [ -x "$repo/scripts/chain" ] || fail "$provider sync did not install an executable scripts/chain"

  for row in "${rows[@]}"; do
    IFS='|' read -r verb sub script kind lead <<<"$row"
    [ -n "$verb" ] && [ -n "$script" ] && [ -n "$kind" ] || fail "malformed row: $row"
    for entry in "source:$CHAIN" "installed:$inst/skills/5_executing/scripts/chain"; do
      where="$(bash "${entry#*:}" --where "$verb" $sub)" || fail "$provider ${entry%%:*}: '$verb $sub' does not resolve"
      [ -f "$where" ] && [ "$(basename "$where")" = "$script" ] || fail "$provider ${entry%%:*}: '$verb $sub' -> $where, expected $script"
    done
    where="$(bash "$repo/scripts/chain" --where "$verb" $sub)" || fail "$provider repo: '$verb $sub' does not resolve"
    [ "$where" = "$repo/scripts/$script" ] || fail "$provider repo: '$verb $sub' -> $where, expected scripts/$script"
  done

  # 3. passthrough: stub scripts echo their name, args and stdin; chain must not alter any of it
  stub="$TMP/$provider-stub"; mkdir -p "$stub"; cp "$CHAIN" "$stub/chain"
  for row in "${rows[@]}"; do
    IFS='|' read -r verb sub script kind lead <<<"$row"
    case "$script" in
      *.mjs) printf 'let i="";process.stdin.on("data",d=>i+=d).on("end",()=>{console.log("%s|"+process.argv.slice(2).join(" ")+"|"+i.trim());process.exit(Number(process.env.STUB_EXIT||0))})\n' "$script" >"$stub/$script" ;;
      *) printf 'echo "%s|$*|$(cat)"\nexit "${STUB_EXIT:-0}"\n' "$script" >"$stub/$script" ;;
    esac
    got="$(echo payload | bash "$stub/chain" "$verb" $sub 'a b' --flag)" || fail "$provider stub '$verb $sub' failed"
    [ "$got" = "$script|${lead:+$lead }a b --flag|payload" ] || fail "$provider '$verb $sub' altered the call: $got"
  done
  rc=0; STUB_EXIT=7 bash "$stub/chain" state get </dev/null >/dev/null || rc=$?
  [ "$rc" = 7 ] || fail "$provider exit code not passed through (got $rc)"
  # a sub only matches in first position: a PROJ named like a sub must not be swallowed
  got="$(bash "$stub/chain" review add claude </dev/null)"
  [ "$got" = "cross-review.sh|add claude|" ] || fail "$provider sub matched outside the first position: $got"

  # 4. errors: unknown verb and a missing script are distinct, non-zero exits
  rc=0; bash "$stub/chain" nope >/dev/null 2>&1 || rc=$?; [ "$rc" = 64 ] || fail "$provider unknown verb should exit 64, got $rc"
  rc=0; bash "$stub/chain" >/dev/null 2>&1 || rc=$?; [ "$rc" = 64 ] || fail "$provider bare chain should exit 64, got $rc"
  rm "$stub/state.sh"; rc=0; bash "$stub/chain" state get >/dev/null 2>&1 || rc=$?
  [ "$rc" = 127 ] || fail "$provider missing script should exit 127, got $rc"
done

# 5. CHAIN_SCRIPTS_DIR: a project's own (customized) copy wins over the installed one; others still resolve from the tree
proj="$TMP/project"; mkdir -p "$proj/scripts"; printf 'echo custom-ledger "$@"\n' >"$proj/scripts/findings.mjs"
rc=0; got="$(cd "$proj" && CHAIN_SCRIPTS_DIR="$proj/scripts" bash "$ROOT/claude/skills/5_executing/scripts/chain" --where findings)"
[ "$got" = "$proj/scripts/findings.mjs" ] || fail "CHAIN_SCRIPTS_DIR copy not preferred: $got"
got="$(cd "$proj" && CHAIN_SCRIPTS_DIR="$proj/scripts" bash "$ROOT/claude/skills/5_executing/scripts/chain" --where state)"
case "$got" in */5_executing/scripts/state.sh) ;; *) fail "helper missing in CHAIN_SCRIPTS_DIR must fall back to the tree: $got" ;; esac
# the phase runner passes its project's scripts/ dir: a customized helper in a repo WITHOUT scripts/chain stays selected
(
  cd "$proj"; printf 'echo custom-worktree "$@"\n' >scripts/worktree.sh
  cp -R "$ROOT/claude/skills" "$TMP/sp ace"   # a skill tree path with a space must survive the runner's loops
  CHAIN_REPO=""; CHAIN_SKILL="$TMP/sp ace/5_executing/scripts/chain"
  eval "$(sed -n '/^chain_has() {/,/^}/p;/^chain() {/,/^}/p' "$ROOT/runner/run-phase.sh")"
  [ "$(chain worktree locate 1)" = "custom-worktree locate 1" ] || { echo "runner chain() ignored the project copy" >&2; exit 1; }
  chain_has worktree || { echo "chain_has lost the project copy" >&2; exit 1; }
) || fail "runner project-copy preference"

echo "test-chain-dispatcher: ok"
