#!/usr/bin/env bash
# delivery.sh — the two P8 gates that talk to git and gh.
#
#   delivery.sh probe <proj-x> <theme> [target-branch]   (default: main)
#     Probe the PROJ branch against the target WITHOUT touching any real branch.
#     Creates a throwaway detached worktree on the target branch, attempts
#     `git merge --no-commit --no-ff <proj-branch>` there, records the conflicted
#     files, aborts, and removes the worktree (trap-guarded). Classification is a
#     file-type heuristic: lockfiles and generated files are `trivial`
#     (auto-fixable); everything else is `semantic` (risk assessment into the PR
#     + escalate — CONCEPT.md §4 P8).
#     Output: JSON on stdout: {"branch","target","verdict":"none|trivial|semantic","conflicts":[{"file","class"}]}
#     Exit:   0 probe ran (read verdict from JSON) · 1 probe failed · 64 usage
#
#   delivery.sh poll <pr-number> [timeout-seconds] [expected-head]
#     Wait for the PR's CI checks and surface red checks with verbatim logs for
#     fix agents. Resolves the PR head SHA and requires a completed, successful
#     latest run for every workflow on that commit, plus zero pending PR checks
#     (this also covers third-party checks such as CodeRabbit, which run no
#     GitHub Actions workflow of their own). "No run yet" is deliberately red:
#     queued concurrency-group work has no PR check to watch. expected-head binds
#     the poll to the exact local seal commit.
#     Exit:   0 all checks green · 1 at least one check red · 2 timeout · 64 usage
set -euo pipefail
_compat_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_compat_dir/compat.sh" ]; then source "$_compat_dir/compat.sh"; else source "$_compat_dir/../../5_executing/scripts/compat.sh"; fi

# Each gate is a subshell function: its own variables, its own EXIT trap, its own exit code.
probe() (

  PROJ="${1:-}"; THEME="${2:-}"; TARGET="${3:-main}"
  if [ -z "$PROJ" ] || [ -z "$THEME" ]; then
    echo "Usage: delivery.sh probe <proj-x> <theme> [target-branch]" >&2
    exit 64
  fi

  BRANCH="proj/PROJ-${PROJ}"
  git rev-parse --verify --quiet "$BRANCH" >/dev/null || { echo "delivery.sh probe: branch $BRANCH not found" >&2; exit 1; }

  # Best-effort: refresh the target ref from its remote-tracking upstream before
  # probing, so a stale local main does not report a false "no conflicts". Not
  # fatal — some contexts (test fixtures, no remote) legitimately have none.
  if remote_ref="$(git rev-parse --abbrev-ref --symbolic-full-name "${TARGET}@{upstream}" 2>/dev/null)"; then
    remote="${remote_ref%%/*}"
    git fetch --quiet "$remote" "${TARGET}:${TARGET}" 2>/dev/null || echo "delivery.sh probe: could not refresh $TARGET from $remote (continuing with local ref)" >&2
  fi

  git rev-parse --verify --quiet "$TARGET" >/dev/null || { echo "delivery.sh probe: target $TARGET not found" >&2; exit 1; }

  WT="$(mktemp -d)/probe"
  cleanup() {
    git -C "$WT" merge --abort >/dev/null 2>&1 || true
    git worktree remove --force "$WT" >/dev/null 2>&1 || true
    rm -rf "$(dirname "$WT")"
  }
  trap cleanup EXIT

  if ! git worktree add --detach "$WT" "$TARGET" >/dev/null 2>"$(dirname "$WT")/worktree-add.err"; then
    echo "delivery.sh probe: failed to create probe worktree for $TARGET:" >&2
    cat "$(dirname "$WT")/worktree-add.err" >&2
    exit 1
  fi

  CONFLICTS=""
  if ! git -C "$WT" merge --no-commit --no-ff "$BRANCH" >/dev/null 2>&1; then
    CONFLICTS="$(git -C "$WT" diff --name-only --diff-filter=U)"
  fi

  # trivial: lockfiles + generated artifacts; everything else: semantic
  printf '%s\n' "$CONFLICTS" | jq -R -s \
    --arg branch "$BRANCH" --arg target "$TARGET" '
    [ split("\n")[] | select(length > 0)
      | { file: .,
          class: (if test("(^|/)(package-lock\\.json|pnpm-lock\\.yaml|yarn\\.lock|bun\\.lockb?|Cargo\\.lock|composer\\.lock|poetry\\.lock)$")
                     or test("\\.(generated|min)\\.")
                  then "trivial" else "semantic" end) }
    ] as $c
    | { branch: $branch,
        target: $target,
        verdict: (if ($c | length) == 0 then "none"
                  elif ([$c[] | select(.class == "semantic")] | length) > 0 then "semantic"
                  else "trivial" end),
        conflicts: $c }'
)

poll() (

  PR="${1:-}"; TIMEOUT="${2:-1800}"; EXPECTED_HEAD="${3:-}"
  if [ -z "$PR" ]; then
    echo "Usage: delivery.sh poll <pr-number> [timeout-seconds]" >&2
    exit 64
  fi
  case "$TIMEOUT" in (*[!0-9]*|'') echo "delivery.sh poll: timeout must be a positive integer" >&2; exit 64 ;; esac

  HEAD_SHA="$(gh pr view "$PR" --json headRefOid --jq .headRefOid)"
  [ -n "$HEAD_SHA" ] || { echo "delivery.sh poll: could not resolve the head commit of PR #${PR}" >&2; exit 1; }
  if [ -n "$EXPECTED_HEAD" ] && [ "$HEAD_SHA" != "$EXPECTED_HEAD" ]; then
    echo "delivery.sh poll: PR head $HEAD_SHA does not match expected sealed head $EXPECTED_HEAD" >&2
    exit 1
  fi
  echo "→ [$(now_iso)] polling PR #${PR} at ${HEAD_SHA:0:7} (timeout ${TIMEOUT}s)"

  # Push and pull_request can produce two runs. The newest per workflow is the
  # verdict; a newest cancelled/failed run never inherits an older success.
  latest_runs() {
    gh run list --commit "$HEAD_SHA" --limit 50 --json databaseId,status,conclusion,name \
      --jq 'group_by(.name) | map(max_by(.databaseId))'
  }

  # gh run list only sees GitHub Actions workflow runs. Third-party checks
  # (CodeRabbit's PR review, Vercel, etc.) are separate check contexts that
  # only `gh pr checks` reports — waiting on Actions alone declares victory
  # while such a check is still mid-review, so a later-arriving finding
  # triggers a fix + push that retriggers the checks just called green.
  pending_third_party_checks() {
    gh pr checks "$PR" --json bucket,name --jq '[.[] | select(.bucket == "pending")]' 2>/dev/null || echo '[]'
  }

  DEADLINE=$(( $(date +%s) + TIMEOUT ))
  while :; do
    RUNS="$(latest_runs 2>/dev/null || echo '[]')"
    TOTAL=$(jq 'length' <<<"$RUNS")
    PENDING=$(jq '[.[] | select(.status != "completed")] | length' <<<"$RUNS")
    PENDING_CHECKS="$(pending_third_party_checks)"
    CHECKS_PENDING=$(jq 'length' <<<"$PENDING_CHECKS")
    [ "$TOTAL" -gt 0 ] && [ "$PENDING" -eq 0 ] && [ "$CHECKS_PENDING" -eq 0 ] && break
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
      if [ "$TOTAL" -eq 0 ]; then
        echo "❌ TIMEOUT: no workflow run appeared for ${HEAD_SHA:0:7}; nothing verified this commit." >&2
      else
        echo "❌ TIMEOUT after ${TIMEOUT}s — still running:" >&2
        jq -r '.[] | select(.status != "completed") | "   \(.name): \(.status)"' <<<"$RUNS" >&2
        jq -r '.[] | "   \(.name): pending"' <<<"$PENDING_CHECKS" >&2
      fi
      exit 2
    fi
    echo "   [$(date +%H:%M:%S)] ${TOTAL} workflow(s), ${PENDING} not finished, ${CHECKS_PENDING} check(s) pending — waiting"
    sleep 30
  done

  RED=0
  FAILED=$(jq -r '.[] | select(.conclusion != "success" and .conclusion != "skipped") | "\(.databaseId) \(.name) \(.conclusion)"' <<<"$RUNS")
  if [ -n "$FAILED" ]; then
    RED=1
    echo "❌ workflow runs that did not succeed on ${HEAD_SHA:0:7}:" >&2
    sed 's/^/   /' <<<"$FAILED" >&2
  fi
  CHECKS="$(gh pr checks "$PR" 2>/dev/null || true)"
  if grep -qE $'\tfail\t' <<<"$CHECKS"; then
    RED=1
    echo "❌ red PR checks:" >&2
    grep -E $'\tfail\t' <<<"$CHECKS" | sed 's/^/   /' >&2
  fi
  if [ "$RED" -eq 0 ]; then
    CURRENT_PR_HEAD="$(gh pr view "$PR" --json headRefOid --jq .headRefOid)"
    if [ "$CURRENT_PR_HEAD" != "$HEAD_SHA" ]; then
      echo "delivery.sh poll: PR head changed during polling ($HEAD_SHA -> $CURRENT_PR_HEAD); result is stale" >&2
      exit 1
    fi
    echo "✓ every workflow completed successfully on ${HEAD_SHA:0:7}, and no PR check is red"
    jq -r '.[] | "   \(.name): \(.conclusion)"' <<<"$RUNS"
    exit 0
  fi
  for run_id in $(jq -r '.[] | select(.conclusion != "success" and .conclusion != "skipped") | .databaseId' <<<"$RUNS"); do
    echo "── failed run ${run_id} on ${HEAD_SHA:0:7} (log-failed, verbatim) ──" >&2
    gh run view "$run_id" --log-failed >&2 || true
  done

  echo "→ NEXT ACTION: hand the verbatim output above to a fix agent (max 3 attempts, then stop condition §8)." >&2
  exit 1
)

case "${1:-}" in
  probe) shift; probe "$@" ;;
  poll) shift; poll "$@" ;;
  *) echo "Usage: delivery.sh probe <proj-x> <theme> [target-branch] | poll <pr-number> [timeout-seconds] [expected-head]" >&2; exit 64 ;;
esac
