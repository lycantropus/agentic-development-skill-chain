#!/usr/bin/env bash
# Worker context without lock or recovery: the wave comes from the plan file
# name, each wave compiles on its own, a rerun is idempotent and never touches
# state.json. P6: the runner stores the finder report. No provider calls.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/codex/skills/5_executing"
CASE="$(mktemp -d)"
trap 'rm -rf "$CASE"' EXIT
die() { echo "runner-context-recovery: $*" >&2; exit 1; }
cd "$CASE"
BASE="specs/PROJ-1-demo"
mkdir -p "$BASE/3-4_plan" "$BASE/5_progress/lanes" scripts templates/roles
cp "$SKILL/scripts/compile-context-bundles.mjs" "$SKILL/scripts/story-slice.mjs" "$SKILL/scripts/validate-wave-plan.mjs" "$SKILL/scripts/state.sh" scripts/
cp "$SKILL/manifests/roles/backend-implementer.md" templates/roles/
bash scripts/state.sh init 1 demo >/dev/null
node --input-type=module <<'JS'
import { writeFileSync } from 'node:fs';
const p = 'specs/PROJ-1-demo/3-4_plan/';
writeFileSync(p + 'PROJ-1-architecture.md', '# Architecture\n\n## Cross-Cutting Tech Decisions\n' +
  [1, 2].map(n => `### Decision ${n}: Wave ${n} rule\n**Affects:** PRD-${n}\n**Summary:** ${'Required rule. '.repeat(1200)}\n`).join('\n'));
for (const n of [1, 2]) writeFileSync(p + `PROJ-1-wave-${n}-plan.md`, `# Wave ${n}\n\n**PRDs involved:** PROJ-1-PRD-${n}\n\n` +
  `## User Stories in this Wave\n\n| US ID | Scope | Agent Type | Complexity | Can start when |\n|---|---|---|---|---|\n` +
  `| PROJ-1-PRD-${n}-US-1 | backend | backend-implementer | sonnet | immediately |\n\n## PROJ-1-PRD-${n}-US-1: Story ${n}\n`);
JS
compile() { node scripts/compile-context-bundles.mjs compile 1 demo "$@" >/dev/null; }
snap() { find "$BASE/context" -type f | sort | xargs sha256sum; }
cp "$BASE/state.json" "$CASE/state.before"
# Both waves fit alone; a merged view would breach the budget, so this only
# passes while every wave compiles on its own.
compile || die 'per-wave compile failed (merged view?)'
W1="$BASE/context/workers/wave-1/PROJ-1-PRD-1-US-1.md"
W2="$BASE/context/workers/wave-2/PROJ-1-PRD-2-US-1.md"
grep -q 'Decision 1:' "$W1" && ! grep -q 'Decision 2:' "$W1" || die 'wave 1 must hold only its decision'
grep -q 'Decision 2:' "$W2" && ! grep -q 'Decision 1:' "$W2" || die 'wave 2 must hold only its decision'
head -1 "$W2" | grep -qF '· wave 2' || die 'wave not taken from the plan file name'
[ ! -e "$BASE/context/bundles.lock.json" ] || die 'compile wrote a lock'
cmp "$CASE/state.before" "$BASE/state.json" || die 'compile touched state.json'
# Rerun is idempotent (the recovery is: run compile again).
snap >"$CASE/first.snap"
compile
snap | cmp - "$CASE/first.snap" || die 'rerun changed the context'
# The plan file name is the wave: renaming wave 2 to wave 3 moves its files.
mv "$BASE/3-4_plan/PROJ-1-wave-2-plan.md" "$BASE/3-4_plan/PROJ-1-wave-3-plan.md"
compile
[ -e "$BASE/context/workers/wave-3/PROJ-1-PRD-2-US-1.md" ] || die 'wave-3 file missing after rename'
[ ! -e "$BASE/context/workers/wave-2" ] || die 'wave-2 directory survived without a plan'
PROJ=1 THEME=demo STATE_SH=scripts/state.sh

# The prompt the runner renders for a P5/P7 writer lane names the worker files
# by path and no longer mentions hook, projection, hashes or a lock.
(
  PHASE=P5 LANE_DIR="$BASE/5_progress/lanes" RUNNER_DIR="$ROOT/runner"
  # Loading only this function avoids runner/provider side effects.
  eval "$(sed -n '/^render_prompt() {/,/^}/p' "$ROOT/runner/run-phase.sh")"
  render_prompt writer 'Run P5.' prompt
  [ "$prompt" = "$LANE_DIR/P5-writer-prompt.md" ] || die "render_prompt wrote to an unexpected path: $prompt"
  for want in "## Worker context files" "\`$BASE/context/\`" 'workers/wave-<N>/<US-ID>.md' 'roles/wave-<N>/<role>.md' \
              "node scripts/compile-context-bundles.mjs compile $PROJ $THEME --wave <N>" 'Brief: <US-ID>'; do
    grep -qF -- "$want" "$prompt" || die "writer prompt lacks: $want"
  done
  # the pointer matches the real layout compile produced above
  [ -e "$BASE/context/workers/wave-1/PROJ-1-PRD-1-US-1.md" ] && [ -e "$BASE/context/roles/wave-1/backend-implementer.md" ] \
    || die "prompt points at a layout compile did not produce"
  if grep -qiE 'SubagentStart|hook|projection|hash|bundles\.lock|\.context\.bundles|bundle-|\block\b|stale' "$prompt"; then
    grep -niE 'SubagentStart|hook|projection|hash|bundles\.lock|\.context\.bundles|bundle-|\block\b|stale' "$prompt" >&2
    die 'writer prompt still talks about hook, projection, hash or lock'
  fi
  PHASE=P7 render_prompt writer 'Run P7.' p7
  grep -qF '## Worker context files' "$p7" || die 'P7 writer prompt lacks the worker context section'
  render_prompt peer 'Review P5.' peer
  grep -qF 'Worker context files' "$peer" && die 'a peer lane must not get the worker context section'
  PHASE=P6 render_prompt writer 'Run P6.' p6
  grep -qF 'Worker context files' "$p6" && die 'only P5/P7 writer lanes get the worker context section'
  exit 0
) || exit 1

# An older run's state.json with .context.bundles stays valid: state.sh (the
# schema mirror) accepts it, and the schema keeps the field, only deprecated.
bash scripts/state.sh set 1 demo .context.bundles \
  '{"implementer":{"hash":"a1","claude_hash":"b2","codex_hash":"c3","tokens":900,"wave":1,"compiled_at":"2026-01-01T00:00:00Z"}}' >/dev/null \
  || die 'state.sh rejected an old .context.bundles record'
jq -e '.properties.context | (has("additionalProperties") | not) and .properties.bundles.deprecated == true
  and .properties.bundles.additionalProperties.required == ["hash"]' "$ROOT/runner/schemas/state.schema.json" >/dev/null \
  || die 'state.schema.json must keep .context.bundles (deprecated) and an open .context'

# P6: the finder's text output is stored by the runner and recorded in state.
eval "$(sed -n '/^store_finder_report() {/,/^}/p' "$ROOT/runner/run-phase.sh")"
printf '%s\n' '{"source":"qa","severity":"low","summary":"x"}' '## QA Results' 'AC-1 PASS' >"$CASE/finder.out"
store_finder_report "$CASE/finder.out" 20261013-000000
report="$BASE/5_progress/qa-finder-20261013-000000.md"
grep -q 'AC-1 PASS' "$report" || die 'finder report missing its text'
grep -q '^{' "$report" && die 'finder report kept a JSON finding line'
[ "$(bash scripts/state.sh get 1 demo .qa.finder_report)" = "$report" ] || die 'finder report path not recorded in state'
echo 'runner-context-recovery: ok'
