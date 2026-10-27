# Deferred Dos/Don’ts Review Follow-ups — PR #32

Date: 2026-10-27 · Status: five Minor items recorded as deferred for the user-authorized merge of PR #32; follow-up implementation remains open.

Recorded on 2026-10-27 from [the CodeRabbit review of PR #32](https://github.com/silviobeer/agentic-development-skill-chain/pull/32#pullrequestreview-5660474243), reviewed head `920666d`. These five Minor items remain open. This section records follow-up work only; it does not implement the changes or claim a clean review. Each item applies to both the `claude/skills/` and `codex/skills/` trees.

1. **Open — align component detection at intake sealing.**
   - **Scope:** `7_documentation/scripts/curation.sh`, the related intake contract, and curation harness coverage.
   - **Observation/risk:** sealing detects only `src/components` and `src/features/*/components`, while the component registry scans every outermost `components` directory under `src`. A repository with `src/lib/components`, for example, can be treated as backend-only and seal without its UI baseline files.
   - **Proposed change and verification:** broaden detection consistently with registry discovery, excluding `node_modules`. Add positive cases for supported component locations, including `src/lib/components`, and a backend-only negative control; verify that UI files are required only when qualifying components exist and keep helper copies byte-identical.

2. **Open — exclude fenced examples from Traps counting.**
   - **Scope:** the Traps counter in `7_documentation/scripts/curation.sh` and `scripts/test-curation.sh`.
   - **Observation/risk:** list markers in a fenced example can increase the Traps count, and a heading inside that fence can change section tracking. The review's assertion that the PR contract excludes fenced examples refers to the checklist-header tests; a Traps fence exemption has not been implemented.
   - **Proposed change and verification:** handle fenced blocks while counting Traps, including headings inside fences. Verify that ten real Traps plus a fenced list example pass, while eleven real Traps fail; preserve nested-list and indentation coverage.

3. **Open — include the checklist in the cross-review documentation example.**
   - **Scope:** the `docs` command example in `cross-review/SKILL.md`.
   - **Observation/risk:** the example omits `docs/review-checklist.md`, so a reviewer following it may lack the project's antipattern checks and Known Debt context.
   - **Proposed change and verification:** include the checklist when it exists and explicitly account for its absence before intake. Exercise the example with present and absent checklist files; neither silently omit an available checklist nor fail merely because a pre-intake repository lacks one.

4. **Open — preserve unchanged checklist context in the P7 truth gate.**
   - **Scope:** review-artifact selection and its fallback in `7_documentation/SKILL.md`.
   - **Observation/risk:** selection based on changed documentation can omit an unchanged checklist, and the fallback list also lacks it. The truth reviewer can therefore miss the standing review rules even when the baseline file exists.
   - **Proposed change and verification:** supply an existing checklist as review input whether changed or unchanged, while retaining the pre-intake missing-baseline WARN behavior. Verify changed, unchanged, and missing checklist cases without inventing a checklist for a repository that has no baseline yet.

5. **Open — make the bootstrap-reconcile baseline count conditional.**
   - **Scope:** `0b_intake/references/bootstrap-reconcile.md`.
   - **Observation/risk:** the reference still describes all nine baseline files unconditionally, unlike the intake skill's seven always-required core files plus two conditional UI files. This can cause an unnecessary UI-document requirement for backend-only repositories.
   - **Proposed change and verification:** mirror the intake skill's wording while preserving the nine-file total and the existing component-directory condition. Compare both provider references with their intake output, drafting, and seal instructions; confirm that the checklist remains one of the seven required core files.
