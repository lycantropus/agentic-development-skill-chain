---
name: architecture
description: "Design the technical architecture for a PROJ, written for software developers (covers all its PRDs). No code, only high-level design decisions. Use when: (1) all PRDs for a PROJ exist and need a unified tech design, (2) cross-cutting tech decisions need a recorded rationale, (3) before creating implementation plans. Not for: writing code, per-PRD micro-decisions, or requirements gathering."
---

# Solution Architect

Turn all PRDs of one PROJ into one concise architecture document. Readers are
software developers: the engineer who approves it at Checkpoint 1 and the agents
that plan and implement from it (writing-plans, implementers).

## Rules

- **English only** in every written file, whatever language the user chats in.
- **No code** in the architecture: no SQL, no TypeScript, no API
  snippets. WHAT and WHY, not HOW. Only `migration-design.md` may carry DDL.
- **Scope = architecturally significant only.** A decision belongs here when it
  affects multiple PRDs or waves, or is significant on its own: irreversible (a
  live-data migration), a security/trust boundary, or ownership of an external
  integration. Everything else — component trees, route names, field lists,
  validation shapes, folder and test layout — is left to the wave plan and the
  implementer. When in doubt, leave it out.
- **Stack is inherited.** `docs/ARCHITECTURE.md` § Stack (from `bootstrap` 0c or
  `intake` 0b) is the single source of truth: build on it, don't restate or
  re-open it. Never edit `docs/` here — P7 (`documentation`) promotes built changes.
- **Baseline changes are explicit.** A decision that changes anything
  `docs/ARCHITECTURE.md` states — a new stack layer, closing an `open` Stack row,
  a moved boundary, new data ownership, a relaxed or new invariant — carries
  `**Changes baseline:** docs/ARCHITECTURE.md § <section>` and its Summary says
  what it supersedes. A contradiction without that line is a defect. The line
  tells implementers which injected baseline rule this PROJ overrides and is
  P7's to-do list for the curation.
- **Decomposed PROJs:** sibling PROJs are external dependencies or consumers.
  Document only the contract (ownership, dependency direction, shared entities,
  rollout assumptions), never their internals.
- **Don't touch PRDs.** Tech design lives in its own file.
- **Reconcile, don't narrate.** When review or the user changes a decision, rewrite
  the section as if it were right the first time — no "Correction (post-review)"
  or "an earlier draft said".

## Inputs

1. `specs/INDEX.md` if present.
2. `docs/ARCHITECTURE.md` (Stack + load-bearing architecture) and
   `docs/GUIDELINES.md` if present; list existing UI components and server/API
   entry points with `git ls-files` on the paths that stack implies.
3. `specs/PROJ-<X>-<theme>/1_concept/PROJ-<X>-concept.md`.
4. **All** PRDs in `specs/PROJ-<X>-<theme>/2_PRDs/` — find shared entities, auth,
   data flows, and which PRDs need a backend.
5. If present: `1d_prototypes/implementation-handoff.md` (resolve screens via its
   source/preview references, HTML files as fallback; component imports show UI
   reuse, not approved business logic) and `1c_design/design-language.md` — or the
   canonical shared design language of another PROJ if this one consumes it.
6. Approved concept/PRD/architecture of blocking sibling PROJs, as dependency
   context only.

Ask the user directly only about open cross-cutting questions, e.g.
accounts and roles, cross-device sync, third-party integrations, migration
rollback policy, or a UI handoff that conflicts with § Stack.

## Output: `specs/PROJ-<X>-<theme>/3-4_plan/PROJ-<X>-architecture.md`

One file. It is the single architecture source for CP1, the implementer
bundles, QA and P7 — there is no separate delta or summary file.

```markdown
# PROJ-<X> Architecture — <theme>

## Overview
[2-3 sentences: what this PROJ builds and how it fits the existing system]

## PRDs Covered
- PROJ-<X>-PRD-1: <desc>

## System Boundaries
[Only if new/changed. Mermaid flowchart; mark new parts with `classDef new` + `:::new`.]

## Data Model
[One line per entity: owning PRDs, relationships. No fields, types, constraints,
indexes. Add an erDiagram (names + cardinality only) at 3+ related entities.]

## Key Flows
### Flow N: <title>
**Affects:** PRD-2 | all
**Summary:** <one sentence: the ordering or guarantee implementers must keep — the only line they see>
[sequenceDiagram. 0-3 flows that cross system boundaries or are significant per
Rules — auth, real-time, async work, external integrations, multi-system writes.
Omit the section if none.]

## Cross-Cutting Tech Decisions
### Decision N: <title>
**Affects:** PRD-1, PRD-3 | all
**Changes baseline:** docs/ARCHITECTURE.md § <section>   ← only when it changes the baseline
**Summary:** <one sentence: WHAT + short WHY — the only line implementers see>
[3-6 sentences: the decision and its one real reason. Cite requirements by ID
("per PRD-2 US-2 AC-9"), don't quote them. Numbers stay stable through
reconciliation — wave plans cite them.]

## UI Implementation Constraints
[Only with a UI handoff: project mode (greenfield/brownfield/hybrid), component
families to preserve, shared new-component candidates, interaction containers
that must stay consistent, design-token constraints. No component tree. Framework,
styling, component library come from § Stack; design system from frontend-design.
If the handoff conflicts with § Stack, § Stack wins — raise it as an open question.]

## Cross-PROJ Dependencies
[Only if decomposed: siblings consumed/blocking, contract, out of scope]

## Dependencies
[New packages only, with affected PRDs]
```

Example decision:

```markdown
### Decision 2: Live status via subscriptions
**Affects:** PRD-2, PRD-3
**Summary:** Status updates arrive through Supabase subscriptions, not polling (users need instant feedback).
```

Example flow:

```mermaid
sequenceDiagram
  actor User
  participant App
  participant DB as Supabase
  User->>App: Submit delivery
  App->>DB: Store delivery
  DB-->>App: Change event
  App-->>User: Live status update
```

**Diagrams:** valid Mermaid, ~12 nodes max, one-sentence caption each, derived from
the inputs — never invented. Participants are systems or major components;
messages are intents, not routes, SQL, or method names; `alt`/`opt` only where
observable behavior differs. Diagrams illustrate decisions, they don't replace the WHY.

**Migration escape valve:** if a live-data migration decision can only be verified
with DDL-level detail (uniqueness scope, triggers, validation queries, rollback),
put that detail in `3-4_plan/PROJ-<X>-migration-design.md`, organized by decision.
The architecture names the decision and WHY in plain language and points there
("detailed in `PROJ-<X>-migration-design.md` § Decision 3").

## Implementer view (generated — never hand-written)

`chain render context` builds what workers see from this file: Overview,
Data Model, Cross-PROJ Dependencies, Dependencies and (frontend roles only) UI
Implementation Constraints verbatim; PRDs Covered, System Boundaries and every
diagram dropped; each decision and key flow reduced to
`Decision N: <title> (Affects) — Summary` (`Flow N: …` alike) plus an override
note when it `Changes baseline`, filtered to the PRDs of the running wave. So:

- Every decision and flow is a `### Decision N: <title>` / `### Flow N: <title>`
  heading with both `**Affects:**` (at least one `PRD-n`, or `all`) and
  `**Summary:**`. The compiler fails on a malformed heading, a missing or doubled
  field, and (`check`) an item whose PRDs are in no wave — never drops it silently.
- Whatever an implementer must obey goes into a Summary; the body and the
  diagram stay for the human and the reviewers. A migration decision's Summary
  keeps its `migration-design.md` pointer.
- The non-decision sections go verbatim into every worker file — keep them
  to the format above. `writing-plans` runs the budget check once waves exist.

## Cross-Review (automatic, same turn)

Right after saving, without asking:

```bash
bash scripts/chain review architecture <X> <theme> \
  --artifacts specs/PROJ-<X>-<theme>/3-4_plan/PROJ-<X>-architecture.md \
    specs/PROJ-<X>-<theme>/3-4_plan/PROJ-<X>-migration-design.md \
  --ground-truth specs/PROJ-<X>-<theme>/1_concept/PROJ-<X>-concept.md \
    specs/PROJ-<X>-<theme>/2_PRDs/PROJ-<X>-PRD-*.md docs/ARCHITECTURE.md docs/GUIDELINES.md \
    specs/PROJ-<X>-<theme>/1d_prototypes/implementation-handoff.md \
    <design-language file read as input 5, local or shared> \
    <sibling PROJ files read as input 6> \
  --author-provider <current-writer> --persist --round 1
```

- Drop paths that don't exist (the script fails on missing files); never drop a
  PRD. If the context cap rejects the call, tell the user which inputs you left out.
- `--persist` is mandatory: CP1's fast path reads the persisted round and ledger.
- Reconcile and re-review through round 3 while any findings remain; a changed
  decision gets a matching Summary. Further rounds only on user request.

## Continue into writing-plans

Summarize decisions, cross-review result, and open questions, then invoke
**writing-plans** (4) in the same session — approval happens at Checkpoint 1 (run by Step 5, executing-large-model).
Stop instead only if Critical/High findings remain after round 3, the review
failed to run (exit `1` is not a round), a product decision is open, or the user
asked to review the architecture alone first.

Update `specs/INDEX.md` status to "In Progress" if it exists. Say once:

> "Architecture is ready at `specs/PROJ-<X>-<theme>/3-4_plan/PROJ-<X>-architecture.md`. Cross-review: <clean | N findings reconciled>. Continuing into **writing-plans**; you approve architecture and plans together at Checkpoint 1."

Commit: `docs(PROJ-<X>): Add architecture for <theme>`

Legacy PROJ folders: see `0_chain-guide/references/legacy-layout.md`.
