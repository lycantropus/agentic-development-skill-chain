#!/usr/bin/env bash
# Full setup: verify both provider CLIs and the helper toolchain, install both skill
# chains, then report Ponytail readiness. Every missing prerequisite is listed at once,
# with an offer to install it (the exact commands are shown first; anything but "y"
# declines, including a non-interactive stdin). Nothing is copied until all are present.
# The per-provider installers stay usable alone (update-chain runs them;
# single-provider machines use them directly).
# Keep this file bash-3.2-safe so stock macOS reaches the bash hint, not a syntax error.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NL='
'

need() { # need <command> <manual install hint>
  if ! command -v "$1" >/dev/null 2>&1; then
    missing="$missing$NL  - $1: $2"
    missing_cmds="$missing_cmds $1"
  fi
}
check_prereqs() { # sets $missing (report lines) and $missing_cmds (names)
  missing="" missing_cmds=""
  need claude "curl -fsSL https://claude.ai/install.sh | bash, then run claude once to sign in"
  need codex "npm install -g @openai/codex, then run codex once to sign in"
  need git "install it with your package manager"
  need jq "install it with your package manager (macOS: brew install jq)"
  need node "install Node.js 18 or newer"
  # perl only backs compat.sh's timeout fallback (stock macOS); Linux has timeout built in.
  if ! has timeout && ! has gtimeout; then
    need perl "needed because timeout is absent; install it with your package manager"
  fi
  if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    missing="$missing$NL  - bash >= 4.4 (found $BASH_VERSION): macOS: brew install bash, and put it before /bin on PATH"
    missing_cmds="$missing_cmds bash"
  fi
}
lacks() { case "$missing_cmds " in *" $1 "*) return 0 ;; esac; return 1; }
has() { command -v "$1" >/dev/null 2>&1; }

plan_installs() { # sets $plan (one command per line, dependency order) and $manual (what it cannot install)
  plan="" manual=""
  local sudo="" pm="" pkgs="" npm_sudo="" t
  [ "$(id -u)" = 0 ] || sudo="sudo "
  for t in brew apt-get dnf; do
    if has "$t"; then pm="$t"; break; fi
  done

  for t in git jq perl; do
    if lacks "$t"; then pkgs="$pkgs $t"; fi
  done
  # Codex installs through npm; Homebrew's node ships npm, distro packages split it out.
  if lacks node || { lacks codex && ! has npm; }; then
    if [ "$pm" = brew ]; then pkgs="$pkgs node"
    elif lacks node; then pkgs="$pkgs nodejs npm"
    else pkgs="$pkgs npm"
    fi
  fi
  if lacks claude && ! has curl; then pkgs="$pkgs curl"; fi
  if [ -n "$pkgs" ]; then
    case "$pm" in
      brew) plan="brew install$pkgs" ;;
      apt-get) plan="${sudo}apt-get update && ${sudo}apt-get install -y$pkgs" ;;
      dnf) plan="${sudo}dnf install -y$pkgs" ;;
      *) manual="$manual$pkgs" ;;
    esac
  fi

  if lacks claude; then plan="$plan${NL}curl -fsSL https://claude.ai/install.sh | bash"; fi
  if lacks codex; then
    # A root-owned global prefix (system node) needs sudo; nvm and Homebrew prefixes do not.
    if has npm; then
      [ -w "$(npm config get prefix)" ] || npm_sudo="$sudo"
    elif [ "$pm" != brew ]; then
      npm_sudo="$sudo"
    fi
    plan="$plan${NL}${npm_sudo}npm install -g @openai/codex"
  fi
  if lacks bash; then manual="$manual bash>=4.4"; fi
  plan="${plan#"$NL"}"
}

run_plan() { # runs $plan line by line, stopping at the first failure
  local cmd old_ifs="$IFS"
  IFS="$NL"; set -f
  for cmd in $plan; do
    echo "install: running: $cmd" >&2
    if ! bash -c "$cmd"; then
      echo "install: failed: $cmd" >&2
      break
    fi
  done
  IFS="$old_ifs"; set +f
  # The Claude installer puts claude in ~/.local/bin, which may not be on PATH yet.
  PATH="$HOME/.local/bin:$PATH"
  hash -r
}

check_prereqs
new_clis=""
for t in claude codex; do
  if lacks "$t"; then new_clis="$new_clis $t"; fi
done

if [ -n "$missing" ]; then
  echo "install: missing prerequisites:$missing" >&2
  plan_installs
  if [ -n "$manual" ]; then
    echo "install: cannot install automatically, install manually:$manual" >&2
  fi
  if [ -n "$plan" ]; then
    echo "install: these commands install the rest:" >&2
    printf '%s\n' "$plan" | sed 's/^/    /' >&2
    printf 'Run them now? [y/N] ' >&2
    answer=""
    read -r answer || true
    [ -t 0 ] || echo >&2 # a piped answer is not echoed; end the prompt line
    case "$answer" in
      y|Y|yes|Yes|YES) run_plan; check_prereqs ;;
    esac
  fi
fi

if [ -n "$missing" ]; then
  echo "install: missing prerequisites, nothing installed:$missing" >&2
  echo "install: single-provider machine? Run ./scripts/install-claude.sh or ./scripts/install-codex.sh alone." >&2
  exit 1
fi

bash "$ROOT/scripts/install-claude.sh"
bash "$ROOT/scripts/install-codex.sh"

# Ponytail is required for framework runs only (P0 blocks without it), so a gap warns
# instead of failing the install. The check prints the exact install commands.
if ! (cd "$ROOT" && bash "${CLAUDE_HOME:-$HOME/.claude}/skills/5_executing/scripts/chain" check ponytail); then
  echo "install: skills installed; install Ponytail (commands above) before framework runs" >&2
fi
if [ -n "$new_clis" ]; then
  echo "install: newly installed:$new_clis; start each once to sign in" >&2
fi
