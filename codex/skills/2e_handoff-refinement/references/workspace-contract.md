# Workspace inventory and onboarding

## Portable versus local

The coordination marker is `delivery-workspace.json`, at the agreed tracked coordination location (root or an explicitly supplied subdirectory). Whatever the marker location, each refinement project is its own directory in `<checkout-root>/specs/`; in the handoff's source repository it sits beside the source product project, never inside it. A valid marker identifies ownership; absence means unregistered, not empty. The helper never writes the inventory.

Three statements about an inventory stay separate:

| Statement | Command | Meaning |
|---|---|---|
| Schema valid | `node <handoff-refinement>/scripts/workspace.mjs check <inventory>` | Structure only. Says nothing about whether any remote exists. |
| Remote verified | `workspace.mjs verify <inventory>` | `git ls-remote` answered for the coordination remote (and reports every other listed remote). |
| Team ready | `verify` returns `teamReady: true` | Team mode and verified coordination remote; the marker may be registered on the team path. |

A prepared file with `mode: team` and `planned: false` whose coordination remote does not exist yet is a **draft**: keep it outside the coordination location (for example `delivery-workspace.draft.json` in a scratch directory) and do not report it as a set-up workspace. `discover` returns `status: "draft"` for a team marker inside a checkout that does not track the inventory's coordination remote, so a locally initialized directory cannot pass as the team workspace. Register the real marker only after `verify` succeeds and through normal branch/PR policy.

```json
{
  "schemaVersion": 1,
  "mode": "team",
  "coordinationRepo": "specs",
  "repositories": [
    {"key": "specs", "role": "coordination", "remote": "https://git.example/team/specs", "planned": false},
    {"key": "web", "role": "implementation", "remote": "https://git.example/team/web", "planned": false,
     "baseline": {"status": "accepted", "commit": "1111111111111111111111111111111111111111", "evidence": "baseline-reviews/web.md"}},
    {"key": "api", "role": "implementation", "remote": null, "planned": true}
  ]
}
```

Keys are stable lowercase names, independent of folder names. Roles are `coordination`, `implementation`, or `both`, and describe the repository's work for this handoff, not whether it contains code: the repository that produced the handoff and only hosts coordination is `coordination` (its code is reference only), and becomes `both` only when agreed ownership assigns it implementation work. Remotes use sanitized canonical HTTPS identities without credentials, `.git`, query strings or fragments; authentication/transport is local configuration. `remote: null` is allowed for planned repositories and unpublished local repositories. `mode: local-only` requires explicit user selection and remains temporary/unpublished; never set it up unasked as a stand-in for a blocked team remote. Team mode requires the coordination remote. Do not invent a remote for a future repo.

Baseline statuses: `missing`, `partial`, `local-sealed`, `proposed`, `accepted`. They describe baseline maturity: `local-sealed` is a seal commit that exists locally or on a pushed branch without a review request, `proposed` has an open review/PR, `accepted` was merged or approved under the team's policy. Only `accepted` with verified evidence is team acceptance; a sealed state on a remote branch stays `local-sealed` or `proposed`. Active work is not a status field: it is inspection evidence (open intake PR, confirmed owner) reported next to the status. The last three statuses require the exact 40-character commit and a portable evidence URL or relative Markdown path. Evidence records the seal check, review/acceptance decision and accepted repository revision, including owner/date under normal team policy. A hash existing locally is not evidence of team acceptance. Record proposed PR separately in that evidence. The helper validates structure, not human authority: verify evidence and Git reachability before reporting accepted readiness.

Machine-local bindings are a separate JSON object, e.g. `{"web":"/local/checkout"}`, outside Git or in an explicitly ignored local file. Check `git check-ignore` and `git ls-files` before storing local bindings inside a checkout; an already tracked file is not made private by `.gitignore`. Never put paths, credentials or local configuration in the portable inventory. Resolve each key independently. A missing path gives a clone/select instruction, never a guessed `cd`.

## Discovery and safe remote setup

Probe access before proposing clone or creation: `workspace.mjs access --remote=<url> [--checkout=<path>] [--github=<owner/name>]` reports `read` (`git ls-remote`), `write` (`git push --dry-run` from the given checkout; `unknown` when the dry run failed for another reason), and for GitHub `exists`, `admin`, `pullRequests` (`gh pr list`) or, for an absent target, `create` (personal account match or active organization membership with creation rights). `exists: "unknown"` after a 404 means the target may be private and invisible. These are read-only probes, not authority: the result lists `missing` permissions so you can name them to the user concretely. Run the creation-rights probe before asking for the final creation approval. Missing PR read access means missing intake evidence, not proof that no intake is active.

`workspace.mjs inspect <checkout>` reports its Git root, sanitized remote identities, dirty state and intake hints. It supports `.git` files/worktrees and does not switch branches. `discover <explicit-path>...` checks only those paths and root markers; for a marker at an agreed subdirectory, pass its location to `check` and inspect the owning root explicitly. An explicit remote identity wins over automatic discovery. Several candidates require selection; local absence only prompts remote discovery. Inspect markers and remote ownership before trusting a matching checkout. An invalid marker fails, never silently falls back to linear mode.

`workspace.mjs clone <remote> <destination>` reuses a matching root without modifying it, clones only to a missing destination and refuses other collisions. Supply credential-free transport arguments; use existing Git authentication. Do not change existing remotes to make them match. For a new target, first identify provider, owner, repository name, visibility, intended minimal README/inventory, authorization and branch policy. Recheck exact target existence immediately before creation and after any uncertain response. Verify matching ownership/visibility; on conflict or denial, stop and resolve access. Do not retry creation blindly or pick another name to evade an error.

For GitHub, `workspace.mjs ensure-github <owner/name> <private|internal|public> [--authorized]` uses authenticated `gh`. Without `--authorized` it may reuse an existing exact target but cannot create. Pass the flag only when session authorization covers that exact target, visibility and initial content. It checks the owner/repository inventory, rechecks the exact target before mutation and reads it once after creation. `403`, authentication, unexpected provider results and uncertain unconfirmed creation fail. A `404` can hide a private repository: resolve known access concerns before using creation, and never treat a local search as proof of nonexistence. The helper creates an empty remote only; initialize minimal README/inventory locally afterward through normal branch/PR policy. Do not upload handoffs as a creation side effect. Other providers use their supported tools with the same checks; do not add a hosting abstraction.

Local-only staging is used only when the user explicitly selects it after remote access/setup is blocked; offer it, do not default to it. Initialize only a new empty selected directory or safely register the agreed existing repo. Reconciliation after access returns must compare the real remote's history and inventory, not force-push local history. Reruns preserve user rules and handoffs. Read upstream changes before proposing team revisions; reconcile competing edits and re-evaluate affected baseline/answer readiness rather than overwriting them.

## Baseline evidence and handoff

For every code repository, inspect its current code and curated documents, `specs/intake/`, local/remote branches and accessible provider PRs (e.g. `gh pr list --repo <owner/name> --state open --json number,title,headRefName,author,url`). Inspect candidate PR diffs when title/branch is unclear. Missing provider access is missing evidence, not proof no intake is active.

- Complete baseline: run `workspace.mjs baseline <checkout> <seal-commit> [examined-revision] [remote-evidence.json]` and verify the existing intake seal/check evidence and accepted commit against the code repo's accepted branch/review policy; reuse that revision. A local seal or open PR remains `local-sealed`/`proposed`. If the checkout lacks the accepted revision, offer safe acquisition/selection; do not silently reset it.
- Partial/interrupted baseline: report missing documents/decisions/checks and resume the existing intake. Preserve existing documents as merge inputs. An active intake branch/PR routes to its owner before another intake starts.
- Missing baseline with existing code: provide an intake prompt. Code, not the incoming feature, defines current behavior. `docs/PRODUCT.md` describes this repo's responsibility and may reference shared product context without rewriting feature requirements.
- New/planned code repository: provide bootstrap/greenfield routing with approved product scope and shared architectural decisions. Missing checkout is explicit; no fictional extracted baseline or duplicate product discovery.
- Suspected drift: report concrete evidence and propose an explicit audit. New handoffs alone never trigger intake/audit.
- Coordination-only repository (`role: coordination`, including a source repository that hosts coordination): exempt from app intake, architecture/design-system/test-convention requirements. A `both` repository follows the implementation routing above.

The exported `nextBaselineStep` is only a deterministic routing aid: its `applicability` report plus `acceptedRevisionVerified`, `sealVerified`, `activeIntake`, `hasCode` and `drift` evidence comes from the inspection above. Explicit evidence of active intake takes priority over baseline reuse. Branch names alone are inspection hints, not proof of active work: they do not override a recorded accepted baseline. A recorded seal/proposal/accepted baseline without an applicability report returns `verify-baseline-applicability`. A report with missing seal/files or divergent unequal documents returns `reconcile-baseline-applicability`, never automatic intake. A divergent but byte-equivalent baseline is eligible for reuse once acceptance is verified. The report examines committed trees, not uncommitted documents; inspect dirty changes separately. Keep `sealRevision`, `examinedRevision`, `ancestor`, per-file presence/equality and `remoteAcceptance` distinct. Remote evidence input is `{verified,revision,evidence}` from the actual remote probe; the helper reports it but does not authenticate human acceptance. Match the report to the recorded seal and examined code revision before routing. A recorded accepted baseline with incomplete acceptance verification returns `verify-accepted-baseline`: verify its evidence and safely acquire/select that revision before reuse, never start duplicate intake. Recorded local seals/proposals await team acceptance (or coordinate their active intake); this is not a readiness claim. It does not fabricate evidence or launch a skill.

Close every coordination setup (location located, marker drafted or registered, clone or creation) with this status block, one line each, each answered `yes`, `no` or `not attempted` with its evidence:

```
Locally checked:   <checkouts inspected, inventory schema result>
Remote checked:    <verify result for the coordination remote; access probe summary>
Draft prepared:    <path of the draft inventory, or none>
Published:         <marker commit/PR on the team path, or none>
Team accepted:     <per-repo accepted baselines with evidence, or none>
```

On an access blocker, add the single next user action (for example "grant push on team/specs" or "confirm creation of team/specs as private") and restate the authorization already granted so the continuation does not ask for it again.

Then give the checklist and one prompt per session that is required now and has a real target checkout. Bootstrap or intake work whose checkout or authorization is still unresolved is listed as a later task with its prerequisites, not as a start prompt. Only repositories affected by this handoff appear; a discovered but unaffected repository gets no prompt. Example prompt: “Use intake in the selected `web` checkout. Resume the existing intake at `<actual path>`, preserve its interview/seal contract, and read `<inventory>` plus `<pinned handoff>` as future context only. Report local seal commit and team acceptance separately.” Bind app sessions to the real checkout. Refinement can gather code evidence/questions now; do not declare all repositories ready because one passed. No workspace setup changes `state.json` or `findings.json`.
