#!/usr/bin/env bash
# Codex cross-review adapter protocol controls against a PATH-shimmed codex:
# identical findings collapse, review-clean may not coexist with a finding, and
# sandbox noise next to a finding never counts as a review.
set -euo pipefail
export SKILLCHAIN_POLL_SECONDS=0.1 # stubs return instantly; production default stays

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/codex/skills/cross-review/scripts/review-with-codex.sh"
CASE="$(mktemp -d)"
trap 'rm -rf "$CASE"' EXIT
die() { echo "review-with-codex: $*" >&2; exit 1; }

printf 'prompt\n' >"$CASE/prompt.txt"
stub() { printf '#!/bin/sh\n[ "$1" = login ] && exit 0\n%s\n' "$1" >"$CASE/codex"; chmod +x "$CASE/codex"; }
run() { PATH="$CASE:$PATH" bash "$SCRIPT" --prompt "$CASE/prompt.txt" --timeout 10 "$@"; }
F='{"severity":"medium","category":"%s","file":"docs/ARCHITECTURE.md","line":2,"summary":"%s"}'

stub "echo '$(printf "$F" duplicate "same finding")'; echo '$(printf "$F" duplicate "same finding")'"
[ "$(run 2>/dev/null | grep -c '^{')" -eq 1 ] || die 'identical findings must collapse into one'

stub "echo '{\"severity\":\"low\",\"category\":\"review-clean\",\"summary\":\"clean\"}'; echo '$(printf "$F" contradiction "not clean")'"
! out="$(run 2>&1)" && grep -q 'appeared together' <<<"$out" || die 'review-clean plus a finding must be rejected'

stub "echo 'bubblewrap: user namespaces unavailable'; echo '$(printf "$F" false-success "must not pass")'"
! out="$(run 2>&1)" && grep -q 'sandbox/infrastructure failure' <<<"$out" || die 'sandbox false-success output must be rejected'

# SC-14: a provider error is distinct from review content about rate limits.
# A failed call may mix plain stderr with a structured quota envelope.
stub "echo warning-before-json >&2; echo '{\"is_error\":true,\"type\":\"error\",\"error\":\"usage_limit_reached\"}'; exit 1"
rc=0; run >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 75 ] || { echo "FAIL: mixed stderr quota must return 75, got $rc" >&2; exit 1; }
# A recovered transient quota event cannot override a completed review.
stub "echo '{\"is_error\":true,\"type\":\"error\",\"error\":\"usage_limit_reached\"}'; echo '{\"severity\":\"low\",\"category\":\"review-clean\",\"summary\":\"recovered review\"}'; exit 0"
rc=0; run >"$CASE/recovered-quota" 2>"$CASE/recovered-quota.err" || rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: completed review after transient quota must succeed, got $rc" >&2; exit 1; }
jq -e '.category == "review-clean"' "$CASE/recovered-quota" >/dev/null
stub "echo '{\"is_error\":true,\"type\":\"error\",\"error\":\"usage_limit_reached\"}'; exit 1"
rc=0; run >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 75 ] || { echo "FAIL: runtime quota must return 75, got $rc" >&2; exit 1; }
stub "echo '{\"severity\":\"medium\",\"category\":\"reliability\",\"summary\":\"rate limit validation is missing\"}'; exit 1"
rc=0; run >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL: an unrelated failed review mentioning rate limits must stay exit 1, got $rc" >&2; exit 1; }

echo "review-with-codex: ok"

# SC-10: a refused resource admission cannot start the provider.
printf '{"resources":{"test_workers":0,"wait_seconds":0}}\n' >"$CASE/resources.json"
stub 'echo launched >"$RESOURCE_CHILD_MARKER"; exit 0'
export RESOURCE_CHILD_MARKER="$CASE/resource-child"
rc=0; resource_out="$(run --resource-config "$CASE/resources.json" 2>&1)" || rc=$?
[ "$rc" -eq 64 ] || { echo "FAIL: resource validation must return 64, got $rc" >&2; exit 1; }
grep -q "invalid resources policy" <<<"$resource_out" || { echo "FAIL: expected resource validation, got $resource_out" >&2; exit 1; }
[ ! -e "$RESOURCE_CHILD_MARKER" ] || { echo "FAIL: provider launched after resource refusal" >&2; exit 1; }

printf 'MemAvailable: 100 kB\n' >"$CASE/meminfo"
printf 'full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' >"$CASE/psi"
printf '{"resources":{"min_available_mb":1024,"wait_seconds":0}}\n' >"$CASE/resources.json"
export SKILLCHAIN_MEMINFO_FILE="$CASE/meminfo" SKILLCHAIN_PSI_FILE="$CASE/psi" SKILLCHAIN_CGROUP_DIR="$CASE/no-cgroup" SKILLCHAIN_RESOURCE_LOCK_DIR="$CASE/resource-locks"
rc=0; resource_out="$(run --resource-config "$CASE/resources.json" 2>&1)" || rc=$?
[ "$rc" -eq 77 ] || { echo "FAIL: pressure must return 77, got $rc: $resource_out" >&2; exit 1; }
[ ! -e "$RESOURCE_CHILD_MARKER" ] || { echo "FAIL: pressure launched provider" >&2; exit 1; }

# Telemetry warnings must stay separate from provider structured output.
printf 'unavailable\n' >"$CASE/vmstat"
export SKILLCHAIN_VMSTAT_FILE="$CASE/vmstat"
stub "echo '{\"severity\":\"low\",\"category\":\"review-clean\",\"summary\":\"clean\"}'"
run --resource-config "$CASE/resources.json" >"$CASE/recovered" 2>"$CASE/recovered.err"
jq -e '.category == "review-clean"' "$CASE/recovered" >/dev/null
grep -q 'resource telemetry unavailable' "$CASE/recovered.err"
