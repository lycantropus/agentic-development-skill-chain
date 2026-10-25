# Checkpoint — Structured Reconcile Loop For CP1, Bootstrap, CP2

At CP1 and CP2, write generated artifacts, decision logs, reports and handoff prompts in English; converse with the user in their language. The bootstrap variant follows its owning intake skill.

Subskill of `5_executing`, not a standalone skill; any Step 5 lead
(`5b_executing-large-model` by default, or `5_executing`) runs it at CP1: its caller (the
"orchestrator" below) runs it through subagents, see **Roles**.

Checkpoints are not a "looks good? yes/no" question. This subskill
generalizes the proven `review-reconcile` (2c) pattern to the two human
checkpoints of the agent workflow (CONCEPT.md §4): feedback is collected
point by point, every point ends in an explicit decision, the decision
log is durable, and each change cascades through ALL affected artifacts
before anything is sealed. Between the checkpoints the run is
autonomous — this loop is where the human steers.

Three call sites, one loop:

| Call site (orchestrator) | Reviewed | Seal |
|---|---|---|
| **CP1** (Step 5 lead — main) | architecture + wave plans + gate config + api-contracts | `state.json` → `CP1:approved` — the ONLY thing that unlocks P0 |
| **Bootstrap** (via 0b_intake) | intake first drafts (all eight baseline files) | curated baseline commit — no state.json |
| **CP2** (via delivery, 8) | PR review comments | classified comments: fix now / debt / reject |

## Roles — Subagents Do The Work, The Orchestrator Owns The Conversation

Subagents cannot reach the user, and the review loop exists precisely to
put each point in front of one. So the work is split in three, and the
orchestrator's context only ever holds the compact point list:

1. **Prepare subagent** (spawned first, foreground): runs Step 0. Fast path
   taken → it appends Step 0's single `adopt` entry to the decision log,
   runs Step 5, and returns `sealed`. Otherwise it runs
   Step 1 and returns the review package as a numbered point list
   (≤ 300 tokens plus artifact paths).
2. **Orchestrator** (the main agent of the calling skill): runs Step 2
   with the user — one point at a time, one outcome per point — and
   appends each outcome to the decision log (Step 3, Cascade `pending`)
   before raising the next point, so an interrupted round loses nothing.
   It edits no other artifact.
3. **Apply subagent** (fresh spawn; given the decision-log path and the
   round's ids): runs Steps 4–5, fills each entry's Cascade field, and
   returns `sealed`, or the validator/self-review errors. Errors become
   the next round's points — back to 2.

Steps 0–5 above are the CP1 procedure. The variants reuse the split with
their own content:

- **Bootstrap** (orchestrator: intake): prepare skips Step 0 (no fast
  path) and returns the Bootstrap review queue; decisions go to
  `specs/intake/decisions.md`; apply cascades into the drafts only. No
  state.json, no plan validator — intake itself seals with the baseline
  commit.
- **CP2** (orchestrator: delivery): prepare skips Step 0 and returns the
  classified-comment list; apply runs the `debt` ledger records and PR
  replies. `fix now` items are dispatched by delivery itself; there is no
  CP1 seal. Without subagents (or where delegation is
prohibited) the orchestrator runs every step inline and says why.

## Core Principle

Decide before you edit, record before you move on. Every review point
ends in exactly one of `adopt` / `change (how)` / `reject (why)` /
`defer` — recorded in the decision log BEFORE the next point is raised.
Never silently absorb feedback by editing an artifact with no recorded
rationale, and never seal an approval while a cascade is unapplied.

CP1 has one narrow exception: Step 0's fast path, which auto-adopts and seals
without an interactive prompt — but only when the upstream cross-reviews
already did the judging and came back clean. It is still a recorded decision
(one decision-log entry, same as any other), it is still conditional on the
machine validator, and anything that actually needed a human call still gets
the full loop. It removes a redundant re-confirmation, not the checkpoint
itself.

## Input

1. `specs/PROJ-<X>-<theme>/3-4_plan/PROJ-<X>-architecture.md` (legacy delta-only projects must first return to `architecture` to supply this document)
2. `specs/PROJ-<X>-<theme>/3-4_plan/PROJ-<X>-wave-<N>-plan.md` (all waves) + `wave-gate-config.json`
3. `specs/PROJ-<X>-<theme>/api-contracts.md` (if present)
4. Open pre-mortem risks / plan self-review findings (if present)
5. `specs/PROJ-<X>-<theme>/decisions.md` from earlier rounds (if present)

## External handoff at CP1

If the PROJ contains `external-handoff.json`, read [the receiving input contract](../../handoff-refinement/references/input-contract.md) and run `chain check inputs <project-directory>` before the fast path or any seal. Verify the accepted team revision against the coordination remote and each affected repo baseline. The marker's resolved scope replaces local PRD lookup in the structure gates below; a malformed marker or unresolved applicable product question blocks CP1, including the automatic fast path.

Checkpoint decisions can change engineering plans, not product approval. Product questions return through `handoff-refinement`; retain their owner, baseline and blocked scope rather than auto-deferring them as debt. Never edit immutable sources during the cascade. After explicit product responses or a superseding package, reconcile derived artifacts and repeat applicable review, input and context checks before sealing. Bind this seal to one repository's pinned scope; it does not approve other repo runs or integrated feature delivery.

## Workflow (CP1 — the main application)

### 0. Fast path — auto-approve when upstream was already clean

Before presenting anything, check whether this round needs the interactive
walk-through at all. All four must hold, checked in this order (cheapest
first):

1. `specs/PROJ-<X>-<theme>/decisions.md` has no open or deferred entry from an
   earlier round. An earlier round that left something open is a standing
   decision this round must still honor or revisit — never silently paper
   over it. Fails → no fast path, continue at Step 1.
2. Both cross-reviews actually ran — `.cross_review[]` in state.json (appended
   by `chain review --persist`, never by hand) has at least one record with
   `mode == "architecture"` and at least one with `mode == "plan"`:
   ```bash
   bash ~/.claude/skills/5_executing/scripts/chain state get <X> <theme> \
     '[.cross_review[]? | .mode] | (index("architecture") != null) and (index("plan") != null)'
   ```
   `false` (a mode never ran — declined, or run without `--persist`) → no fast
   path, continue at Step 1.
3. Nothing from those rounds is still open. This is the exact query
   `chain review` itself uses to decide BLOCKING — reuse it rather than
   inventing a second definition of "clean":
   ```bash
   bash ~/.claude/skills/5_executing/scripts/chain findings list <X> <theme> | jq '[.findings[]? | select(.status == "open") | select(.severity == "critical" or .severity == "high") | select(.source == "cross-review" or ((.sources // []) | index("cross-review")))] | length'
   ```
   Nonzero (a finding needed a human decision and nobody resolved it in the
   ledger) → no fast path, continue at Step 1.
4. Run all three document structure gates (PRDs, architecture, plan) and the
   context check (exact commands in Step 4 below). Any error → no fast path, continue at Step 1.

If all four hold: skip the interactive walk-through (Steps 1-2) and the
cascade (Step 4 — nothing changed, so there is nothing to cascade). Append one
decision-log entry to `decisions.md` (`templates/decisions.md.tmpl`):
Decision `adopt`, Detail "auto-approved — architecture and plan cross-review
both clean, validator green", Cascade `none`. Go straight to Step 5 (Seal the
approval) and tell the user in one line that CP1 auto-approved and why.

This is the only auto-approve path. Anything cross-review didn't clear, or
that a human already had to judge, or that an earlier round left open, always
gets the interactive loop below — that is precisely the case where a rubber
stamp is not safe. The fast path removes a redundant re-confirmation of
already-reviewed artifacts; it does not remove the one check that only fires
when something is actually wrong.

### 1. Present a compact review package — never raw artifacts

Build a summary the human can decide on in minutes:

- **Decision summary:** every `Decision N` with its Affects and Summary
  line — exactly what implementers will receive — not the full architecture
  text.
- **Wave overview:** waves with story sets, dependency rationale, and
  execution mode per wave.
- **Open risks:** unresolved pre-mortem findings and weak spots the
  plan self-review flagged.

Point to the full artifacts by path for drill-down; do not paste them.

### 2. Collect feedback point by point (orchestrator only)

Walk the package one point at a time (AskUserQuestion or guided
conversation — never one bulk "any comments?" prompt). For each point:

1. Explain plainly what was decided/planned and why.
2. Frame realistic alternatives with a recommendation where feedback
   suggests a change.
3. Close with exactly one outcome: **adopt** / **change (how)** /
   **reject (why)** / **defer**.

### 3. Write the decision log

Append this round to `specs/PROJ-<X>-<theme>/decisions.md` using
`templates/decisions.md.tmpl` (copy the template frame; one `D-<X>-<NN>`
entry per point, IDs unique across rounds), each entry written as soon
as its point is decided, Cascade `pending` until Step 4 fills it. The log
is append-only — earlier rounds are never edited. P7 curation later migrates decisions
with lasting value into `docs/ARCHITECTURE.md`/ADRs.

### 4. Cascade updates into ALL affected artifacts

<HARD-GATE>
One decision ("drop US-7, cut Wave 2 differently") touches several
artifacts. For every `change`/`reject` decision, update EVERY affected
file — the architecture (decision body AND its Summary line), wave plans,
`wave-gate-config.json`, api-contracts — and record the touched files in the entry's
**Cascade** field. Then re-run the plan self-review (the consistency
check from writing-plans, 4): story/dependency/contract consistency
across all waves. A checkpoint that edits a wave plan but not the gate
config produces an overnight run that gates against a stale plan.

Run all three document structure gates before plan approval, after every cascade and once more even
when the round adopted every point unchanged:

```bash
bash ~/.claude/skills/5_executing/scripts/chain check prds specs/PROJ-<X>-<theme>/2_PRDs
bash ~/.claude/skills/5_executing/scripts/chain check architecture \
  specs/PROJ-<X>-<theme>/3-4_plan/PROJ-<X>-architecture.md \
  specs/PROJ-<X>-<theme>/2_PRDs
bash ~/.claude/skills/5_executing/scripts/chain check plan \
  specs/PROJ-<X>-<theme>/3-4_plan
bash ~/.claude/skills/5_executing/scripts/chain render context check <X> <theme> --roles-dir ~/.claude/skills/5_executing/manifests/roles
```

Malformed PRDs or architecture return to their owning skill; repeat its review
before approving. These gates also catch direct edits made after review.

The context `check` compiles every wave's worker and role files in memory (it writes
nothing) and fails when a role would exceed its budget at P0, a decision or key
flow is malformed, or one reaches no wave. It also fails (exit 2) when a story
cannot be assigned to a role from the plan table's `Agent Type` column
(duplicate, missing, unsupported, or contradicting `Scope`/`Split`), and when an
installed role manifest still has the old preamble or lacks the design system
in `implementer`: refresh the installed skill. Before P0, explicitly use installed
roles because project roles (`templates/roles/`) may still await synchronization.
A green installed-role check does not authorize implementation: P0 must reconcile
sync conflicts and pass the default project-role check without `--roles-dir`
before execution.

This is a hard pre-approval gate. It checks unique AC IDs, their task/command
mapping, bidirectional task/test-file agreement, broad regressions, auth-budget
hooks, and protected-route coverage through auth state or mapped authenticated
E2E files. Do not seal CP1 while it is red. For a legacy layout, use the
existing `6_plan/` directory for both architecture and plan paths instead.
</HARD-GATE>

### 5. Seal the approval

Only after the cascade is clean:

1. Read the `state.json` created with the PROJ folder by concept (1).
   If this is a legacy PROJ without one, recover once with
   `bash ~/.claude/skills/5_executing/scripts/chain state init <X> <theme>`;
   it must still be `CP1:pending` before this checkpoint approves it.
2. `bash ~/.claude/skills/5_executing/scripts/chain state transition <X> <theme> CP1 running` (first
   round, or resuming from `CP1:blocked`), then `bash ~/.claude/skills/5_executing/scripts/chain state transition <X> <theme> CP1 approved`
   (the installed helper — the repo copy arrives with P0)
3. `bash ~/.claude/skills/5_executing/scripts/chain state set <X> <theme> .decision_log specs/PROJ-<X>-<theme>/decisions.md`
4. Commit: `docs(PROJ-<X>): CP1 approved — decision log + cascaded plan updates`

`CP1:approved` in state.json is the only thing that unlocks P0. Never
set it by hand, never set it while decisions are open or deferred
points are unresolved-but-blocking.

→ RETURN `sealed` to the orchestrator; the Step 5 lead then spawns the
**setup** subskill (`subskills/setup.md`) for P0.

## CP2 Variant (invoked by delivery, 8)

Same loop over PR review comments instead of plan artifacts: classify
each comment `fix now` (spawn fix, verify, push) / `debt` (ledger record
via `scripts/chain findings`, `ponytail:` marker) / `reject with rationale`
(reply on the PR via `gh`). Decision log entries carry the PR comment
link. Principle-level feedback ("I never want to see this again") is
harvested as an AGENTS.md/GUIDELINES candidate through the existing
approval pipeline — not silently applied.

## Bootstrap Variant (via 0b_intake)

Specialised loop for the intake drafts: `0b_intake/references/bootstrap-reconcile.md`.

## Completion Checklist

- [ ] Fast path checked first (Step 0); took it only if decisions.md was clean, `.cross_review[]` had both an `architecture` and a `plan` record, the findings ledger had zero open Critical/High from cross-review, and the validator passed
- [ ] Review package presented compactly (summary, waves, risks) — fast-path rounds skip this
- [ ] Every point closed as adopt / change / reject / defer — none skipped (or the single fast-path `adopt` entry)
- [ ] Decision log appended with one `D-<X>-<NN>` entry per point
- [ ] Every change cascaded through ALL affected artifacts; Cascade field filled
- [ ] Plan self-review re-run after cascades — consistent
- [ ] Plan consistency validator passes after the final cascade
- [ ] state.json sealed `CP1:approved` with `.decision_log` set (CP1 only)
- [ ] Committed

## Git Commit Format

```text
docs(PROJ-<X>): CP1 approved — decision log + cascaded plan updates
```

Legacy PROJ folders: see `0_chain-guide/references/legacy-layout.md`.
