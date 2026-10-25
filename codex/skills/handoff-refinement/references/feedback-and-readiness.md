# Product feedback and readiness format

Use this format for the human-facing exchange and readiness report; the machine-readable authority, identity and hash fields are defined only in [input-contract.md](input-contract.md).

## Portable product return package

Create one round under `product-feedback/<round>/` containing the questions and the minimum evidence needed to answer. Include baseline identity/version/hash, source owner, receiver repo keys and source AC excerpts verbatim. Link only packaged evidence or accessible pinned team sources; strip credentials and machine-local paths. Retain earlier rounds. The round directory is the portable return unit: include the needed source excerpts and evidence inside it, or use accessible immutable team URLs. Relative links must resolve after copying only that directory elsewhere; links back into the receiver workspace do not make a standalone return package. Verify that copy before handoff.

Lead with a concise decision summary, omitting empty groups:

- Decisions needed now: stable question ID, affected behavior, recommendation, alternatives and impacts.
- Previously known questions now blocking work: what changed and why an answer is needed now.
- Resolved since the previous round: explicit response provenance and affected requirements.
- Open, currently non-blocking items: owner and next decision point.

Place each question in one summary group; reference its full record below instead of repeating it. Keep engineering-only decisions in refinement artifacts. For mixed issues, state exactly which product decision engineering needs. Summaries do not establish approval or replace the complete evidence.

Carry unresolved questions into this portable round with enough context to answer without earlier round folders. Account for prior questions by stable ID, including superseded items and items requiring reassessment, in their full records; cite the resolution or replacement and explain baseline applicability. Retain existing response statuses from the input contract. A zero-new-findings summary must still expose outstanding questions.

For each question record:

- Stable question ID and classification.
- Applicable baseline and source requirement/AC IDs.
- Observed code/integration evidence with repo revision and path.
- The concrete question, plausible alternatives and their user/engineering impact.
- Product decision owner and exactly which repo/tasks are blocked.
- Response status and, when answered, the explicit answer, owner, date, baseline and provenance. Distinguish approval of a change from a proposal or acknowledgement.

The source-side session prompt names `review-reconcile`, the product source project and this round. It asks the product owner to resolve or defer each question, update owned sources where approved, and supply explicit responses or a new `handoff-package` run. Preparing the prompt is not permission to send messages or publish artifacts.

## Readiness report

`refinement/readiness.md` links the resolver result and records:

| Item | Evidence |
|---|---|
| Product baseline and responses | Immutable identities, versions/hashes and accepted team revision |
| Round reconciliation | Compared input revisions, semantic changes and affected requirements; disposition and evidence for prior findings/questions, with missing comparison evidence explicit |
| Package consistency | Cross-PRD rules and transitions checked, shared issues linked to all affected requirements, and material non-applicability reasons |
| Source preservation | Hash verification result and location of integrity metadata |
| Repo baseline | Repo key, accepted intake commit or missing/resume/bootstrap action |
| Product blockers | Question IDs, owner and affected scope; no silent defaults |
| Engineering requirements | Separate IDs, authority/source links and testable checks; optional standalone technical stories with rationale, ownership and dependencies |
| Coverage | Every source AC mapped to owning repo tasks and verification responsibility |
| Cross-repo dependencies | Pinned contracts/revisions, readiness and release order |
| Integration acceptance | Required scenarios, compatible revisions and actual evidence or pending status |
| Next session | Owning skill and portable artifact paths, with blockers explicit |

For example, a product interaction can require a task in `client` and another in `service`. Both bundles retain the same source identity and assign only their own work; the shared coverage record names both and an integration scenario against their compatible commits. Separate local project IDs and checkout paths do not change the product identity. If the service requirement awaits a product answer, neither the client's green tests nor its PR clears that dependency.
