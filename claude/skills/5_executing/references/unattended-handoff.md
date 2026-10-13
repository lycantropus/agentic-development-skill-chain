# Unattended handoff (P0:done → runner)

Asked once per PROJ, in the lead, after P0 is sealed. Run from `.worktree.path`
with `<X> <theme>` filled in. `scripts/test-unattended-handoff.sh` executes both
blocks against stubs.

## Probe

Prints `SKIP` (no question: the runner's own P5 lane, or any phase other than
`P0:done`) or `ASK` plus one line per prerequisite. P0's `preflight.sh` already
made `claude`, `coderabbit` and, with frontend waves, `agent-browser` hard
stops; this re-reads them from the shell the detached run will inherit.

```bash probe
S=specs/PROJ-<X>-<theme>/state.json
if [ "${SKILLCHAIN_RUNNER_MANAGED:-}" = 1 ] || [ "$(jq -r '.phase + ":" + .status' "$S" 2>/dev/null)" != P0:done ]; then
  echo SKIP
else
  echo ASK
  { command -v codex >/dev/null && codex login status >/dev/null 2>&1; } \
    && echo "codex: ok" \
    || echo "codex: missing or unauthenticated -> single-provider run, flagged in the morning report and PR body"
  for t in coderabbit agent-browser; do
    command -v "$t" >/dev/null && echo "$t: ok" || echo "$t: MISSING -> its gate step fails and parks the run"
  done
  off=; for f in ~/.claude/settings.json .claude/settings.json .claude/settings.local.json /etc/claude-code/managed-settings.json; do
    jq -e '.permissions.disableBypassPermissionsMode == "disable"' "$f" >/dev/null 2>&1 && off=1
  done
  [ -z "$off" ] && echo "permissions: ok" || echo "permissions: bypass mode disabled -> the claude lane stops at its first prompt"
  [ -x "${SKILLCHAIN_RUNNER:-runner/run-phase.sh}" ] && echo "runner: ok" \
    || echo "runner: NOT FOUND (unattended only) -> set SKILLCHAIN_RUNNER=<chain checkout>/runner/run-phase.sh, or continue interactively"
fi
```

## Launch

Detached, never a foreground Bash call: a foreground call is capped at 10 minutes
and a background call at 2 hours, and an overnight run outlives both.

```bash launch
LOG="$(mktemp --suffix=.log "${TMPDIR:-/tmp}/skillchain-auto-PROJ-<X>.XXXXXX")"
setsid nohup "${SKILLCHAIN_RUNNER:-runner/run-phase.sh}" auto <X> <theme> >"$LOG" 2>&1 </dev/null &
echo "log: $LOG  pid: $!"
```

Then print, and end the turn (the waiting session never polls):

- the log path and `pid`; stop the run with `kill -TERM -- -<pid>` (the runner kills both lane process groups)
- progress: `jq -r '.phase + ":" + .status' specs/PROJ-<X>-<theme>/state.json`, or `node <runner dir>/render-report.mjs morning specs`
- after a stop: `bash scripts/state.sh transition <X> <theme> <phase> running`, then relaunch the block above
