# Repository Instructions

- Keep `AGENTS.md` as the only curated durable-context file.
- Keep `CLAUDE.md` pointer-only; it must reference `AGENTS.md` and must not contain durable rules.
- Keep Codex and Claude skill chains aligned unless tool-specific wording is required.
- Include only the core 0-to-8 chain and explicitly documented optional skills in this repository.
- Treat `specs/PROJ-<X>-<theme>/2b_handoff/` package runs as generated artifacts: only the `handoff-package` skill may create or update them. Other skills must update source artifacts and let `handoff-package` generate a new dated run.
- Write `specs/**/state.json` only via `state.sh` and `specs/**/findings.json` only via `findings.mjs` — never with ad-hoc edits or raw jq writes. Morning reports, stop reports, and PR bodies are rendered by the template scripts (`render.mjs`), never written or edited by hand.
- Keep the framework helper scripts byte-identical across their skill copies (`chain`, `state.sh`, `preflight.sh`, `env-local.sh`, `ponytail-check.sh`, `plan.mjs`, `render.mjs`, `worktree.sh`, the role manifests, `curation.sh`, the cross-review scripts/template, `agent-md-entry.md.tmpl`, `findings.mjs`, `runner/prompts/p6-controller.md` (also as `5_executing/references/p6-controller.md`), `in-session-driver.md`, `wave-gate.sh`, the 8_delivery scripts/templates); `validate.sh` enforces this.
- Run `./scripts/validate.sh` before publishing changes.
