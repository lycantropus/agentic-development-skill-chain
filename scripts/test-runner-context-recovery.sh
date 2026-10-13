#!/usr/bin/env bash
# Execute the rendered recovery instructions; no provider calls required.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/codex/skills/5_executing"
CASE="$(mktemp -d)"
trap 'rm -rf "$CASE"' EXIT
die() { echo "runner-context-recovery: $*" >&2; exit 1; }
cd "$CASE"
BASE="specs/PROJ-1-demo"
mkdir -p "$BASE/3-4_plan" "$BASE/5_progress/lanes" scripts templates/roles
cp "$SKILL/scripts/compile-context-bundles.mjs" "$SKILL/scripts/state.sh" scripts/
cp "$SKILL/manifests/roles/backend-implementer.md" templates/roles/
bash scripts/state.sh init 1 demo >/dev/null
node --input-type=module <<'JS'
import { writeFileSync } from 'node:fs';
const p = 'specs/PROJ-1-demo/3-4_plan/';
writeFileSync(p + 'PROJ-1-architecture.md', '# Architecture\n\n## Cross-Cutting Tech Decisions\n' +
  [1, 2].map(n => `### Decision ${n}: Wave ${n} rule\n**Affects:** PRD-${n}\n**Summary:** ${'Required rule. '.repeat(1200)}\n`).join('\n'));
for (const n of [1, 2]) writeFileSync(p + `PROJ-1-wave-${n}-plan.md`, `# Wave ${n}\n\n**PRDs involved:** PROJ-1-PRD-${n}\n`);
JS
compile() { node scripts/compile-context-bundles.mjs compile 1 demo "$@" >/dev/null; }
# Both waves fit alone, but a merged compile blocks the role.
compile --wave all >"$CASE/unscoped.out" 2>&1
jq -e 'length == 1' "$BASE/context/blocked-roles.json" >/dev/null || die 'fixture must breach the unscoped budget'
compile --wave 1
jq -e '."backend-implementer".wave == 1' "$BASE/context/bundles.lock.json" >/dev/null || die 'wave 1 must fit'
PHASE=P5 PROJ=1 THEME=demo STATE_SH=scripts/state.sh
LANE_DIR="$BASE/5_progress/lanes" RUNNER_DIR="$ROOT/runner"
# Loading only this function avoids runner/provider side effects.
eval "$(sed -n '/^render_prompt() {/,/^}/p' "$ROOT/runner/run-phase.sh")"
render_prompt writer 'Run P5.' prompt

recover() {
  awk '/^```bash$/ { block=1; next } /^```$/ { block=0 } block' "$prompt" >"$CASE/recover.sh"
  [ -s "$CASE/recover.sh" ] || die 'rendered recovery command missing'
  bash "$CASE/recover.sh"
}

# P5 advances after prompt creation; recovery must use the latest wave scope.
compile --wave 2
jq -e '."backend-implementer".wave == 2' "$BASE/context/bundles.lock.json" >/dev/null || die 'wave 2 must fit'
rm "$BASE/context/bundle-backend-implementer.codex.md"
recover >"$CASE/recovery.out" 2>&1 || { cat "$CASE/recovery.out" >&2; die 'wave-scoped recovery failed'; }
jq -e '."backend-implementer".wave == 2' "$BASE/context/bundles.lock.json" >/dev/null || die 'recovery lost the current wave'
grep -q 'Decision 2:' "$BASE/context/bundle-backend-implementer.md" || die 'current wave decision missing'
grep -q 'Decision 1:' "$BASE/context/bundle-backend-implementer.md" && die 'unrelated decision leaked'
jq -e --slurpfile lock "$BASE/context/bundles.lock.json" '.context.bundles == $lock[0]' "$BASE/state.json" >/dev/null || die 'regenerated lock not recorded through state.sh'

# Intentional unscoped legacy locks remain compatible when their context fits.
sed -i 's/^\*\*Summary:\*\*.*/**Summary:** A short rule./' "$BASE/3-4_plan/PROJ-1-architecture.md"
compile --wave all
recover >/dev/null
jq -e '."backend-implementer".wave == null' "$BASE/context/bundles.lock.json" >/dev/null || die 'legacy scope changed'

# Unknown scope must stop before mutating the context or recorded state.
cp "$BASE/context/bundles.lock.json" "$CASE/lock.bak"
rm "$BASE/context/bundles.lock.json"
render_prompt writer 'Run P5 without a lock.' prompt
if recover >"$CASE/missing.out" 2>&1; then die 'missing lock guessed a wave'; fi
[ ! -e "$BASE/context/bundles.lock.json" ] || die 'missing lock recovery wrote context'
cp "$CASE/lock.bak" "$BASE/context/bundles.lock.json"
jq '. + {"other-role": {wave: 2}}' "$BASE/context/bundles.lock.json" >"$CASE/mixed.json"
cp "$CASE/mixed.json" "$BASE/context/bundles.lock.json"
if recover >"$CASE/mixed.out" 2>&1; then die 'mixed lock scope accepted'; fi
cmp "$CASE/mixed.json" "$BASE/context/bundles.lock.json" || die 'mixed scope recovery wrote context'

# P6: the finder's text output is stored by the runner and recorded in state.
eval "$(sed -n '/^store_finder_report() {/,/^}/p' "$ROOT/runner/run-phase.sh")"
printf '%s\n' '{"source":"qa","severity":"low","summary":"x"}' '## QA Results' 'AC-1 PASS' >"$CASE/finder.out"
store_finder_report "$CASE/finder.out" 20261013-000000
report="$BASE/5_progress/qa-finder-20261013-000000.md"
grep -q 'AC-1 PASS' "$report" || die 'finder report missing its text'
grep -q '^{' "$report" && die 'finder report kept a JSON finding line'
[ "$(bash scripts/state.sh get 1 demo .qa.finder_report)" = "$report" ] || die 'finder report path not recorded in state'
echo 'runner-context-recovery: ok'
