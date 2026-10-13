# In-session driver (P5 done → PR)

For the answer "drive it to the PR in this session". The lead does what the
runner's phase lanes do, from `.worktree.path`, under the same state, ledger and
stop rules, and asks nothing until a stop condition. Under `/goal` (for example
`/goal PROJ-<X> has an open PR and state.json is P8:done`) the session keeps
taking turns: never end a turn before the exit or a stop. No `/compact` flush
between phases; every heavy step below runs in a subagent so this context keeps
only verdicts. `scripts/test-in-session-driver.sh` executes the mechanical blocks.

Entry is state-driven: read `bash scripts/state.sh get <X> <theme> '.phase + ":" + .status'`
and continue at the matching step, so a fresh session resumes anywhere.

1. **`P5:running` after the Quality Gate proof:** `bash scripts/state.sh transition <X> <theme> P5 done`.
2. **P6** (`P5:done` → `transition P6 running`; `P6:running` → continue):
   1. **Finder**, run on every entry to P6, resumes included (the ledger
      dedupes; a report from an earlier revision proves nothing about this one).
      One fresh, read-only subagent: "Load and execute the QA skill qa (6_qa)
      READ-ONLY for specs/PROJ-<X>-<theme>: find bugs, do not fix anything. Emit
      each finding as one JSON line on stdout ({"source":"qa","severity":...,"summary":...});
      you must not write files or run mutating commands." Its persona review
      (`cross-review.sh --personas`) is the opposite-provider panel: six
      separate Codex workers, or six Claude workers on the strongest model when
      Codex is unavailable (say so). A finder that errors, returns no complete
      report (no `Production-ready recommendation:` line), emits a malformed
      finding line, or changes the tree is a stop: re-run it once, a second
      failure parks the run. Snapshot the tree before and after with
      `{ git status --porcelain; git diff HEAD -- . ':(exclude)specs'; } | sha1sum`
      (edits to existing untracked or ignored files are not covered; `specs/`
      is excluded because the QA scripts legitimately write the ledger and
      state). There is no wall-clock bound in-session; only the detached runner
      has `--timeout`. Ingest fails closed: the report is recorded only after
      the ledger accepted every finding line.

      ```bash ingest
      if [ ! -s "$OUT" ] || ! grep -q 'Production-ready recommendation' "$OUT"; then
        echo "finder returned no complete QA report"; false
      else
        ALL="$(grep -c '^{' "$OUT" || true)"
        VALID="$(grep '^{' "$OUT" | while IFS= read -r l; do
          jq -c 'select(type == "object" and .source? and .severity? and .summary?)' <<<"$l" 2>/dev/null
        done)"
        GOOD="$(printf '%s' "$VALID" | grep -c . || true)"
        if [ "$GOOD" != "$ALL" ]; then echo "malformed finding line(s): $GOOD of $ALL valid; re-run the finder"; false; else
          { [ -z "$VALID" ] || printf '%s\n' "$VALID" | node scripts/ledger.mjs add <X> <theme>; } && {
            REPORT="specs/PROJ-<X>-<theme>/5_progress/qa-finder-$(date +%Y%m%d-%H%M%S).md"
            grep -v '^{' "$OUT" >"$REPORT" || true
            bash scripts/state.sh set <X> <theme> .qa.finder_report "$REPORT"
          }
        fi
      fi
      ```
   2. **Controller:** follow `references/p6-controller.md` with `<X>` and
      `<theme>` filled in. Fixers are workers, tiered as in Step 5. A fixer never
      certifies its own repair: re-verify with
      `bash scripts/cross-review.sh qa <X> <theme> --personas --persist --round N …`
      as in `6_qa` (six separate processes on the opposite provider).
   3. **Seal** only with no open Critical/High; a non-zero exit means keep
      fixing or stop:

      ```bash seal
      [ "$(node scripts/ledger.mjs stats <X> <theme> | jq -r '.open_blocking // 0')" = 0 ] \
        && bash scripts/state.sh transition <X> <theme> P6 done \
        || { echo "P6 cannot seal: open Critical/High findings remain"; false; }
      ```
3. **P7:** `transition P7 running`, then `/7_documentation` for the PROJ; it runs
   the framework curation and gates and seals `P7 done`. A red gate is a stop.
4. **P8:** `/8_delivery` for the PROJ; it transitions, opens the PR, polls CI on
   the exact head and seals `P8 done` (its non-runner path owns the final poll
   and the post-merge cleanup). An open PR is the success state.
5. **Finish:** one line: the PR URL, CI result, and the open Medium/Low debt count.

**Stop conditions** are the runner's: three failed repair attempts on the same
Critical/High finding, a red gate, a sealed P6 with open Critical/High, a finder
that modified the tree. Record the cause, park the run, and end the turn:

```bash stop
bash scripts/state.sh set <X> <theme> .stop "{\"reason\": $(jq -Rn --arg r "$REASON" '$r'), \"at\": \"$(date -Iseconds)\"}"
bash scripts/state.sh transition <X> <theme> "$(bash scripts/state.sh get <X> <theme> .phase)" blocked
RR="$(dirname "${SKILLCHAIN_RUNNER:-runner/run-phase.sh}")/render-report.mjs"
[ -f "$RR" ] && node "$RR" stop <X> <theme> --reason "$REASON" \
  && bash scripts/state.sh set <X> <theme> .stop.report "specs/PROJ-<X>-<theme>/5_progress/stop-report.md"
```

Uncommitted work stays in the worktree (no rescue branch in-session). Without the runner there is no stop report; the reason is in `.stop`. Tell the user to clear the goal
(`/goal clear`): a parked run cannot meet it. After the fix:
`bash scripts/state.sh transition <X> <theme> <phase> running`, then re-invoke Step 5.
