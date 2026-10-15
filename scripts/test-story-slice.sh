#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLICE="$ROOT/codex/skills/5_executing/scripts/story-slice.mjs"
CASE="$(mktemp -d)"
trap 'rm -rf "$CASE"' EXIT

cat >"$CASE/plan.md" <<'PLAN'
# Wave 1

## Execution
- **Mode:** `parallel`

## PROJ-1-PRD-1-US-1: First
**Acceptance Criteria:**
- [ ] PROJ-1-PRD-1-US-1-AC-1: works

### Task PROJ-1-PRD-1-US-1-T1: Build
````md
```
## not a heading inside a fence
````

## PROJ-1-PRD-1-US-10: Tenth
- [ ] PROJ-1-PRD-1-US-10-AC-1: other
PLAN

node "$SLICE" "$CASE/plan.md" PROJ-1-PRD-1-US-1 >"$CASE/out"
head -n 1 "$CASE/out" | grep -qx '## PROJ-1-PRD-1-US-1: First' || { echo "slice must start at its heading" >&2; exit 1; }
grep -qF '## not a heading inside a fence' "$CASE/out" || { echo "fenced ## line must not end the slice" >&2; exit 1; }
grep -qF 'US-10' "$CASE/out" && { echo "slice leaked into US-10" >&2; exit 1; }
grep -qF 'Execution' "$CASE/out" && { echo "slice leaked the lead header" >&2; exit 1; }
node "$SLICE" "$CASE/plan.md" PROJ-1-PRD-1-US-10 | grep -qF 'US-10-AC-1' || { echo "last section must slice to EOF" >&2; exit 1; }

# CRLF plan: fences and headings still match; only the line endings differ
sed 's/$/\r/' "$CASE/plan.md" >"$CASE/crlf.md"
node "$SLICE" "$CASE/crlf.md" PROJ-1-PRD-1-US-1 | tr -d '\r' | cmp - "$CASE/out" || { echo "CRLF plan sliced differently" >&2; exit 1; }
node "$SLICE" "$CASE/crlf.md" PROJ-1-PRD-1-US-1 | head -1 | grep -q $'\r$' || { echo "CRLF slice must keep its bytes" >&2; exit 1; }

# exported slice(): same bytes as the CLI; throws with `count` unless exactly one section matches
node --input-type=module -e '
const { slice } = await import(process.argv[1]);
const { readFileSync, writeFileSync } = await import("node:fs");
const text = readFileSync(process.argv[2], "utf8");
writeFileSync(process.argv[3], slice(text, "PROJ-1-PRD-1-US-1"));
const countOf = (t, id) => { try { slice(t, id); } catch (e) { return e.count; } return "no throw"; };
for (const [t, id, want] of [[text, "PROJ-1-PRD-1-US-2", 0], [text + "\n## PROJ-1-PRD-1-US-1: Again\n", "PROJ-1-PRD-1-US-1", 2]]) {
  if (countOf(t, id) !== want) { console.error(`slice(${id}) count: ${countOf(t, id)}, want ${want}`); process.exit(1); }
}
' "file://$(dirname "$SLICE")/document-parser.mjs" "$CASE/plan.md" "$CASE/api-out"
cmp "$CASE/out" "$CASE/api-out" || { echo "slice() differs from CLI output" >&2; exit 1; }

if node "$SLICE" "$CASE/plan.md" PROJ-1-PRD-1-US-2 >/dev/null 2>&1; then echo "missing ID accepted" >&2; exit 1; fi
printf '\n## PROJ-1-PRD-1-US-1: Again\n' >>"$CASE/plan.md"
if node "$SLICE" "$CASE/plan.md" PROJ-1-PRD-1-US-1 >/dev/null 2>&1; then echo "duplicate ID accepted" >&2; exit 1; fi

node "$SLICE" "$ROOT/scripts/fixtures/wave-plan-validator/plan-valid.md" PROJ-1-PRD-1-US-1 | grep -qF '### Task PROJ-1-PRD-1-US-1-T1' || { echo "validator fixture did not slice" >&2; exit 1; }
echo "story-slice: ok"
