#!/usr/bin/env bash
# render.mjs must reproduce the documents the two retired renderers (render-pr-body.mjs,
# render-report.mjs) produced for the same fixture, and keep their exit codes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$ROOT/scripts/fixtures/render"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "test-render: $*" >&2; exit 1; }
norm() { sed -E "s/[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9:.]+Z)?//g; s#$ROOT/runner#@RUNNER@#g"; }

for provider in claude codex; do
  CHAIN="$ROOT/$provider/skills/5_executing/scripts/chain"
  W="$TMP/$provider"; mkdir -p "$W"; (cd "$W" && bash "$FIX/make-fixture.sh" "$W")
  cd "$W"
  bash "$CHAIN" render pr 1 demo | norm | cmp - "$FIX/expected-pr.txt" || fail "$provider pr body differs"
  bash "$CHAIN" render report stop 1 demo --reason boom >/dev/null
  norm <specs/PROJ-1-demo/5_progress/stop-report.md | cmp - "$FIX/expected-stop.txt" || fail "$provider stop report differs"
  bash "$CHAIN" render report morning specs >/dev/null
  norm <specs/morning-report-*.md | cmp - "$FIX/expected-morning.txt" || fail "$provider morning report differs"

  # the P8 resume command names the runner the caller points at
  SKILLCHAIN_RUNNER_DIR="$ROOT/runner" bash "$CHAIN" render report stop 1 demo --reason boom >/dev/null
  grep -qF "$ROOT/runner/run-phase.sh" specs/PROJ-1-demo/5_progress/stop-report.md || fail "$provider resume command lost the runner path"
  # an explicit template path wins; usage and missing-input exit codes stay
  printf '{{PROJ}} {{THEME}}\n' >"$TMP/t.tmpl"
  [ "$(bash "$CHAIN" render pr 1 demo "$TMP/t.tmpl")" = "PROJ-1 demo" ] || fail "$provider custom template ignored"
  rc=0; bash "$CHAIN" render pr >/dev/null 2>&1 || rc=$?; [ "$rc" = 64 ] || fail "$provider usage should exit 64, got $rc"
  rc=0; bash "$CHAIN" render pr 9 none >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "$provider missing state should exit 2, got $rc"
  rc=0; bash "$CHAIN" render report bogus >/dev/null 2>&1 || rc=$?; [ "$rc" = 64 ] || fail "$provider unknown report mode should exit 64, got $rc"
  bash "$CHAIN" render pr --selftest >/dev/null || fail "$provider selftest failed"
  # Preserve recorded degradation reasons without inventing provider/model attribution.
  bash "$CHAIN" state set 1 demo .degraded_reason '"same-provider/same-model override after earlier Claude reviews"' >/dev/null
  bash "$CHAIN" render pr 1 demo >"$W/degraded-pr.txt"
  grep -qF 'Provider degradation: same-provider/same-model override after earlier Claude reviews' "$W/degraded-pr.txt" || fail "$provider degradation reason changed"
  ! grep -qE 'single-provider run|model-opposite fallback' "$W/degraded-pr.txt" || fail "$provider invented fallback attribution"
  bash "$CHAIN" state set 1 demo .degraded_reason null >/dev/null
  bash "$CHAIN" render report morning specs >/dev/null
  grep -qF 'Provider degradation: reason not recorded' specs/morning-report-*.md || fail "$provider missing-reason attribution is not neutral"
  # Multiline ledger summaries must stay inside one Markdown table row.
  printf '%s\n' '{"source":"debt","severity":"low","status":"deferred","summary":"first | pipe\r\nsecond\rthird\nfourth","file":"src/debt.ts"}' | bash "$CHAIN" findings add 1 demo >/dev/null
  bash "$CHAIN" render pr 1 demo >"$W/multiline-pr.txt"
  grep -qF 'first \| pipe<br>second<br>third<br>fourth |' "$W/multiline-pr.txt" || fail "$provider multiline debt broke its table row"
  # Invalid external inputs fail before emitting a PR body, with a concise diagnostic.
  node --input-type=module <<'JS'
import fs from 'node:fs';
import { createHash } from 'node:crypto';
const base = 'specs/PROJ-1-demo';
const source = 'A1: Preserve source requirements.';
const acceptance = 'Accepted team revision.';
fs.writeFileSync(`${base}/source.txt`, source);
fs.writeFileSync(`${base}/acceptance.txt`, acceptance);
const requirement = 'product@v1:source:A1';
fs.writeFileSync(`${base}/external-handoff.json`, JSON.stringify({
  schemaVersion: 1, baseline: { id: 'product', version: 'v1' }, derivedFrom: 'product@v1',
  repository: 'app', repositories: ['app'],
  sources: [
    { id: 'source', path: 'source.txt', sha256: createHash('sha256').update(source).digest('hex') },
    { id: 'acceptance', path: 'acceptance.txt', sha256: createHash('sha256').update(acceptance).digest('hex') }
  ],
  team: { status: 'accepted', revision: 'a'.repeat(40), source: 'acceptance', evidence: acceptance },
  requirements: [{ id: requirement, source: 'source', sourceId: 'A1', sourceRange: { startLine: 1, endLine: 1 }, text: 'A1: Preserve source requirements.', repositories: ['app'] }],
  mappings: [{ requirement, repository: 'app', story: 'PROJ-1-PRD-1-US-1', ac: 'PROJ-1-PRD-1-US-1-AC-1' }],
  engineering: [], questions: [], responses: [], dependencies: [],
  prototype: { kind: 'none', reference: 'No prototype supplied.', simulated: [] }
}));
JS
  bash "$CHAIN" render pr 1 demo >"$W/external-pr.txt"
  grep -qF 'Shared integration: pending' "$W/external-pr.txt" || fail "$provider valid external inputs were not rendered"
  cp specs/PROJ-1-demo/external-handoff.json "$W/valid-marker.json"
  mkdir -p specs/PROJ-1-demo/refinement
  for invalid in marker integration; do
    if [ "$invalid" = marker ]; then
      printf '{' >specs/PROJ-1-demo/external-handoff.json
    else
      cp "$W/valid-marker.json" specs/PROJ-1-demo/external-handoff.json
      printf '{}' >specs/PROJ-1-demo/refinement/integration.json
    fi
    rc=0; bash "$CHAIN" render pr 1 demo >"$W/invalid-pr.txt" 2>"$W/invalid-pr.err" || rc=$?
    [ "$rc" = 1 ] || fail "$provider invalid $invalid should exit 1, got $rc"
    [ ! -s "$W/invalid-pr.txt" ] || fail "$provider invalid $invalid emitted a partial PR body"
    grep -q '^render.mjs: ' "$W/invalid-pr.err" || fail "$provider invalid $invalid has no concise renderer diagnostic"
    [ "$(wc -l <"$W/invalid-pr.err")" = 1 ] || fail "$provider invalid $invalid leaked a stack trace"
  done
done
echo "test-render: ok"
