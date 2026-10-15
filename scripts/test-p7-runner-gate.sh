#!/usr/bin/env bash
# P7 runner gate: stubbed writer lanes seal P7:done; the runner re-verifies and
# parks the run when a curation gate is red (caps, review evidence, open
# Critical/High cross-review finding) and lets green gates pass. No provider calls.
set -euo pipefail
export SKILLCHAIN_POLL_SECONDS=0.1 # stubs return instantly; production default stays

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS="$ROOT/claude/skills"
CASE="$(mktemp -d)"
trap 'rm -rf "$CASE"' EXIT
die() { echo "p7-runner-gate: $*" >&2; exit 1; }

FIX="$CASE/repo"
mkdir -p "$FIX"/{docs,scripts,bin,specs/PROJ-96-stage2}
cd "$FIX"
git init -q -b main; git config user.email t@local; git config user.name t
for d in PRODUCT ARCHITECTURE GUIDELINES DESIGN-SYSTEM security-baseline test-conventions; do printf '# %s\n- one line\n' "$d" >"docs/$d.md"; done
printf '# Components\n- Button\n' >docs/components.md
printf '# Rules\n- rule 1\n' >AGENTS.md
for s in 5_executing/scripts/chain 5_executing/scripts/render.mjs 5_executing/scripts/state.sh 5_executing/scripts/compile-context.mjs 5_executing/scripts/document-parser.mjs 5_executing/scripts/architecture-parser.mjs \
         6_qa/scripts/findings.mjs 7_documentation/scripts/curation.sh; do
  cp "$SKILLS/$s" scripts/
done
chmod +x scripts/*.sh scripts/chain
git add -A; git commit -qm base
chain() { bash scripts/chain "$@"; }
state() { chain state get 96 stage2 '.phase + ":" + .status'; }

chain state init 96 stage2 >/dev/null
chain state set 96 stage2 .base_sha "\"$(git rev-parse HEAD)\"" >/dev/null
# advance the fixture state to P6:done so P7 is the legal next phase
for t in "CP1 running" "CP1 approved" "P0 running" "P0 done" "P5 running" "P5 done" "P6 running" "P6 done"; do
  chain state transition 96 stage2 $t >/dev/null
done

# Two writer stubs: one seals WITHOUT any cross-review evidence, one records a
# docs cross-review round (as the real documentation skill would) first.
write_stub_writer() { # <with-evidence: 0|1>
  if [ "$1" -eq 1 ]; then
    cat >bin/claude <<'EOF'
#!/bin/sh
bash scripts/chain state transition 96 stage2 P7 running >/dev/null 2>&1
CUR="$(bash scripts/chain state get 96 stage2 '.cross_review // []')"
UPD="$(printf '%s' "$CUR" | jq -c --arg at "$(date -Iseconds)" '. + [{mode:"docs",round:1,reviewer_provider:"codex",reviewer_model:"codex-default",degraded_fallback:false,findings_added:0,at:$at}]')"
bash scripts/chain state set 96 stage2 .cross_review "$UPD" >/dev/null 2>&1
bash scripts/chain state transition 96 stage2 P7 done >/dev/null 2>&1
exit 0
EOF
  else
    cat >bin/claude <<'EOF'
#!/bin/sh
# stub P7 writer: seals the phase without running any curation gate
bash scripts/chain state transition 96 stage2 P7 running >/dev/null 2>&1
bash scripts/chain state transition 96 stage2 P7 done >/dev/null 2>&1
exit 0
EOF
  fi
  chmod +x bin/claude
}
cat >bin/codex <<'EOF'
#!/bin/sh
case "$1" in login) exit 0 ;; esac
echo '{"source":"review","severity":"low","category":"note","summary":"stub peer note"}'
EOF
chmod +x bin/codex
run_p7() { # <out-file>; prints the runner's exit code
  local rc=0
  PATH="$FIX/bin:$PATH" timeout --foreground 120 "$ROOT/runner/run-phase.sh" P7 96 stage2 --timeout 60 >"$1" 2>&1 || rc=$?
  echo "$rc"
}
mark_open_xr_fixed() {
  for id in $(jq -r '.findings[] | select(.status=="open" and (.source=="cross-review" or ((.sources // []) | index("cross-review")))) | .id' specs/PROJ-96-stage2/findings.json 2>/dev/null); do
    chain findings set-status 96 stage2 "$id" fixed deadbeef >/dev/null 2>&1
  done
}

# gate 1: caps red -> parked (checked before evidence and findings)
write_stub_writer 0
seq 1 31 >docs/PRODUCT.md
rc="$(run_p7 "$CASE/a.out")"
[ "$rc" -eq 1 ] && [ "$(state)" = "P7:blocked" ] && grep -q "curation caps FAIL" "$CASE/a.out" \
  || die "caps gate: rc=$rc state=$(state)"
git checkout -q docs/PRODUCT.md

# gate 2: caps green but NO cross-review ever ran -> parked (a skipped review
# must not look like a clean one)
chain state transition 96 stage2 P7 running >/dev/null
rc="$(run_p7 "$CASE/b.out")"
[ "$rc" -eq 1 ] && [ "$(state)" = "P7:blocked" ] && grep -q "NO docs cross-review" "$CASE/b.out" \
  || die "evidence gate: rc=$rc state=$(state)"

# gate 3: evidence present, an open Critical OR High cross-review finding -> parked (distinct
# findings: the ledger merges identical ones, which would hide the second severity)
write_stub_writer 1
for severity in critical high; do
  printf '{"source":"cross-review","severity":"%s","category":"stale-claim-%s","file":"docs/ARCHITECTURE.md","line":2,"provider":"codex","summary":"%s blocking finding"}\n' "$severity" "$severity" "$severity" \
    | chain findings add 96 stage2 >/dev/null
  chain state transition 96 stage2 P7 running >/dev/null
  rc="$(run_p7 "$CASE/c-$severity.out")"
  [ "$rc" -eq 1 ] && [ "$(state)" = "P7:blocked" ] && grep -q "cross-review finding" "$CASE/c-$severity.out" \
    || die "truth gate ($severity): rc=$rc state=$(state)"
  mark_open_xr_fixed
done

# gate 4: evidence + clean ledger + caps green -> phase completes
chain state transition 96 stage2 P7 running >/dev/null
rc="$(run_p7 "$CASE/d.out")"
[ "$rc" -eq 0 ] && [ "$(state)" = "P7:done" ] || die "green path: rc=$rc state=$(state)"
echo "p7-runner-gate: ok"
