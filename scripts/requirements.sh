# requirements.sh — the setup's tool requirements and shared helpers, sourced (not run)
# by install.sh, check-setup.sh and uninstall.sh. When a change needs a newer tool, raise
# its minimum here: check-setup.sh then flags machines still below it after a pull, and
# install.sh offers the upgrade. Empty = any version. Keep this file bash-3.2-safe.

REQ_CLAUDE=
REQ_CODEX=
REQ_GIT=
REQ_JQ=
# Oldest maintained Node.js LTS (22: end of life April 2027) and the version CI runs.
# Raise it when that line reaches end of life. install.sh always installs the current LTS.
REQ_NODE=22
REQ_BASH=4.4

# Skill folders folded into others; same list as the "retired" loop in install-*.sh.
RETIRED_SKILLS="4a_checkpoint 4b_setup"

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
lacks() { case "$missing_cmds " in *" $1 "*) return 0 ;; esac; return 1; }

tool_version() { # tool_version <command>: first dotted number in its --version output, or empty
  "$1" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1 || true
}
version_ge() { # version_ge <have> <need>: numerically, part by part (1.10 > 1.9; missing parts are 0)
  local have="$1." need="$2." h n
  while [ -n "$need" ]; do
    h="${have%%.*}" n="${need%%.*}"
    have="${have#*.}" need="${need#*.}"
    case "$h" in ''|*[!0-9]*) h=0 ;; esac
    if [ "$h" -gt "$n" ]; then return 0; fi
    if [ "$h" -lt "$n" ]; then return 1; fi
  done
  return 0
}

gap() { # gap <name> <report line>: record a missing or outdated prerequisite
  missing="$missing$NL  - $1: $2"
  missing_cmds="$missing_cmds $1"
}
need() { # need <command> <minimum version or empty> <how to install>
  local v
  if ! has "$1"; then gap "$1" "$3"; return 0; fi
  v="$(tool_version "$1")"
  if [ -n "$2" ] && ! version_ge "$v" "$2"; then
    gap "$1" "found ${v:-an unknown version}, need >= $2: $3"
  else
    found="$found$NL  ✓ $1${v:+ $v}${2:+ (>= $2)}"
  fi
}

check_prereqs() { # sets $missing/$missing_cmds (what to fix) and $found (what is fine)
  missing="" missing_cmds="" found=""
  need claude "$REQ_CLAUDE" "curl -fsSL https://claude.ai/install.sh | bash, then run claude once to sign in"
  need codex "$REQ_CODEX" "npm install -g @openai/codex, then run codex once to sign in"
  need git "$REQ_GIT" "install it with your package manager"
  need jq "$REQ_JQ" "install it with your package manager (macOS: brew install jq)"
  need node "$REQ_NODE" "install the current Node.js LTS, e.g. with nvm: nvm install --lts"
  # perl only backs compat.sh's timeout fallback (stock macOS); Linux has timeout built in.
  if ! has timeout && ! has gtimeout; then
    need perl "" "needed because timeout is absent; install it with your package manager"
  fi
  # The framework runs under the first bash on PATH (#!/usr/bin/env bash): the one running this.
  if version_ge "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" "$REQ_BASH"; then
    found="$found$NL  ✓ bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]} (>= $REQ_BASH)"
  else
    gap bash "found $BASH_VERSION, need >= $REQ_BASH: macOS: brew install bash, and put it before /bin on PATH"
  fi
}

# Ponytail install commands per provider (docs/installation.md § Ponytail), one per line.
PONYTAIL_INSTALL_CLAUDE="claude plugin marketplace add DietrichGebert/ponytail${NL}claude plugin install ponytail@ponytail"
PONYTAIL_INSTALL_CODEX="codex plugin marketplace add DietrichGebert/ponytail${NL}codex plugin add ponytail@ponytail"
ponytail_on() { # ponytail_on claude|codex: the Ponytail plugin is installed there (read-only; same files and overrides as chain check ponytail)
  case "$1" in
    claude) grep -q '"ponytail@ponytail"' "${PONYTAIL_CLAUDE_REGISTRY:-$HOME/.claude/plugins/installed_plugins.json}" 2>/dev/null ;;
    codex) grep -q 'plugins\."ponytail@ponytail"' "${PONYTAIL_CODEX_CONFIG:-$HOME/.codex/config.toml}" 2>/dev/null ||
             [ -d "${PONYTAIL_CODEX_CACHE:-$HOME/.codex/plugins/cache/ponytail/ponytail}" ] ;;
  esac
}
