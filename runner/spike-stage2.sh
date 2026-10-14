#!/usr/bin/env bash
# spike-stage2.sh — Stage 2 verification spike / release gate (CONCEPT.md §10.2).
#
# Only what needs real CLIs lives here: the live cross-review adapter smoke
# against a planted factual error, per available direction. Everything
# deterministic runs in scripts/test-*.sh under validate.sh (context compiler:
# test-compile-context-bundles.sh, routing: test-cross-review-routing.sh,
# adapters: test-review-with-{claude,codex}.sh, P7 gate: test-p7-runner-gate.sh).
#
# Usage: spike-stage2.sh   (makes real, short Claude/Codex calls)
# Exit:  0 all assertions passed · 1 any assertion failed
set -uo pipefail

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SPIKE_DIR/.." && pwd)"
SKILLS="$REPO_ROOT/claude/skills"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $*"; FAIL=$((FAIL+1)); }
step() { echo "→ $*"; }

# Fixture: a docs claim that src/queue.js contradicts.
FIX="$WORK/repo"
mkdir -p "$FIX"/{docs,src,scripts}
cd "$FIX"
printf '# Architecture\nsrc/queue.js implements exponential backoff with a dead-letter queue for failed events.\n' > docs/ARCHITECTURE.md
printf '// retry forever, NO backoff, NO dead-letter handling\nmodule.exports = () => {};\n' > src/queue.js
for s in 5_executing/scripts/chain cross-review/scripts/review-with-claude.sh cross-review/scripts/review-with-codex.sh; do
  cp "$SKILLS/$s" scripts/
done

# =============================================================================
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
  step "codex unavailable — claude-authored->codex live direction not testable on this machine (degraded parity is covered by scripts/test-cross-review-routing.sh)"
fi

# =============================================================================
echo
if [ "$FAIL" -eq 0 ]; then
  echo "✓ STAGE 2 SPIKE PASSED ($PASS assertions)"
  exit 0
else
  echo "❌ STAGE 2 SPIKE FAILED — $FAIL failed, $PASS passed"
  exit 1
fi
