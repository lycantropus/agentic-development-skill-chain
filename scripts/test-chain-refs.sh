#!/usr/bin/env bash
# check-chain-refs.mjs must accept chain-only prose and reject script names, dead paths and unknown verbs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "test-chain-refs: $*" >&2; exit 1; }

mkdir -p "$TMP/claude/skills/5_executing/scripts" "$TMP/claude/skills/6_qa/scripts" "$TMP/docs"
cp "$ROOT/claude/skills/5_executing/scripts/chain" "$TMP/claude/skills/5_executing/scripts/chain"
touch "$TMP/claude/skills/5_executing/scripts/state.sh" "$TMP/claude/skills/6_qa/scripts/ledger.mjs" "$TMP/README.md"
DOC="$TMP/claude/skills/5_executing/SKILL.md"

check() { node "$ROOT/scripts/check-chain-refs.mjs" "$TMP" >"$TMP/out" 2>&1; }
accepts() { printf '%s\n' "$2" >"$DOC"; check || { cat "$TMP/out" >&2; fail "rejected valid prose: $1"; }; }
rejects() { printf '%s\n' "$3" >"$DOC"; if check; then fail "accepted: $1"; fi; grep -qF -- "$2" "$TMP/out" || { cat "$TMP/out" >&2; fail "wrong reason for: $1 (wanted '$2')"; }; }

accepts "chain verbs"            'Run `bash scripts/chain state get 1 x .phase`, then `chain gate wave 2 1 x` and `chain findings add 1 x`.'
accepts "script names in a table" '| `5_executing/scripts/state.sh`, `ledger.mjs` | `scripts/` |'
accepts "plain prose"            'Nothing here calls a helper.'
rejects "script name in prose"   "names script 'state.sh'"          'Run `bash scripts/state.sh get 1 x`.'
rejects "bare script name"       "names script 'ledger.mjs'"          'Findings go through `ledger.mjs`.'
rejects "removed skill copy"     "6_qa/scripts/gone.sh does not exist" 'See `6_qa/scripts/gone.sh`.'
rejects "unknown project script" "scripts/gone.sh does not exist"    'Run `bash scripts/gone.sh`.'
rejects "unknown verb"           "'chain bogus' is not a chain verb"  'Run `chain bogus x`.'
rejects "unknown sub"            "'chain check nope' is not in the dispatcher table" 'Run `chain check nope`.'
echo "test-chain-refs: ok"
