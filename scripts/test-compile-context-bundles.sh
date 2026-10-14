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
COMPILE="$SKILL/scripts/plan.mjs"
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

# PRD and progress.md never reach a worker file
mkdir -p "$P/2_PRDs" "$P/5_progress"
printf '# PRD\nNEVER-INJECT-MARKER-PRD full requirement text.\n' >"$P/2_PRDs/PROJ-1-PRD-1.md"
printf '# Progress\nNEVER-INJECT-MARKER-PROGRESS wave log.\n' >"$P/5_progress/PROJ-1-progress.md"
cp "$P/3-4_plan/PROJ-1-architecture.md" "$CASE/arch.keep"
cd "$CASE"
run() { node "$COMPILE" context "$@" --roles-dir "$SKILL/manifests/roles"; }
CTX="specs/PROJ-1-demo/context"
snap() { find "$CTX" .claude -type f 2>/dev/null | sort | xargs -r sha256sum; }
rc() { local r=0; "$@" >/dev/null 2>"$CASE/err" || r=$?; echo "$r"; } # exit code; stderr in $CASE/err

mkdir -p .claude/agents   # foreign agent files, one named like a role: compile must not touch them
printf 'mine\n' >.claude/agents/my-agent.md
printf 'mine\n' >.claude/agents/implementer.md
sha256sum .claude/agents/my-agent.md .claude/agents/implementer.md >"$CASE/foreign.sha"
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
bash "$SKILL/scripts/chain" render slice "$PLAN1" PROJ-1-PRD-1-US-1 >"$CASE/slice.out"
sed '1,/^## Deine Story$/d' "$W" | tail -n +2 | cmp - "$CASE/slice.out" || die "story part is not the slice byte for byte"
[ "$(tail -n +3 "$W" | sed '/^## Deine Story$/,$d')" = "$(tail -n +3 "$B")" ] || die "story file role context differs from the role file"
grep -qF 'STORY_ONE_AC' "$B" && die "story leaked into the role file"
# Split: contract -> two files with the side roles; fan-out -> one shared file
for side in backend frontend; do
  head -1 "$CTX/workers/wave-1/PROJ-1-PRD-1-US-2.$side.md" | grep -qF "role $side-implementer" || die "contract $side file missing or wrong role"
done
[ -e "$CTX/workers/wave-1/PROJ-1-PRD-1-US-2.md" ] && die "contract story also got an unsplit file"
head -1 "$CTX/workers/wave-1/PROJ-1-PRD-1-US-3.md" | grep -qF 'role implementer' || die "fan-out story must be one implementer file"
[ "$(ls "$CTX"/workers/wave-1/PROJ-1-PRD-1-US-3* | wc -l)" -eq 1 ] || die "fan-out story must give exactly one file"
grep -qF 'Design system (docs/DESIGN-SYSTEM.md)' "$CTX/workers/wave-1/PROJ-1-PRD-1-US-3.md" || die "implementer file lacks the design system"
grep -qF 'Security baseline' "$CTX/workers/wave-1/PROJ-1-PRD-1-US-3.md" || die "implementer file lacks the security baseline"
# agent files: path pointer for roles with an inject list only
grep -qF 'Dein vollständiger Auftrag steht in der Datei aus dem Spawn-Prompt. Lies sie zuerst vollständig. Fehlt der Pfad oder ist die Datei nicht lesbar, brich ab und melde das.' .claude/agents/skillchain-implementer.md \
  || die "implementer agent file lacks the path pointer"
grep -qF 'Spawn-Prompt' .claude/agents/skillchain-micro-fixer.md && die "micro-fixer agent file got a path pointer"
grep -qF 'SubagentStart' .claude/agents/skillchain-*.md && die "agent files still mention the hook"
[ -e .claude/agents/skillchain-explore.md ] && die "explore got an agent file"
[ -e "$CTX/roles/wave-1/micro-fixer.md" ] || [ -e "$CTX/roles/wave-1/explore.md" ] && die "tier 0/explore got a role file"
[ -z "$(find "$CTX" \( -name 'micro-fixer*' -o -name 'explore*' \))" ] || die "tier 0/explore got a worker or role file"
# only skillchain-<manifest>.md agent files are written; foreign ones stay byte-identical
sha256sum -c --quiet "$CASE/foreign.sha" || die "compile touched a foreign agent file"
[ "$(ls .claude/agents | tr '\n' ' ')" = "implementer.md my-agent.md skillchain-backend-implementer.md skillchain-frontend-implementer.md skillchain-implementer.md skillchain-micro-fixer.md skillchain-reviewer.md " ] \
  || die "unexpected agent files: $(ls .claude/agents | tr '\n' ' ')"

# role matrix over the file contents; sections are told apart by their titles
# (preambles mention "design system" and "security baseline" in prose)
T_PRODUCT='Product (docs/PRODUCT.md)'; T_ARCH='Architecture overview (docs/ARCHITECTURE.md)'; T_PROJ='PROJ architecture ('
T_GUIDE='Guidelines (docs/GUIDELINES.md)'; T_DS='Design system (docs/DESIGN-SYSTEM.md)'; T_COMP='Component registry (docs/components.md)'
T_API='API contracts — own wave only'; T_SEC='Security baseline (docs/security-baseline.md)'; T_TEST='Test conventions (docs/test-conventions.md)'
T_GROUND='Validated assumptions ('; T_CRIT='Review criteria'; T_DIFF='Diff scope'; T_STORY='Deine Story'
sections() { # file, then +title (must have a "## title..." line) / -title (must not)
  local f="$1" spec t; shift
  for spec in "$@"; do
    t="${spec:1}"
    if awk -v t="## $t" 'index($0, t) == 1 { found = 1 } END { exit !found }' "$f"; then [ "${spec:0:1}" = "+" ] || die "$f must not have a '## $t' section"
    else [ "${spec:0:1}" = "-" ] || die "$f lacks a '## $t' section"; fi
  done
}
CORE=("+$T_PRODUCT" "+$T_ARCH" "+$T_PROJ" "+$T_GUIDE" "+$T_API" "+$T_TEST" "+$T_GROUND" "-$T_CRIT" "-$T_DIFF")
for f in "$CTX/roles/wave-1/frontend-implementer.md" "$CTX/workers/wave-1/PROJ-1-PRD-1-US-2.frontend.md"; do
  sections "$f" "${CORE[@]}" "+$T_DS" "+$T_COMP" "-$T_SEC"
done
for f in "$CTX/roles/wave-1/backend-implementer.md" "$CTX/workers/wave-1/PROJ-1-PRD-1-US-1.md" "$CTX/workers/wave-1/PROJ-1-PRD-1-US-2.backend.md"; do
  sections "$f" "${CORE[@]}" "-$T_DS" "-$T_COMP" "+$T_SEC"
done
for f in "$CTX/roles/wave-1/implementer.md" "$CTX/workers/wave-1/PROJ-1-PRD-1-US-3.md"; do
  sections "$f" "${CORE[@]}" "+$T_DS" "+$T_COMP" "+$T_SEC"
done
sections "$CTX/roles/wave-1/reviewer.md" "+$T_PRODUCT" "+$T_CRIT" "+$T_DIFF" "-$T_ARCH" "-$T_PROJ" "-$T_GUIDE" "-$T_DS" "-$T_COMP" "-$T_API" "-$T_SEC" "-$T_TEST" "-$T_GROUND" "-$T_STORY"
for f in "$CTX"/roles/wave-1/*.md; do sections "$f" "-$T_STORY"; done   # role files carry no story
for f in "$CTX"/workers/wave-1/*.md; do sections "$f" "+$T_STORY"; done  # every story file does
ls "$CTX"/workers/wave-1 | grep -q reviewer && die "reviewer got a worker file"
# the preambles agree with the file: story in the file, design system also for the full-stack role
for r in implementer frontend-implementer backend-implementer; do
  grep -qF 'are in the `## Deine Story` section of this' "$CTX/roles/wave-1/$r.md" || die "$r preamble does not point to the story section"
  grep -qF 'arrive in the spawn prompt from the orchestrator' "$CTX/roles/wave-1/$r.md" && die "$r preamble still says the story is in the spawn prompt"
done
grep -qF 'stays with frontend-implementer' "$CTX/roles/wave-1/implementer.md" && die "implementer preamble still keeps the design system with the frontend"
[ "$(sed -n 's/^budget_tokens: //p' "$SKILL/manifests/roles/implementer.md")" = "$(sed -n 's/^budget_tokens: //p' "$SKILL/manifests/roles/frontend-implementer.md")" ] \
  || die "implementer budget must equal the frontend-implementer budget"

run compile 1 demo --wave 2 >/dev/null
B2="$CTX/roles/wave-2/backend-implementer.md"
grep -qF 'Decision 2: Export queue' "$B2" || die "wave-2 decision missing"
grep -qF 'Decision 1' "$B2" && die "wave-1 decision leaked into wave 2"
grep -qF 'Flow 1: Invoice export** (Affects: PRD-2) — Export enqueues first' "$B2" || die "wave-2 key flow missing"
head -1 "$CTX/workers/wave-2/PROJ-1-PRD-2-US-1.md" | grep -qF 'role frontend-implementer · wave 2' || die "role must come from the table"
[ -e "$W" ] || die "--wave 2 removed wave-1 files"
# 'Affects: all' reaches every wave, in the role file and in the story files; the other wave's item never does
W2S="$CTX/workers/wave-2/PROJ-1-PRD-2-US-1.md"
grep -qF 'Decision 3: Auth on every route' "$B2" && grep -qF 'Decision 3: Auth on every route' "$W2S" || die "'all' decision missing from wave 2"
grep -qF 'Decision 2: Export queue' "$W2S" && ! grep -qF 'Decision 1' "$W2S" && grep -qF 'Decision 1' "$W" && ! grep -qF 'Decision 2' "$W" \
  || die "story files must hold only the decisions of their own wave"
sections "$W2S" "${CORE[@]}" "+$T_DS" "+$T_COMP" "-$T_SEC" "+$T_STORY"
# every story file ends in the slice of its own plan, byte for byte
n=0
for f in "$CTX"/workers/wave-*/*.md; do
  w="${f#*/workers/wave-}"; w="${w%%/*}"; id="$(basename "$f" .md)"; id="${id%.backend}"; id="${id%.frontend}"
  bash "$SKILL/scripts/chain" render slice "specs/PROJ-1-demo/3-4_plan/PROJ-1-wave-$w-plan.md" "$id" >"$CASE/slice.out"
  sed '1,/^## Deine Story$/d' "$f" | tail -n +2 | cmp - "$CASE/slice.out" || die "$f: story part is not the slice byte for byte"
  n=$((n+1))
done
[ "$n" -eq 5 ] || die "expected 5 story files, found $n"

# compile without --wave compiles every wave on its own; a rerun is idempotent
rm -rf "$CTX"
run compile 1 demo >/dev/null
grep -qF 'Decision 1' "$B" && ! grep -qF 'Decision 2' "$B" && grep -qF 'Decision 2' "$B2" && ! grep -qF 'Decision 1' "$B2" \
  || die "compile without --wave must compile each wave separately"
[ "$(ls "$CTX" | tr '\n' ' ')" = "roles workers " ] && [ -z "$(find "$CTX/roles" "$CTX/workers" -mindepth 1 -maxdepth 1 ! -name 'wave-*')" ] \
  && [ "$(ls "$CTX/roles/wave-1" | tr '\n' ' ')" = "backend-implementer.md frontend-implementer.md implementer.md reviewer.md " ] \
  || die "context must hold only per-wave roles/ and workers/ directories (no cross-wave view)"
snap >"$CASE/full.snap"
run compile 1 demo --wave all >/dev/null
snap | cmp - "$CASE/full.snap" || die "rerun is not byte-identical"
rm -rf "$CTX" .claude/agents/skillchain-*.md
run compile 1 demo >/dev/null
snap | cmp - "$CASE/full.snap" || die "a compile from scratch does not reproduce every byte"
grep -rq 'NEVER-INJECT-MARKER' "$CTX" .claude && die "never-inject violated: PRD or progress.md content in a worker or agent file"

# budget breach and parser error: exit != 0, nothing written or deleted
cp -r "$SKILL/manifests/roles" "$CASE/tight"
sed -i 's/^budget_tokens: .*/budget_tokens: 50/' "$CASE/tight/reviewer.md"
[ "$(rc node "$COMPILE" context compile 1 demo --roles-dir "$CASE/tight")" -eq 1 ] || die "budget breach must exit 1"
node "$COMPILE" context compile 1 demo --roles-dir "$CASE/tight" >"$CASE/budget.out" 2>&1 || true
grep -qE 'reviewer [0-9]+/50 tokens' "$CASE/budget.out" || die "budget breach must name role, tokens and budget"
snap | cmp - "$CASE/full.snap" || die "budget breach changed files"
cp "$PLAN1" "$CASE/plan1.bak"
sed -i 's/^| PROJ-1-PRD-1-US-1 | backend | backend-implementer/| PROJ-1-PRD-1-US-1 | backend | data-implementer/' "$PLAN1"
[ "$(rc run compile 1 demo)" -eq 2 ] || die "unsupported Agent Type must exit 2"
grep -qF "$PLAN1: PROJ-1-PRD-1-US-1: unsupported Agent Type" "$CASE/err" || die "parser error must name plan and story"
snap | cmp - "$CASE/full.snap" || die "parser error changed files"
[ "$(rc run check 1 demo)" -eq 2 ] && grep -qF "$PLAN1: PROJ-1-PRD-1-US-1: unsupported Agent Type" "$CASE/err" || die "check must exit 2 for an unassignable story, naming plan and story"
cp "$CASE/plan1.bak" "$PLAN1"

# write error (a file where the workers dir belongs): exit 1, rerun completes
rm -rf "$CTX/workers"; touch "$CTX/workers"
[ "$(rc run compile 1 demo)" -eq 1 ] || die "write error must exit 1"
rm "$CTX/workers"
run compile 1 demo >/dev/null
snap | cmp - "$CASE/full.snap" || die "rerun after a write error is incomplete"

# migration of a running PROJ: old bundles, lock and blocked roles vanish; a
# rerun is a no-op; compile never touches .claude/settings.json
for f in bundle-implementer.md bundle-implementer.claude.md bundle-reviewer.codex.md bundles.lock.json blocked-roles.json; do echo old >"$CTX/$f"; done
printf '{"hooks":{"PreToolUse":[]},"env":{"FOO":"1"}}\n' >.claude/settings.json
cp .claude/settings.json "$CASE/settings.before"
run compile 1 demo --wave 1 >/dev/null
ls "$CTX" | grep -qE '^bundle-|bundles.lock.json|blocked-roles.json' && die "old bundles/lock survived compile"
for name in PROJ-1-PRD-1-US-1 PROJ-1-PRD-1-US-2.backend PROJ-1-PRD-1-US-2.frontend PROJ-1-PRD-1-US-3; do
  [ -s "$CTX/workers/wave-1/$name.md" ] || die "migration: $name has no worker file"
done
for role in implementer frontend-implementer backend-implementer reviewer; do
  grep -qF 'Dein vollständiger Auftrag steht in der Datei aus dem Spawn-Prompt' ".claude/agents/skillchain-$role.md" || die "migration: $role agent file lacks the path pointer"
done
cmp -s .claude/settings.json "$CASE/settings.before" || die "compile must leave .claude/settings.json alone"
snap >"$CASE/migrated.snap"
run compile 1 demo --wave 1 >/dev/null
snap | cmp - "$CASE/migrated.snap" || die "second compile after the migration changed something"
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

# compile --wave 1 also drops files of stories deleted from plan 2 (and of unknown roles there);
# valid wave-2 files stay untouched (same bytes, same mtime, not regenerated)
PLAN2="specs/PROJ-1-demo/3-4_plan/PROJ-1-wave-2-plan.md"
sed -i 's/^| PROJ-1-PRD-2-US-1 .*/&\n| PROJ-1-PRD-2-US-2 | frontend | frontend-implementer | sonnet | immediately |/' "$PLAN2"
printf '\n## PROJ-1-PRD-2-US-2: Print invoices\n**Scope:** frontend\n' >>"$PLAN2"
run compile 1 demo >/dev/null
[ -e "$CTX/workers/wave-2/PROJ-1-PRD-2-US-2.md" ] || die "second wave-2 story not compiled"
echo stale >"$CTX/roles/wave-2/retired-role.md"
wave2() { find "$CTX/workers/wave-2" "$CTX/roles/wave-2" -type f ! -name 'PROJ-1-PRD-2-US-2.md' ! -name 'retired-role.md' -printf '%p %T@ ' -exec sha256sum {} \; | sort; }
wave2 >"$CASE/wave2.before"
restore_plans
run compile 1 demo --wave 1 >/dev/null
[ -e "$CTX/workers/wave-2/PROJ-1-PRD-2-US-2.md" ] && die "story deleted from plan 2 kept its file after compile --wave 1"
[ -e "$CTX/roles/wave-2/retired-role.md" ] && die "role file without manifest survived in a non-compiled wave"
wave2 | cmp - "$CASE/wave2.before" || die "valid wave-2 files changed during compile --wave 1"
# a role change in plan 2 drops that story's wave-2 file on compile --wave 1; a plan-hash change alone does not
sed -i 's/^| PROJ-1-PRD-2-US-1 .*/&\n| PROJ-1-PRD-2-US-3 | backend | backend-implementer | sonnet | immediately |/' "$PLAN2"
printf '\n## PROJ-1-PRD-2-US-3: Archive invoices\n**Scope:** backend\n' >>"$PLAN2"
run compile 1 demo >/dev/null
wave2() { find "$CTX/workers/wave-2" "$CTX/roles/wave-2" -type f ! -name 'PROJ-1-PRD-2-US-3.md' -printf '%p %T@ ' -exec sha256sum {} \; | sort; }
wave2 >"$CASE/wave2.before"
printf '\n## Post-Wave Notes\nWave 2 shipped.\n' >>"$PLAN2"
run compile 1 demo --wave 1 >/dev/null
[ -e "$CTX/workers/wave-2/PROJ-1-PRD-2-US-3.md" ] || die "a plan-hash change alone removed a wave-2 file"
wave2 | cmp - "$CASE/wave2.before" || die "a plan-hash change alone touched wave-2 files"
sed -i 's/^| PROJ-1-PRD-2-US-3 | backend | backend-implementer/| PROJ-1-PRD-2-US-3 | full-stack | implementer/; s/^\*\*Scope:\*\* backend$/**Scope:** full-stack/' "$PLAN2"
run compile 1 demo --wave 1 >/dev/null
[ -e "$CTX/workers/wave-2/PROJ-1-PRD-2-US-3.md" ] && die "role change in a non-compiled wave left the old-role file"
wave2 | cmp - "$CASE/wave2.before" || die "role change touched the other wave-2 files"
printf 'no header\n' >"$CTX/workers/wave-2/PROJ-1-PRD-2-US-3.md"
run compile 1 demo --wave 1 >/dev/null
[ -e "$CTX/workers/wave-2/PROJ-1-PRD-2-US-3.md" ] && die "worker file without a parseable header survived"
restore_plans

# role change and a new split rewrite the story's files and leave no stale ones; the story size is no budget
run compile 1 demo >/dev/null
workers() { (cd "$CTX/workers" && find . -type f | sort | tr '\n' ' '); }
WORKER_SET="./wave-1/PROJ-1-PRD-1-US-1.md ./wave-1/PROJ-1-PRD-1-US-2.backend.md ./wave-1/PROJ-1-PRD-1-US-2.frontend.md ./wave-1/PROJ-1-PRD-1-US-3.md ./wave-2/PROJ-1-PRD-2-US-1.md "
[ "$(workers)" = "$WORKER_SET" ] || die "unexpected worker file set: $(workers)"
U1="$CTX/workers/wave-1/PROJ-1-PRD-1-US-1.md"
sed -i 's/^| PROJ-1-PRD-1-US-1 | backend | backend-implementer/| PROJ-1-PRD-1-US-1 | full-stack | implementer/; s/^\*\*Scope:\*\* backend → backend-implementer$/**Scope:** full-stack → implementer/' "$PLAN1"
run compile 1 demo --wave 1 >/dev/null
head -1 "$U1" | grep -qF 'role implementer · wave 1' && sections "$U1" "+$T_DS" "+$T_SEC" || die "role change did not rewrite the story file"
sed -i 's/^\*\*Scope:\*\* full-stack → implementer$/&\n**Split:** `contract`/' "$PLAN1"
run compile 1 demo --wave 1 >/dev/null
[ -e "$U1" ] && die "a newly split story kept its unsplit file"
head -1 "$CTX/workers/wave-1/PROJ-1-PRD-1-US-1.frontend.md" | grep -qF 'role frontend-implementer' && [ -e "$CTX/workers/wave-1/PROJ-1-PRD-1-US-1.backend.md" ] || die "new split gave no side files"
cp "$CASE/plan1.bak" "$PLAN1"
run compile 1 demo --wave 1 >/dev/null
[ "$(workers)" = "$WORKER_SET" ] \
  || die "restoring the plan left stale or missing files: $(workers)"
sections "$U1" "-$T_DS" "+$T_SEC"
awk 'BEGIN { for (i = 0; i < 3000; i++) print "A long implementation note in the slice, counted as story tokens, never as role budget." }' >>"$PLAN1"
run compile 1 demo --wave 1 >"$CASE/big.out" && grep -qE 'PROJ-1-PRD-1-US-3 \(implementer, story [0-9]{4,} tokens\)' "$CASE/big.out" || die "a large story must compile and report its tokens (no story budget)"
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
bash "$SKILL/scripts/chain" render slice "$PLAN1" PROJ-1-PRD-1-US-3 >"$CASE/slice.out"
sed '1,/^## Deine Story$/d' "$CTX/workers/wave-1/PROJ-1-PRD-1-US-3.md" | tail -n +2 | cmp - "$CASE/slice.out" || die "CRLF story part is not the slice byte for byte"
grep -qF 'Decision 1: Server-side totals' "$B" || die "CRLF architecture lost its decisions"
restore_plans; cp "$CASE/arch.keep" "$P/3-4_plan/PROJ-1-architecture.md"

# a manifest name becomes a file name: anything but ^[a-z][a-z0-9-]*$ is refused
cp -r "$SKILL/manifests/roles" "$CASE/badname"
sed -i 's|^name: reviewer$|name: ../reviewer|' "$CASE/badname/reviewer.md"
[ "$(rc node "$COMPILE" context compile 1 demo --roles-dir "$CASE/badname")" -eq 1 ] && grep -qF "manifest name '../reviewer'" "$CASE/err" \
  || die "invalid manifest name must exit 1"

# missing plan wave, plan without a story, missing plan folder: exit 2
[ "$(rc run compile 1 demo --wave 9)" -eq 2 ] || die "unknown wave must exit 2"
printf '# Wave 3\n\n**PRDs involved:** PROJ-1-PRD-1\n' >specs/PROJ-1-demo/3-4_plan/PROJ-1-wave-3-plan.md
[ "$(rc run compile 1 demo)" -eq 2 ] || die "plan without a story must exit 2"
rm specs/PROJ-1-demo/3-4_plan/PROJ-1-wave-3-plan.md
# Agent Type table with head and separator but no rows, and no story section: exit 2, nothing written
run compile 1 demo >/dev/null
snap >"$CASE/empty.snap"
printf '# Wave 3\n\n**PRDs involved:** PROJ-1-PRD-1\n\n## User Stories in this Wave\n\n| US ID | Scope | Agent Type | Complexity | Can start when |\n|---|---|---|---|---|\n' >specs/PROJ-1-demo/3-4_plan/PROJ-1-wave-3-plan.md
for args in "compile 1 demo" "compile 1 demo --wave 1" "check 1 demo"; do
  [ "$(rc run $args)" -eq 2 ] && grep -qF 'PROJ-1-wave-3-plan.md' "$CASE/err" && grep -qiF 'no story' "$CASE/err" \
    || die "$args: empty story table must exit 2 naming the plan"
done
snap | cmp - "$CASE/empty.snap" || die "empty story table changed files"
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
node "$COMPILE" context compile 1 demo --wave 1 >/dev/null || die "unchanged local manifests rejected"
sed -i 's/^Your story and its ACs are in the `## Deine Story` section of this$/Your US, ACs, and tasks arrive in the spawn prompt from the orchestrator./' templates/roles/frontend-implementer.md
snap >"$CASE/before.snap"
[ "$(rc node "$COMPILE" context compile 1 demo --wave 1)" -eq 2 ] && grep -qF 'templates/roles/frontend-implementer.md' "$CASE/err" || die "old local preamble: want 2 naming the file"
[ "$(rc node "$COMPILE" context check 1 demo)" -eq 2 ] || die "check must report the old local preamble"
snap | cmp - "$CASE/before.snap" || die "manifest error changed files"
cp "$SKILL/manifests/roles/frontend-implementer.md" templates/roles/
sed -i '/^  - design-system$/d' templates/roles/implementer.md
[ "$(rc node "$COMPILE" context compile 1 demo --wave 1)" -eq 2 ] && grep -qF 'design-system' "$CASE/err" || die "local implementer without design system: want 2"
rm -rf templates

# check: compiles every wave in memory, writes nothing, exits 1 on a breach
rm -rf specs/PROJ-1-demo/context
run check 1 demo >"$CASE/check.out" || die "check failed on a fitting PROJ"
grep -q '^wave 2:' "$CASE/check.out" || die "check must cover every wave"
[ -e specs/PROJ-1-demo/context ] && die "check must not write"
[ "$(rc node "$COMPILE" context check 1 demo --roles-dir "$CASE/tight")" -eq 1 ] && grep -qE 'reviewer [0-9]+/50 tokens' "$CASE/err" || die "check must exit 1 on a budget breach naming the role"

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
grep -qF 'LEGACY_DELTA_TEXT' "$B2" && grep -qxF "## Architecture delta of this PROJ (specs/PROJ-1-demo/architecture-delta.md — legacy PROJ)" "$B" \
  || die "legacy delta must reach every wave unfiltered under its own title"
grep -qF 'Implementer view of' "$B" && die "legacy delta must not be reduced to the implementer view"
grep -qF 'LEGACY_DELTA_TEXT' "$CTX/workers/wave-1/PROJ-1-PRD-1-US-1.md" || die "legacy delta missing from the story file"
rm "$P/architecture-delta.md"
run compile 1 demo >/dev/null
grep -qF 'FULL_RATIONALE_ONE' "$B" || die "legacy full-document fallback broken"
grep -q '^## PROJ architecture (.*legacy format without Summary lines, injected whole)$' "$B" || die "legacy full document must carry its own title"
grep -qF 'Implementer view of' "$B" && die "legacy full document got a filtered view"
grep -qF 'DIAGRAM_NODE' "$B" && grep -qF 'Decision 2: Export queue' "$B" && grep -qF 'Decision 1: Server-side totals' "$B2" && grep -qF 'UI_ONLY_CONSTRAINT' "$B" \
  || die "legacy full document must come whole (diagrams, other waves' decisions, UI constraints) in every wave"
cp "$CASE/arch.bak" "$P/3-4_plan/PROJ-1-architecture.md"

# repo manifests synced before the rename still say architecture-delta
cp -r "$SKILL/manifests/roles" "$CASE/roles"
sed -i 's/^  - proj-architecture$/  - architecture-delta/' "$CASE/roles/backend-implementer.md"
node "$COMPILE" context compile 1 demo --wave 1 --roles-dir "$CASE/roles" >/dev/null || die "legacy manifest id rejected"
grep -qF 'Decision 1: Server-side totals' "$B" || die "legacy manifest id did not map to the architecture view"

echo "compile-context-bundles: ok"
