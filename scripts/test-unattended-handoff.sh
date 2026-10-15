#!/usr/bin/env bash
# Execute the probe and launch blocks of the unattended handoff against
# PATH-shimmed stubs; no provider calls, no real runner.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="$ROOT/claude/skills/5_executing/references/unattended-handoff.md"
CASE="$(mktemp -d)"
trap 'rm -rf "$CASE"' EXIT
die() { echo "unattended-handoff: $*" >&2; exit 1; }

cmp -s "$REF" "$ROOT/codex/skills/5_executing/references/unattended-handoff.md" || die 'claude and codex copies differ'

block() { # <name> -> the fenced ```bash <name> block, placeholders filled
  awk -v n="$1" '$0 == "```bash " n { on=1; next } /^```$/ { on=0 } on' "$REF" | sed 's/<X>/1/g; s/<theme>/demo/g'
}
block probe  >"$CASE/probe.sh";  [ -s "$CASE/probe.sh" ]  || die 'probe block missing'
block launch >"$CASE/launch.sh"; [ -s "$CASE/launch.sh" ] || die 'launch block missing'

cd "$CASE"
STATE="$ROOT/claude/skills/5_executing/scripts/chain state"
mkdir -p specs/PROJ-1-demo
bash $STATE init 1 demo >/dev/null
for p in "CP1 running" "CP1 approved" "P0 running" "P0 done"; do bash $STATE transition 1 demo $p >/dev/null; done
jq -e '.phase == "P0" and .status == "done"' specs/PROJ-1-demo/state.json >/dev/null || die 'fixture must sit at P0:done'

# Stubs: codex authenticated, runner records how it was started.
mkdir -p bin runner
for t in codex; do printf '#!/bin/sh\nexit 0\n' >"bin/$t"; done
cat >runner/run-phase.sh <<'STUB'
#!/usr/bin/env bash
echo "args: $*"; echo "pgid: $(ps -o pgid= $$ | tr -d ' ')"; echo "stdin: $(readlink /proc/$$/fd/0)"
sleep 3; echo finished
STUB
chmod +x bin/* runner/run-phase.sh
export PATH="$CASE/bin:$PATH" HOME="$CASE"   # HOME: no user settings leak in
unset SKILLCHAIN_RUNNER_MANAGED SKILLCHAIN_RUNNER || true

# 1. P0:done, not runner-managed -> exactly one ASK with all-ok prerequisites.
out="$(bash probe.sh 2>&1)" || die 'probe failed'
[ "$(printf '%s\n' "$out" | grep -c '^ASK$')" = 1 ] || die "expected exactly one ASK, got: $out"
[ "$(printf '%s\n' "$out" | grep -c -E '^(SKIP)$')" = 0 ] || die 'ASK and SKIP together'
for l in 'codex: ok' 'permissions: ok' 'runner: ok'; do
  printf '%s\n' "$out" | grep -qx "$l" || die "missing prerequisite line '$l' in: $out"
done

# 2. runner-managed lane -> SKIP, no question, no prerequisite lines.
out="$(SKILLCHAIN_RUNNER_MANAGED=1 bash probe.sh 2>&1)"
[ "$out" = SKIP ] || die "SKILLCHAIN_RUNNER_MANAGED=1 must print only SKIP, got: $out"

# 3. any phase other than P0:done (resume) -> SKIP.
bash $STATE transition 1 demo P5 running >/dev/null
out="$(bash probe.sh 2>&1)"; [ "$out" = SKIP ] || die "P5:running must SKIP, got: $out"
rm -f specs/PROJ-1-demo/state.json
out="$(bash probe.sh 2>&1)"; [ "$out" = SKIP ] || die "no state.json must SKIP, got: $out"

# 4. Missing prerequisites are named and still ASK (the user decides).
mkdir -p specs/PROJ-1-demo && bash $STATE init 1 demo >/dev/null
for p in "CP1 running" "CP1 approved" "P0 running" "P0 done"; do bash $STATE transition 1 demo $p >/dev/null; done
rm runner/run-phase.sh
mkdir bin2; ln -s "$(command -v jq)" bin2/jq   # PATH with only jq: codex absent
mkdir -p .claude; echo '{"permissions":{"disableBypassPermissionsMode":"disable"}}' >.claude/settings.json
out="$(PATH="$CASE/bin2" "$BASH" probe.sh 2>&1)"
for l in '^ASK$' '^codex: missing' '^permissions: bypass mode disabled' '^runner: NOT FOUND'; do
  printf '%s\n' "$out" | grep -q "$l" || die "degraded probe lacks '$l' in: $out"
done
rm -f .claude/settings.json

# 5. Launch: returns before the runner finishes, detached (own session), stdin /dev/null, output in the log.
cat >runner/run-phase.sh <<'STUB'
#!/usr/bin/env bash
echo "args: $*"; echo "pgid: $(ps -o pgid= $$ | tr -d ' ')"; echo "stdin: $(readlink /proc/$$/fd/0)"
sleep 3; echo finished
STUB
chmod +x runner/run-phase.sh
export TMPDIR="$CASE"
start=$SECONDS
launched="$(bash launch.sh)"
[ $((SECONDS - start)) -lt 2 ] || die 'launch blocked until the runner finished (not detached)'
LOG="$(printf '%s\n' "$launched" | sed -n 's/^log: \(.*\)  pid: [0-9]*$/\1/p')"
case "$LOG" in "$CASE"/skillchain-auto-PROJ-1.*) ;; *) die "launch must print a private log path and pid, got: $launched" ;; esac
pid="$(printf '%s\n' "$launched" | sed -n 's/.*pid: \([0-9]*\).*/\1/p')"
for _ in $(seq 1 20); do grep -q '^stdin:' "$LOG" 2>/dev/null && break; sleep 0.2; done
grep -qx 'args: auto 1 demo' "$LOG" || die "runner not started as 'auto 1 demo': $(cat "$LOG")"
grep -qx 'stdin: /dev/null' "$LOG" || die 'runner stdin must be /dev/null'
[ "$(sed -n 's/^pgid: //p' "$LOG")" = "$pid" ] || die 'runner must lead its own process group (setsid), pgid != pid'
[ "$pid" != "$$" ] && [ "$(sed -n 's/^pgid: //p' "$LOG")" != "$(ps -o pgid= $$ | tr -d ' ')" ] || die 'runner shares the caller process group'
for _ in $(seq 1 30); do grep -qx finished "$LOG" && break; sleep 0.2; done
grep -qx finished "$LOG" || die 'detached runner did not run to completion'

# 6. Installers ship the runner next to its skill, and the probe finds that copy without ./runner
#    or SKILLCHAIN_RUNNER (HOME is the sandbox, so ~/.claude/skills is the installed tree).
rm -rf runner
out="$(bash probe.sh 2>&1)"; printf '%s\n' "$out" | grep -q '^runner: NOT FOUND' || die "no runner anywhere must report NOT FOUND: $out"
CLAUDE_HOME="$CASE/.claude" bash "$ROOT/scripts/install-claude.sh" >/dev/null
CODEX_HOME="$CASE/codexhome" bash "$ROOT/scripts/install-codex.sh" >/dev/null
for h in "$CASE/.claude" "$CASE/codexhome"; do
  [ -x "$h/skills/5_executing/runner/run-phase.sh" ] \
    && [ -d "$h/skills/5_executing/runner/prompts" ] || die "installer must ship the runner into $h"
  ls "$h"/skills/5_executing/runner/spike-*.sh >/dev/null 2>&1 && die 'spikes are dev-only and must not be installed'
done
out="$(bash probe.sh 2>&1)"; printf '%s\n' "$out" | grep -qx 'runner: ok' || die "installed runner must be found: $out"
# The runner finds its helpers in both layouts (chain checkout and installed copy), outside any project scripts/.
eval "$(sed -n '/^skill_file() {/,/^}/p' "$ROOT/runner/run-phase.sh")"
for RUNNER_DIR in "$ROOT/runner" "$CASE/.claude/skills/5_executing/runner" "$CASE/codexhome/skills/5_executing/runner"; do
  for f in "5_executing scripts/chain" "5_executing scripts/state.sh" "5_executing scripts/worktree.sh" "6_qa scripts/findings.mjs" "6_qa scripts/findings-store.mjs" "7_documentation scripts/curation.sh" "8_delivery scripts/delivery.sh"; do
    [ -f "$(skill_file $f)" ] || die "runner at $RUNNER_DIR cannot resolve helper: $f"
  done
done
mkdir "$CASE/empty" && (cd "$CASE/empty" && bash "$CASE/.claude/skills/5_executing/runner/run-phase.sh" P5 1 demo 2>&1 | grep -q 'chain not found') && die 'installed runner must find chain in the skill tree'
echo "unattended-handoff: ok"
