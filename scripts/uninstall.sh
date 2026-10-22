#!/usr/bin/env bash
# Undo install.sh: remove the chain's skill folders (by name, so other skills in the same
# directories stay) and, where installed, the Ponytail plugin and marketplace on each
# provider (Ponytail's shared config stays: other Ponytail installs read it too).
# Everything is shown first and each part is confirmed separately; anything but "y"
# (or a non-interactive stdin) keeps that part.
# Claude Code, Codex, the toolchain and helper copies synced into projects stay.
# Keep this file bash-3.2-safe, like install.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/requirements.sh"

# Skill folders: every name this repo ships, plus the folded-away ones the installers clear.
skills=""
for provider in claude codex; do
  if [ "$provider" = claude ]; then dest="${CLAUDE_HOME:-$HOME/.claude}/skills"; else dest="${CODEX_HOME:-$HOME/.codex}/skills"; fi
  for skill in "$ROOT/$provider/skills"/* $RETIRED_SKILLS; do
    name="$(basename "$skill")"
    if [ -d "$dest/$name" ]; then skills="$skills$NL$dest/$name"; fi
  done
done
skills="${skills#"$NL"}"

# Ponytail plugin and marketplace per provider.
pt_plan="" pt_manual=""
if ponytail_on claude; then
  if has claude; then
    pt_plan="$pt_plan${NL}claude plugin uninstall ponytail@ponytail${NL}claude plugin marketplace remove ponytail"
  else
    pt_manual="$pt_manual claude"
  fi
fi
if ponytail_on codex; then
  if has codex; then
    pt_plan="$pt_plan${NL}codex plugin remove ponytail@ponytail${NL}codex plugin marketplace remove ponytail"
  else
    pt_manual="$pt_manual codex"
  fi
fi
pt_plan="${pt_plan#"$NL"}"

if [ -z "$skills" ] && [ -z "$pt_plan" ] && [ -z "$pt_manual" ]; then
  echo "uninstall: nothing from the skill chain is installed"
  exit 0
fi

status=0
old_ifs="$IFS"
if [ -n "$skills" ]; then
  echo "uninstall: skill-chain folders (other skills in these directories stay):" >&2
  show "$skills"
  if ask "Remove these skill folders?"; then
    IFS="$NL"; set -f
    for dir in $skills; do rm -rf "$dir"; done
    IFS="$old_ifs"; set +f
    echo "uninstall: removed $(printf '%s\n' "$skills" | wc -l | tr -d ' ') skill folders"
  else
    echo "uninstall: skill folders kept"
  fi
fi

if [ -n "$pt_manual" ]; then
  echo "uninstall: Ponytail is installed for$pt_manual but that CLI is missing; remove it there manually" >&2
fi
if [ -n "$pt_plan" ]; then
  echo "uninstall: these commands remove Ponytail:" >&2
  show "$pt_plan"
  if ask "Remove Ponytail?"; then
    # Keep going after a failure (e.g. a marketplace already removed by hand); report it at the end.
    IFS="$NL"; set -f
    for cmd in $pt_plan; do
      echo "uninstall: running: $cmd" >&2
      if ! bash -c "$cmd"; then
        echo "uninstall: failed: $cmd" >&2
        status=1
      fi
    done
    IFS="$old_ifs"; set +f
    if [ "$status" = 0 ]; then echo "uninstall: Ponytail removed"; fi
  else
    echo "uninstall: Ponytail kept"
  fi
fi
exit "$status"
