---
name: handoff-refinement
description: "Receive a versioned product handoff, inspect affected code repositories, separate engineering requirements from product questions, and prepare pinned repository inputs for architecture and execution. Use for developer-side refinement of an external package, not product PRD authoring or workspace initialization."
---

# Handoff Refinement

Refine a product-owned handoff into evidence-backed engineering inputs without taking ownership of its product requirements. This optional receiving workflow precedes architecture; the existing linear chain needs no additional files or approvals.

## Inputs and ownership

Read [the input contract](references/input-contract.md) for the authoritative manifest schema, resolver commands and readiness rules. Reuse the inventory from [delivery-workspace](../delivery-workspace/SKILL.md), including portable repo keys and machine-local checkout bindings. Missing coordination identity or checkout setup belongs to that skill; do not initialize another coordination repo for each package. An agreed tracked location in one code repo is sufficient for single-repo work.

Product owns the immutable baseline and explicit product responses. Engineering owns evidence, technical constraints and implementation decisions. Architecture and plans derive from those inputs; neither engineering judgment nor model review grants product approval. Contradictions get an owner and block affected scope, with no blanket engineering-over-product precedence.

Write new refinement, exchanges and handoff prompts in English. Preserve source identifiers, verbatim ACs/evidence and intended product localization. Never translate or rewrite a received requirement to satisfy a local validator.

## Receive and inspect

1. Identify package version/source, product owner, affected repo keys and agreed coordination location. Pin consumed shared inputs to a commit or content hash. Distinguish local drafts, proposed PR revisions and accepted team revisions; a local commit is not team acceptance.
2. Preserve every received file under `handoff-inputs/<version>/` with integrity metadata. Do not rewrite links inside the received copy, require a numbered source layout, or write into a generated `2b_handoff/` run. Keep prior versions. Create only folders with actual content.
3. Record prototype mode honestly: pinned source revision or runnable bundle with start instructions when available, static-only references otherwise, plus simulated/missing behavior. Prototypes inform interaction, not production architecture; static references alone are not a universal blocker.
4. Inspect relevant code in the identified repositories. Cite repo key, commit, path and relevant evidence; distinguish implemented behavior from proposed behavior. Record testable engineering requirements separately, linked to source ACs or explicit engineering authority. Never weaken a product AC by relabeling it technical. Keep implementation details inside the product story unless the work has an independently verifiable technical outcome; then declare an optional engineering story under the input contract, with rationale, authority, criteria and dependencies. Do not manufacture a product PRD for it.
5. Read each repo's intake status from workspace onboarding. Reuse its accepted baseline revision. An incomplete intake resumes with its owner; suspected drift needs an explicitly chosen audit. Planned repos route to bootstrap with approved scope. Read-only investigation and product questions may proceed before all baselines are ready, but downstream readiness remains per repository.

## Local project state

For each selected implementation repository with a bound checkout, establish its local PROJ ID and create `specs/PROJ-<X>-<theme>/` while placing its actual refinement inputs. Resolve `<installed-5_executing>` to `~/.codex/skills/5_executing` for Codex or `~/.claude/skills/5_executing` for Claude. From that checkout root, run `bash <installed-5_executing>/scripts/chain state init <X> <theme>` before its refinement review and architecture handoff. This replaces Concept's initialization on the external-entry route: a new state is `CP1:pending`, and an existing state is retained unchanged by the idempotent helper. Never reset a resumed project or infer CP1 approval from received product approval; only the Step 5 checkpoint may approve CP1.

Keep execution state in its owning implementation repository, not the shared coordination project or portable input bundles. If a checkout is unavailable, record initialization as a receiving-refinement prerequisite in its onboarding prompt; do not invent a checkout or initialize another repository's state in coordination. Record review defects with the existing findings helper; it creates the stage ledger when needed, including before state exists. Do not hand that repository to architecture until local initialization and readiness checks are complete.

## Repeat rounds and package consistency

On repeat rounds, compare current inputs with the previous consumed baseline and responses. Identify changes to requirements, approved product answers, shared rules, relevant engineering constraints and interface contracts; cite the revisions and affected requirement IDs. Record missing comparison evidence rather than claiming no change. Re-evaluate affected requirements even when their source bytes are unchanged: the delta directs attention, not review exemptions.

First assess current requirements against current authoritative inputs without using prior findings as the analysis outline. Then reconcile every earlier finding and product question: still open, resolved with cited evidence, superseded with a replacement reference, or requiring reassessment with a reason. Preserve IDs and applicable baselines in the existing findings or feedback artifacts, using their existing statuses rather than introducing another ledger or machine-readable status vocabulary. No new findings does not mean old questions are answered.

Avoid repeating a question only when an accepted decision still applies to the current baseline; cite that decision and the applicability check. Changed requirements, constraints or counterevidence require reassessment. Proposed, superseded or deprecated decisions cannot silently close questions. A technical decision is not product approval, a documented design is not implementation evidence, and implementation evidence is not integration acceptance.

Check package-wide consistency of states, roles, terminology and shared rules, including compatible preconditions and outcomes at cross-PRD transitions. When a finding exposes a reusable diagnostic, apply it to other relevant requirements; search for assumptions behind the old rule, not only its wording or ID. Keep one issue identity with all affected references. Record a brief reason for material suspected impacts found not applicable, without an exhaustive negative-check report. Route cross-project impacts to their owners without editing sibling scope. These checks supplement AC ownership, coverage and integration verification.

## Product feedback and responses

Classify each issue as product question, engineering decision, code/integration gap or missing evidence. Give product questions stable IDs, baseline/source AC references, concrete evidence, alternatives and impacts, owner and blocking scope. Keep them in `product-feedback/`, separate from engineering review findings. Use [the feedback and handoff format](references/feedback-and-readiness.md) to prepare a portable return package with sufficient excerpts and evidence to answer without this checkout. Do not send or publish it without explicit authorization.

Ingest only explicit product responses with question ID, owner, date and applicable baseline. An informal suggestion stays a proposal; silence, a clean review, an open PR or a developer's assumption cannot close the question. Retain response provenance and original source bytes. For a superseding package, preserve the prior version and reconcile affected questions, requirements, architecture, plans and tests; approvals against an old baseline do not transfer automatically. Reconcile concurrent team edits and upstream answers before updating readiness.

Product-owned source changes run through `review-reconcile` in the source project; `handoff-package` emits a new dated package when needed. The receiver never edits the original PRDs, even in a copied local product-authoring folder.

## Review and readiness

Create `external-handoff.json` and refinement mappings according to the input contract. Validate with the resolver; a present malformed marker must fail, not fall back to linear inputs. Use its blocked-inspection option only to investigate and prepare feedback, never to authorize architecture or execution.

Run an independent read-only review via [cross-review](../cross-review/SKILL.md), `requirements` mode, with refinement artifacts and the complete scoped baseline, responses, engineering constraints and code evidence as ground truth. For repeat rounds, also supply the relevant prior findings/questions and input-change evidence; ask the reviewer to check their complete reconciliation and package-wide consistency. Record defects through the existing findings helper. Product questions remain in their exchange artifacts and cannot be resolved or auto-deferred by that review.

Produce `refinement/readiness.md` with pinned inputs, integrity result, repo baseline status, coverage, blocking questions, dependencies and next owning skill. Check every source requirement has implementation and verification ownership across the affected repositories. Do not require each repo to implement the entire baseline. Prepare self-contained pinned bundles in `repo-handoffs/<repo-key>/`, or a reproducible pinned acquisition procedure; never depend on another developer's absolute paths or sibling layout. Shared decisions and integration evidence stay in the agreed team coordination location through its normal review process.

Each implementation repo uses its own project ID, checkout/worktree, state, tests and PR. Shared architecture records repository boundaries and versioned interfaces; local plans declare external dependencies. Feature-wide completion requires aggregate coverage, compatible revisions, required integration evidence and release ordering. One green repo or open PR is not feature acceptance.

## Session handoff

Finish refinement checks and its independent review here, then stop at a copyable prompt for a new user-started session. Do not auto-invoke architecture, intake, bootstrap or another producing skill; `/compact` is not a new session. Name the next skill, actual bound checkout/worktree, local project identity, pinned input/response revision, inventory and readiness paths, scope and blockers. Use machine-local paths only in the personal prompt, not shared artifacts. If the checkout is missing, give its onboarding action instead of inventing a `cd` path. Do not hand blocked scope to architecture or implementation; prepare the product return package or baseline-resume prompt instead.
