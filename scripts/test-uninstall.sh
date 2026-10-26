#!/usr/bin/env bash
# uninstall.sh: shows everything and asks per part; declining keeps it; accepting removes
# only the chain's skill folders (foreign skills and the skills directories stay) and runs
# the retired Ponytail's removal for each provider where it is still installed; a failed command is
# reported without skipping the rest; a missing provider CLI is named; an empty home is a
# no-op. Skills come from the real installers into a scratch home; claude/codex are fake
# CLIs that log their arguments, on a PATH farm so the host's real CLIs never count.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "test-uninstall: $*" >&2; exit 1; }

TOOLS="bash env sh dirname basename mkdir rm cp ls cat grep sed wc tr"
LOG="$TMP/cli.log" BIN="$TMP/bin" H="$TMP/home"
farm() { # farm <omitted tool>...: real TOOLS plus fake claude/codex, minus the omitted ones
  local tool
  rm -rf "$BIN"; mkdir -p "$BIN"; : >"$LOG"
  for tool in $TOOLS claude codex; do
    case " $* " in *" $tool "*) continue ;; esac
    case "$tool" in
      claude|codex) printf '#!/bin/sh\necho "%s $*" >>"$FAKE_LOG"\n[ "%s $*" != "$FAKE_FAIL" ]\n' "$tool" "$tool" >"$BIN/$tool"
                    chmod +x "$BIN/$tool" ;;
      *) ln -s "$(command -v "$tool")" "$BIN/$tool" ;;
    esac
  done
}
setup() { # setup [bare]: both chains installed next to foreign skills, Ponytail on both providers
  rm -rf "$H"; mkdir -p "$H"
  [ "${1:-}" = bare ] && return 0
  CLAUDE_HOME="$H/.claude" bash "$ROOT/scripts/install-claude.sh" >/dev/null
  CODEX_HOME="$H/.codex" bash "$ROOT/scripts/install-codex.sh" >/dev/null
  mkdir -p "$H/.claude/skills/synced" "$H/.codex/skills/mine" "$H/.claude/skills/4a_checkpoint"
  mkdir -p "$H/.claude/plugins" "$H/.codex/plugins/cache/ponytail/ponytail/4.8.4" "$H/.config/ponytail"
  echo '{"version":2,"plugins":{"ponytail@ponytail":[{"version":"4.8.4"}]}}' >"$H/.claude/plugins/installed_plugins.json"
  printf '[plugins."ponytail@ponytail"]\nenabled = true\n' >"$H/.codex/config.toml"
  echo '{"defaultMode":"full"}' >"$H/.config/ponytail/config.json"
}
run() { # run [answer]...: one line per prompt (none: closed stdin); exit code in $rc, output in $TMP/out, $TMP/err
  rc=0
  { if [ $# -gt 0 ]; then printf '%s\n' "$@"; fi; } | env -i PATH="$BIN" HOME="$H" \
    FAKE_LOG="$LOG" FAKE_FAIL="${FAKE_FAIL:-}" "$(command -v bash)" "$ROOT/scripts/uninstall.sh" >"$TMP/out" 2>"$TMP/err" || rc=$?
}
chain_count() { # chain_count <skills dir>: how many of the repo's skill folders are present
  local n=0 skill
  for skill in "$ROOT/claude/skills"/*; do [ ! -d "$1/$(basename "$skill")" ] || n=$((n + 1)); done
  echo "$n"
}
total="$(ls "$ROOT/claude/skills" | wc -l | tr -d ' ')"

# Declined (closed stdin, then "n" twice): full plan shown, nothing removed or run.
for answers in "" "n n"; do
  farm; setup
  # shellcheck disable=SC2086 # split the answers into one line each
  run $answers
  [ "$rc" = 0 ] || fail "declining should exit 0, got $rc: $(cat "$TMP/err")"
  for p in claude codex; do [ "$(chain_count "$H/.$p/skills")" = "$total" ] || fail "declined '$answers': $p skills removed"; done
  grep -q "^    $H/.claude/skills/4a_checkpoint$" "$TMP/err" || fail "retired folder not listed: $(cat "$TMP/err")"
  ! grep -q '/synced$\|/mine$' "$TMP/err" || fail "foreign skills listed for removal"
  for c in 'claude plugin uninstall ponytail@ponytail' 'claude plugin marketplace remove ponytail' \
           'codex plugin remove ponytail@ponytail' 'codex plugin marketplace remove ponytail'; do
    grep -qxF "    $c" "$TMP/err" || fail "plan line missing: $c"
  done
  [ ! -s "$LOG" ] && [ -f "$H/.config/ponytail/config.json" ] || fail "declined '$answers': Ponytail touched"
  grep -q 'skill folders kept' "$TMP/out" && grep -q 'Ponytail kept' "$TMP/out" || fail "kept parts not reported"
done

# Skills only: every chain folder gone on both providers, foreign skills and the directories stay.
farm; setup; run y n
[ "$rc" = 0 ] || fail "skills-only uninstall should exit 0, got $rc"
for p in claude codex; do [ "$(chain_count "$H/.$p/skills")" = 0 ] || fail "$p chain skills left"; done
[ ! -e "$H/.claude/skills/4a_checkpoint" ] || fail "retired folder left"
[ -d "$H/.claude/skills/synced" ] && [ -d "$H/.codex/skills/mine" ] || fail "foreign skills removed"
grep -q "removed $((total * 2 + 1)) skill folders" "$TMP/out" || fail "removal count wrong: $(cat "$TMP/out")"
[ ! -s "$LOG" ] && [ -f "$H/.config/ponytail/config.json" ] || fail "Ponytail touched when declined"

# Ponytail only: plugin then marketplace per provider; the shared config and the skills stay.
farm; setup; run n y
[ "$rc" = 0 ] || fail "Ponytail uninstall should exit 0, got $rc: $(cat "$TMP/err")"
[ "$(cat "$LOG")" = "claude plugin uninstall ponytail@ponytail
claude plugin marketplace remove ponytail
codex plugin remove ponytail@ponytail
codex plugin marketplace remove ponytail" ] || fail "Ponytail commands wrong: $(cat "$LOG")"
[ -f "$H/.config/ponytail/config.json" ] || fail "shared Ponytail config removed (other Ponytail installs read it)"
[ "$(chain_count "$H/.claude/skills")" = "$total" ] || fail "skills removed when declined"

# A failing command is reported, the rest still run, exit 1.
farm; setup; FAKE_FAIL='claude plugin marketplace remove ponytail' run n y
[ "$rc" = 1 ] || fail "failed command should exit 1, got $rc"
grep -q 'failed: claude plugin marketplace remove ponytail' "$TMP/err" || fail "failure not reported"
grep -q '^codex plugin marketplace remove ponytail$' "$LOG" || fail "commands after a failure skipped"

# Codex CLI missing: its Ponytail is named for manual removal; the Claude side is still offered.
farm codex; setup; run n n
grep -q 'Ponytail is installed for codex but that CLI is missing' "$TMP/err" || fail "missing codex CLI not named"
! grep -q '^    codex ' "$TMP/err" || fail "codex commands planned without the CLI"
grep -qxF '    claude plugin uninstall ponytail@ponytail' "$TMP/err" || fail "claude side not offered"

# Nothing installed: no prompt, exit 0.
farm; setup bare; run
[ "$rc" = 0 ] && grep -q 'nothing from the skill chain is installed' "$TMP/out" || fail "empty home not a no-op"
! grep -q '\[y/N\]' "$TMP/err" || fail "prompted with nothing installed"

echo "test-uninstall: ok"
