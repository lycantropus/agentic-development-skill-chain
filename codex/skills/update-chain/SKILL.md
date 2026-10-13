---
name: update-chain
description: "Update the installed skill chain from the upstream GitHub repo: shallow-clone silviobeer/agentic-development-skill-chain (main, or a given branch/tag), show which installed skills change, and run the repo's own installer for the current provider. Use when the user asks to update, upgrade, refresh, or pull the latest skill chain or skills. Not part of the 0-8 chain. Not for: editing skills in this repo (edit the repo, then run its install script), updating a project's helper copies (Step 5 runs sync-framework.mjs on every start or resume)."
---

# Update Chain

Pull the latest skill chain from GitHub and install it over the local copy.
Optional input: a branch or tag (default `main`).

Set `PROVIDER` to `claude` (Claude Code, installs to `~/.claude/skills`) or
`codex` (Codex, installs to `~/.codex/skills`) — whichever you are running as.

```bash
PROVIDER=claude   # or: codex
REF="${REF:-main}"
DEST="${CLAUDE_HOME:-$HOME/.claude}/skills"; [ "$PROVIDER" = codex ] && DEST="${CODEX_HOME:-$HOME/.codex}/skills"
SRC="$(mktemp -d)"
git clone --quiet --depth 1 --branch "$REF" https://github.com/silviobeer/agentic-development-skill-chain.git "$SRC"
git -C "$SRC" log -1 --format='Installing %h %s (%cd)' --date=short
# What will change (read-only); no output means already up to date
for d in "$SRC/$PROVIDER"/skills/*/; do diff -rq "$d" "$DEST/$(basename "$d")" || true; done
bash "$SRC/scripts/install-$PROVIDER.sh"
rm -rf "$SRC"
```

The installer replaces every skill folder shipped by the repo, so local edits
inside those folders are overwritten. Skills not shipped by the repo are left
alone.

Report the installed commit and the changed skills from the diff. Then add one
line: project helper copies (`scripts/state.sh`, `wave-gate.sh`, …) are not
touched; Step 5 refreshes them on its next start or resume, or preview now with
`node <installed>/5_executing/scripts/sync-framework.mjs --check` inside a
project.

If the clone fails (offline, unknown ref), stop and report the error. Do not
install from a partial clone.
