#!/usr/bin/env bash
# Deterministic behavior tests for findings ingestion, dedupe, reopen and the ponytail: debt harvest.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

run_suite() {
  local ledger="$1" label="$2" work
  work="$TMP/$label"
  mkdir -p "$work/specs/PROJ-1-test"

  set +e
  (cd "$work" && node "$ledger" add 1 test </dev/null) >"$work/empty.out" 2>&1
  local rc=$?
  set -e
  [[ "$rc" -eq 1 ]] || fail "$label: empty stdin returned $rc, expected 1"
  [[ ! -e "$work/specs/PROJ-1-test/findings.json" ]] || fail "$label: empty stdin wrote a ledger"

  set +e
  printf '%s\n' '{"source":"coderabbit","severity":"major","category":{"name":"review"},"summary":"Bad category","file":"src/a.ts","line":1.5,"anchor":["symbol"]}' \
    | (cd "$work" && node "$ledger" add 1 test) >"$work/invalid.out" 2>&1
  rc=$?
  set -e
  [[ "$rc" -eq 1 ]] || fail "$label: invalid optional field types returned $rc, expected 1"
  [[ ! -e "$work/specs/PROJ-1-test/findings.json" ]] || fail "$label: invalid optional field types wrote a ledger"

  set +e
  printf '%s\n' '{"source":"coderabbit","severity":"major","summary":"   "}' \
    | (cd "$work" && node "$ledger" add 1 test) >"$work/blank-summary.out" 2>&1
  rc=$?
  set -e
  [[ "$rc" -eq 1 ]] || fail "$label: whitespace-only summary returned $rc, expected 1"
  [[ ! -e "$work/specs/PROJ-1-test/findings.json" ]] || fail "$label: whitespace-only summary wrote a ledger"

  set +e
  printf '%s\n' '{"source":"coderabbit","severity":"major","summary":"Bad wave"}' \
    | (cd "$work" && node "$ledger" add 1 test --wave nope) >"$work/invalid-wave.out" 2>&1
  rc=$?
  set -e
  [[ "$rc" -eq 1 ]] || fail "$label: invalid wave returned $rc, expected 1"
  [[ ! -e "$work/specs/PROJ-1-test/findings.json" ]] || fail "$label: invalid wave wrote a ledger"

  printf '%s\n' \
    '{"source":"coderabbit","severity":"major","category":"review","summary":"First issue","file":"src/a.ts"}' \
    '{"source":"coderabbit","severity":"major","category":"review","summary":"Second issue","file":"src/a.ts"}' \
    | (cd "$work" && node "$ledger" add 1 test) >/dev/null
  [[ $(jq '.findings | length' "$work/specs/PROJ-1-test/findings.json") -eq 2 ]] \
    || fail "$label: distinct unanchored findings collapsed"

  printf '%s\n' '{"source":"coderabbit","severity":"major","category":"review","summary":"  FIRST   issue ","file":"src/a.ts"}' \
    | (cd "$work" && node "$ledger" add 1 test) >/dev/null
  [[ $(jq '.findings | length' "$work/specs/PROJ-1-test/findings.json") -eq 2 ]] \
    || fail "$label: genuine duplicate was added"

  local id
  id=$(jq -r '.findings[] | select(.summary == "First issue") | .id' "$work/specs/PROJ-1-test/findings.json")
  (cd "$work" && node "$ledger" set-status 1 test "$id" fixed abc123) >/dev/null
  printf '%s\n' '{"source":"coderabbit","severity":"critical","category":"review","summary":"First issue","file":"src/a.ts"}' \
    | (cd "$work" && node "$ledger" add 1 test) >"$work/reopen.out"
  jq -e --arg id "$id" '.findings[] | select(.id == $id) | .status == "open" and .severity == "critical"' \
    "$work/specs/PROJ-1-test/findings.json" >/dev/null || fail "$label: fixed finding was not reopened/escalated"
  grep -q 'REOPENED' "$work/reopen.out" || fail "$label: reopen was not reported"

  # harvest: ponytail: markers become deferred debt findings; idempotent; quiet when there is nothing to do
  local hv="$TMP/$label-harvest"
  mkdir -p "$hv/specs/PROJ-1-test" "$hv/src/deep" "$hv/node_modules/x" "$hv/specs/PROJ-1-test/notes"
  printf 'a\n// ponytail: global lock, per-account locks if throughput matters\nb\n' >"$hv/src/a.ts"
  printf '# ponytail:no space note\n' >"$hv/src/deep/b.py"
  printf '// ponytail: ignored, vendored\n' >"$hv/node_modules/x/c.js"
  printf 'ponytail: ignored, a spec note\n' >"$hv/specs/PROJ-1-test/notes/n.md"
  (cd "$hv" && node "$ledger" harvest 1 test) >"$hv/out" || fail "$label: harvest failed"
  [[ $(jq '.findings | length' "$hv/specs/PROJ-1-test/findings.json") -eq 2 ]] || fail "$label: harvest should find exactly the two src markers"
  jq -e '[.findings[] | select(.file == "src/a.ts")] | length == 1 and .[0].line == 2 and .[0].status == "deferred" and .[0].severity == "low" and .[0].source == "debt"
         and .[0].summary == "ponytail: global lock, per-account locks if throughput matters"
         and .[0].debt_marker == "global lock, per-account locks if throughput matters"' \
    "$hv/specs/PROJ-1-test/findings.json" >/dev/null || fail "$label: harvested finding has the wrong shape"
  jq -e '[.findings[] | select(.file == "src/deep/b.py")][0].summary == "ponytail: no space note"' "$hv/specs/PROJ-1-test/findings.json" >/dev/null \
    || fail "$label: marker without a space after the colon"
  (cd "$hv" && node "$ledger" harvest 1 test) >/dev/null
  [[ $(jq '.findings | length' "$hv/specs/PROJ-1-test/findings.json") -eq 2 ]] || fail "$label: harvest is not idempotent"
  (cd "$hv" && node "$ledger" harvest 1 test nowhere) | grep -q 'does not exist' || fail "$label: a missing search root should be reported, not fatal"
  mkdir "$hv/empty"; (cd "$hv" && node "$ledger" harvest 1 test empty) | grep -q 'no ponytail: markers' || fail "$label: no markers should be reported, not fatal"
  [[ $(jq '.findings | length' "$hv/specs/PROJ-1-test/findings.json") -eq 2 ]] || fail "$label: an empty harvest changed the ledger"
  (cd "$hv" && node "$ledger" harvest 1 test .) >/dev/null
  [[ $(jq '[.findings[] | select(.file | startswith("node_modules") or startswith("specs"))] | length' "$hv/specs/PROJ-1-test/findings.json") -eq 0 ]] \
    || fail "$label: harvest of the repo root must still skip node_modules and specs"
  set +e; (cd "$hv" && node "$ledger" harvest 1) >/dev/null 2>&1; rc=$?; set -e
  [[ "$rc" -eq 64 ]] || fail "$label: harvest without a theme returned $rc, expected 64"
}

run_suite "$ROOT/codex/skills/6_qa/scripts/findings.mjs" codex
run_suite "$ROOT/claude/skills/6_qa/scripts/findings.mjs" claude
cmp -s "$ROOT/codex/skills/6_qa/scripts/findings.mjs" "$ROOT/claude/skills/6_qa/scripts/findings.mjs" \
  || fail "findings copies are not byte-identical"

echo 'findings behavior tests: PASS'
