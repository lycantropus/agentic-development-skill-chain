#!/usr/bin/env bash
# Check this machine against the current checkout; run it after pulling. Read-only.
# Reports tools below the minimums in requirements.sh, installed skill copies that differ
# from this checkout (changed, missing or retired folders), and a leftover Ponytail plugin
# (a warning only: retired, but it still injects into every subagent). Exits 1 when
# ./scripts/install.sh is needed.
# Keep this file bash-3.2-safe so stock macOS reaches the bash hint, not a syntax error.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/requirements.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
problems=0

echo "Tools (minimums in scripts/requirements.sh):"
check_prereqs
if [ -n "$found" ]; then printf '%s\n' "${found#"$NL"}"; fi
if [ -n "$missing" ]; then printf '%s\n' "${missing#"$NL"}" | sed 's/^  - /  ✗ /'; fi
for t in $missing_cmds; do problems=$((problems + 1)); done

echo "Installed skills (compared with this checkout):"
for provider in claude codex; do
  # A fresh install of this checkout is the reference, so the installers' copy rules
  # (runner, excluded spikes) are not restated here.
  if [ "$provider" = claude ]; then
    dest="${CLAUDE_HOME:-$HOME/.claude}/skills"
    CLAUDE_HOME="$TMP/claude" bash "$ROOT/scripts/install-claude.sh" >/dev/null
  else
    dest="${CODEX_HOME:-$HOME/.codex}/skills"
    CODEX_HOME="$TMP/codex" bash "$ROOT/scripts/install-codex.sh" >/dev/null
  fi
  total=0 changed="" absent="" retired=""
  for skill in "$TMP/$provider/skills"/*; do
    name="$(basename "$skill")"
    total=$((total + 1))
    if [ ! -d "$dest/$name" ]; then absent="$absent $name"
    elif ! diff -rq "$skill" "$dest/$name" >/dev/null 2>&1; then changed="$changed $name"
    fi
  done
  for name in $RETIRED_SKILLS; do
    if [ -d "$dest/$name" ]; then retired="$retired $name"; fi
  done
  absent_count=0
  for name in $absent; do absent_count=$((absent_count + 1)); done

  if [ "$absent_count" = "$total" ]; then
    echo "  ✗ $provider: not installed in $dest"
  elif [ -z "$changed$absent$retired" ]; then
    echo "  ✓ $provider: $total skills match"
  else
    if [ -n "$changed" ]; then echo "  ✗ $provider: changed in this checkout:$changed"; fi
    if [ -n "$absent" ]; then echo "  ✗ $provider: new in this checkout, not installed:$absent"; fi
    if [ -n "$retired" ]; then echo "  ✗ $provider: retired, still installed:$retired"; fi
  fi
  if [ -n "$changed$absent$retired" ]; then problems=$((problems + 1)); fi
done

for provider in claude codex; do
  if ponytail_on "$provider"; then
    if [ "$provider" = claude ]; then pt_remove="$PONYTAIL_REMOVE_CLAUDE"; else pt_remove="$PONYTAIL_REMOVE_CODEX"; fi
    echo "  ! $provider: the retired Ponytail plugin is still installed (while enabled it injects into every subagent); remove it:"
    printf '%s\n' "$pt_remove" | sed 's/^/      /'
  fi
done

echo
if [ "$problems" = 0 ]; then
  echo "Setup is up to date with this checkout."
  exit 0
fi
echo "$problems problem(s): run ./scripts/install.sh to fix them."
exit 1
