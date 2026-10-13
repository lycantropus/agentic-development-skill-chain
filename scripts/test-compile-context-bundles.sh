#!/usr/bin/env bash
# compile-context-bundles.mjs: implementer view of the ONE PROJ architecture
# document (wave filter, dropped diagrams, strict item parsing, scope reuse),
# the pre-CP1 `check`, the legacy delta fallback and the `architecture-delta`
# manifest alias.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/codex/skills/5_executing"
COMPILE="$SKILL/scripts/compile-context-bundles.mjs"
CASE="$(mktemp -d)"
trap 'rm -rf "$CASE"' EXIT
die() { echo "compile-context-bundles: $*" >&2; exit 1; }

P="$CASE/specs/PROJ-1-demo"
mkdir -p "$P/3-4_plan" "$CASE/docs"
echo "# Product" >"$CASE/docs/PRODUCT.md"
cat >"$P/3-4_plan/PROJ-1-architecture.md" <<'ARCH'
# PROJ-1 Architecture — demo

## Overview
Adds invoices.

## PRDs Covered
- PROJ-1-PRD-1: invoices

## System Boundaries
```mermaid
flowchart LR
  APP-->DIAGRAM_NODE
```

## Data Model
- Invoice: owned by PRD-1

## Key Flows
### Flow 1: Invoice export
**Affects:** PRD-2
**Summary:** Export enqueues first, then polls (FLOW_ONE_RULE).
```mermaid
sequenceDiagram
  APP->>FLOW_DIAGRAM: export
```

## Cross-Cutting Tech Decisions
### Decision 1: Server-side totals
**Affects:** PRD-1
**Summary:** Totals are computed on the server (one rounding rule).
FULL_RATIONALE_ONE spans several sentences.

### Decision 2: Export queue
**Affects:** PRD-2
**Summary:** Exports run through a queue (long jobs).

### Decision 3: Auth on every route
**Affects:** all
**Changes baseline:** docs/ARCHITECTURE.md § Invariants
**Summary:** Every route checks the session.

## UI Implementation Constraints
- UI_ONLY_CONSTRAINT
ARCH
printf '# Wave 1\n\n**PRDs involved:** PROJ-1-PRD-1\n\n## PROJ-1-PRD-1-US-1: Create invoice\n' >"$P/3-4_plan/PROJ-1-wave-1-plan.md"
printf '# Wave 2\n\n**PRDs involved:** PROJ-1-PRD-2\n\n## PROJ-1-PRD-2-US-1: Export invoices\n' >"$P/3-4_plan/PROJ-1-wave-2-plan.md"

cd "$CASE"
run() { node "$COMPILE" "$@" --roles-dir "$SKILL/manifests/roles"; }

run compile 1 demo --wave 1 >/dev/null
B="specs/PROJ-1-demo/context/bundle-backend-implementer.md"
F="specs/PROJ-1-demo/context/bundle-frontend-implementer.md"
grep -qF 'Decision 1: Server-side totals** (Affects: PRD-1) — Totals are computed' "$B" || die "wave-1 decision missing"
grep -qF 'Decision 3: Auth on every route' "$B" || die "'all' decision missing"
grep -qF 'Overrides the baseline: docs/ARCHITECTURE.md § Invariants' "$B" || die "Changes baseline pointer missing"
grep -q 'Decision 1: Server-side totals.*(one rounding rule)\.$' "$B" || die "a decision without Changes baseline must not get the override note"
grep -qF 'Decision 2' "$B" && die "wave-2 decision leaked into wave 1"
grep -qF 'FLOW_ONE_RULE' "$B" && die "wave-2 key flow leaked into wave 1"
grep -qF 'FLOW_DIAGRAM' "$B" && die "key flow diagram leaked"
grep -qF 'FULL_RATIONALE_ONE' "$B" && die "decision body leaked (only Summary belongs in the bundle)"
grep -qF 'DIAGRAM_NODE' "$B" && die "Mermaid diagram leaked"
grep -qF 'Invoice: owned by PRD-1' "$B" || die "data model section missing"
grep -qF 'UI_ONLY_CONSTRAINT' "$B" && die "UI constraints leaked into a backend bundle"
grep -qF 'UI_ONLY_CONSTRAINT' "$F" || die "UI constraints missing from the frontend bundle"
jq -e '."backend-implementer" | .budget == 6500 and .budget_override == false' specs/PROJ-1-demo/context/bundles.lock.json >/dev/null \
  || die "lock must record the effective budget and override flag"

run compile 1 demo --wave 2 >/dev/null
grep -qF 'Decision 2: Export queue' "$B" || die "wave-2 decision missing"
grep -qF 'Decision 1' "$B" && die "wave-1 decision leaked into wave 2"
grep -qF 'Flow 1: Invoice export** (Affects: PRD-2) — Export enqueues first' "$B" || die "wave-2 key flow missing"

# compile without --wave keeps the lock's scope; no lock -> refuse, write nothing
run compile 1 demo >/dev/null
jq -e '[.[].wave] | unique == [2]' specs/PROJ-1-demo/context/bundles.lock.json >/dev/null || die "scope not kept from the lock"
mv specs/PROJ-1-demo/context/bundles.lock.json "$CASE/lock.keep"
if run compile 1 demo >/dev/null 2>&1; then die "compile without lock or --wave guessed a scope"; fi
[ -e specs/PROJ-1-demo/context/bundles.lock.json ] && die "refused compile wrote a lock"
mv "$CASE/lock.keep" specs/PROJ-1-demo/context/bundles.lock.json

CONTEXT_BUNDLE_BUDGET=99999 run compile 1 demo --wave all >/dev/null 2>&1
jq -e '."backend-implementer".budget_override == true' specs/PROJ-1-demo/context/bundles.lock.json >/dev/null \
  || die "budget override must be recorded in the lock"
grep -qF 'Decision 2' "$B" && grep -qF 'Decision 1' "$B" || die "unscoped compile must list every decision"

# check: compiles every wave in memory, writes nothing, exits 1 on a breach
rm -rf specs/PROJ-1-demo/context
run check 1 demo >"$CASE/check.out" || die "check failed on a fitting PROJ"
grep -q '^wave 2:' "$CASE/check.out" || die "check must cover every wave"
[ -e specs/PROJ-1-demo/context ] && die "check must not write"
if run check 1 demo --budget 50 >/dev/null 2>&1; then die "check accepted a budget breach"; fi

# The header must cover real story sections before it can filter decisions.
PLAN="$P/3-4_plan/PROJ-1-wave-1-plan.md"
cp "$PLAN" "$CASE/plan.bak"
for header in '**PRDs involved:** PROJ-1-PRD-2' '**PRDs involved:**' ''; do
  printf '# Wave 1\n\n%s\n\n## PROJ-1-PRD-1-US-1: Create invoice\n' "$header" >"$PLAN"
  for command in 'compile 1 demo --wave 1' 'check 1 demo'; do
    if run $command >"$CASE/prds.out" 2>&1; then die "$command accepted a header omitting PRD-1"; fi
    grep -qF 'PRDs involved' "$CASE/prds.out" && grep -qF 'PRD-1' "$CASE/prds.out" \
      || die "missing PRD rejection must identify the header and omitted PRD"
  done
done
cat >"$PLAN" <<'PLAN'
# Wave 1
**PRDs involved:** PROJ-1-PRD-1, PROJ-1-PRD-2
## PROJ-1-PRD-1-US-1: Create invoice
## PROJ-1-PRD-2-US-1: Export invoices
````markdown
## PROJ-1-PRD-3-US-1: Example only
```not-a-closing-fence
## PROJ-1-PRD-4-US-1: Still an example
````
~~~markdown
## PROJ-1-PRD-5-US-1: Another example
~~~
PLAN
run compile 1 demo --wave 1 >/dev/null
grep -qF 'Decision 1: Server-side totals' "$B" && grep -qF 'Decision 2: Export queue' "$B" \
  || die "complete mixed-PRD header must include both decisions"
run check 1 demo >/dev/null || die "check rejected a complete header or counted fenced examples"
cp "$CASE/plan.bak" "$PLAN"

# malformed items fail loudly instead of vanishing from (or corrupting) the bundle
A="$P/3-4_plan/PROJ-1-architecture.md"
cp "$A" "$CASE/arch.bak"
rejects() { # sed-expression reason
  cp "$CASE/arch.bak" "$A"; sed -i "$1" "$A"
  if run check 1 demo >/dev/null 2>&1; then die "accepted: $2"; fi
}
rejects '/^\*\*Summary:\*\* Exports run/d' "decision without Summary"
rejects 's/^### Decision 2: Export queue/### Decision 2 — Export queue/' "malformed decision heading"
rejects 's/^\*\*Affects:\*\* PRD-2$/**Affects:** PRD-2\n**Affects:** PRD-1/' "doubled Affects line"
rejects 's/^\*\*Affects:\*\* PRD-2$/**Affects:** US-4 (exports)/' "Affects without a PRD"
rejects 's/^\*\*Affects:\*\* PRD-2$/**Affects:** PRD-9/' "Affects reaching no wave"
rejects '/^### Flow 1/d' "key flow content without a Flow item"
cp "$CASE/arch.bak" "$A"

# legacy PROJ: no Summary lines anywhere -> architecture-delta.md
sed -i '/^\*\*Summary:\*\*/d' "$P/3-4_plan/PROJ-1-architecture.md"
echo "LEGACY_DELTA_TEXT" >"$P/architecture-delta.md"
run compile 1 demo --wave all >/dev/null
grep -qF 'LEGACY_DELTA_TEXT' "$B" || die "legacy delta fallback broken"
rm "$P/architecture-delta.md"
run compile 1 demo >/dev/null
grep -qF 'FULL_RATIONALE_ONE' "$B" || die "legacy full-document fallback broken"
cp "$CASE/arch.bak" "$P/3-4_plan/PROJ-1-architecture.md"

# repo manifests synced before the rename still say architecture-delta
mkdir -p "$CASE/roles"
cp "$SKILL/manifests/roles/backend-implementer.md" "$CASE/roles/"
sed -i 's/^  - proj-architecture$/  - architecture-delta/' "$CASE/roles/backend-implementer.md"
node "$COMPILE" compile 1 demo --wave 1 --roles-dir "$CASE/roles" >/dev/null || die "legacy manifest id rejected"
grep -qF 'Decision 1: Server-side totals' "$B" || die "legacy manifest id did not map to the architecture view"

echo "compile-context-bundles: ok"
