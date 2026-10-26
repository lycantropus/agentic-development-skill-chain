#!/usr/bin/env bash
# check-setup.sh after a pull: up to date passes; a raised minimum in requirements.sh, a
# changed / new skill in the checkout, a retired folder still installed, or no install
# at all fails with the reason; foreign skills are ignored; a leftover Ponytail only warns;
# nothing on the machine is changed. "Pulls" are edits to a copied checkout. PATH is a
# farm of real tools plus fake claude/codex with fixed versions. Also unit-tests version_ge.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "test-check-setup: $*" >&2; exit 1; }

# version_ge: numeric per part, missing parts are 0, unknown is below any minimum.
(
  . "$ROOT/scripts/requirements.sh"
  for ok in "1.10 1.9" "22 22" "24.14.0 22" "4.4 4.4" "5.2.21 4.4" "2.0 2" "2 2.0"; do
    # shellcheck disable=SC2086 # two arguments
    version_ge $ok || fail "version_ge $ok should hold"
  done
  for no in "1.9 1.10" "18.20.0 22" "4.3.48 4.4"; do
    # shellcheck disable=SC2086
    ! version_ge $no || fail "version_ge '$no' should not hold"
  done
  ! version_ge "" 1 || fail "an unknown version must not meet a minimum"
)

CO="$TMP/checkout" H="$TMP/home" BIN="$TMP/bin" PT="$TMP/pt"
mkdir -p "$CO" "$BIN"
cp -R "$ROOT/claude" "$ROOT/codex" "$ROOT/runner" "$ROOT/scripts" "$CO/"
for tool in bash env sh dirname basename mkdir mktemp rm cp ls cat grep sed head tr diff jq git node perl; do
  ln -s "$(command -v "$tool")" "$BIN/$tool"
done
printf '#!/bin/sh\necho "2.1.220 (Claude Code)"\n' >"$BIN/claude"
printf '#!/bin/sh\necho "codex-cli 0.163.0"\n' >"$BIN/codex"
chmod +x "$BIN/claude" "$BIN/codex"

install_all() { # install_all: both chains from the checkout into a fresh scratch home
  rm -rf "$H"; mkdir -p "$H"
  CLAUDE_HOME="$H/.claude" bash "$CO/scripts/install-claude.sh" >/dev/null
  CODEX_HOME="$H/.codex" bash "$CO/scripts/install-codex.sh" >/dev/null
}
ponytail() { # ponytail on|off: plugin registries for both providers
  rm -rf "$PT"; mkdir -p "$PT/cache"
  if [ "$1" = on ]; then
    echo '{"plugins":{"ponytail@ponytail":[{"version":"4.8.4"}]}}' >"$PT/claude.json"
    printf '[plugins."ponytail@ponytail"]\nenabled = true\n' >"$PT/codex.toml"
  else
    echo '{"plugins":{}}' >"$PT/claude.json"; : >"$PT/codex.toml"; rmdir "$PT/cache"
  fi
}
run() { # run: check-setup from the checkout; exit code in $rc, output in $TMP/out
  rc=0
  env -i PATH="$BIN" HOME="$H" CLAUDE_HOME="$H/.claude" CODEX_HOME="$H/.codex" \
    PONYTAIL_CLAUDE_REGISTRY="$PT/claude.json" PONYTAIL_CODEX_CONFIG="$PT/codex.toml" PONYTAIL_CODEX_CACHE="$PT/cache" \
    "$(command -v bash)" "$CO/scripts/check-setup.sh" >"$TMP/out" 2>&1 || rc=$?
}
has_line() { grep -qF -- "$1" "$TMP/out" || fail "expected '$1' in: $(cat "$TMP/out")"; }
total="$(ls "$CO/claude/skills" | wc -l | tr -d ' ')"

# Up to date, with a foreign skill next to the chain: passes, and changes nothing.
install_all; ponytail off; mkdir -p "$H/.claude/skills/synced"
# -A, not -a: the ".." entry is $TMP itself, which run() writes to (its size changes on APFS).
snapshot() { (cd "$TMP" && ls -lAR home pt); }
before="$(snapshot)"
run
[ "$rc" = 0 ] || fail "up-to-date setup should exit 0, got $rc: $(cat "$TMP/out")"
has_line "  ✓ codex 0.163.0"; has_line "  ✓ claude: $total skills match"; has_line "  ✓ codex: $total skills match"
has_line "Setup is up to date with this checkout."
after="$(snapshot)"
[ "$after" = "$before" ] || fail "check-setup changed the machine: $(diff <(echo "$before") <(echo "$after"))"

# A pull raises a minimum: the tool is flagged with both versions.
sed -i.bak 's/^REQ_CODEX=$/REQ_CODEX=0.200/' "$CO/scripts/requirements.sh"
run
[ "$rc" = 1 ] || fail "raised minimum should exit 1, got $rc"
has_line "  ✗ codex: found 0.163.0, need >= 0.200: npm install -g @openai/codex"
has_line "1 problem(s): run ./scripts/install.sh to fix them."
mv "$CO/scripts/requirements.sh.bak" "$CO/scripts/requirements.sh"

# A pull changes a skill: only that provider and folder are flagged, until reinstalled.
echo "pulled change" >>"$CO/claude/skills/6_qa/SKILL.md"
run
[ "$rc" = 1 ] || fail "changed skill should exit 1, got $rc"
has_line "  ✗ claude: changed in this checkout: 6_qa"; has_line "  ✓ codex: $total skills match"
CLAUDE_HOME="$H/.claude" bash "$CO/scripts/install-claude.sh" >/dev/null
run; [ "$rc" = 0 ] || fail "reinstalling should clear the changed skill: $(cat "$TMP/out")"

# A pull adds a skill; a retired folder lingers.
mkdir -p "$CO/codex/skills/zz_new"; echo '---' >"$CO/codex/skills/zz_new/SKILL.md"
mkdir -p "$H/.claude/skills/4b_setup"
run
[ "$rc" = 1 ] || fail "new and retired skills should exit 1, got $rc"
has_line "  ✗ codex: new in this checkout, not installed: zz_new"
has_line "  ✗ claude: retired, still installed: 4b_setup"
has_line "2 problem(s)"
rm -rf "$CO/codex/skills/zz_new"

# Nothing installed: both providers say so.
rm -rf "$H"; mkdir -p "$H"; run
[ "$rc" = 1 ] || fail "no install should exit 1, got $rc"
has_line "  ✗ claude: not installed in $H/.claude/skills"; has_line "  ✗ codex: not installed in $H/.codex/skills"

# Retired Ponytail still installed: warned with the removal commands, but not a problem.
install_all; ponytail on; run
[ "$rc" = 0 ] || fail "a leftover Ponytail must only warn, got $rc: $(cat "$TMP/out")"
has_line "  ! claude: the retired Ponytail plugin is still installed (while enabled it injects into every subagent); remove it:"
has_line "      claude plugin uninstall ponytail@ponytail"; has_line "      claude plugin marketplace remove ponytail"
has_line "  ! codex: the retired Ponytail plugin is still installed (while enabled it injects into every subagent); remove it:"
has_line "      codex plugin remove ponytail@ponytail"; has_line "      codex plugin marketplace remove ponytail"

echo "test-check-setup: ok"
