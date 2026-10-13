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
      you must not write files or run mutating commands." The tree must be
      unchanged afterwards; compare this snapshot taken before and right after
      the finder, before any bookkeeping (it excludes only the ledger and state
      the QA scripts write):
      `P=(. ':(exclude)specs/*/state.json' ':(exclude)specs/*/findings.json'); { git status --porcelain -- "${P[@]}"; git diff HEAD -- "${P[@]}"; } | sha1sum`.
      A finder that errors, changes the tree, or fails the ingest is re-run
      once; a second failure is a stop. `ledger.mjs add` rejects the whole
      batch on any malformed line, so nothing partial is recorded:

      ```bash ingest
      if ! grep -q 'Production-ready recommendation' "$OUT" 2>/dev/null; then
        echo "finder returned no complete QA report"; false
      elif ! grep -q '^{' "$OUT" || grep '^{' "$OUT" | node scripts/ledger.mjs add <X> <theme>; then
        REPORT="specs/PROJ-<X>-<theme>/5_progress/qa-finder-$(date +%Y%m%d-%H%M%S).md"
        grep -v '^{' "$OUT" >"$REPORT" || true
        bash scripts/state.sh set <X> <theme> .qa.finder_report "$REPORT"
      else
        echo "ledger rejected the finding lines (nothing written); re-run the finder"; false
      fi
      ```
   2. **Controller:** follow `references/p6-controller.md` with `<X>` and
      `<theme>` filled in. Fixers are workers, tiered as in Step 5. The opposite
      re-verification is `bash scripts/cross-review.sh qa <X> <theme> --personas --persist --round N …`
      as in `6_qa`.
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
that modified the tree. Record the cause, park the run, and end the turn with
the reason as the stop report:

```bash stop
bash scripts/state.sh set <X> <theme> .stop "{\"reason\": $(jq -Rn --arg r "$REASON" '$r'), \"at\": \"$(date -Iseconds)\"}"
bash scripts/state.sh transition <X> <theme> "$(bash scripts/state.sh get <X> <theme> .phase)" blocked
```

Uncommitted work stays in the worktree (no rescue branch in-session). Tell the user to clear the goal
(`/goal clear`): a parked run cannot meet it. After the fix:
`bash scripts/state.sh transition <X> <theme> <phase> running`, then re-invoke Step 5.
