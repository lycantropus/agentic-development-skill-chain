#!/usr/bin/env bash
# compile-context-bundles.mjs: one file per worker (story files with the slice,
# role files per wave, contract/fan-out splits, cleanup, migration, show,
# fail-before-write), the implementer view of the ONE PROJ architecture
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
cat >"$P/3-4_plan/PROJ-1-wave-1-plan.md" <<'PLAN'
# Wave 1

**PRDs involved:** PROJ-1-PRD-1

## User Stories in this Wave

| US ID | Scope | Agent Type | Complexity | Can start when |
|---|---|---|---|---|
| PROJ-1-PRD-1-US-1 | backend | backend-implementer | sonnet | immediately |
| PROJ-1-PRD-1-US-2 | full-stack | implementer | opus | US-1 merged |
| PROJ-1-PRD-1-US-3 | full-stack | skillchain-implementer | sonnet | immediately |

## PROJ-1-PRD-1-US-1: Create invoice
**Scope:** backend → backend-implementer

- [ ] PROJ-1-PRD-1-US-1-AC-1: STORY_ONE_AC

## PROJ-1-PRD-1-US-2: Invoice form
**Scope:** full-stack → implementer
**Split:** `contract`

## PROJ-1-PRD-1-US-3: Bulk edit
**Scope:** full-stack
**Split:** `fan-out` + disjoint file sets
PLAN
cat >"$P/3-4_plan/PROJ-1-wave-2-plan.md" <<'PLAN'
# Wave 2

**PRDs involved:** PROJ-1-PRD-2

## User Stories in this Wave

| US ID | Scope | Agent Type | Complexity | Can start when |
|---|---|---|---|---|
| PROJ-1-PRD-2-US-1 | frontend | frontend-implementer | sonnet | immediately |

## PROJ-1-PRD-2-US-1: Export invoices
**Scope:** frontend
PLAN

cp "$P/3-4_plan/PROJ-1-architecture.md" "$CASE/arch.keep"
cd "$CASE"
run() { node "$COMPILE" "$@" --roles-dir "$SKILL/manifests/roles"; }
CTX="specs/PROJ-1-demo/context"
snap() { find "$CTX" .claude -type f 2>/dev/null | sort | xargs -r sha256sum; }
rc() { local r=0; "$@" >/dev/null 2>"$CASE/err" || r=$?; echo "$r"; } # exit code; stderr in $CASE/err

# retired injector stub (skill-tree manifests; no lock, no bundles here):
# roles with an inject list get the notice only, everything else nothing, exit 0
INJ="$SKILL/scripts/context-injector.mjs"
NOTICE='{"hookSpecificOutput":{"hookEventName":"SubagentStart","additionalContext":"Dieser Hook ist stillgelegt. Dein Auftrag steht in der Datei aus dem Spawn-Prompt. Ohne Pfad: abbrechen und melden."}}'
for t in implementer skillchain-implementer frontend-implementer backend-implementer reviewer skillchain-reviewer-x micro-fixer explore scout general-purpose ''; do
  out="$(printf '{"agent_type":"%s"}' "$t" | node "$INJ" claude)" || die "stub exited non-zero for '$t'"
  case "$t" in micro-fixer|explore|scout|general-purpose|'') want='' ;; *) want="$NOTICE" ;; esac
  [ "$out" = "$want" ] || die "stub output for '$t': $out"
done
[ -z "$(echo 'not json' | node "$INJ" claude)" ] || die "stub must ignore unparseable hook input"
[ -z "$(node "$INJ" codex implementer --path 2>/dev/null)" ] || die "stub codex mode must print nothing"
[ "$(rc node "$INJ" bogus)" -eq 1 ] || die "stub with an unknown mode must exit 1"

run compile 1 demo --wave 1 >/dev/null
B="$CTX/roles/wave-1/backend-implementer.md"
F="$CTX/roles/wave-1/frontend-implementer.md"
grep -qF 'Decision 1: Server-side totals** (Affects: PRD-1) — Totals are computed' "$B" || die "wave-1 decision missing"
grep -qF 'Decision 3: Auth on every route' "$B" || die "'all' decision missing"
grep -qF 'Overrides the baseline: docs/ARCHITECTURE.md § Invariants' "$B" || die "Changes baseline pointer missing"
grep -q 'Decision 1: Server-side totals.*(one rounding rule)\.$' "$B" || die "a decision without Changes baseline must not get the override note"
grep -qF 'Decision 2' "$B" && die "wave-2 decision leaked into wave 1"
grep -qF 'FLOW_ONE_RULE' "$B" && die "wave-2 key flow leaked into wave 1"
grep -qF 'FLOW_DIAGRAM' "$B" && die "key flow diagram leaked"
grep -qF 'FULL_RATIONALE_ONE' "$B" && die "decision body leaked (only Summary belongs in the file)"
grep -qF 'DIAGRAM_NODE' "$B" && die "Mermaid diagram leaked"
grep -qF 'Invoice: owned by PRD-1' "$B" || die "data model section missing"
grep -qF 'UI_ONLY_CONSTRAINT' "$B" && die "UI constraints leaked into a backend file"
grep -qF 'UI_ONLY_CONSTRAINT' "$F" || die "UI constraints missing from the frontend file"
[ -e "$CTX/roles/wave-2" ] && die "--wave 1 compiled wave 2"

# story file: header, role from the table, slice byte-exact at the end
W="$CTX/workers/wave-1/PROJ-1-PRD-1-US-1.md"
PLAN1="specs/PROJ-1-demo/3-4_plan/PROJ-1-wave-1-plan.md"
[ "$(head -1 "$W")" = "Generated from $PLAN1 @ $(sha256sum "$PLAN1" | cut -c1-12) · role backend-implementer · wave 1" ] || die "story file header wrong: $(head -1 "$W")"
node "$SKILL/scripts/story-slice.mjs" "$PLAN1" PROJ-1-PRD-1-US-1 >"$CASE/slice.out"
sed '1,/^## Deine Story$/d' "$W" | tail -n +2 | cmp - "$CASE/slice.out" || die "story part is not the slice byte for byte"
[ "$(tail -n +3 "$W" | sed '/^## Deine Story$/,$d')" = "$(tail -n +3 "$B")" ] || die "story file role context differs from the role file"
grep -qF 'STORY_ONE_AC' "$B" && die "story leaked into the role file"
# Split: contract -> two files with the side roles; fan-out -> one shared file
for side in backend frontend; do
  head -1 "$CTX/workers/wave-1/PROJ-1-PRD-1-US-2.$side.md" | grep -qF "role $side-implementer" || die "contract $side file missing or wrong role"
done
[ -e "$CTX/workers/wave-1/PROJ-1-PRD-1-US-2.md" ] && die "contract story also got an unsplit file"
head -1 "$CTX/workers/wave-1/PROJ-1-PRD-1-US-3.md" | grep -qF 'role implementer' || die "fan-out story must be one implementer file"
grep -qF 'Design system (docs/DESIGN-SYSTEM.md)' "$CTX/workers/wave-1/PROJ-1-PRD-1-US-3.md" || die "implementer file lacks the design system"
grep -qF 'Security baseline' "$CTX/workers/wave-1/PROJ-1-PRD-1-US-3.md" || die "implementer file lacks the security baseline"
# agent files: path pointer for roles with an inject list only
grep -qF 'Dein vollständiger Auftrag steht in der Datei aus dem Spawn-Prompt. Lies sie zuerst vollständig. Fehlt der Pfad oder ist die Datei nicht lesbar, brich ab und melde das.' .claude/agents/skillchain-implementer.md \
  || die "implementer agent file lacks the path pointer"
grep -qF 'Spawn-Prompt' .claude/agents/skillchain-micro-fixer.md && die "micro-fixer agent file got a path pointer"
grep -qF 'SubagentStart' .claude/agents/skillchain-*.md && die "agent files still mention the hook"
[ -e .claude/agents/skillchain-explore.md ] && die "explore got an agent file"
[ -e "$CTX/roles/wave-1/micro-fixer.md" ] || [ -e "$CTX/roles/wave-1/explore.md" ] && die "tier 0/explore got a role file"

run compile 1 demo --wave 2 >/dev/null
B2="$CTX/roles/wave-2/backend-implementer.md"
grep -qF 'Decision 2: Export queue' "$B2" || die "wave-2 decision missing"
grep -qF 'Decision 1' "$B2" && die "wave-1 decision leaked into wave 2"
grep -qF 'Flow 1: Invoice export** (Affects: PRD-2) — Export enqueues first' "$B2" || die "wave-2 key flow missing"
head -1 "$CTX/workers/wave-2/PROJ-1-PRD-2-US-1.md" | grep -qF 'role frontend-implementer · wave 2' || die "role must come from the table"
[ -e "$W" ] || die "--wave 2 removed wave-1 files"

# compile without --wave compiles every wave on its own; a rerun is idempotent
rm -rf "$CTX"
run compile 1 demo >/dev/null
grep -qF 'Decision 1' "$B" && ! grep -qF 'Decision 2' "$B" && grep -qF 'Decision 2' "$B2" && ! grep -qF 'Decision 1' "$B2" \
  || die "compile without --wave must compile each wave separately"
snap >"$CASE/full.snap"
run compile 1 demo --wave all >/dev/null
snap | cmp - "$CASE/full.snap" || die "rerun is not byte-identical"

# budget breach and parser error: exit != 0, nothing written or deleted
cp -r "$SKILL/manifests/roles" "$CASE/tight"
sed -i 's/^budget_tokens: .*/budget_tokens: 50/' "$CASE/tight/reviewer.md"
if node "$COMPILE" compile 1 demo --roles-dir "$CASE/tight" >"$CASE/budget.out" 2>&1; then die "budget breach compiled"; fi
grep -qE 'reviewer [0-9]+/50 tokens' "$CASE/budget.out" || die "budget breach must name role, tokens and budget"
snap | cmp - "$CASE/full.snap" || die "budget breach changed files"
cp "$PLAN1" "$CASE/plan1.bak"
sed -i 's/^| PROJ-1-PRD-1-US-1 | backend | backend-implementer/| PROJ-1-PRD-1-US-1 | backend | data-implementer/' "$PLAN1"
[ "$(rc run compile 1 demo)" -eq 2 ] || die "unsupported Agent Type must exit 2"
grep -qF "$PLAN1: PROJ-1-PRD-1-US-1: unsupported Agent Type" "$CASE/err" || die "parser error must name plan and story"
snap | cmp - "$CASE/full.snap" || die "parser error changed files"
if run check 1 demo >/dev/null 2>&1; then die "check accepted an unassignable story"; fi
cp "$CASE/plan1.bak" "$PLAN1"

# write error (a file where the workers dir belongs): exit 1, rerun completes
rm -rf "$CTX/workers"; touch "$CTX/workers"
[ "$(rc run compile 1 demo)" -eq 1 ] || die "write error must exit 1"
rm "$CTX/workers"
run compile 1 demo >/dev/null
snap | cmp - "$CASE/full.snap" || die "rerun after a write error is incomplete"

# migration of a running PROJ: old bundles, lock, blocked roles and the
# injector hook vanish; only the injector entry and the Ponytail matcher leave
# the settings (foreign hooks, look-alike commands, groups, env and key order
# stay); a rerun is a no-op
for f in bundle-implementer.md bundle-implementer.claude.md bundle-reviewer.codex.md bundles.lock.json blocked-roles.json; do echo old >"$CTX/$f"; done
cp "$ROOT/scripts/fixtures/injector-hook/settings.json" .claude/settings.json   # shared with test-preflight-biome.sh
run compile 1 demo --wave 1 >/dev/null
ls "$CTX" | grep -qE '^bundle-|bundles.lock.json|blocked-roles.json' && die "old bundles/lock survived compile"
for name in PROJ-1-PRD-1-US-1 PROJ-1-PRD-1-US-2.backend PROJ-1-PRD-1-US-2.frontend PROJ-1-PRD-1-US-3; do
  [ -s "$CTX/workers/wave-1/$name.md" ] || die "migration: $name has no worker file"
done
for role in implementer frontend-implementer backend-implementer reviewer; do
  grep -qF 'Dein vollständiger Auftrag steht in der Datei aus dem Spawn-Prompt' ".claude/agents/skillchain-$role.md" || die "migration: $role agent file lacks the path pointer"
done
[ "$(jq -c . .claude/settings.json)" = "$(jq -c . "$ROOT/scripts/fixtures/injector-hook/expected.json")" ] \
  || die "compile must remove only the injector hooks and the Ponytail matcher: $(jq -c . .claude/settings.json)"
grep -q '^  "permissions": {$' .claude/settings.json || die "settings must keep two-space indentation"
snap >"$CASE/migrated.snap"
run compile 1 demo --wave 1 >/dev/null
snap | cmp - "$CASE/migrated.snap" || die "second compile after the migration changed something"
printf '{"hooks":{"SubagentStart":[{"hooks":[{"type":"command","command":"node scripts/context-injector.mjs claude"}]}]}}\n' >.claude/settings.json
run compile 1 demo --wave 1 >/dev/null
[ "$(jq -c . .claude/settings.json)" = '{}' ] || die "injector-only settings must lose hooks entirely"
printf '{ broken\n' >.claude/settings.json
run compile 1 demo --wave 1 >/dev/null 2>"$CASE/err" || die "unparseable settings must not abort compile"
grep -qF 'not valid JSON' "$CASE/err" && [ "$(cat .claude/settings.json)" = '{ broken' ] || die "unparseable settings: want a warning and an unchanged file"
rm .claude/settings.json
run compile 1 demo --wave 1 >/dev/null
[ ! -e .claude/settings.json ] || die "compile created .claude/settings.json"

# show: story file, split suffix, role per wave; 64 lists candidates, 2 when not compiled
run show 1 demo PROJ-1-PRD-1-US-1 | cmp - "$W" || die "show US-ID"
run show 1 demo PROJ-1-PRD-1-US-2.frontend | cmp - "$CTX/workers/wave-1/PROJ-1-PRD-1-US-2.frontend.md" || die "show split suffix"
run show 1 demo --wave 2 backend-implementer | cmp - "$B2" || die "show --wave N role"
for args in "PROJ-1-PRD-1-US-2|PROJ-1-PRD-1-US-2.backend" "backend-implementer|--wave 1 backend-implementer" "PROJ-1-PRD-9-US-1|PROJ-1-PRD-2-US-1" "--wave 1 nobody|--wave 2 reviewer"; do
  [ "$(rc run show 1 demo ${args%%|*})" -eq 64 ] && grep -qF -- "${args#*|}" "$CASE/err" || die "show ${args%%|*}: want 64 listing ${args#*|}"
done
rm "$W"
[ "$(rc run show 1 demo PROJ-1-PRD-1-US-1)" -eq 2 ] && grep -qF 'run compile' "$CASE/err" || die "show of an uncompiled file: want 2 with a compile hint"

# cleanup: deleted story, story moved to another wave, lifted split, deleted wave
run compile 1 demo >/dev/null
sed -i '/^| PROJ-1-PRD-1-US-3 /d; /^## PROJ-1-PRD-1-US-3:/,$d' "$PLAN1"
sed -i 's/^\*\*Split:\*\* `contract`$/**Split:** none/' "$PLAN1"
run compile 1 demo --wave 1 >/dev/null
[ -e "$CTX/workers/wave-1/PROJ-1-PRD-1-US-3.md" ] && die "deleted story left its file"
[ -e "$CTX/workers/wave-1/PROJ-1-PRD-1-US-2.backend.md" ] && die "lifted split left its side files"
[ -e "$CTX/workers/wave-1/PROJ-1-PRD-1-US-2.md" ] || die "lifted split must give one file"
printf '| PROJ-1-PRD-1-US-1 | backend | backend-implementer | sonnet | immediately |\n\n## PROJ-1-PRD-1-US-1: Create invoice\n' >"$CASE/moved"
sed -i 's/^\*\*PRDs involved:\*\* PROJ-1-PRD-2$/**PRDs involved:** PROJ-1-PRD-1, PROJ-1-PRD-2/; /^| PROJ-1-PRD-2-US-1 /r '"$CASE/moved" specs/PROJ-1-demo/3-4_plan/PROJ-1-wave-2-plan.md
sed -i '/^| PROJ-1-PRD-1-US-1 /d; /^## PROJ-1-PRD-1-US-1:/,/^## /{/^## PROJ-1-PRD-1-US-2/!d}' "$PLAN1"
run compile 1 demo --wave 2 >/dev/null
[ -e "$CTX/workers/wave-2/PROJ-1-PRD-1-US-1.md" ] || die "moved story missing in its new wave"
[ -e "$CTX/workers/wave-1/PROJ-1-PRD-1-US-1.md" ] && die "moved story left its file in the old wave"
mv specs/PROJ-1-demo/3-4_plan/PROJ-1-wave-2-plan.md "$CASE/wave2.bak"
run compile 1 demo --wave 1 >/dev/null
[ -e "$CTX/workers/wave-2" ] || [ -e "$CTX/roles/wave-2" ] && die "deleted wave left its directories"
mv "$CASE/wave2.bak" specs/PROJ-1-demo/3-4_plan/PROJ-1-wave-2-plan.md
restore_plans() { cp "$CASE/plan1.bak" "$PLAN1"; printf '# Wave 2\n\n**PRDs involved:** PROJ-1-PRD-2\n\n## User Stories in this Wave\n\n| US ID | Scope | Agent Type | Complexity | Can start when |\n|---|---|---|---|---|\n| PROJ-1-PRD-2-US-1 | frontend | frontend-implementer | sonnet | immediately |\n\n## PROJ-1-PRD-2-US-1: Export invoices\n**Scope:** frontend\n' >specs/PROJ-1-demo/3-4_plan/PROJ-1-wave-2-plan.md; }
restore_plans

# one story ID in two wave plans: compile (even --wave N), check and show exit 2 before any change
run compile 1 demo >/dev/null
snap >"$CASE/dup.snap"
PLAN2="specs/PROJ-1-demo/3-4_plan/PROJ-1-wave-2-plan.md"
cp "$PLAN2" "$CASE/plan2.bak"
sed -i 's/PROJ-1-PRD-2-US-1/PROJ-1-PRD-1-US-1/g; s/^\*\*PRDs involved:\*\* PROJ-1-PRD-2$/**PRDs involved:** PROJ-1-PRD-1/' "$PLAN2"
for args in "compile 1 demo --wave 1" "check 1 demo" "show 1 demo PROJ-1-PRD-1-US-1"; do
  [ "$(rc run $args)" -eq 2 ] && grep -qF "PROJ-1-PRD-1-US-1 is a story in two wave plans: $PLAN1 and $PLAN2" "$CASE/err" \
    || die "$args: duplicate story across waves must exit 2 naming ID and both plans"
done
snap | cmp - "$CASE/dup.snap" || die "duplicate story across waves changed files"
cp "$CASE/plan2.bak" "$PLAN2"

# CRLF plan (with a fenced ## line) and CRLF architecture compile like LF
printf '\n```md\n## not a story heading\n```\n' >>"$PLAN1"
sed -i 's/$/\r/' "$PLAN1" "$P/3-4_plan/PROJ-1-architecture.md"
run compile 1 demo --wave 1 >/dev/null || die "CRLF plan failed to compile"
node "$SKILL/scripts/story-slice.mjs" "$PLAN1" PROJ-1-PRD-1-US-3 >"$CASE/slice.out"
sed '1,/^## Deine Story$/d' "$CTX/workers/wave-1/PROJ-1-PRD-1-US-3.md" | tail -n +2 | cmp - "$CASE/slice.out" || die "CRLF story part is not the slice byte for byte"
grep -qF 'Decision 1: Server-side totals' "$B" || die "CRLF architecture lost its decisions"
restore_plans; cp "$CASE/arch.keep" "$P/3-4_plan/PROJ-1-architecture.md"

# a manifest name becomes a file name: anything but ^[a-z][a-z0-9-]*$ is refused
cp -r "$SKILL/manifests/roles" "$CASE/badname"
sed -i 's|^name: reviewer$|name: ../reviewer|' "$CASE/badname/reviewer.md"
[ "$(rc node "$COMPILE" compile 1 demo --roles-dir "$CASE/badname")" -eq 1 ] && grep -qF "manifest name '../reviewer'" "$CASE/err" \
  || die "invalid manifest name must exit 1"

# missing plan wave, plan without a story, missing plan folder: exit 2
[ "$(rc run compile 1 demo --wave 9)" -eq 2 ] || die "unknown wave must exit 2"
printf '# Wave 3\n\n**PRDs involved:** PROJ-1-PRD-1\n' >specs/PROJ-1-demo/3-4_plan/PROJ-1-wave-3-plan.md
[ "$(rc run compile 1 demo)" -eq 2 ] || die "plan without a story must exit 2"
rm specs/PROJ-1-demo/3-4_plan/PROJ-1-wave-3-plan.md
mkdir -p specs/PROJ-2-legacy/6_plan
cp specs/PROJ-1-demo/3-4_plan/PROJ-1-wave-2-plan.md specs/PROJ-2-legacy/6_plan/PROJ-2-wave-1-plan.md
sed -i 's/PROJ-1-PRD-2/PROJ-2-PRD-1/g' specs/PROJ-2-legacy/6_plan/PROJ-2-wave-1-plan.md
run compile 2 legacy >/dev/null || die "6_plan project failed"
[ -e specs/PROJ-2-legacy/context/workers/wave-1/PROJ-2-PRD-1-US-1.md ] || die "6_plan project got no story file"
mkdir -p specs/PROJ-3-noplan
[ "$(rc run compile 3 noplan)" -eq 2 ] || die "missing plan folder must exit 2"

# project-local manifests win; the old preamble or an implementer without design system exits 2
mkdir -p templates/roles
cp "$SKILL"/manifests/roles/*.md templates/roles/
node "$COMPILE" compile 1 demo --wave 1 >/dev/null || die "unchanged local manifests rejected"
sed -i 's/^Your story and its ACs are in the `## Deine Story` section of this$/Your US, ACs, and tasks arrive in the spawn prompt from the orchestrator./' templates/roles/frontend-implementer.md
snap >"$CASE/before.snap"
[ "$(rc node "$COMPILE" compile 1 demo --wave 1)" -eq 2 ] && grep -qF 'templates/roles/frontend-implementer.md' "$CASE/err" || die "old local preamble: want 2 naming the file"
[ "$(rc node "$COMPILE" check 1 demo)" -eq 2 ] || die "check must report the old local preamble"
snap | cmp - "$CASE/before.snap" || die "manifest error changed files"
cp "$SKILL/manifests/roles/frontend-implementer.md" templates/roles/
sed -i '/^  - design-system$/d' templates/roles/implementer.md
[ "$(rc node "$COMPILE" compile 1 demo --wave 1)" -eq 2 ] && grep -qF 'design-system' "$CASE/err" || die "local implementer without design system: want 2"
rm -rf templates

# check: compiles every wave in memory, writes nothing, exits 1 on a breach
rm -rf specs/PROJ-1-demo/context
run check 1 demo >"$CASE/check.out" || die "check failed on a fitting PROJ"
grep -q '^wave 2:' "$CASE/check.out" || die "check must cover every wave"
[ -e specs/PROJ-1-demo/context ] && die "check must not write"
if node "$COMPILE" check 1 demo --roles-dir "$CASE/tight" >/dev/null 2>&1; then die "check accepted a budget breach"; fi

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
## PROJ-1-PRD-2-US-2: Export invoices
````markdown
## PROJ-1-PRD-3-US-1: Example only
```not-a-closing-fence
## PROJ-1-PRD-4-US-1: Still an example
````
~~~markdown
## PROJ-1-PRD-5-US-1: Another example
~~~
PLAN
run compile 1 demo --wave 1 >/dev/null 2>"$CASE/fallback.err"
grep -qF "$PLAN1: no Agent Type column in the story table — every story falls back to implementer" "$CASE/fallback.err" \
  || die "a plan without Agent Type column must print the fallback hint"
head -1 "$CTX/workers/wave-1/PROJ-1-PRD-2-US-2.md" | grep -qF 'role implementer' || die "legacy fallback role must be implementer"
grep -qF 'Decision 1: Server-side totals' "$B" && grep -qF 'Decision 2: Export queue' "$B" \
  || die "complete mixed-PRD header must include both decisions"
run check 1 demo >/dev/null 2>&1 || die "check rejected a complete header or counted fenced examples"
cp "$CASE/plan.bak" "$PLAN"

# malformed items fail loudly instead of vanishing from (or corrupting) the file
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
cp -r "$SKILL/manifests/roles" "$CASE/roles"
sed -i 's/^  - proj-architecture$/  - architecture-delta/' "$CASE/roles/backend-implementer.md"
node "$COMPILE" compile 1 demo --wave 1 --roles-dir "$CASE/roles" >/dev/null || die "legacy manifest id rejected"
grep -qF 'Decision 1: Server-side totals' "$B" || die "legacy manifest id did not map to the architecture view"

echo "compile-context-bundles: ok"
