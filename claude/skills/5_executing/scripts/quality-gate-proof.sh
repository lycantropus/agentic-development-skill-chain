#!/usr/bin/env bash
# quality-gate-proof.sh — refuse to seal P5 without machine-readable evidence
# that the PROJ-end Quality Gate ran, including Sonar or a valid skip reason.
# Usage: quality-gate-proof.sh <proj-x> <theme>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env-local.sh"

PROJ="${1:-}"; THEME="${2:-}"
[ -n "$PROJ" ] && [ -n "$THEME" ] || { echo "Usage: $0 <proj-x> <theme>" >&2; exit 64; }
PROGRESS="specs/PROJ-${PROJ}-${THEME}/5_progress/PROJ-${PROJ}-progress.md"
[ -f "$PROGRESS" ] || { echo "quality gate proof: progress file missing: $PROGRESS" >&2; exit 1; }

fail() { echo "quality gate proof: $*" >&2; exit 1; }
section_passed() { # <heading>; matches only within its ### block
  awk -v heading="$1" 'on && /^### / { exit } $0 == "### " heading { on=1 } on && /^Status: passed$/ { ok=1 } END { exit ok ? 0 : 1 }' <<<"$QUALITY"
}
QUALITY="$(awk 'on && /^## / { exit } /^## Quality Gate —/ { on=1 } on { print }' "$PROGRESS")"
[ -n "$QUALITY" ] || fail "Quality Gate section missing"
section_passed 'Code Review' || fail "Code Review needs Status: passed"
section_passed 'Build' || fail "Build needs Status: passed"
section_passed 'Tests' || fail "Tests need Status: passed"
section_passed 'Lint' || fail "Lint needs Status: passed"
grep -q '^### SonarCloud' <<<"$QUALITY" || fail "SonarCloud evidence missing"
SONAR="$(awk 'on && /^### / { exit } /^### SonarCloud/ { on=1 } on { print }' <<<"$QUALITY")"
if grep -qE 'Status: ran' <<<"$SONAR"; then
  :
elif grep -qE 'Status: skipped \((sonar CLI unavailable|project not configured)\)' <<<"$SONAR"; then
  if command -v sonar >/dev/null && command -v sonar-scanner >/dev/null && [ -f sonar-project.properties ]; then
    fail "Sonar was skipped although both CLIs and sonar-project.properties are present"
  fi
else
  fail "SonarCloud needs Status: ran or an explicit allowed skip reason"
fi
# Mutation hardening: optional. The status must agree with the config and the evidence record.
CONFIG="specs/PROJ-${PROJ}-${THEME}/3-4_plan/wave-gate-config.json"
[ -f "$CONFIG" ] || fail "gate config missing: $CONFIG"
MUTATION="$(awk 'on && /^### / { exit } /^### Mutation/ { on=1 } on { print }' <<<"$QUALITY")"
if jq -e '(.mutation_cmd // "") | test("\\S")' "$CONFIG" >/dev/null; then
  RECORD="specs/PROJ-${PROJ}-${THEME}/5_progress/quality-mutation.json"
  [ -f "$RECORD" ] || fail "mutation_cmd is configured but no mutation evidence record exists"
  if grep -qE '^Status: ran$' <<<"$MUTATION"; then
    jq -e '.rc == 0' "$RECORD" >/dev/null || fail "Mutation says ran but the evidence shows surviving mutants; use Status: ran (survivors carried forward)"
  elif grep -qE '^Status: ran \(survivors carried forward\)$' <<<"$MUTATION"; then
    jq -e '.rc != 0' "$RECORD" >/dev/null || fail "Mutation says survivors were carried forward but the evidence shows none"
  else
    fail "Mutation needs Status: ran or ran (survivors carried forward) because mutation_cmd is configured"
  fi
elif [ -n "$MUTATION" ] && ! grep -qE '^Status: skipped \(not configured\)$' <<<"$MUTATION"; then
  fail "Mutation has a status other than skipped (not configured) although mutation_cmd is absent"
fi
node "$(dirname "${BASH_SOURCE[0]}")/quality-evidence.mjs" "$PROJ" "$THEME" check
echo "✓ Quality Gate proof present (code review, build, Sonar disposition)"
