#!/usr/bin/env bash
# Claude cross-review adapter: --max-turns handling and protocol controls
# (dedupe, review-clean plus findings, false-success, error envelope, 10 MB, timeout).
# --max-turns regression:
# --json-schema structured output needs at least 2 model turns (reasoning +
# the schema-validated tool_use finalization); a one-turn cap can cut a real
# review off as error_max_turns before any finding forms. Confirmed via a
# live claude -p run during the fix — this check guards the code shape only.
set -euo pipefail
export SKILLCHAIN_POLL_SECONDS=0.1 # stubs return instantly; production default stays

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/codex/skills/cross-review/scripts/review-with-claude.sh"
CASE="$(mktemp -d)"
trap 'rm -rf "$CASE"' EXIT

cat >"$CASE/claude" <<'EOF'
#!/usr/bin/env bash
turns=""
while [ $# -gt 0 ]; do
  case "$1" in --max-turns) turns="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s\n' "$turns" >"$TURNS_CAPTURE"
cat >/dev/null
printf '%s\n' '{"is_error":false,"structured_output":{"findings":[{"severity":"low","category":"review-clean","summary":"clean"}]}}'
EOF
chmod +x "$CASE/claude"

printf 'artifact material\n' >"$CASE/prompt.txt"

run() { TURNS_CAPTURE="$CASE/turns" PATH="$CASE:$PATH" bash "$SCRIPT" --prompt "$CASE/prompt.txt" "$@"; }

run >/dev/null
DEFAULT_TURNS="$(cat "$CASE/turns")"
[ "$DEFAULT_TURNS" -gt 1 ] || { echo "FAIL: default --max-turns is $DEFAULT_TURNS, must be >1 (a 1-turn cap is below the structured-output floor)" >&2; exit 1; }

run --max-turns 3 >/dev/null
[ "$(cat "$CASE/turns")" = 3 ] || { echo "FAIL: --max-turns override was not forwarded to claude" >&2; exit 1; }

for bad in 0 abc; do
  if run --max-turns "$bad" >/dev/null 2>&1; then
    echo "FAIL: --max-turns $bad should have been rejected" >&2
    exit 1
  fi
done

# Protocol controls: the adapter consumes Claude Code's structured_output
# envelope and must fail closed on anything that merely looks like a review.
stub() { printf '#!/usr/bin/env bash\ncat >/dev/null\n%s\n' "$1" >"$CASE/claude"; chmod +x "$CASE/claude"; }
fails() { local out; ! out="$(run --timeout 10 2>&1)" && grep -q "$1" <<<"$out"; } # rejected, for this reason

stub "echo '{\"is_error\":false,\"structured_output\":{\"findings\":[{\"severity\":\"medium\",\"category\":\"duplicate\",\"file\":\"a.md\",\"line\":2,\"summary\":\"same\"},{\"severity\":\"medium\",\"category\":\"duplicate\",\"file\":\"a.md\",\"line\":2,\"summary\":\"same\"}]}}'"
OUT="$(run --timeout 10 2>/dev/null)"
[ "$(printf '%s\n' "$OUT" | grep -c '^{')" -eq 1 ] && printf '%s\n' "$OUT" | jq -e 'select(.provider == "claude")' >/dev/null \
  || { echo "FAIL: adapter must stamp the provider and deduplicate identical findings" >&2; exit 1; }

stub "echo '{\"is_error\":false,\"structured_output\":{\"findings\":[{\"severity\":\"low\",\"category\":\"review-clean\",\"summary\":\"clean\"},{\"severity\":\"medium\",\"category\":\"contradiction\",\"summary\":\"not clean\"}]}}'"
fails "appeared together" || { echo "FAIL: adapter accepted review-clean plus a finding" >&2; exit 1; }

stub "echo '{\"is_error\":false,\"result\":\"review-blocked: sandbox failed\",\"structured_output\":{\"findings\":[{\"severity\":\"medium\",\"category\":\"false-success\",\"summary\":\"must not pass\"}]}}'"
fails "sandbox/infrastructure failure" || { echo "FAIL: adapter accepted infrastructure false-success output" >&2; exit 1; }

stub "echo '{\"is_error\":true,\"terminal_reason\":\"api_error\",\"result\":\"Not logged in\"}'"
fails "no validated structured findings" || { echo "FAIL: adapter accepted an rc=0 API/auth error envelope" >&2; exit 1; }

dd if=/dev/null of="$CASE/over-limit.md" bs=1 seek=10000001 2>/dev/null   # sparse file (macOS has no truncate)
stub "echo unreachable"
! out="$(bash "$SCRIPT" --prompt "$CASE/over-limit.md" --timeout 10 2>&1)" && grep -q 'stdin is limited to 10 MB' <<<"$out" \
  || { echo "FAIL: adapter must name the 10 MB stdin ceiling" >&2; exit 1; }

# Timeout kills the whole process group: neither the stub nor its child survives the adapter.
stub "echo \$\$ >\"$CASE/pids\"; sleep 300 & echo \$! >>\"$CASE/pids\"; wait"
if run --timeout 3 >/dev/null 2>&1; then echo "FAIL: timed-out adapter exited 0" >&2; exit 1; fi
sleep 1
[ "$(wc -l <"$CASE/pids")" -eq 2 ] || { echo "FAIL: the timeout stub did not start" >&2; exit 1; }
while read -r pid; do
  ! kill -0 "$pid" 2>/dev/null || { kill "$pid"; echo "FAIL: adapter timeout left process $pid alive" >&2; exit 1; }
done <"$CASE/pids"

echo "review-with-claude max-turns and protocol tests passed"
