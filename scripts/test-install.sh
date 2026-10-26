#!/usr/bin/env bash
# install.sh: missing prerequisites are all reported with an install offer; declining or a
# failed install copies nothing; accepting installs them and continues; with every
# prerequisite present both chains install and no plugin command ever runs (the Ponytail
# plugin is retired). PATH is a farm
# of the real tools minus the ones under test, with stubbed claude/codex and fake
# installers (sudo, apt-get, curl, npm) that log calls and drop stubs into the farm,
# so whatever is installed on the host never counts and nothing real is installed.
# The farm has no timeout unless a case adds one, so perl is required by default.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "test-install: $*" >&2; exit 1; }

TOOLS="bash env sh dirname basename mkdir mktemp rm cp ls cat grep sed awk cut sort tail head tr date id uname chmod ln jq git node perl"
REAL="$TMP/real" FAKES="$TMP/fakes" LOG="$TMP/installs.log"
mkdir -p "$REAL" "$FAKES" "$TMP/npm-prefix"
for tool in $TOOLS; do ln -s "$(command -v "$tool")" "$REAL/$tool"; done

# Provider CLIs log their arguments.
cat >"$FAKES/claude" <<'EOF'
#!/bin/sh
echo "claude $*" >>"$FAKE_LOG"
EOF
cat >"$FAKES/codex" <<'EOF'
#!/bin/sh
echo "codex $*" >>"$FAKE_LOG"
EOF
cat >"$FAKES/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >>"$FAKE_LOG"; exec "$@"
EOF
cat >"$FAKES/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >>"$FAKE_LOG"
[ -z "$FAKE_APT_FAILS" ] || exit 100
for p in "$@"; do [ ! -e "$FAKE_REAL/$p" ] || ln -sf "$FAKE_REAL/$p" "$FAKE_BIN/$p"; done
EOF
cat >"$FAKES/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$FAKE_LOG"
case "$*" in
  *nvm-sh/nvm*) echo 'mkdir -p "$HOME/.nvm" && cp "$FAKE_FAKES/nvm.sh" "$HOME/.nvm/nvm.sh"' ;;
  *sonarqube-cli*) cat <<'SCRIPT'
mkdir -p "$HOME/.local/share/sonarqube-cli/bin" && printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/share/sonarqube-cli/bin/sonar" && chmod +x "$HOME/.local/share/sonarqube-cli/bin/sonar"
SCRIPT
  ;;
  *sonar-scanner-cli*) prev=""; for a in "$@"; do [ "$prev" != -o ] || : >"$a"; prev="$a"; done ;;
  *) cat <<'SCRIPT'
mkdir -p "$HOME/.local/bin" && printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/bin/claude" && chmod +x "$HOME/.local/bin/claude"
SCRIPT
  ;;
esac
EOF
# nvm stand-in: "install" puts the real node and the fake npm into a versioned bin dir.
cat >"$FAKES/nvm.sh" <<'EOF'
nvm() {
  echo "nvm $*" >>"$FAKE_LOG"
  b="$HOME/.nvm/versions/node/v24.0.0/bin"
  case "$1" in
    install) mkdir -p "$b" && ln -sf "$FAKE_REAL/node" "$b/node" && cp "$FAKE_FAKES/npm" "$b/npm" ;;
    which) echo "$b/node" ;;
  esac
}
EOF
# unzip stand-in: a scanner zip unpacks to sonar-scanner-<version>-<platform>/bin/sonar-scanner.
cat >"$FAKES/unzip" <<'EOF'
#!/bin/sh
echo "unzip $*" >>"$FAKE_LOG"
zip="" dest=""
while [ $# -gt 0 ]; do case "$1" in -d) dest="$2"; shift ;; -*) ;; *) zip="$1" ;; esac; shift; done
d="$dest/$(basename "$zip" .zip | sed 's/^sonar-scanner-cli-/sonar-scanner-/')/bin"
mkdir -p "$d" && printf '#!/bin/sh\nexit 0\n' >"$d/sonar-scanner" && chmod +x "$d/sonar-scanner"
EOF
cat >"$FAKES/node-old" <<'EOF'
#!/bin/sh
echo v18.20.0
EOF
cat >"$FAKES/npm" <<'EOF'
#!/bin/sh
echo "npm $*" >>"$FAKE_LOG"
case "$*" in
  "config get prefix") echo "$FAKE_NPM_PREFIX" ;;
  "install -g @openai/codex") cp "$FAKE_FAKES/codex" "$FAKE_BIN/codex" ;;
esac
EOF
chmod +x "$FAKES"/*

BIN="$TMP/bin"
farm() { # farm <omitted tool>...: real TOOLS plus stubs and fake installers, minus the omitted ones
  local tool
  rm -rf "$BIN"; mkdir -p "$BIN"; : >"$LOG"
  for tool in $TOOLS claude codex sudo apt-get curl npm unzip; do
    case " $* " in *" $tool "*) continue ;; esac
    if [ -e "$FAKES/$tool" ]; then cp "$FAKES/$tool" "$BIN/$tool"; else ln -s "$REAL/$tool" "$BIN/$tool"; fi
  done
}

run() { # run [answer]: install into a scratch home, answering the prompt (none: closed stdin);
        # exit code in $rc, output in $TMP/out, $TMP/err
  rm -rf "$TMP/home"; mkdir -p "$TMP/home"
  if [ -n "${SEED_SONAR:-}" ]; then # both Sonar CLIs installed per user, folders not on PATH yet
    mkdir -p "$TMP/home/.local/share/sonarqube-cli/bin" "$TMP/home/.local/bin"
    for f in .local/share/sonarqube-cli/bin/sonar .local/bin/sonar-scanner; do printf '#!/bin/sh\nexit 0\n' >"$TMP/home/$f"; chmod +x "$TMP/home/$f"; done
  fi
  if [ -n "${SEED_NVM:-}" ]; then mkdir -p "$TMP/home/.nvm"; cp "$FAKES/nvm.sh" "$TMP/home/.nvm/nvm.sh"; fi
  rc=0
  { if [ $# -gt 0 ]; then printf '%s\n' "$1"; fi; } | env -i PATH="$BIN" HOME="$TMP/home" \
    CLAUDE_HOME="$TMP/home/.claude" CODEX_HOME="$TMP/home/.codex" \
    FAKE_LOG="$LOG" FAKE_REAL="$REAL" FAKE_BIN="$BIN" FAKE_NPM_PREFIX="$TMP/npm-prefix" FAKE_FAKES="$FAKES" \
    FAKE_APT_FAILS="${FAKE_APT_FAILS:-}" \
    "$(command -v bash)" "$ROOT/scripts/install.sh" >"$TMP/out" 2>"$TMP/err" || rc=$?
}
installed_nothing() {
  [ ! -e "$TMP/home/.claude" ] && [ ! -e "$TMP/home/.codex" ] || fail "$1: skills copied despite missing prerequisites"
  ! grep -qE '^(sudo |apt-get|curl|npm install)' "$LOG" || fail "$1: install commands ran: $(cat "$LOG")"
}

# Declined (closed stdin, then "n"): every gap listed with the exact plan, nothing run or copied.
for answer in "" n; do
  farm claude codex jq
  if [ -n "$answer" ]; then run "$answer"; else run; fi
  [ "$rc" = 1 ] || fail "declined install should exit 1, got $rc"
  for tool in claude codex jq; do
    grep -q "^  - $tool: " "$TMP/err" || fail "missing $tool not reported: $(cat "$TMP/err")"
  done
  for tool in git node perl; do
    ! grep -q "^  - $tool: " "$TMP/err" || fail "present $tool reported missing"
  done
  grep -qE '^    (sudo )?apt-get update && (sudo )?apt-get install -y jq$' "$TMP/err" || fail "package plan wrong: $(cat "$TMP/err")"
  grep -qxF '    curl -fsSL https://claude.ai/install.sh | bash' "$TMP/err" || fail "claude plan missing"
  grep -qxF '    npm install -g @openai/codex' "$TMP/err" || fail "codex plan wrong (writable npm prefix needs no sudo)"
  grep -q 'Run them now? \[y/N\]' "$TMP/err" || fail "no install prompt"
  installed_nothing "declined '$answer'"
done

# Accepted: packages, Claude and Codex installed in order, then both chains, with a sign-in reminder.
farm claude codex jq; run y
[ "$rc" = 0 ] || fail "accepted install should exit 0, got $rc: $(cat "$TMP/err")"
grep -q '^apt-get install -y jq$' "$LOG" || fail "jq not installed: $(cat "$LOG")"
[ "$(grep -nE '^(apt-get install|curl|npm install)' "$LOG" | cut -d: -f2 | cut -c1-3 | tr '\n' ' ')" = "apt cur npm " ] || \
  fail "install order wrong: $(cat "$LOG")"
[ -x "$TMP/home/.local/bin/claude" ] || fail "claude installer not run"
for provider in claude codex; do
  [ -f "$TMP/home/.$provider/skills/0_chain-guide/SKILL.md" ] || fail "$provider skills not installed after accepting"
done
grep -q 'newly installed: claude codex; start each once to sign in' "$TMP/err" || fail "sign-in reminder missing"

# A failed install stops the remaining commands and copies nothing.
farm claude codex jq; FAKE_APT_FAILS=1 run y
[ "$rc" = 1 ] || fail "failed install should exit 1, got $rc"
grep -q 'install: failed: .*apt-get' "$TMP/err" || fail "failure not reported: $(cat "$TMP/err")"
! grep -qE '^(curl|npm install)' "$LOG" || fail "commands after a failure ran: $(cat "$LOG")"
grep -q 'missing prerequisites, nothing installed' "$TMP/err" || fail "remaining gaps not reported"
[ ! -e "$TMP/home/.claude" ] || fail "skills copied after a failed install"

# Node missing: never a distro package; nvm (installed first if absent) takes the current LTS,
# and Codex then installs into nvm's npm without sudo.
pin() { sed -n "s/^$1=//p" "$ROOT/scripts/requirements.sh"; } # a pinned download version
[ -n "$(pin NVM_VERSION)" ] && [ -n "$(pin SONAR_SCANNER_VERSION)" ] || fail "download pins not found in requirements.sh"
nvm_line="curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$(pin NVM_VERSION)/install.sh | bash && . $TMP/home/.nvm/nvm.sh && nvm install --lts && nvm alias default 'lts/*'"
farm codex node npm; run
grep -qxF "    $nvm_line" "$TMP/err" || fail "nvm plan wrong: $(cat "$TMP/err")"
! grep -q 'nodejs\|apt-get' "$TMP/err" || fail "node offered as a distro package"
grep -qxF '    npm install -g @openai/codex' "$TMP/err" || fail "codex via nvm npm must not need sudo"
farm codex node npm; SEED_NVM=1 run
grep -qxF "    . $TMP/home/.nvm/nvm.sh && nvm install --lts && nvm alias default 'lts/*'" "$TMP/err" || fail "existing nvm not reused: $(cat "$TMP/err")"

# Node too old: reported with its version and replaced through nvm.
farm codex; rm "$BIN/node"; cp "$FAKES/node-old" "$BIN/node"; run
grep -q '^  - node: found 18.20.0, need >= 22: install the current Node.js LTS' "$TMP/err" || fail "old node not reported: $(cat "$TMP/err")"
grep -qxF "    $nvm_line" "$TMP/err" || fail "old node not replaced through nvm"

# Accepted with node missing: nvm installs the LTS, its node goes on PATH, Codex installs with it.
farm codex node npm; run y
[ "$rc" = 0 ] || fail "nvm install should exit 0, got $rc: $(cat "$TMP/err")"
grep -q "^nvm install --lts$" "$LOG" && grep -q "^nvm alias default lts/\*$" "$LOG" || fail "nvm not driven: $(cat "$LOG")"
grep -q '^npm install -g @openai/codex$' "$LOG" && [ -x "$BIN/codex" ] || fail "codex not installed with nvm's npm: $(cat "$LOG")"
[ -f "$TMP/home/.codex/skills/0_chain-guide/SKILL.md" ] || fail "skills not installed after nvm"

# perl backs only the timeout fallback: required without timeout/gtimeout, ignored with either.
farm perl; run
grep -q '^  - perl: needed because timeout is absent' "$TMP/err" || fail "perl not required without timeout: $(cat "$TMP/err")"
grep -qE 'apt-get install -y perl$' "$TMP/err" || fail "perl not offered without timeout"
for t in timeout gtimeout; do
  farm perl; printf '#!/bin/sh\nexit 0\n' >"$BIN/$t"; chmod +x "$BIN/$t"; run
  [ "$rc" = 0 ] || fail "perl must not be required with $t: $(cat "$TMP/err")"
done

# No supported package manager: the tools it cannot install are named; the rest is still offered.
farm claude jq apt-get; run
grep -q 'cannot install automatically, install manually: jq' "$TMP/err" || fail "manual tools not named: $(cat "$TMP/err")"
grep -qxF '    curl -fsSL https://claude.ai/install.sh | bash' "$TMP/err" || fail "claude still installable without a package manager"
installed_nothing "no package manager"

# Everything present: no prompt, both chains installed with their runner, no plugin command, no warning.
farm; run
[ "$rc" = 0 ] || fail "full install should exit 0, got $rc: $(cat "$TMP/err")"
! grep -q 'Run them now' "$TMP/err" || fail "prompted with nothing missing"
for provider in claude codex; do
  [ -f "$TMP/home/.$provider/skills/0_chain-guide/SKILL.md" ] || fail "$provider skills not installed"
  [ -d "$TMP/home/.$provider/skills/5_executing/runner" ] || fail "$provider runner not installed"
done
! grep -q 'plugin' "$LOG" || fail "a fresh install must never run a plugin command (the plugin is retired): $(cat "$LOG")"
! grep -qi 'ponytail' "$TMP/out" "$TMP/err" || fail "the retired plugin is mentioned by the installer: $(cat "$TMP/err")"
! grep -q 'newly installed' "$TMP/err" || fail "sign-in reminder without new installs"

# Sonar CLIs missing (the farm never has them), offer declined: plan shown, nothing run, exit 0.
farm; run
[ "$rc" = 0 ] || fail "a declined Sonar offer must not fail the install, got $rc"
grep -qxF '    curl -o- https://raw.githubusercontent.com/SonarSource/sonarqube-cli/refs/heads/master/user-scripts/install.sh | bash' "$TMP/err" || fail "sonar plan missing: $(cat "$TMP/err")"
grep -qF "binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-$(pin SONAR_SCANNER_VERSION)-" "$TMP/err" || fail "sonar-scanner plan missing"
grep -q 'Install the Sonar CLIs now? \[y/N\]' "$TMP/err" || fail "Sonar not offered"
! grep -q 'sonar' "$LOG" || fail "Sonar commands ran without consent: $(cat "$LOG")"

# Sonar offer accepted (the only question here): both CLIs land per user, then the manual next steps.
farm; run y
[ "$rc" = 0 ] || fail "Sonar install should exit 0, got $rc: $(cat "$TMP/err")"
[ -x "$TMP/home/.local/share/sonarqube-cli/bin/sonar" ] || fail "sonar not installed: $(cat "$LOG")"
[ -x "$TMP/home/.local/bin/sonar-scanner" ] || fail "sonar-scanner link missing: $(cat "$TMP/err")"
grep -q "Sonar CLIs installed. By hand: run 'sonar auth login'" "$TMP/err" || fail "Sonar next steps missing: $(cat "$TMP/err")"
grep -qF "Sonar CLIs not on your PATH when this ran: $TMP/home/.local/share/sonarqube-cli/bin $TMP/home/.local/bin;" "$TMP/err" || fail "PATH hint missing: $(cat "$TMP/err")"

# Re-run before a new shell: the per-user installs are found, not offered again, PATH hint repeated.
farm; SEED_SONAR=1 run
! grep -q 'Install the Sonar CLIs now' "$TMP/err" || fail "Sonar offered again although installed per user"
grep -qF "Sonar CLIs not on your PATH when this ran:" "$TMP/err" || fail "PATH hint missing on re-run"

# Both Sonar CLIs present: not offered. Without unzip, the plan installs it first.
farm; for t in sonar sonar-scanner; do printf '#!/bin/sh\nexit 0\n' >"$BIN/$t"; chmod +x "$BIN/$t"; done; run
! grep -q 'Sonar' "$TMP/err" || fail "Sonar offered (or PATH hint shown) although installed on PATH"
farm unzip; run
grep -qE '^    (sudo )?apt-get update && (sudo )?apt-get install -y unzip$' "$TMP/err" || fail "unzip not planned: $(cat "$TMP/err")"

echo "test-install: ok"
