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
done
echo "test-render: ok"
