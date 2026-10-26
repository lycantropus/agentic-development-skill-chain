# Installation

## Both providers (recommended)

From the repository root:

```bash
./scripts/install.sh
```

It verifies `claude`, `codex`, bash >= 4.4, `git`, `jq` and Node.js >= 22 (the
oldest maintained LTS; the version CI runs) first, plus
`perl` where `timeout` is absent (stock macOS; perl ships with it). If any are missing it lists all of them, prints the commands that would
install them and asks before running anything:

- `git`, `jq`, `perl` (and `curl` if needed) through `brew`, `apt-get` or
  `dnf` (with `sudo` when not root);
- Node.js, missing or older than 22, as the current LTS through
  [nvm](https://github.com/nvm-sh/nvm) (`nvm install --lts`, set as nvm's
  default; nvm itself is installed first if absent and adds its loader to your
  shell profile). Distro `nodejs` packages are not used: they often ship an
  end-of-life Node;
- [Claude Code](https://code.claude.com/docs/en/setup) via
  `curl -fsSL https://claude.ai/install.sh | bash`;
- [Codex](https://github.com/openai/codex) via `npm install -g @openai/codex`
  (no `sudo` with nvm; with an existing system Node only when the global npm
  prefix is not writable).

An old bash, or tools without a supported package manager, stay manual. Any
answer but `y` (or a non-interactive stdin) declines; then, or when an install
command fails, nothing is copied. Start newly installed `claude` and `codex`
once to sign in.

With everything present it runs both installers below. Then, if `sonar` or
`sonar-scanner` is missing, it offers the
optional [Sonar CLIs](#sonar-clis-optional-per-project) the same way. The
per-provider installers stay
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

The optional receiving skills and their references/helpers are included by both
installers. Their presence does not activate external mode in existing projects.
For a disposable installation check, use temporary destinations:

```bash
test_install_root="$(mktemp -d)"
env CODEX_HOME="$test_install_root/codex" ./scripts/install-codex.sh
env CLAUDE_HOME="$test_install_root/claude" ./scripts/install-claude.sh
```

These commands do not change the live installed skills. A normal installation
still uses the explicit commands above and replaces matching installed folders.

## Platforms

The framework helpers run on Linux and macOS. They need bash >= 4.4, `git`, `jq` and Node.js >= 22 (an LTS line); where `timeout` is absent (stock macOS) also `perl`, which ships with macOS.

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

## Ponytail (retired)

The third-party Ponytail plugin was the framework's minimalism ladder until
2026-10-26. Its rules now live in the chain's own role manifests
(`5_executing/manifests/roles/*.md`, `## Minimal by default`), so nothing
installs or gates it any more. Where it is still installed it keeps injecting
into every subagent on that provider, so `./scripts/check-setup.sh` warns and
`./scripts/uninstall.sh` offers its removal (see [Uninstall](#uninstall)), or
remove it by hand:

```bash
# Claude Code
claude plugin uninstall ponytail@ponytail
claude plugin marketplace remove ponytail
# Codex
codex plugin remove ponytail@ponytail
codex plugin marketplace remove ponytail
```

## Sonar CLIs (optional, per project)

Only projects with a `sonar-project.properties` (or `sonar_required: true` in
the wave-gate config) need them; P0 preflight checks that per project. The
PROJ-end Quality Gate uses two separate tools with separate logins:

| CLI | Binary | Used for |
|---|---|---|
| SonarQube CLI | `sonar` | Login, issues, API, quality-gate and measure data |
| SonarScanner CLI | `sonar-scanner` | The analysis itself (uploads a report) |

`./scripts/install.sh` offers both when missing, per user and without `sudo`:

- `sonar`: SonarSource's install script
  (`curl -o- https://raw.githubusercontent.com/SonarSource/sonarqube-cli/refs/heads/master/user-scripts/install.sh | bash`),
  into `~/.local/share/sonarqube-cli/bin` (it adds that to your shell profile).
  There is no Homebrew formula for it.
- `sonar-scanner`: `brew install sonar-scanner` where Homebrew exists; otherwise
  the official SonarScanner zip for your OS (it bundles Java; version pinned as
  `SONAR_SCANNER_VERSION` in `scripts/requirements.sh`),
  unpacked into `~/.local/share` and linked as `~/.local/bin/sonar-scanner`
  (`unzip` is installed first if missing). Do not use `npm i -g sonar-scanner`:
  that is an old unofficial wrapper.

Both folders count as installed even before a new terminal has them on `PATH`,
so a re-run does not offer the CLIs again; while they are not on your `PATH`,
the installer names the folders to add to your shell profile.

Login and the token stay manual:

```bash
sonar auth login     # browser; SonarQube Cloud US: --server https://sonarqube.us, self-hosted: --server https://<host>
sonar auth status
```

The scanner needs `SONAR_TOKEN` (Sonar: My Account → Security; never commit it):
exported in your environment, or as `SONAR_TOKEN=...` in the control checkout's
`.env.local`, which `chain worktree` symlinks into every worktree.

## After pulling updates

The installed skills are copies, so a pull does not reach them, and a pull may
raise a tool's required version. From the repository root:

```bash
./scripts/check-setup.sh
```

It changes nothing and reports:

- **Tools**: each prerequisite with its version, against the minimums in
  [`scripts/requirements.sh`](../scripts/requirements.sh) (`REQ_NODE`,
  `REQ_BASH`, ...; empty means any version).
- **Installed skills**, per provider, compared with a fresh install of this
  checkout: skills changed or added since the last install, retired folders
  still installed, or no install at all. Other skills in those directories are
  ignored.
- A leftover [Ponytail](#ponytail-retired) plugin per provider, as a warning only.

It exits 1 when anything but Ponytail needs fixing; `./scripts/install.sh`
fixes all of it (it treats a tool below its minimum like a missing one and
offers the upgrade and reinstalls the skills).

### Optional: run it after every pull

Nothing runs the check for you. If you want it after each pull, add local git
hooks in your own clone (hooks are not versioned, so this affects only you).
They only report, and never block or undo the pull:

```bash
hooks="$(git rev-parse --git-path hooks)"
cat >"$hooks/post-merge" <<'EOF'
#!/bin/sh
# Local, optional: check the setup after each pull. Never blocks the pull.
./scripts/check-setup.sh || true
EOF
cat >"$hooks/post-rewrite" <<'EOF'
#!/bin/sh
# Same for `git pull --rebase` (post-rewrite also runs on commit --amend: skip that).
[ "$1" = rebase ] && ./scripts/check-setup.sh
exit 0
EOF
chmod +x "$hooks/post-merge" "$hooks/post-rewrite"
```

`post-merge` covers `git pull` (merge or fast-forward), `post-rewrite` covers
`git pull --rebase`. This overwrites existing hooks of the same name, so check
`ls "$hooks"` first and merge by hand if you already have them. To stop, delete
the two files.

**Maintainers**: when a change needs a newer tool, raise its `REQ_*` minimum in
`scripts/requirements.sh`. `install.sh` and `check-setup.sh` both read it. The
versions `install.sh` downloads (`NVM_VERSION`, `SONAR_SCANNER_VERSION`) are
pinned in the same file, under their own heading.

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
- The retired **Ponytail** plugin, where still installed: `claude plugin uninstall ponytail@ponytail`,
  `claude plugin marketplace remove ponytail`, `codex plugin remove
  ponytail@ponytail` and `codex plugin marketplace remove ponytail`. A failed
  command is reported and the rest still run (exit 1). If a provider's CLI is
  missing, its Ponytail is named for manual removal. The shared
  `~/.config/ponytail/config.json` stays, since other Ponytail installs read it
  too.

Any answer but `y` (or a non-interactive stdin) keeps that part. Claude Code,
Codex, the toolchain, the Sonar CLIs, and helper copies already synced into projects
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
- The 0-to-8 core chain and its `cross-review` mechanism are installed, along with the optional receiving step `2e_handoff-refinement`, and the documented optional skills: `bugfixing`, `refactor-dreamer`, `sonar-cli`, `supabase-local-dev`, `update-chain`, and `vibecoder`.
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
