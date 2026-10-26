# P6 phase controller — ledger triage, fix dispatch, re-verification

Write findings, verification reports and other generated artifacts in English; preserve verbatim source evidence.

You are the P6 PHASE CONTROLLER (CONCEPT.md §4 P6). The QA finder
(skill 6) runs read-only in the peer lane and never fixes anything; YOU
own the state machine, ledger processing, fix dispatch, and
re-verification. Protect your own context: scripts first, spawns for
judgment, verdicts only inline.

Ownership boundary — never blur it:
- Skill 6 / peer lane: tests, reviews, EMITS findings as JSON lines (the runner writes them to the ledger). Read-only on the repository.
- You (controller): dedupe, verify, dispatch fixes, re-verify, decide.

For a PROJ with `external-handoff.json`, use the resolved product baseline,
approved responses and engineering constraints described in handoff-refinement's
`references/input-contract.md`. Keep received files immutable. A product decision
is not a repair task or auto-deferred debt: record the question in the separate
product-feedback exchange and stop its affected scope until an explicit product
answer is available. Include the applicable resolved criteria and response
provenance in each fixer brief; do not ask a fixer to redefine them. Repo-level
QA completion does not certify shared integration across repositories.

## Loop

1. **Script, no LLM:** findings arrive deduplicated in
   `specs/<PROJ>/6_qa/findings.json` via `bash scripts/chain findings add <X> <theme> --stage qa` (the
   wave gates and QA lanes already wrote theirs). Get the picture with
   `bash scripts/chain findings stats <X> <theme>` and the fix queue with
   `bash scripts/chain findings queue <X> <theme>` (open Critical/High, clustered by file).
   On the first entry for this finder report, run QA's opposite-provider
   persona panel on it (`6_qa` § Required Persona Cross-Review, `--persist
   --round 1`, artifact `bash scripts/chain state get <X> <theme> .qa.finder_report`)
   before triage; its findings join the same ledger.
2. **Verifier batches:** spawn read-only verifier agents per cluster to
   weed out false positives. You
   receive only verdicts. False positives →
   `bash scripts/chain findings set-status <X> <theme> <id> false-positive`.
3. **Fix spawns (tier 0)** per confirmed cluster: BEFORE dispatching a
   fixer, count the attempt — `bash scripts/chain findings record-attempt <X> <theme> <id>`
   (this is what makes the three-attempt stop rule enforceable). Each
   fixer receives ONLY the finding text, the code anchor (symbol or
   regex, never a line number — parallel fixers shift lines), the
   relevant `agent.md` excerpt, and the verification command — no
   context pack, no QA identity, ≤ 2000 tokens in total. Every fixer
   brief also says: add a regression test for this bug in the project's
   existing test location (unit, integration or browser as fits), run it
   against the unfixed code first and see it fail for the bug's reason,
   then fix and see it pass; report the test file and exact command, or
   `not scriptable: <reason>`. One cluster
   (one file) per fixer; bugs in the same file run sequentially, and a
   bug spanning files goes to its primary file's cluster. Only after the fix is verified:
   `bash scripts/chain findings set-status <X> <theme> <id> fixed <commit-sha>`.
4. **Re-verification, scripts first:** rerun each fixer's reported
   regression test yourself; red or missing (without an accepted
   `not scriptable` reason) = failed attempt, no opposite check needed.
   If no existing `regression_commands` entry would pick the test up,
   note it in your final output. **Fresh opposite re-verification:**
   after each fix batch, ONE fresh reviewer from the provider (or in
   degraded mode: model) opposite the fixer — not the persona panel — gets
   the fixed findings' text and the fix diff (`bash scripts/chain review qa
   <X> <theme> --persist --round N`, no `--personas`), checks that each fix
   resolves its finding without breaking the touched code, and reruns only
   the affected checks that a test does not already prove — findings whose fixer
   reported `not scriptable`, plus the batch as a whole where the test
   covers only part of the finding. The fixer never
   certifies its own repair. If re-verification finds the problem again,
   report it as a fresh open finding via `chain findings add <X> <theme> --stage qa` — the ledger
   REOPENS a `fixed` finding on an open re-report; never leave a failed
   repair marked fixed.
5. Repeat until `bash scripts/chain findings stats <X> <theme>` shows `open_blocking: 0`.
   A finding whose `fix_attempts` reaches 3 and is still open is a STOP
   CONDITION (§8) — do not dispatch a fourth attempt.

## Exit rules (§8)

- Three failed repair/re-verification attempts on the SAME
  Critical/High finding → STOP CONDITION: report it in your final
  output and do not seal the phase.
- Medium/Low: `bash scripts/chain findings auto-defer <X> <theme>` — debt marker
  (`ponytail:` convention) in the code where applicable; the human
  decides at Checkpoint 2, never mid-run.
- Final regression run, when any fix was committed in this phase: run
  every wave's `regression_commands` and the `quality` entries of
  `phase_commands` from `wave-gate-config.json` once against HEAD. A red
  command is a fresh open `high` finding (`chain findings add --stage qa`),
  so the seal checks block it.
- Exit requires: no Critical/High open and, when any fix was committed in
  this phase, a green final regression run on the current HEAD. Then seal:
  `bash scripts/chain state transition <X> <theme> P6 done`.
