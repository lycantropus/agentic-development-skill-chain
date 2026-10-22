# Installation

## Both providers (recommended)

From the repository root:

```bash
./scripts/install.sh
```

It verifies `claude`, `codex`, bash >= 4.4, `git`, `jq` and `node` first, plus
`perl` where `timeout` is absent (stock macOS; perl ships with it). If any are missing it lists all of them, prints the commands that would
install them and asks before running anything:

- `git`, `jq`, `perl`, `node`/`npm` (and `curl` if needed) through `brew`,
  `apt-get` or `dnf` (with `sudo` when not root);
- [Claude Code](https://code.claude.com/docs/en/setup) via
  `curl -fsSL https://claude.ai/install.sh | bash`;
- [Codex](https://github.com/openai/codex) via `npm install -g @openai/codex`
  (with `sudo` only when the global npm prefix is not writable).

An old bash, or tools without a supported package manager, stay manual. Any
answer but `y` (or a non-interactive stdin) declines; then, or when an install
command fails, nothing is copied. Start newly installed `claude` and `codex`
once to sign in.

With everything present it runs both installers below and then
`chain check ponytail`. A missing Ponytail
plugin only warns (with the install commands), because it is needed for
framework runs, not for installing skills. The per-provider installers stay
available for single-provider machines and for `update-chain`.

## Codex

From the repository root:

```bash
./scripts/install-codex.sh
```

This copies the bundled chain into:

```text
~/.codex/skills/
```

## Claude

From the repository root:

```bash
./scripts/install-claude.sh
```

This copies the bundled chain into:

```text
~/.claude/skills/
```

## Platforms

The framework helpers run on Linux and macOS. They need bash >= 4.4, `git`, `jq` and `node`; where `timeout` is absent (stock macOS) also `perl`, which ships with macOS.

- **macOS**: `/bin/bash` is 3.2, which is too old. Install a current bash and put it before `/bin` on `PATH`
  (`chain` and the gates stop with this hint otherwise):

  ```bash
  brew install bash jq
  ```

  `coreutils` (`timeout`) and `flock` are optional (`brew install coreutils flock`): without them the helpers use a built-in perl `timeout` and an
  exclusive `mkdir` lock (a `--shared` request degrades to exclusive: safe, slower). The wave gate's `resources`
  budget reads `vm_stat` on macOS; there is no memory-pressure (PSI) check there.
- **Windows**: use WSL2 (it is Linux). Native Windows shells are not supported.
- Case-insensitive filesystems (the macOS default) are not hardened: do not name two PROJ worktrees or `app_root`
  paths that differ only by case.
- All GNU-only calls live in `compat.sh`; `scripts/check-portability.sh` (part of `validate.sh`) enforces it and
  `scripts/test-portability.sh` runs the fast suites on a Linux box with macOS-like tool shims.

## Ponytail (required for framework runs, Stage 2)

The framework's minimalism ladder is the third-party
[Ponytail](https://github.com/DietrichGebert/ponytail) plugin — installed
on all active providers in mode `full`. Versions may differ and are reported
for diagnostics only. The P0 preflight (`chain check ponytail`) blocks runs
on absence, wrong mode, or restricted subagent coverage.

```bash
# Claude Code
claude plugin marketplace add DietrichGebert/ponytail
claude plugin install ponytail@ponytail
# Codex
codex plugin marketplace add DietrichGebert/ponytail
codex plugin add ponytail@ponytail
```

The shared mode lives in `~/.config/ponytail/config.json`
(`{"defaultMode":"full"}` — `chain check ponytail` persists it if absent).
Leave `PONYTAIL_SUBAGENT_MATCHER` unset. Ponytail then reaches every normal
subagent, including generic implementation fallbacks; P0 rejects a scoped
matcher because it silently misses those fallbacks.

`PONYTAIL_ENFORCE=0` is the loud escape hatch — the run continues without
the ladder, recorded in state.json and flagged in the reports.

## Uninstall

From the repository root:

```bash
./scripts/uninstall.sh
```

It lists what it found and asks separately before removing each part:

- **Skill folders**: every skill this repository ships (plus the retired
  `4a_checkpoint`/`4b_setup`) in `~/.claude/skills/` and `~/.codex/skills/`
  (or `CLAUDE_HOME`/`CODEX_HOME`). It matches by name, so your other skills
  and the directories themselves stay.
- **Ponytail**, where installed: `claude plugin uninstall ponytail@ponytail`,
  `claude plugin marketplace remove ponytail`, `codex plugin remove
  ponytail@ponytail`, `codex plugin marketplace remove ponytail`, and the
  shared `~/.config/ponytail/config.json`. A failed command is reported and the
  rest still run (exit 1). If a provider's CLI is missing, its Ponytail is named
  for manual removal.

Any answer but `y` (or a non-interactive stdin) keeps that part. Claude Code,
Codex, the toolchain, and helper copies already synced into projects
(`chain sync`) are not touched.

## Notes

The core chain (steps 0 to 8) is one installation unit. Both installers copy every
skill folder and the runner; there is no per-skill selection and no dependency
resolution. The early skills lean on the shared helpers in `5_executing`
(`scripts/chain` and friends), and `5b_executing-large-model` requires
`5_executing` alongside it. Copying single folders by hand is unsupported unless
you also copy the folders they document as dependencies.

Framework helpers in a project are versioned snapshots of the installed skills.
P0 and every implementation start/resume run the installed synchronizer before
workers start:

```bash
bash ~/.codex/skills/5_executing/scripts/chain sync
# Claude: bash ~/.claude/skills/5_executing/scripts/chain sync
```

Run from the PROJ worktree root, or pass `--target /path/to/worktree`.
`--check` reports freshness without changing project files. The generated
`.skillchain-helpers.json` records installed-source and project-file hashes;
commit it with the helpers. Untouched copies update automatically. Existing
different files without a baseline, local edits, or upstream changes to reviewed
adaptations require reconciliation. After merging and testing each such file,
use `--adopt scripts/<file>` to record its reviewed contents. Repeat the option
for multiple files. Adoption is an explicit review acknowledgment, not a merge.
Conflicts prevent the entire refresh from writing project files.

Always invoke the installed synchronizer; a project copy requires an explicit
`--skills-root /path/to/installed/skills`. Refresh only before implementation,
never during a gate. Installation remains explicit: pull this framework and run
the installers to obtain new releases. Sync compares with those installed files,
not a remote branch, and never silently discards project-specific adaptations.

- Existing skill folders with the same names are overwritten.
- The `update-chain` skill does this from inside a session: it clones the upstream repo, shows which installed skills change, and runs the installer for the current provider.
- The installed folders are copies, not Git repositories. To update another
  machine, pull this skill-chain repository there and run both installers
  again; do not try to push from `~/.claude/skills/` or `~/.codex/skills/`.
- Re-running the installers also refreshes the shared P0/P8 worktree helper,
  the plan-consistency validator, and the provider-specific Wave Gate.
- The 0-to-8 core chain and its `cross-review` mechanism are installed, along with the documented optional skills: `bugfixing`, `refactor-dreamer`, `sonar-cli`, `supabase-local-dev`, `update-chain`, and `vibecoder`.
- `CLAUDE.md` is not installed as a skill. It is a repo-level pointer file only.

## Updating an existing PROJ for the optimized gates

Refresh before starting/resuming implementation, with workers and gates stopped.
The helper inventory includes the `chain` dispatcher and the helpers behind
`chain quality`, `chain gate wave` and `chain quality seal`. Commit the synchronized helper set and manifest
together. If repository-wide lint includes generated framework scripts, extend
its existing exclusions for newly introduced helpers using the P0 preflight
inventory; syncing files alone does not change lint configuration.

Build/coverage reuse is opt-in. Declare real output paths in `build_artifacts`
and, for separate coverage, `coverage_cmd` plus `coverage_artifacts`. The
configured `sonar_cmd` must then scan without running coverage again. Do not
also declare the same coverage command as a quality-phase test. Projects without
these options continue running their existing commands without artifact reuse.

Old markdown-only PROJ gate statuses cannot satisfy the new proof checker.
Generate current evidence through `chain quality`; do not fabricate or
copy success records from an earlier run. The [execution guide](executing-skill.md#proj-quality-gate)
describes the commands and invalidation rules. An already-running agent is not
updated mid-gate; resume with the refreshed skill instructions and helper set.

### External prerequisites, browser selection and lock modes

Install the updated skills first, then refresh and commit the project helpers
as described above before introducing new config fields. Older gates may ignore
unknown fields. Installing skills does not rewrite a running project's config,
test harness or copied helpers.

- Keep each AC's original test, command and plan mapping when adding
  `external_dependency`. Its `reason`, `decided_by`, `decided_at` and
  `check_command` describe a real authorized decision and readiness check.
  An absent prerequisite produces `blocked_external` / exit 76 without
  certifying the wave. Refresh the plan validator and PR renderer too; update
  the framework checkout used to run `chain render report` for matching
  stop/morning reports.
- Browser regressions with filtered selection can add `selection_check_cmd`:
  a read-only discovery command using the real selector and printing a positive
  supported test count. It runs before AC verification. Existing suites need
  no automatic file split; files above 800 lines receive an advisory warning.
- `chain worktree with-shared-lock` remains exclusive. Opt into `--shared` only
  after proving fixture/actor isolation, using the same lock path in all
  worktrees. Migrations, resets and global changes remain exclusive.
  Auth-consuming gate commands still hold an exclusive outer lock over the
  command; switching an inner helper to shared mode does not shorten that hold.
- Give lock acquisition an explicit `--timeout` that fits inside the enclosing
  process timeout together with the command's execution budget. Preserve exit
  73 and stderr through project wrappers. The gate also recognizes the helper's
  `SKILLCHAIN_LOCK_TIMEOUT` marker when a wrapper changes the failure exit code.

Any helper/config/test commit changes HEAD and invalidates AC cache reuse;
config changes also change the complete gate-config fingerprint. Preserve
historical certificates as historical evidence. A deliberate test split updates
plan, command and route mappings together and requires fresh affected checks.
For fixture isolation, browser lifecycle and incremental parallelism, follow the
[execution reference](../claude/skills/5_executing/references/worker-lifecycle.md#reduce-verification-cost-before-increasing-concurrency).
