# Runner — Host-Neutral Dual-Lane Phase Runner (Stage 1 + Stage 2)

The thin runner from CONCEPT.md §5/§6b: it starts fresh Claude and
Codex lanes per phase, keeps exactly one writer per phase, and hands
state between phases ONLY via `specs/PROJ-<X>-<theme>/state.json` and
files on disk. No conversation history crosses a phase boundary.

`scripts/install-claude.sh` / `install-codex.sh` copy this directory to
`<skills>/5_executing/runner/`, where Step 5's unattended handoff finds it
(override with `SKILLCHAIN_RUNNER=<path>/run-phase.sh`).

## Contents

| File | Purpose |
|---|---|
| `run-phase.sh` | run one phase (`P0 P5 P6 P7 P8`) or `auto` (all remaining phases → one-line summary; the morning report renders only when P8 neither left an open PR nor removed the worktree); P5 loads `5b_executing-large-model` by default; `SKILLCHAIN_P5_SKILL="executing (5_executing)"` swaps in the full-procedure skill for weaker writer models |
| `spike-dual-lane.sh` | Stage 1 release gate: concurrent lanes, read-only enforcement, JSONL capture, attribution, kill-tree cancellation |
| `spike-stage2.sh` | Stage 2 release gate: live smoke of the Claude and Codex review adapters against a planted factual error (real CLI calls; the deterministic checks run in `scripts/test-*.sh` under `validate.sh`) |
| `prompts/lane-prompt.md.tmpl` | generic lane prompt (role rules, state discipline) |
| `prompts/p6-controller.md` | the P6 phase-controller contract (ledger triage, fix dispatch, opposite re-verification) |
| `schemas/state.schema.json`, `schemas/findings.schema.json` | documented contracts for the two machine files (validation is embedded in `chain state` / `chain findings`) |

Report inputs include state, findings where used, and the PROJ's
`3-4_plan/wave-gate-config.json` (falling back to legacy `6_plan/`).
Stop/morning reports and the P8 PR renderer list declared external prerequisites
with AC ID, wave, reason, decision author/date, readiness command and evidence
path. These are declarations, not passing or current-readiness evidence; rendering
does not execute the checks. `blocked_external` / exit 76 at a wave gate does
not seal P5 or unlock the next wave. See the
[execution guide](../docs/executing-skill.md#wave-scoped-outer-ralph).

## Typical overnight run

```bash
# Step 5 starts this for you when you answer its one question after P0:done ("unattended"),
# detached: setsid nohup ... > <log> 2>&1 &   (see 5_executing/references/unattended-handoff.md)
# by hand, after CP1 was approved via the Step 5 checkpoint subskill (state.json = CP1:approved):
runner/run-phase.sh auto <proj-x> <theme>            # P0 → P5 → P6 → P7 → P8
# morning: read the run's one-line summary and the PR body, then review the PR (CP2)
# optional cross-PROJ overview: bash ~/.claude/skills/5_executing/scripts/chain render report morning specs
```

Single phase / resume after a stop:

```bash
bash scripts/chain state transition <proj-x> <theme> <phase> running   # resume from blocked
runner/run-phase.sh <phase> <proj-x> <theme> [--timeout 3600] [--writer claude|codex]
```

## Invariants the runner owns

- **Single writer-orchestrator:** one top-level lane per phase may write. It
  delegates covered edits to workers under its authority, while retaining
  decomposition, integration, deterministic verification, gates, commits, and
  operational records. Disjoint worker ownership may run concurrently;
  dependencies and overlap are serialized, and local edits require an explicit
  unavailable/prohibited-delegation fallback. The peer lane runs
  with read-only tools (`--allowedTools Read,Grep,Glob` /
  `codex exec --sandbox read-only`; the P6 finder additionally gets
  `Bash` to run tests, with a working-tree integrity check after it).
  Peer findings are ingested into the ledger; a failed peer never stops
  the run — but a failed or timed-out WRITER cancels the peer
  immediately, and SIGINT/SIGTERM kill both lane process groups.
- **Permissions are not bypassed by default:** the claude writer lane runs
  under the project's `.claude/settings.json` (allowlist + deny list,
  `defaultMode: acceptEdits`, merged by `merge-project-settings.sh`); a
  command outside the allowlist is denied and the run parks.
  `SKILLCHAIN_SKIP_PERMISSIONS=1` adds `--dangerously-skip-permissions` as an
  explicit opt-in only. Peer lanes always keep their read-only tool lists.
- **Persistent PROJ worktree:** P0 creates or resumes the registered sibling
  worktree and `run-phase.sh` re-executes there before later phases. Dependencies
  are local to that checkout; `.env.local`, development data, and hosted-auth
  limits are shared. Cleanup is conservative and belongs to successful P8.
- **P6 is sequential:** the read-only QA finder runs FIRST and its
  findings are ingested before the P6 controller starts; the runner
  refuses `P6:done` while the ledger has open Critical/High findings.
  The finder's text output is stored by the runner as
  `5_progress/qa-finder-<ts>.md` (path in `state.json` `.qa.finder_report`).
- **Models are pinned:** the claude writer runs `CLAUDE_WRITER_MODEL`
  (default `opus`), review lanes run `CLAUDE_REVIEW_MODEL` (default: the
  strongest model in `CLAUDE_MODEL_RANK`, `fable opus sonnet`, that is not
  the writer model); both are recorded per lane in state.json and the runner
  refuses to start when they are equal — degraded "model-opposite" must
  actually be a different model.
- **Degraded mode is never silent:** codex missing or unauthenticated →
  single-provider run with the model-opposite reviewer; `degraded` is
  set in state.json and rendered into the morning report and PR body.
- **Stop policy (§8):** writer failure, timeout, or an unsealed phase
  parks the run — the rescue branch is built through a temporary git
  index (the working tree, including state.json and lane outputs, is
  never touched), state → `blocked` with the exact cause, rendered stop
  report with a cleanup list. Nothing is simply aborted.
- **Interrupted-run receipts:** before each provider launch, the supervisor writes
  an atomic, flushed `started` receipt under the Git common directory's
  `skillchain-runs/PROJ-<X>-<theme>/`. These operational files stay outside the
  checkout and survive a killed lane. The supervisor records the child exit and
  timeout observation, then settles receipts only after phase verification (or
  an explicit stop). Exit codes above 128 carry the shell signal convention;
  an explicit exit can match that code, so this is never proof of OOM.
  A per-PROJ supervisor lease serializes reconciliation and lane launch; on hosts
  with `flock`, the supervisor holds the lease without passing it into provider
  tools or long-lived preview daemons. A launch wrapper checks the recorded
  supervisor identity and records its own process identity before executing the
  provider; it refuses when that check detects a missing supervisor.
  Reconciliation blocks while a prior attached lane remains
  alive under a missing supervisor. P0 releases and reacquires the lease
  when re-entering its worktree, before launching any subsequent provider.
  Without `flock`, the portable directory lease fails closed after a killed
  supervisor: verify no prior tools remain, then remove the named stale
  `supervisor.lock.d` manually. It never races to reap another owner's lease.
  A restart reconciles incomplete receipts before skipping sealed phases: a live
  supervisor blocks a duplicate run; a missing supervisor produces an
  `interrupted` / unverified outcome and parks state as `blocked`. Restarts from
  the control checkout first re-enter the registered persistent PROJ worktree,
  so recovery updates that worktree's state. Resume the
  blocked phase only after inspecting prior lane outputs and stopping any
  surviving orphan tools. Linux ownership uses boot ID plus process start ticks;
  other supported hosts use `ps` start time and refuse uncertain ownership.
  If the supervisor itself was killed, its signal and cause remain unknown.
  No journal guarantees reporting while the entire host is down, or durable
  storage surviving kernel, filesystem, or hardware failure.
- **Sealing:** the writer lane seals its phase via
  `chain state transition <phase> done`; the runner verifies the seal and
  refuses to advance without it.
- **P7 curation gates (Stage 2):** after the P7 seal the runner
  independently re-verifies FORM (`chain check caps` exit 0) and TRUTH
  (no open Critical/High ledger findings from source `cross-review`) —
  sealing past a red gate parks the run, mirror of the P6 gate.
- **Worker context files (Stage 2):** P5/P7 writer prompts carry a POINTER to
  `specs/.../context/` — file text is never pasted. Every worker reads one
  compiled file whose path the spawn prompt names:
  `workers/wave-N/<US-ID>.md` per story (role from the plan's `Agent Type`
  column), `roles/wave-N/<role>.md` for reviewers and fix workers. There is
  no SubagentStart hook, no lock and no hash bookkeeping (a file's first line carries the plan hash): `compile --wave N` runs at each
  wave start, and no worker starts after a non-zero exit until a rerun
  exits 0.
- **Ponytail coverage (Stage 2):** the runner clears
  `PONYTAIL_SUBAGENT_MATCHER`, using Ponytail's native all-subagent path;
  P0 blocks any scoped matcher because it can miss generic implementation
  fallbacks. Installation and mode `full` remain gated in `chain check ponytail`; versions may differ.

Env knobs: `CLAUDE_WRITER_MODEL`, `CLAUDE_REVIEW_MODEL`, `CLAUDE_MODEL_RANK`, `PEER_GRACE`
(seconds a peer may outlive the writer, default 300), `SKILLCHAIN_POLL_SECONDS`
(lane poll interval, default 5; the test harnesses set 0.1),
`PONYTAIL_ENFORCE` (0 = loud escape hatch for the P0 ponytail gate),
`SKILLCHAIN_WORKTREE_ROOT` overrides the default sibling-worktree base;
`SKILLCHAIN_DEV_PORT` records the PROJ dev port when setup needs a non-default.

The runner never edits `state.json` or `findings.json` directly — all
writes go through `scripts/chain state` and `scripts/chain findings` (both
serialize concurrent writes via locks and validate against the schema
contract on every write).
