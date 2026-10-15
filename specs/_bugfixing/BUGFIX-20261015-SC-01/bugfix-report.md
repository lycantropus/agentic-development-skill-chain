# SC-01: context checks before role synchronization

## Scope and reproduction

Status: fixed and verified.

Starting revision: `1ae90a4`, with existing unrelated working-tree changes retained.
The reported command was `chain render context check 6 varianten-finden`:
project-local roles still expected the story in the spawn prompt, so the default
check exited 2 before P0. The installed-role override passed all three waves;
copying only the six installed roles made the default check pass.

An isolated temporary fixture reproduces the same sequence without modifying a
project checkout: stale project-role preamble → default check exit 2; explicit
installed-role check → exit 0 with stale role hashes unchanged; copying the six
current role manifests → default check exit 0. The fixture covers every wave.
The original `varianten-finden` project was not rerun.

## Root cause and correction

The compiler correctly prefers project-local `templates/roles/` manifests.
Step 4 and CP1 nevertheless used its default role resolution before P0, although
P0 owns synchronization. Both Codex and Claude now pass their installed
`5_executing/manifests/roles` directory explicitly in those pre-P0 checks.

P0 now explicitly requires a default context check after successful sync and
conflict reconciliation, before proceeding. This validates synchronized project
roles and their adaptations. A green installed-role check alone never authorizes
implementation. P0's compile guidance now acknowledges project-role adaptations
as a possible failure source. Compiler behavior remains unchanged.

## Verification and test escape

- Red proof: after adding the regression guard, before changing instructions,
  `bash scripts/test-compile-context-bundles.sh` exited 1 at
  `codex/4_writing-plans/SKILL.md: pre-P0 check must explicitly use installed roles`.
- Green proof: the same command exited 0 (`compile-context-bundles: ok`) after
  updating both providers. It checks both installed-role instruction commands,
  the sequence sync → default project-role check → compile, and the isolated
  stale/override/synchronized runtime scenario.
- Existing tests already rejected stale role manifests but explicitly supplied
  installed roles in their regular helper. They did not guard the actual skill
  command selection or the pre-P0/post-sync sequence, allowing this escape.
- Full repository validation: `./scripts/validate.sh` exited 0 and ended
  `validate: ok`; all harnesses passed.
- CodeRabbit and Sonar analysis were skipped: the checkout has no corresponding
  repository configuration. No compiler changes, new dependencies, commit,
  publication, or installed-skill synchronization are part of this repair.
