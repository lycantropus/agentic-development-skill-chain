# Delegated evidence briefs

Subagents gather evidence; the lead classifies, discusses and decides. Use them when the active instructions allow delegation and the work is isolable: code inspection per implementation repository (step 4) and package-wide consistency checks on repeat rounds. If delegation is unavailable, run the same brief inline. The developer dialogue, the product-question/engineering classification, `product-feedback/` and readiness stay in the lead.

Delegate in parallel, one brief per repository or per consistency topic. Workers may run on a cheaper model; the lead stays on the strongest available model and verifies before using any result. Subagent findings arrive in the same confident register as facts: open at least one cited location per brief in the real checkout (`git show <commit>:<path>` or the file at the pinned revision) and discard anything whose citation does not hold.

## Repository inspection brief

Give the worker: repo key, bound checkout path and pinned commit, the ACs this repository owns (verbatim, with `sourceId`), the engineering constraints already known, and this contract. The worker is read-only: no edits, no branch changes, no network writes.

Required output, one block per AC plus a closing section:

```
AC <sourceId> (<repo-key>@<commit>)
  implemented: <path>:<line-range> — <one line what it does> | none
  proposed:    <path>:<line-range> or PR/branch — <one line> | none
  gap:         <what the AC needs that the code lacks> | none
  technical:   <open engineering question with 1-3 options and trade-offs> | none
  confidence:  high | medium | low — <why>

Cross-cutting: shared modules, interfaces, data contracts touched by several ACs, each with path and line range.
Not found: ACs with no related code at all.
```

Rules for the worker: cite only paths that exist at the pinned commit; mark inference as `medium` or `low`; never label a product AC as technical; never propose scope. A missing capability is a `gap`, not a recommendation to drop the AC.

## Consistency brief (repeat rounds and multi-PRD packages)

Give the worker: the complete scoped baseline, accepted responses, the shared rules and glossary, and one topic: a state machine, a role, a term, or a cross-PRD transition pair. Required output per candidate:

```
C-<n> <topic>
  sources:   <PRD/AC references on both sides>
  conflict:  <precondition, outcome, role or term that does not line up>
  evidence:  <verbatim excerpts, minimal>
  severity:  blocks | unclear | cosmetic
```

The worker reports candidates only. The lead decides whether each is a product question, an engineering decision or a non-issue, records a brief reason for dismissed material candidates, and keeps one issue identity across all affected references.

## After delegation

Merge results into the refinement artifacts with their repo key and commit; keep raw worker transcripts out of shared files. Technical items go into the developer discussion in this session and are recorded as engineering constraints or an optional engineering story with rationale. Gaps and conflicts that need a product decision become product questions with the smallest affected blocking scope.
