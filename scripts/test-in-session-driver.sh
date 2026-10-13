#!/usr/bin/env bash
# Execute the mechanical blocks of the in-session driver against real
# state.sh / ledger.mjs, and prove the QA persona panel is six concurrent
# processes with six distinct personas. No provider calls.
set -euo pipefail
export SKILLCHAIN_POLL_SECONDS=0.1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="$ROOT/claude/skills/5_executing/references/in-session-driver.md"
CASE="$(mktemp -d)"
trap 'rm -rf "$CASE"' EXIT
die() { echo "in-session-driver: $*" >&2; exit 1; }

block() { # <name> -> fenced ```bash <name> block, placeholders filled
  awk -v n="$1" '$0 ~ "^ *```bash " n "$" { on=1; next } /^ *```$/ { on=0 } on' "$REF" | sed 's/^ *//; s/<X>/1/g; s/<theme>/demo/g'
}
block ingest >"$CASE/ingest.sh"; [ -s "$CASE/ingest.sh" ] || die 'ingest block missing'
block stop   >"$CASE/stop.sh";   [ -s "$CASE/stop.sh" ]   || die 'stop block missing'

# --- fixture: a PROJ sitting at P5:running (quality gate passed) -----------
mkdir -p "$CASE/repo/scripts" "$CASE/repo/specs/PROJ-1-demo/5_progress" "$CASE/bin"
cp "$ROOT/claude/skills/5_executing/scripts/state.sh" "$ROOT/claude/skills/6_qa/scripts/ledger.mjs" "$CASE/repo/scripts/"
cd "$CASE/repo"
S="bash scripts/state.sh"
$S init 1 demo >/dev/null
for p in "CP1 running" "CP1 approved" "P0 running" "P0 done" "P5 running"; do $S transition 1 demo $p >/dev/null; done

# 1. The driver's phase sequence is legal as written (P5 done -> ... -> P8 done).
for p in "P5 done" "P6 running"; do $S transition 1 demo $p >/dev/null || die "illegal transition $p"; done

# 2. Finder ingest: valid JSON lines reach the ledger, malformed ones and prose do not;
#    the prose becomes the report and its path is recorded through state.sh.
cat >"$CASE/finder.out" <<'EOF'
## QA Results
All ACs tested.
{"source":"qa","severity":"high","category":"bug","summary":"login drops session","file":"src/a.ts","line":3}
{"source":"qa","severity":"low","summary":"typo in empty state","file":"src/b.ts","line":9}
{"source":"qa","summary":"no severity, must be dropped"}
{not json
EOF
OUT="$CASE/finder.out" bash "$CASE/ingest.sh" >/dev/null 2>&1 || die 'ingest block failed'
[ "$(jq '.findings | length' specs/PROJ-1-demo/findings.json)" = 2 ] || die 'ledger must hold exactly the 2 valid findings'
rep="$($S get 1 demo .qa.finder_report | tr -d '"')"
[ -f "$rep" ] || die "recorded finder report missing: $rep"
grep -q '^## QA Results' "$rep" && ! grep -q '^{' "$rep" || die 'report must hold the prose only'
[ "$(node scripts/ledger.mjs stats 1 demo | jq .open_blocking)" = 1 ] || die 'one open Critical/High expected'

# 3. Seal path: P6 -> P7 -> P8 -> done is legal in order.
for p in "P6 done" "P7 running" "P7 done" "P8 running" "P8 done"; do $S transition 1 demo $p >/dev/null || die "illegal transition $p"; done

# 4. Stop block parks the run: reason recorded, phase blocked, resumable.
mkdir -p specs/PROJ-2-demo2
$S init 2 demo2 >/dev/null
for p in "CP1 running" "CP1 approved" "P0 running" "P0 done" "P5 running" "P5 done" "P6 running"; do $S transition 2 demo2 $p >/dev/null; done
sed 's/ 1 demo/ 2 demo2/g; s/<X>/2/g' "$CASE/stop.sh" >"$CASE/stop2.sh"
REASON='three failed repair attempts on BUG-7' bash "$CASE/stop2.sh" >/dev/null || die 'stop block failed'
[ "$($S get 2 demo2 '.phase + ":" + .status')" = 'P6:blocked' ] || die 'stop must park the phase as blocked'
$S get 2 demo2 .stop.reason | grep -q 'BUG-7' || die 'stop reason not recorded'
$S transition 2 demo2 P6 running >/dev/null || die 'a parked run must be resumable'

# 5. QA personas: six concurrent processes, six distinct personas (not one prompt naming six).
cat >"$CASE/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-} ${2:-}" == "login status" ]]; then exit 0; fi
prompt="$(cat)"
persona="$(printf '%s\n' "$prompt" | grep -A1 '^## Assigned QA persona' | sed -n 's/^You are \([^—]*\) —.*/\1/p')"
printf '%s|%s|%s\n' "$$" "$persona" "start $(date +%s.%N)" >>"$PERSONA_LOG"
sleep 1
printf '%s\n' '{"severity":"low","category":"review-clean","summary":"clean"}'
printf '%s|%s|%s\n' "$$" "$persona" "end $(date +%s.%N)" >>"$PERSONA_LOG"
EOF
chmod +x "$CASE/bin/codex"
git init -q . && git config user.email t@example.invalid && git config user.name t
printf 'qa report\n' >artifact.md; printf 'x\n' >a.txt; git add -A >/dev/null; git commit -qm base
: >"$CASE/personas.log"
PATH="$CASE/bin:$PATH" PERSONA_LOG="$CASE/personas.log" \
  bash "$ROOT/claude/skills/cross-review/scripts/cross-review.sh" qa 1 demo --artifacts artifact.md \
  --author-provider claude --personas --round 1 >"$CASE/cr.out" 2>&1 || { cat "$CASE/cr.out" >&2; die 'persona review failed'; }
starts="$(grep -c '|start ' "$CASE/personas.log")"
[ "$starts" = 6 ] || die "expected 6 persona workers, got $starts"
[ "$(grep '|start ' "$CASE/personas.log" | cut -d'|' -f1 | sort -u | wc -l)" = 6 ] || die 'persona workers must be six distinct processes'
[ "$(grep '|start ' "$CASE/personas.log" | cut -d'|' -f2 | sort -u | wc -l)" = 6 ] || die "six distinct personas expected: $(cut -d'|' -f2 "$CASE/personas.log" | sort -u | tr '\n' ',')"
last_start="$(grep '|start ' "$CASE/personas.log" | sed 's/.*start //' | sort -n | tail -1)"
first_end="$(grep '|end ' "$CASE/personas.log" | sed 's/.*end //' | sort -n | head -1)"
awk -v s="$last_start" -v e="$first_end" 'BEGIN { exit !(s < e) }' || die 'persona workers must run concurrently'
echo "in-session-driver: ok"
