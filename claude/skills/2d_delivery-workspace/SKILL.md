---
name: delivery-workspace
description: "Discover or set up the shared team coordination checkout for an incoming product handoff and route baseline onboarding per implementation repository. Use when developers need to locate the handoff workspace, safely clone or create its team remote, or identify which repositories need intake. Optional; not feature refinement or application implementation."
---

# Delivery Workspace

We use one shared repository for handoffs, PRD refinement and open decisions. If the team has none yet, we set one up. Read [references/workspace-contract.md](references/workspace-contract.md) for the portable inventory, the access and creation procedure and the baseline evidence. This skill owns workspace setup; `handoff-refinement` reuses its inventory for each incoming version.

Three outcomes are distinct and are reported separately: a **prepared draft** (inventory written, remote not confirmed), a **set-up team workspace** (remote verified, marker registered on the team path) and **team acceptance** of a baseline. Schema validity alone never promotes a draft.

## 1. Explain purpose, then discover

Tell the user what the coordination repo is for and that an existing repo or a tracked subdirectory of an implementation repo is fine. Discover in order: explicit team remote/identity, valid registered inventory and checkout, bounded inspection of the current and user-supplied neighboring repositories. Inspect Git roots, remotes and the marker; directory names are not ownership evidence. Ask which owner to use when ambiguous. If nothing is identified, request the address or search only the selected organization with authenticated provider tools. Local absence does not prove remote absence. An inaccessible remote is an access blocker; an unmarked repository is legacy/unregistered. Neither permits replacement or overwriting.

## 2. Probe access early

Before proposing a clone or creation, run `workspace.mjs access` and report four separate answers: Git read, Git write, repository administration (or creation rights in the target owner) and PR read access. When creation is possible, check creation rights before asking for the final creation approval, so the user is not asked to authorize something the session cannot do. Name each missing permission concretely with the owner/repo it concerns. Never request credentials in chat; use private secret entry/authentication tools if needed.

## 3. Reuse, clone or create, then verify

Reuse a matching checkout without resetting or switching branches. Clone a known remote into an unoccupied path when onboarding calls for it. For a missing remote, make provider, owner, name, visibility and minimal README/inventory concrete, confirm authorization for that exact target, and create only within it. Follow the bounded procedure in the reference; never infer public visibility. Register the team marker only after `workspace.mjs verify` confirms the coordination remote. Until then the inventory is a draft kept outside the coordination location. A local-only mode exists only when the user explicitly selects it; do not set up a local-only store on your own as a substitute for the team remote.

## 4. Record portable identities

Record identities in `delivery-workspace.json` at the agreed tracked coordination location. Keep local checkout bindings outside versioned content. A dedicated specifications repository is optional: a tracked location in one implementation repository works. Do not create empty placeholder trees, initialize a code checkout's parent as Git, track nested repositories, or clone unrelated repositories.

## 5. Investigate in two stages

First build a bounded repository inventory: which repos exist, which are affected by this handoff, which are coordination-only. Then deepen baseline evidence only for core repositories and dependencies the handoff concretely touches. Not every discovered repository needs an intake or its own session. Read the incoming manifest/README for the prototype inclusion decision and actual format, and carry that context into the refinement prompt. A packaged prototype or its source repository is a reference, not automatically an implementation repository: do not register it for intake/bootstrap unless the agreed repository ownership explicitly assigns it implementation work. Missing promised prototype files go to `handoff-refinement` as a package discrepancy; they do not block unrelated workspace setup. For prototype evidence state three things separately: source present, version matches the handoff, executability actually checked. Screenshots are not a runnable prototype.

For each affected implementation repository rate three things independently: baseline maturity (`missing`, `partial`, `local-sealed`, `proposed`, `accepted`), team acceptance (only `accepted` with verified evidence) and active work (open intake PR or confirmed owner). A sealed state on a remote branch is still not team acceptance. Branch names are hints to inspect, not proof of running work. Reuse accepted baselines; resume incomplete intake; coordinate active intake with its owner. Do not rerun sealed intake for a new package or infer completeness from `docs/PRODUCT.md`. Propose drift audits only from evidence. Coordination-only repositories need no application baseline. Planned repositories go to the existing greenfield/bootstrap path using approved scope.

## 6. Keep shared changes on the team path

Keep shared changes on the team's normal review path. Record local drafts, proposed PRs and accepted revisions distinctly. Pin inputs to accepted commits/content hashes. Reconcile upstream changes and conflicting answers before readiness; no force-push, last-write-win, distributed lock or new approval system.

Recommend sibling checkouts under a plain `work/` directory for convenience (`delivery-specs/`, `frontend/`, `backend/`), without requiring that layout. Non-sibling paths, worktrees and spaces work. In apps that bind sessions to repositories, bind the next session to its actual repo/worktree; a prompt saying `cd` does not bind it.

## 7. Close with one status report

Finish setup and its checks here. Do not auto-run intake, bootstrap or refinement. End with the five-line status from the reference (locally checked, remote checked, draft prepared, published, team accepted) and the per-repo checklist. Emit a copyable start prompt only for sessions that are actually required now and have a real target checkout; list unresolved bootstrap work as a later task with its prerequisites instead. Do not repeat a sealed intake because a new handoff arrived. On an access blocker name the one concrete next user action and keep the already granted authorization recorded so the continuation does not re-ask for it. Intake must keep its interview and seal process. Preliminary read-only refinement and product-question preparation may start before every baseline is ready; architecture/planning/execution still check the relevant repository prerequisites. The ordinary linear chain has no new inventory or team-approval requirement.
