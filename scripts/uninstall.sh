#!/usr/bin/env bash
# Undo install.sh: remove the chain's skill folders (by name, so other skills in the same
# directories stay) and, where installed, the Ponytail plugin and marketplace on each
# provider plus Ponytail's shared config. Everything is shown first and each part is
# confirmed separately; anything but "y" (or a non-interactive stdin) keeps that part.
# Claude Code, Codex, the toolchain and helper copies synced into projects stay.
# Keep this file bash-3.2-safe, like install.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NL='
'
has() { command -v "$1" >/dev/null 2>&1; }
ask() { # ask <question>: succeeds on y/yes
  local answer=""
  printf '%s [y/N] ' "$1" >&2
  read -r answer || true
  [ -t 0 ] || echo >&2 # a piped answer is not echoed; end the prompt line
  case "$answer" in y|Y|yes|Yes|YES) return 0 ;; esac
  return 1
}
show() { printf '%s\n' "$1" | sed 's/^/    /' >&2; }

# Skill folders: every name this repo ships, plus the folded-away ones the installers clear.
skills=""
for provider in claude codex; do
  if [ "$provider" = claude ]; then dest="${CLAUDE_HOME:-$HOME/.claude}/skills"; else dest="${CODEX_HOME:-$HOME/.codex}/skills"; fi
  for skill in "$ROOT/$provider/skills"/* 4a_checkpoint 4b_setup; do
    name="$(basename "$skill")"
    if [ -d "$dest/$name" ]; then skills="$skills$NL$dest/$name"; fi
  done
done
skills="${skills#"$NL"}"

# Ponytail: detected the same way as chain check ponytail (same override variables).
claude_reg="${PONYTAIL_CLAUDE_REGISTRY:-$HOME/.claude/plugins/installed_plugins.json}"
codex_toml="${PONYTAIL_CODEX_CONFIG:-$HOME/.codex/config.toml}"
codex_cache="${PONYTAIL_CODEX_CACHE:-$HOME/.codex/plugins/cache/ponytail/ponytail}"
pt_config="${PONYTAIL_CONFIG:-$HOME/.config/ponytail/config.json}"
pt_plan="" pt_manual=""
if grep -q '"ponytail@ponytail"' "$claude_reg" 2>/dev/null; then
  if has claude; then
    pt_plan="$pt_plan${NL}claude plugin uninstall ponytail@ponytail${NL}claude plugin marketplace remove ponytail"
  else
    pt_manual="$pt_manual claude"
  fi
fi
if grep -q 'plugins\."ponytail@ponytail"' "$codex_toml" 2>/dev/null || [ -d "$codex_cache" ]; then
  if has codex; then
    pt_plan="$pt_plan${NL}codex plugin remove ponytail@ponytail${NL}codex plugin marketplace remove ponytail"
  else
    pt_manual="$pt_manual codex"
  fi
fi
if [ -f "$pt_config" ]; then pt_plan="$pt_plan${NL}rm -f $(printf '%q' "$pt_config")"; fi
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
