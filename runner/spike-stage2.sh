#!/usr/bin/env bash
# spike-stage2.sh — Stage 2 verification spike / release gate (CONCEPT.md §10.2).
#
# Proves, on disposable fixtures (the context compiler moved to
# scripts/test-compile-context-bundles.sh, the P7 runner gate to
# scripts/test-p7-runner-gate.sh):
#   cross-review       — symmetric deterministic routing via PATH-shimmed CLIs
#                        (opposite provider, six-persona parity, auth preflight,
#                        structured output, ledger attribution, protocol controls,
#                        manual rounds, same-model refusal), process-group timeout,
#                        LIVE adapter smoke per available direction (+ degraded
#                        model-opposite fallback), degraded flag in the morning report
#
# Usage: spike-stage2.sh [--skip-live]   (--skip-live: no real LLM calls)
# Exit:  0 all assertions passed · 1 any assertion failed
set -uo pipefail

SKIP_LIVE=0
[ "${1:-}" = "--skip-live" ] && SKIP_LIVE=1

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SPIKE_DIR/.." && pwd)"
SKILLS="$REPO_ROOT/claude/skills"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $*"; FAIL=$((FAIL+1)); }
step() { echo "→ $*"; }

# =============================================================================
# Fixture repo: intake-style baseline + one PROJ, framework scripts installed
# =============================================================================
FIX="$WORK/repo"
mkdir -p "$FIX"/{docs,src/feature,scripts,templates/roles,specs/PROJ-96-stage2/2_PRDs,specs/PROJ-96-stage2/5_progress}
cd "$FIX"
git init -q -b main; git config user.email spike@local; git config user.name spike

printf '# Product\nA queue-backed task app.\n' > docs/PRODUCT.md
printf '# Architecture\nsrc/queue.js implements exponential backoff with a dead-letter queue for failed events.\n' > docs/ARCHITECTURE.md
printf '# Guidelines\n- errors via Result type\n' > docs/GUIDELINES.md
printf '# Design system\n- token: --color-primary\n' > docs/DESIGN-SYSTEM.md
printf '# Components\n- Button\n' > docs/components.md
printf '# Security baseline\n- no secrets in code\n' > docs/security-baseline.md
printf '# Test conventions\n- vitest\n' > docs/test-conventions.md
printf '# Rules\n- rule 1\n' > AGENTS.md
printf '// retry forever, NO backoff, NO dead-letter handling\nmodule.exports = () => {};\n' > src/queue.js
printf '# PRD\nNEVER-INJECT-MARKER-PRD full requirement text.\n' > specs/PROJ-96-stage2/2_PRDs/PROJ-96-PRD-1.md
printf '# Progress\nNEVER-INJECT-MARKER-PROGRESS wave log.\n' > specs/PROJ-96-stage2/5_progress/PROJ-96-progress.md
printf '## Wave 1 — queue API\nPOST /enqueue\n' > specs/PROJ-96-stage2/api-contracts.md
printf '# Ground file\nAssumption: node 22.\n' > specs/PROJ-96-stage2/ground-file.md
mkdir -p specs/PROJ-96-stage2/3-4_plan
cat > specs/PROJ-96-stage2/3-4_plan/PROJ-96-wave-1-plan.md <<'EOF'
# Wave 1

**PRDs involved:** PROJ-96-PRD-1

## User Stories in this Wave

| US ID | Scope | Agent Type | Complexity | Can start when |
|---|---|---|---|---|
| PROJ-96-PRD-1-US-1 | frontend | frontend-implementer | sonnet | immediately |
| PROJ-96-PRD-1-US-2 | backend | backend-implementer | sonnet | immediately |

## PROJ-96-PRD-1-US-1: Queue view
**Scope:** frontend → frontend-implementer

## PROJ-96-PRD-1-US-2: Queue API
**Scope:** backend → backend-implementer
EOF
mkdir -p specs/intake
printf '# Bootstrap decisions\n\n- D-BOOTSTRAP-01 · Point: error convention · Decision: adopt\n' > specs/intake/decisions.md

for s in 5_executing/scripts/chain 5_executing/scripts/render.mjs 5_executing/scripts/state.sh 5_executing/scripts/plan.mjs \
         5_executing/scripts/ponytail-check.sh \
         6_qa/scripts/findings.mjs 7_documentation/scripts/curation.sh \
         cross-review/scripts/cross-review.sh cross-review/scripts/review-with-claude.sh \
         cross-review/scripts/review-with-codex.sh; do
  cp "$SKILLS/$s" scripts/
done
mkdir -p templates
cp "$SKILLS/cross-review/templates/cross-review-prompt.md.tmpl" "$SKILLS"/5_executing/templates/{morning,stop}-report.md.tmpl templates/
cp "$SKILLS"/5_executing/manifests/roles/*.md templates/roles/
chmod +x scripts/*.sh scripts/chain
git add -A; git commit -qm base
BASE_SHA="$(git rev-parse HEAD)"

bash scripts/chain state init 96 stage2 >/dev/null
bash scripts/chain state set 96 stage2 .base_sha "\"$BASE_SHA\"" >/dev/null

# =============================================================================
step "cross-review mechanics (PATH-shimmed CLIs, deterministic)"
# =============================================================================
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/claude" <<'EOF'
#!/bin/sh
[ "${1:-}" != auth ] || { [ "${CLAUDE_AUTH_FAIL:-0}" -eq 0 ]; exit; }
[ -z "${QA_STUB_LOG:-}" ] || printf 'claude\n' >> "$QA_STUB_LOG"
input="$(cat)"
case "$input" in
  *"## Artifact under review:"*) ;;
  *) exit 9 ;;
esac
if [ "${REQUIREMENTS_STUB:-0}" -eq 1 ]; then
  case "$input" in
    *"Testability:"*"Cross-PRD consistency:"*) ;;
    *) exit 10 ;;
  esac
fi
severity="${CLAUDE_STUB_SEVERITY:-high}"
category="${CLAUDE_STUB_CATEGORY:-claude-stale-claim}"
printf '{"is_error":false,"structured_output":{"findings":[{"severity":"%s","category":"%s","file":"docs/ARCHITECTURE.md","line":2,"summary":"stub claude finding"}]}}\n' "$severity" "$category"
EOF
cat > "$STUB/codex" <<'EOF'
#!/bin/sh
[ "$1" = "login" ] && exit 0
[ -z "${QA_STUB_LOG:-}" ] || printf 'codex\n' >> "$QA_STUB_LOG"
input="$(cat)"
case "$input" in
  *"## Artifact under review: docs/ARCHITECTURE.md"*) ;;
  *) exit 9 ;;
esac
echo '{"severity":"medium","category":"stale-claim","file":"docs/ARCHITECTURE.md","line":2,"summary":"stub codex finding"}'
EOF
chmod +x "$STUB/claude" "$STUB/codex"
bash scripts/chain state set 96 stage2 .authorship '{"docs-delta":{"author_provider":"claude","author_model":"opus"},"codex-delta":{"author_provider":"codex","author_model":"gpt-5.6"}}' >/dev/null
PATH="$STUB:$PATH" bash scripts/chain review docs 96 stage2 --artifacts docs/ARCHITECTURE.md --author-key docs-delta --round 1 >/dev/null 2>&1
RC=$?
XRP="$(jq -r '.cross_review[-1].reviewer_provider' specs/PROJ-96-stage2/state.json 2>/dev/null)"
[ "$RC" -eq 0 ] && [ "$XRP" = "codex" ] && ok "claude-authored -> codex reviews; round recorded in state" || bad "routing rc=$RC reviewer=$XRP"
LED="$(jq -r '[.findings[] | select((.source == "cross-review") and .provider == "codex")] | length' specs/PROJ-96-stage2/findings.json 2>/dev/null)"
[ "${LED:-0}" -ge 1 ] && ok "finding landed in the ledger: source=cross-review, provider attributed" || bad "ledger has no attributed cross-review finding"
# Mirror the normal persistent route: Codex-authored material must reach an
# authenticated Claude reviewer, be provider-stamped, and land in state/ledger.
PATH="$STUB:$PATH" CLAUDE_STUB_SEVERITY=medium bash scripts/chain review docs 96 stage2 --artifacts docs/ARCHITECTURE.md --author-key codex-delta --round 1 >/dev/null 2>&1
RC=$?
XRP="$(jq -r '.cross_review[-1].reviewer_provider' specs/PROJ-96-stage2/state.json 2>/dev/null)"
LED="$(jq -r '[.findings[] | select((.source == "cross-review") and .provider == "claude")] | length' specs/PROJ-96-stage2/findings.json 2>/dev/null)"
[ "$RC" -eq 0 ] && [ "$XRP" = "claude" ] && [ "${LED:-0}" -ge 1 ] \
  && ok "codex-authored -> authenticated Claude review is recorded and ingested" \
  || bad "Codex->Claude persistent routing rc=$RC reviewer=$XRP ledger=$LED"
# Codex QA must start six separate Claude persona workers, not one simulated
# panel. Authentication probes are excluded from the worker count.
QA_CLAUDE_LOG="$WORK/qa-claude-personas.log"
PATH="$STUB:$PATH" QA_STUB_LOG="$QA_CLAUDE_LOG" CLAUDE_STUB_SEVERITY=medium \
  bash scripts/chain review qa 96 stage2 --artifacts docs/ARCHITECTURE.md \
  --author-provider codex --persist --personas --round 1 >/dev/null 2>&1
RC=$?
QA_XR="$(jq -r '.cross_review[-1] | .mode + ":" + .reviewer_provider' specs/PROJ-96-stage2/state.json 2>/dev/null)"
[ "$RC" -eq 0 ] && [ "$QA_XR" = "qa:claude" ] && [ "$(wc -l < "$QA_CLAUDE_LOG" | tr -d ' ')" -eq 6 ] \
  && ok "Codex QA starts six separate Claude personas and records the review" \
  || bad "Codex QA persona routing rc=$RC record=$QA_XR workers=$(wc -l < "$QA_CLAUDE_LOG" | tr -d ' ')"
# A Codex-authored run has no same-provider fallback. Fail before rendering or
# invoking a reviewer when Claude authentication is unavailable.
CLAUDE_AUTH_OUT="$WORK/claude-auth-fail.out"
PATH="$STUB:$PATH" CLAUDE_AUTH_FAIL=1 bash scripts/chain review docs 97 pre-p0 \
  --artifacts docs/ARCHITECTURE.md --author-provider codex >"$CLAUDE_AUTH_OUT" 2>&1
RC=$?
[ "$RC" -eq 1 ] && grep -q 'Claude is required.*unavailable or unauthenticated' "$CLAUDE_AUTH_OUT" \
  && ok "Codex->Claude fails early and clearly when Claude auth is unavailable" \
  || bad "Claude auth preflight did not fail closed (rc=$RC)"
# QA evidence authored in Claude gets six *separate* Codex persona workers.
# They must not be one prompt that merely names six personas.
QA_LOG="$WORK/qa-personas.log"
PATH="$STUB:$PATH" QA_STUB_LOG="$QA_LOG" bash scripts/chain review qa 96 stage2 --artifacts docs/ARCHITECTURE.md --author-provider claude --persist --personas --round 1 >/dev/null 2>&1
RC=$?
QA_XR="$(jq -r '.cross_review[-1] | .mode + ":" + .reviewer_provider' specs/PROJ-96-stage2/state.json 2>/dev/null)"
[ "$RC" -eq 0 ] && [ "$QA_XR" = "qa:codex" ] && [ "$(wc -l < "$QA_LOG" | tr -d ' ')" -eq 6 ] \
  && ok "Claude QA starts six separate Codex personas and records the review" \
  || bad "Claude QA persona routing rc=$RC record=$QA_XR workers=$(wc -l < "$QA_LOG" | tr -d ' ')"
printf '#!/bin/sh\nexit 1\n' > "$STUB/codex"; chmod +x "$STUB/codex"
QA_FALLBACK_LOG="$WORK/qa-fallback-personas.log"; QA_FALLBACK_OUT="$WORK/qa-fallback.out"
PATH="$STUB:$PATH" QA_STUB_LOG="$QA_FALLBACK_LOG" bash scripts/chain review qa 96 stage2 --artifacts docs/ARCHITECTURE.md --author-provider claude --persist --personas >"$QA_FALLBACK_OUT" 2>&1
RC=$?
QA_FALLBACK="$(jq -r '.cross_review[-1] | .reviewer_provider + ":" + (.degraded_fallback | tostring)' specs/PROJ-96-stage2/state.json 2>/dev/null)"
[ "$RC" -eq 3 ] && [ "$QA_FALLBACK" = "claude:true" ] && [ "$(wc -l < "$QA_FALLBACK_LOG" | tr -d ' ')" -eq 6 ] \
  && grep -q 'opposite provider unavailable; continuing six QA personas with claude' "$QA_FALLBACK_OUT" \
  && ok "missing Codex -> six Claude personas, recorded degraded fallback and visible warning" \
  || bad "Codex fallback wrong rc=$RC record=$QA_FALLBACK workers=$(wc -l < "$QA_FALLBACK_LOG" | tr -d ' ')"
# Restore the successful adapter stub for the remaining protocol controls.
cat > "$STUB/codex" <<'EOF'
#!/bin/sh
[ "$1" = "login" ] && exit 0
echo '{"severity":"medium","category":"stale-claim","file":"docs/ARCHITECTURE.md","line":2,"summary":"stub codex finding"}'
EOF
chmod +x "$STUB/codex"
# Before P0 there is no state.json. An explicit author must route the review,
# embed its input, and report findings only to the human (stdout).
OUT="$(PATH="$STUB:$PATH" bash scripts/chain review concept 97 pre-p0 --artifacts docs/ARCHITECTURE.md --author-provider claude 2>/dev/null)"
RC=$?
printf '%s\n' "$OUT" | jq -e 'select(.provider == "codex" and .source == "cross-review")' >/dev/null 2>&1 \
  && [ "$RC" -eq 0 ] && [ ! -e specs/PROJ-97-pre-p0/findings.json ] \
  && ok "pre-P0 explicit author reports to human without state.json or ledger" \
  || bad "pre-P0 explicit-author path failed (rc=$RC)"
# Requirements is a first-class pre-P0 mode. A prompt above the former 128 KiB
# default must stream to Claude through stdin; an explicitly configured cap
# remains enforceable.
awk 'BEGIN { for (i = 0; i < 150000; i++) printf "x" }' > docs/large-requirements.md
REQUIREMENTS_STUB=1 PATH="$STUB:$PATH" bash scripts/chain review requirements 97 pre-p0 \
  --artifacts docs/large-requirements.md --author-provider codex >/dev/null 2>&1
RC=$?
[ "$RC" -eq 3 ] \
  && ok "requirements mode streams >128 KiB to Claude without an artificial default cap" \
  || bad "large requirements review failed before provider review (rc=$RC)"
CROSS_REVIEW_MAX_CONTEXT_BYTES=1024 PATH="$STUB:$PATH" \
  bash scripts/chain review requirements 97 pre-p0 \
  --artifacts docs/large-requirements.md --author-provider codex >/dev/null 2>&1
[ $? -eq 1 ] && ok "explicit cross-review context cap remains enforceable" \
  || bad "explicit cross-review context cap was ignored"
PATH="$STUB:$PATH" bash scripts/chain review docs 96 stage2 --artifacts docs/ARCHITECTURE.md --author-key docs-delta --round 3 >/dev/null 2>&1
RC=$?
{ [ "$RC" -eq 0 ] || [ "$RC" -eq 3 ]; } && [ "$(jq -r '.cross_review[-1].round' specs/PROJ-96-stage2/state.json)" -eq 3 ] \
  && ok "round 3 runs and is persisted" || bad "round 3 failed (rc=$RC)"
PATH="$STUB:$PATH" bash scripts/chain review docs 96 stage2 --artifacts docs/ARCHITECTURE.md --author-key docs-delta --round 4 >/dev/null 2>&1
RC=$?
{ [ "$RC" -eq 0 ] || [ "$RC" -eq 3 ]; } && [ "$(jq -r '.cross_review[-1].round' specs/PROJ-96-stage2/state.json)" -eq 4 ] \
  && ok "manual round 4 runs and is persisted" || bad "manual round 4 failed (rc=$RC)"

# opposite provider "unavailable": stub codex fails login (a bare rm would fall
# through to a REAL codex on PATH) -> model-opposite fallback
printf '#!/bin/sh\nexit 1\n' > "$STUB/codex"; chmod +x "$STUB/codex"
PATH="$STUB:$PATH" CLAUDE_REVIEW_MODEL=sonnet bash scripts/chain review docs 96 stage2 --artifacts docs/ARCHITECTURE.md --author-key docs-delta --round 2 >/dev/null 2>&1
DEG="$(jq -r '.cross_review[-1] | (.degraded_fallback|tostring) + ":" + .reviewer_model' specs/PROJ-96-stage2/state.json)"
[ "$DEG" = "true:sonnet" ] && ok "degraded: model-opposite fallback used and flagged in state" || bad "degraded record wrong: $DEG"
PATH="$STUB:$PATH" CLAUDE_REVIEW_MODEL=opus bash scripts/chain review docs 96 stage2 --artifacts docs/ARCHITECTURE.md --author-key docs-delta >/dev/null 2>&1
[ $? -eq 1 ] && ok "reviewer model == author model refused (gate never same-model)" || bad "same-model review not refused"

# degraded flag renders in the morning report
bash scripts/chain state set 96 stage2 .degraded true >/dev/null
bash scripts/chain state set 96 stage2 .degraded_reason '"codex unavailable at P7 (spike)"' >/dev/null
bash scripts/chain render report morning specs >/dev/null 2>&1
grep -rq "cross-review: model-opposite fallback" specs/morning-report-*.md 2>/dev/null \
  && ok "degradation rendered in the morning report (cross-review: model-opposite fallback)" \
  || bad "morning report missing the degradation flag"
bash scripts/chain state set 96 stage2 .degraded false >/dev/null

# =============================================================================
if [ "$SKIP_LIVE" -eq 1 ]; then
  step "live adapter smoke SKIPPED (--skip-live)"
else
  step "live cross-review adapter smoke (real CLIs, planted factual error)"
  # docs/ARCHITECTURE.md claims backoff+DLQ; src/queue.js says the opposite.
  LIVE_PROMPT="$WORK/live-prompt.md"
  cat > "$LIVE_PROMPT" <<EOF
You are a read-only adversarial docs reviewer in a verification spike, in
the directory $FIX. Compare the following embedded files. Do not run commands
or modify anything.

## Artifact under review: docs/ARCHITECTURE.md
$(cat "$FIX/docs/ARCHITECTURE.md")

## Ground truth: src/queue.js
$(cat "$FIX/src/queue.js")

Your entire final answer must use the adapter's machine-readable findings
transport, with no prose or fences. When a validated schema is supplied,
populate its findings array; otherwise emit one JSON object per line:
{"source":"cross-review","severity":"high","category":"stale-claim","file":"docs/ARCHITECTURE.md","line":2,"summary":"..."}
If (and only if) everything is accurate: {"source":"cross-review","severity":"low","category":"review-clean","summary":"clean"}
EOF
  LIVE_TIMEOUT=300
  if command -v claude >/dev/null 2>&1; then
    OUT="$(bash scripts/chain review claude --prompt "$LIVE_PROMPT" --model "${CLAUDE_REVIEW_MODEL:-sonnet}" --timeout "$LIVE_TIMEOUT" 2>/dev/null)"
    N="$(grep -c '^{' <<<"$OUT" 2>/dev/null || true)"
    [ "${N:-0}" -ge 1 ] && ok "live claude adapter: $N valid JSON line(s) (codex-authored -> claude direction / model-opposite fallback)" \
                        || bad "live claude adapter produced no valid lines"
  else
    bad "claude CLI missing — cannot spike the hard provider"
  fi
  if command -v codex >/dev/null 2>&1 && codex login status >/dev/null 2>&1; then
    OUT="$(bash scripts/chain review codex --prompt "$LIVE_PROMPT" --timeout "$LIVE_TIMEOUT" 2>/dev/null)"
    N="$(grep -c '^{' <<<"$OUT" 2>/dev/null || true)"
    [ "${N:-0}" -ge 1 ] && ok "live codex adapter: $N valid JSON line(s) (claude-authored -> codex direction)" \
                        || bad "live codex adapter produced no valid lines"
  else
    step "codex unavailable — claude-authored->codex live direction not testable on this machine (degraded parity already proven above)"
  fi
fi

# =============================================================================
echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ STAGE 2 SPIKE PASSED ($PASS assertions$( [ "$SKIP_LIVE" -eq 1 ] && echo ", live skipped"))"
  exit 0
else
  echo "❌ STAGE 2 SPIKE FAILED — $FAIL failed, $PASS passed"
  exit 1
fi
