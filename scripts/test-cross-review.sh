#!/usr/bin/env bash
set -euo pipefail
export SKILLCHAIN_POLL_SECONDS=0.1 # stubs return instantly; production default stays

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/codex/skills/cross-review/scripts/cross-review.sh"
CASE="$(mktemp -d)"
trap 'rm -rf "$CASE"' EXIT

mkdir -p "$CASE/bin" "$CASE/repo/src" "$CASE/repo/specs/run"
cat >"$CASE/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "login status" ]]; then exit 0; fi
cat >"$PROMPT_CAPTURE"
if [ -n "${REVIEW_OUTPUT:-}" ]; then
  printf '%s\n' "$REVIEW_OUTPUT"
else
  printf '%s\n' '{"severity":"low","category":"review-clean","summary":"scoped review clean"}'
fi
EOF
chmod +x "$CASE/bin/codex"

cd "$CASE/repo"
git init -q
git config user.email test@example.invalid
git config user.name test
printf 'artifact\n' >artifact.md
printf 'base\n' >src/app.ts
printf 'base\n' >specs/run/progress.md
git add . && git commit -qm base
BASE_SHA="$(git rev-parse HEAD)"
printf 'changed\n' >>src/app.ts
printf '%02048d\n' 0 >>specs/run/progress.md
git add . && git commit -qm changed

run_review() {
  PATH="$CASE/bin:$PATH" PROMPT_CAPTURE="$CASE/prompt" CROSS_REVIEW_MAX_CONTEXT_BYTES="$1" \
    bash "$SCRIPT" docs 1 test --artifacts artifact.md --author-provider claude \
      --diff-base "$BASE_SHA" --round 1 "${@:2}"
}

if run_review 1000 >"$CASE/out" 2>&1; then
  echo "expected unscoped diff to exceed the context budget" >&2
  exit 1
fi
grep -q 'above configured limit 1000' "$CASE/out" || { cat "$CASE/out" >&2; exit 1; }

if run_review 200 --diff-paths src >"$CASE/out" 2>&1; then
  echo "expected scoped material plus artifact to exceed the small context budget" >&2
  exit 1
fi
grep -q 'omitted changed paths: specs/run/progress.md' "$CASE/out" || { cat "$CASE/out" >&2; exit 1; }

run_review 4000 --diff-paths src >"$CASE/out" 2>&1
grep -q 'cross-review (docs): clean' "$CASE/out"
grep -q 'Omitted from diff ground truth' "$CASE/prompt"
grep -q 'specs/run/progress.md' "$CASE/prompt"
! grep -q '^+00000000000000000000' "$CASE/prompt"

run_review 4000 --round 3 >"$CASE/out" 2>&1
for severity in medium high; do
  expected=0
  [ "$severity" != high ] || expected=3
  rc=0
  REVIEW_OUTPUT="$(printf '{"severity":"%s","category":"stale-claim","summary":"needs correction"}' "$severity")" \
    run_review 4000 --round 3 >"$CASE/out" 2>&1 || rc=$?
  [ "$rc" -eq "$expected" ] || { cat "$CASE/out" >&2; exit 1; }
  grep -q 'needs correction' "$CASE/out"
done
for round in 0 -1 1.5 01 invalid; do
  rc=0
  run_review 4000 --round "$round" >"$CASE/out" 2>&1 || rc=$?
  [ "$rc" -eq 64 ] || { cat "$CASE/out" >&2; exit 1; }
done

# Manual rounds beyond the automatic limit work before and after state exists.
run_review 4000 --round 4 >"$CASE/out" 2>&1
mkdir -p specs/PROJ-1-test
bash "$ROOT/codex/skills/5_executing/scripts/chain" state init 1 test >/dev/null
for round in 4 100; do
  run_review 4000 --round "$round" --persist >"$CASE/out" 2>&1
  [ "$(jq -r '.cross_review[-1].round' specs/PROJ-1-test/state.json)" -eq "$round" ]
done

# Degraded fallback: Codex unavailable → strongest Claude model that is not the author model; QA personas take the strongest even when it is the author.
mkdir -p "$CASE/nocodex"
printf '#!/usr/bin/env bash\nexit 1\n' >"$CASE/nocodex/codex"
cat >"$CASE/nocodex/claude" <<'EOF2'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "auth status" ]]; then exit 0; fi
while [ $# -gt 0 ]; do [ "$1" = --model ] && printf '%s\n' "$2" >>"$MODEL_CAPTURE"; shift; done
cat >/dev/null
printf '%s\n' '{"is_error":false,"structured_output":{"findings":[{"severity":"low","category":"review-clean","summary":"clean"}]}}'
EOF2
chmod +x "$CASE/nocodex/codex" "$CASE/nocodex/claude"
run_degraded() { # author_model
  : >"$CASE/models"
  PATH="$CASE/nocodex:$PATH" MODEL_CAPTURE="$CASE/models" \
    bash "$SCRIPT" docs 1 test --artifacts artifact.md --author-provider claude --author-model "$1" \
      --diff-base "$BASE_SHA" --diff-paths src --round 1 >"$CASE/out" 2>&1
  sort -u "$CASE/models"
}
[ "$(run_degraded claude-fable-5-1)" = opus ] || { cat "$CASE/out" >&2; exit 1; }
[ "$(run_degraded opus)" = fable ] || { cat "$CASE/out" >&2; exit 1; }
[ "$(CLAUDE_REVIEW_MODEL=sonnet run_degraded fable)" = sonnet ] || { cat "$CASE/out" >&2; exit 1; }
run_degraded_qa() { # author_model
  : >"$CASE/models"
  PATH="$CASE/nocodex:$PATH" MODEL_CAPTURE="$CASE/models" \
    bash "$SCRIPT" qa 1 test --artifacts artifact.md --author-provider claude --author-model "$1" --personas \
      --diff-base "$BASE_SHA" --diff-paths src --round 1 >"$CASE/out" 2>&1
  sort -u "$CASE/models"
}
[ "$(run_degraded_qa claude-fable-5-1)" = fable ] || { cat "$CASE/out" >&2; exit 1; }
[ "$(run_degraded_qa opus)" = fable ] || { cat "$CASE/out" >&2; exit 1; }

# Codex-authored QA personas: Claude unavailable -> six Codex workers, flagged degraded.
mkdir -p "$CASE/noclaude"
printf '#!/usr/bin/env bash\nexit 1\n' >"$CASE/noclaude/claude"; chmod +x "$CASE/noclaude/claude"
qa_codex() { PATH="$CASE/noclaude:$CASE/bin:$PATH" PROMPT_CAPTURE="$CASE/prompt" bash "$SCRIPT" qa 1 test --artifacts artifact.md --author-provider codex "$@"; }
qa_codex --personas >"$CASE/out" 2>&1 || { cat "$CASE/out" >&2; exit 1; }
grep -q 'opposite provider unavailable; continuing six QA personas with codex' "$CASE/out" || { cat "$CASE/out" >&2; exit 1; }
# Everything else stays fail-closed for a Codex author without Claude.
if qa_codex >"$CASE/out" 2>&1; then echo "qa without --personas must fail closed" >&2; exit 1; fi
grep -q 'Claude is required' "$CASE/out"
if PATH="$CASE/noclaude:$CASE/bin:$PATH" PROMPT_CAPTURE="$CASE/prompt" bash "$SCRIPT" docs 1 test --artifacts artifact.md --author-provider codex >"$CASE/out" 2>&1; then echo "docs review must fail closed" >&2; exit 1; fi

# Persona focus: tool-measured concerns leave the prompts only when the project configured the tool.
mkdir -p "$CASE/cap" specs/PROJ-1-test/3-4_plan
cat >"$CASE/cap/codex" <<'EOF3'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "login status" ]]; then exit 0; fi
cat >"$PERSONA_CAPTURE/$$-$RANDOM.txt"
printf '%s\n' '{"severity":"low","category":"review-clean","summary":"clean"}'
EOF3
chmod +x "$CASE/cap/codex"
persona_prompts() { # config-json -> captured persona prompts in $CASE/personas
  rm -rf "$CASE/personas"; mkdir -p "$CASE/personas"
  printf '%s\n' "$1" >specs/PROJ-1-test/3-4_plan/wave-gate-config.json
  PATH="$CASE/noclaude:$CASE/cap:$PATH" PERSONA_CAPTURE="$CASE/personas" bash "$SCRIPT" qa 1 test --artifacts artifact.md --author-provider codex --personas >"$CASE/out" 2>&1 || { cat "$CASE/out" >&2; exit 1; }
}
persona_has() { grep -l "You are $1" "$CASE"/personas/*.txt | xargs grep -c "$2" | paste -sd+ - | grep -qv '^0$'; }
persona_prompts '{}'
persona_has 'Marcus Weber' 'coupling' || { echo "default Weber focus lost" >&2; exit 1; }
! grep -rq 'machine-checked' "$CASE/personas" || { echo "unconfigured project got machine-checked text" >&2; exit 1; }
persona_prompts '{"arch_rules_cmd":"npm run arch","complexity_cmd":"npm run cx"}'
persona_has 'Marcus Weber' 'arch_rules_cmd' || { echo "Weber not told about arch_rules_cmd" >&2; exit 1; }
persona_has 'Elena Rodriguez' 'arch_rules_cmd' || { echo "Rodriguez not told about arch_rules_cmd" >&2; exit 1; }
persona_has 'Ken Takahashi' 'complexity_cmd' || { echo "Takahashi not told about complexity_cmd" >&2; exit 1; }
persona_has 'Elena Rodriguez' 'retrospective' || { echo "retrospective instruction lost" >&2; exit 1; }
rm -f specs/PROJ-1-test/3-4_plan/wave-gate-config.json

echo 'cross-review diff-scope, manual-round and degraded-model tests passed'

