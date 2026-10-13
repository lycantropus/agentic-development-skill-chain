# Intake Bootstrap Reconcile

Reference for `0b_intake` step 2. This is the checkpoint loop
(`5_executing/subskills/checkpoint.md`: prepare / orchestrator / apply
roles, point-by-point decisions, cascade) specialised for the intake
drafts. The generated docs are HYPOTHESES, not truth — the loop turns
them into a baseline the developer actually stands behind.

- **Input:** the provenance-marked drafts in `specs/intake/` (all eight
  baseline files: PRODUCT, ARCHITECTURE, GUIDELINES, DESIGN-SYSTEM,
  components, security-baseline, test-conventions, root AGENTS.md).
- **Review queue:** every `[gap: ...]`, every `[assumed]`, every
  inconsistency the scan flagged — plus anything the developer wants to
  challenge in the `[extracted: ...]` statements. The prepare subagent
  builds it (there is no Step 0 fast path); the orchestrator never sees
  the scan output or the drafts, only the queue.
- **Loop:** identical to CP1 — present point by point, each point ends
  in exactly one of adopt / change (how) / reject (why) / defer,
  recorded BEFORE the next point.
- **Decision log:** `specs/intake/decisions.md`, ids `D-BOOTSTRAP-<NN>`,
  same `templates/decisions.md.tmpl` frame (checkpoint name:
  `Bootstrap`).
- **Cascade:** the apply subagent applies every decision to the affected
  draft(s) — a GUIDELINES ruling may also touch ARCHITECTURE or add a
  Known Debt note. No plan validator runs.
- **Seal:** a git COMMIT of the curated baseline (done by the intake
  skill after `intake-seal-check.sh` passes) — explicitly NO
  `state.sh init` and NO phase transition. The bootstrap is pre-PROJ:
  each PROJ's state.json is created later by concept (1).
