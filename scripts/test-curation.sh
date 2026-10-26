#!/usr/bin/env bash
# chain check caps / chain check intake: a scenario transcript (exit code plus the full report) is
# compared with scripts/fixtures/curation/expected.txt, which was recorded from the retired
# curation-caps.sh and intake-seal-check.sh (now curation.sh caps|seal). `test-curation.sh --record` rewrites that file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED="$ROOT/scripts/fixtures/curation/expected.txt"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "test-curation: $*" >&2; exit 1; }

lines() { seq 1 "$1"; }
baseline() { # nine baseline files: seven required + two conditional UI files; capped files at their cap
  rm -rf "$R"; mkdir -p "$R/docs" "$R/src/feature" "$R/specs/intake"; cd "$R"
  { lines 20; printf '\n\n\n'; lines 10; } >docs/PRODUCT.md   # 30 non-blank + blanks
  lines 200 >docs/ARCHITECTURE.md; lines 120 >docs/GUIDELINES.md
  lines 80 >docs/review-checklist.md
  lines 60 >docs/security-baseline.md; lines 60 >docs/test-conventions.md
  lines 40 >AGENTS.md; lines 100 >src/feature/agent.md
  printf 'D-BOOTSTRAP-01 decided\n' >specs/intake/decisions.md
}

run() { # <label> <chain args…> — one transcript block: label, exit code, stdout, stderr
  local label="$1" rc=0; shift
  bash "$CHAIN" "$@" >"$TMP/out" 2>"$TMP/err" || rc=$?
  { echo "### $label (exit $rc)"; cat "$TMP/out"; echo "--- stderr"; cat "$TMP/err"; }
}

transcript() {
  R="$TMP/repo"
  baseline
  run "caps clean at the cap" check caps .
  run "caps default root" check caps
  for spec in "docs/PRODUCT.md 31" "docs/ARCHITECTURE.md 201" "docs/GUIDELINES.md 121" "docs/security-baseline.md 61" \
              "docs/review-checklist.md 81" "docs/test-conventions.md 61" "AGENTS.md 41" "src/feature/agent.md 101"; do
    set -- $spec; baseline; lines "$2" >"$1"
    run "caps breach $1" check caps .
  done
  baseline; printf 'x\n' >>docs/PRODUCT.md; run "caps product 31 non-blank" check caps .
  baseline; lines 81 >docs/DESIGN-SYSTEM.md; run "caps design-system breach" check caps .
  baseline; lines 80 >docs/DESIGN-SYSTEM.md; run "caps design-system at cap" check caps .
  baseline; mkdir -p src/other; lines 101 >src/other/agent.md; run "caps second agent.md breach" check caps .
  rm -rf "$R"; mkdir -p "$R"; cd "$R"
  run "caps empty repo warns" check caps .
  run "caps empty repo require-baseline" check caps --require-baseline .
  baseline; rm docs/PRODUCT.md; run "caps missing product warns" check caps .
  baseline; rm docs/PRODUCT.md; run "caps missing product require-baseline" check caps --require-baseline .

  baseline; rm docs/review-checklist.md; run "caps missing checklist warns" check caps .
  run "caps missing checklist require-baseline" check caps --require-baseline .
  baseline; printf '## Traps\n' >docs/GUIDELINES.md
  for i in $(seq 1 10); do printf '%s. Don’t X → instead Y — why here\n   continuation\n   - nested detail\n' "$i" >>docs/GUIDELINES.md; done
  printf '## Other\n- outside Traps\n' >>docs/GUIDELINES.md
  run "caps ten multiline numbered Traps" check caps .
  baseline; printf '## Traps\n' >docs/GUIDELINES.md
  for i in $(seq 1 11); do printf -- '- Don’t X → instead Y — why here\n' >>docs/GUIDELINES.md; done
  run "caps eleven Traps breach" check caps .
  run "intake eleven Traps breach" check intake .
  baseline; printf '## Traps\n## Other\n- not a trap\n' >docs/GUIDELINES.md
  run "caps empty Traps" check caps .

  baseline; run "intake sealable" check intake .
  baseline; run "intake default root" check intake
  for f in docs/PRODUCT.md docs/ARCHITECTURE.md docs/GUIDELINES.md docs/review-checklist.md docs/security-baseline.md docs/test-conventions.md AGENTS.md; do
    baseline; rm "$f"; run "intake missing $f" check intake .
  done
  for marker in '[extracted: src/a.ts]' '[assumed]' '[gap: who owns this]'; do
    baseline; printf '%s\n' "$marker" >>docs/GUIDELINES.md; run "intake marker $marker" check intake .
  done
  baseline; rm specs/intake/decisions.md; run "intake no decisions file" check intake .
  baseline; printf 'no ids\n' >specs/intake/decisions.md; run "intake decisions without D-BOOTSTRAP" check intake .
  baseline; mkdir -p src/components; run "intake components without design system" check intake .
  baseline; mkdir -p src/components; printf 'ds\n' >docs/DESIGN-SYSTEM.md; printf 'c\n' >docs/components.md; run "intake components documented" check intake .
  baseline; mkdir -p src/features/a/components; run "intake feature components undocumented" check intake .
  baseline; lines 201 >docs/ARCHITECTURE.md; run "intake cap breach" check intake .
  baseline; rm docs/PRODUCT.md AGENTS.md; printf '[gap]\n' >>docs/GUIDELINES.md; rm specs/intake/decisions.md; run "intake everything wrong" check intake .
}

for provider in claude codex; do
  CHAIN="$ROOT/$provider/skills/5_executing/scripts/chain"
  bash "$CHAIN" check caps --help | grep -q 'curation.sh caps' || fail "$provider: caps --help prints no usage"
  CHAIN="$ROOT/$provider/skills/5_executing/scripts/chain"
  transcript >"$TMP/$provider.txt"
  if [ "${1:-}" = "--record" ]; then cp "$TMP/$provider.txt" "$EXPECTED"; echo "test-curation: recorded $EXPECTED"; exit 0; fi
  diff -u "$EXPECTED" "$TMP/$provider.txt" || fail "$provider transcript differs from $EXPECTED"
done
echo "test-curation: ok"
