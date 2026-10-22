#!/usr/bin/env bash
# Full setup: verify both provider CLIs and the helper toolchain, install both skill
# chains, then report Ponytail readiness. Every missing or outdated prerequisite
# (minimums in requirements.sh) is listed at once, with an offer to install it (the
# exact commands are shown first; anything but "y" declines, including a
# non-interactive stdin). Nothing is copied until all are present.
# The per-provider installers stay usable alone (update-chain runs them;
# single-provider machines use them directly).
# Keep this file bash-3.2-safe so stock macOS reaches the bash hint, not a syntax error.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Tool minimums and the shared prerequisite check live in requirements.sh.
. "$ROOT/scripts/requirements.sh"
NVM_VERSION=v0.40.5
# Where nvm lives, resolved the way nvm's own installer does.
if [ -n "${NVM_DIR:-}" ]; then nvm_dir="$NVM_DIR"
elif [ -n "${XDG_CONFIG_HOME:-}" ]; then nvm_dir="$XDG_CONFIG_HOME/nvm"
else nvm_dir="$HOME/.nvm"
fi

plan_installs() { # sets $plan (one command per line, dependency order) and $manual (what it cannot install)
  plan="" manual=""
  local sudo="" pm="" pkgs="" npm_sudo="" node_cmd="" nvm_q t
  [ "$(id -u)" = 0 ] || sudo="sudo "
  for t in brew apt-get dnf; do
    if has "$t"; then pm="$t"; break; fi
  done

  # Node comes from nvm, never the package manager: distro packages often ship an
  # end-of-life Node, and nvm installs the current LTS per user, so npm -g needs no sudo.
  if lacks node; then
    nvm_q="$(printf '%q' "$nvm_dir")"
    if [ -s "$nvm_dir/nvm.sh" ]; then
      node_cmd=". $nvm_q/nvm.sh"
    else
      node_cmd="curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash && . $nvm_q/nvm.sh"
    fi
    node_cmd="$node_cmd && nvm install --lts && nvm alias default 'lts/*'"
  fi

  for t in git jq perl; do
    if lacks "$t"; then pkgs="$pkgs $t"; fi
  done
  # A supported node without npm (split-out distro package) still needs npm for Codex.
  if lacks codex && ! lacks node && ! has npm && [ "$pm" != brew ]; then pkgs="$pkgs npm"; fi
  if ! has curl; then
    case "$node_cmd" in curl*) pkgs="$pkgs curl" ;; *) if lacks claude; then pkgs="$pkgs curl"; fi ;; esac
  fi
  if [ -n "$pkgs" ]; then
    case "$pm" in
      brew) plan="brew install$pkgs" ;;
      apt-get) plan="${sudo}apt-get update && ${sudo}apt-get install -y$pkgs" ;;
      dnf) plan="${sudo}dnf install -y$pkgs" ;;
      *) manual="$manual$pkgs" ;;
    esac
  fi

  if [ -n "$node_cmd" ]; then plan="$plan$NL$node_cmd"; fi
  if lacks claude; then plan="$plan${NL}curl -fsSL https://claude.ai/install.sh | bash"; fi
  if lacks codex; then
    # A root-owned global prefix (system node) needs sudo; nvm and Homebrew prefixes do not.
    if [ -n "$node_cmd" ]; then
      :
    elif has npm; then
      [ -w "$(npm config get prefix)" ] || npm_sudo="$sudo"
    elif [ "$pm" != brew ]; then
      npm_sudo="$sudo"
    fi
    plan="$plan${NL}${npm_sudo}npm install -g @openai/codex"
  fi
  if lacks bash; then manual="$manual bash>=4.4"; fi
  plan="${plan#"$NL"}"
}

use_nvm_node() { # put the node nvm just installed first on PATH, so the Codex step uses it
  local bin
  bin="$(bash -c '. "$1/nvm.sh" >/dev/null 2>&1; nvm which default' _ "$nvm_dir" 2>/dev/null)" || return 0
  if [ -x "$bin" ]; then PATH="$(dirname "$bin"):$PATH"; hash -r; fi
  return 0
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
    case "$cmd" in *"nvm install --lts"*) use_nvm_node ;; esac
  done
  IFS="$old_ifs"; set +f
  # The Claude installer puts claude in ~/.local/bin, which may not be on PATH yet.
  PATH="$HOME/.local/bin:$PATH"
  hash -r
}

check_prereqs
new_clis=""
for t in claude codex; do
  if ! has "$t"; then new_clis="$new_clis $t"; fi # upgrades keep their sign-in
done

if [ -n "$missing" ]; then
  echo "install: missing prerequisites:$missing" >&2
  plan_installs
  if [ -n "$manual" ]; then
    echo "install: cannot install automatically, install manually:$manual" >&2
  fi
  if [ -n "$plan" ]; then
    echo "install: these commands install the rest:" >&2
    show "$plan"
    if ask "Run them now?"; then run_plan; check_prereqs; fi
  fi
fi

if [ -n "$missing" ]; then
  echo "install: missing prerequisites, nothing installed:$missing" >&2
  echo "install: single-provider machine? Run ./scripts/install-claude.sh or ./scripts/install-codex.sh alone." >&2
  exit 1
fi

bash "$ROOT/scripts/install-claude.sh"
bash "$ROOT/scripts/install-codex.sh"

# Ponytail is required for framework runs only (P0 blocks without it): it is offered
# once the skills are in place, and a declined or failed install only warns.
pt_plan=""
if ! ponytail_on claude; then pt_plan="$PONYTAIL_INSTALL_CLAUDE"; fi
if ! ponytail_on codex; then pt_plan="$pt_plan$NL$PONYTAIL_INSTALL_CODEX"; fi
pt_plan="${pt_plan#"$NL"}"
if [ -n "$pt_plan" ]; then
  echo "install: Ponytail (needed for framework runs) is missing; these commands install it:" >&2
  show "$pt_plan"
  if ask "Install Ponytail now?"; then
    # Run every line (adding a marketplace that is already there may fail harmlessly);
    # the check below decides whether Ponytail is in place.
    old_ifs="$IFS"; IFS="$NL"; set -f
    for cmd in $pt_plan; do
      echo "install: running: $cmd" >&2
      bash -c "$cmd" || echo "install: failed: $cmd" >&2
    done
    IFS="$old_ifs"; set +f
  fi
fi
if ! (cd "$ROOT" && bash "${CLAUDE_HOME:-$HOME/.claude}/skills/5_executing/scripts/chain" check ponytail); then
  echo "install: skills installed; Ponytail is not ready (see above), fix it before framework runs" >&2
fi
if [ -n "$new_clis" ]; then
  echo "install: newly installed:$new_clis; start each once to sign in" >&2
fi
