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
    IFS='|' read -r verb sub script kind <<<"$row"
    [ -n "$verb" ] && [ -n "$script" ] && [ -n "$kind" ] || fail "malformed row: $row"
    for entry in "source:$CHAIN" "installed:$inst/skills/5_executing/scripts/chain"; do
      where="$(bash "${entry#*:}" --where "$verb" $sub)" || fail "$provider ${entry%%:*}: '$verb $sub' does not resolve"
      [ -f "$where" ] && [ "$(basename "$where")" = "$script" ] || fail "$provider ${entry%%:*}: '$verb $sub' -> $where, expected $script"
    done
    # render-report.mjs ships with the runner, not in the synchronized helper set
    if [ "$script" = render-report.mjs ]; then continue; fi
    where="$(bash "$repo/scripts/chain" --where "$verb" $sub)" || fail "$provider repo: '$verb $sub' does not resolve"
    [ "$where" = "$repo/scripts/$script" ] || fail "$provider repo: '$verb $sub' -> $where, expected scripts/$script"
  done

  # 3. passthrough: stub scripts echo their name, args and stdin; chain must not alter any of it
  stub="$TMP/$provider-stub"; mkdir -p "$stub"; cp "$CHAIN" "$stub/chain"
  for row in "${rows[@]}"; do
    IFS='|' read -r verb sub script kind <<<"$row"
    case "$script" in
      *.mjs) printf 'let i="";process.stdin.on("data",d=>i+=d).on("end",()=>{console.log("%s|"+process.argv.slice(2).join(" ")+"|"+i.trim());process.exit(Number(process.env.STUB_EXIT||0))})\n' "$script" >"$stub/$script" ;;
      *) printf 'echo "%s|$*|$(cat)"\nexit "${STUB_EXIT:-0}"\n' "$script" >"$stub/$script" ;;
    esac
    got="$(echo payload | bash "$stub/chain" "$verb" $sub 'a b' --flag)" || fail "$provider stub '$verb $sub' failed"
    [ "$got" = "$script|a b --flag|payload" ] || fail "$provider '$verb $sub' altered the call: $got"
  done
  rc=0; STUB_EXIT=7 bash "$stub/chain" state get </dev/null >/dev/null || rc=$?
  [ "$rc" = 7 ] || fail "$provider exit code not passed through (got $rc)"
  # a sub only matches in first position: a PROJ named like a sub must not be swallowed
  got="$(bash "$stub/chain" findings add harvest </dev/null)"
  [ "$got" = "ledger.mjs|add harvest|" ] || fail "$provider sub matched outside the first position: $got"

  # 4. errors: unknown verb and a missing script are distinct, non-zero exits
  rc=0; bash "$stub/chain" nope >/dev/null 2>&1 || rc=$?; [ "$rc" = 64 ] || fail "$provider unknown verb should exit 64, got $rc"
  rc=0; bash "$stub/chain" >/dev/null 2>&1 || rc=$?; [ "$rc" = 64 ] || fail "$provider bare chain should exit 64, got $rc"
  rm "$stub/state.sh"; rc=0; bash "$stub/chain" state get >/dev/null 2>&1 || rc=$?
  [ "$rc" = 127 ] || fail "$provider missing script should exit 127, got $rc"
done

echo "test-chain-dispatcher: ok"
