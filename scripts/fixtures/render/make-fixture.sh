#!/usr/bin/env bash
# Build a PROJ fixture for the renderers in an empty directory: make-fixture.sh <dir>
# Blocked at P5, degraded, retained worktree, one legacy "gap" story (shown as a plain status, never as a known gap), one deferred finding, one external prerequisite.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHAIN="bash $ROOT/claude/skills/5_executing/scripts/chain"
cd "$1"
git init -q
mkdir -p specs/PROJ-1-demo/3-4_plan specs/PROJ-1-demo/5_progress/lanes
$CHAIN state init 1 demo >/dev/null
for p in "CP1 running" "CP1 approved" "P0 running" "P0 done" "P5 running"; do $CHAIN state transition 1 demo $p >/dev/null; done
set_state() { $CHAIN state set 1 demo "$1" "$2" >/dev/null; }
set_state .summary '"Built things."'
set_state .degraded true
set_state .degraded_reason '"codex unavailable"'
set_state .waves '{"current":1,"total":2,"stories":{"PROJ-1-PRD-1-US-1":{"title":"Register","status":"complete","wave":1},"PROJ-1-PRD-1-US-2":"gap"}}'
set_state .worktree '{"path":"/nonexistent/wt","control_path":"/nonexistent/repo","branch":"proj/PROJ-1","dependency_install":"installed","database_mode":"shared","env_link_status":"linked","dev_port":3001,"cleanup_status":"retained","cleanup_reason":"ci red"}'
set_state .pr '{"number":4,"url":"https://example.invalid/pr/4","ci":"green"}'
set_state .docs_changed '["docs/A.md"]'
set_state .lanes '[{"provider":"claude","role":"writer","phase":"P5","exit_code":1,"output_file":"o.out"}]'
printf '%s\n' '{"source":"review","severity":"high","summary":"a | pipe","file":"src/a.ts"}' \
  '{"source":"review","severity":"low","summary":"low one","file":"src/b.ts"}' | $CHAIN findings add 1 demo >/dev/null
id="$(jq -r '.findings[] | select(.severity == "low") | .id' specs/PROJ-1-demo/5_progress/findings.json)"
$CHAIN findings set-status 1 demo "$id" deferred >/dev/null
cat > specs/PROJ-1-demo/3-4_plan/wave-gate-config.json <<'EOF'
{"waves":{"1":{"ac_commands":[{"id":"AC-1","cmd":"true","external_dependency":{"reason":"needs sso","decided_by":"me","decided_at":"2026","check_command":"curl x"}}]}}}
EOF
