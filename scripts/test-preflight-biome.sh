#!/usr/bin/env bash
# Behavior tests for P0 preflight's Biome compatibility and wrapped Sonar probe.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="$ROOT/codex/skills/5_executing/scripts/preflight.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
for command_name in gh claude coderabbit; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_BIN/$command_name"
  chmod +x "$FAKE_BIN/$command_name"
done
# Prevent a real npx fallback from attempting any package/network lookup.
printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKE_BIN/npx"
chmod +x "$FAKE_BIN/npx"

run_preflight() {
  local work="$1"
  (cd "$work" && \
    PATH="$FAKE_BIN:$PATH" \
    PREFLIGHT_SKIP_LIVE_PROBE=1 \
    PREFLIGHT_CODEX_INACTIVE=1 \
    PONYTAIL_ENFORCE=0 \
    PONYTAIL_CONFIG="$TMP/ponytail-config.json" \
    PONYTAIL_CLAUDE_REGISTRY="$TMP/no-claude-registry.json" \
    bash "$PREFLIGHT" 1 biome >/dev/null)
}

ignored='[".claude/settings.json","scripts/compile-context.mjs","scripts/story-slice.mjs","scripts/validate-wave-plan.mjs","scripts/validate-prds.mjs","scripts/validate-architecture.mjs","scripts/document-parser.mjs","scripts/architecture-parser.mjs","scripts/gen-component-registry.mjs","scripts/findings.mjs","scripts/render.mjs", "scripts/sync-framework.mjs", "scripts/quality.mjs", ".skillchain-helpers.json"]'

biome1="$TMP/biome1"
mkdir -p "$biome1"
printf '{"files":{"ignore":["existing/**"]}}\n' >"$biome1/biome.json"
run_preflight "$biome1"
run_preflight "$biome1"
jq -e --argjson expected "$ignored" '
  .files.ignore as $actual
  | ($actual | index("existing/**")) != null
    and all($expected[]; . as $item | ($actual | map(select(. == $item)) | length) == 1)
    and (.files | has("includes") | not)
' "$biome1/biome.json" >/dev/null || fail "Biome 1 files.ignore merge is missing, duplicated, or changed shape"

biome2="$TMP/biome2"
mkdir -p "$biome2"
printf '{"files":{"includes":["src/**"]}}\n' >"$biome2/biome.json"
run_preflight "$biome2"
run_preflight "$biome2"
jq -e --argjson expected "$ignored" '
  .files.includes as $actual
  | ($actual | index("src/**")) != null
    and all($expected[]; ("!" + .) as $item | ($actual | map(select(. == $item)) | length) == 1)
    and (.files | has("ignore") | not)
' "$biome2/biome.json" >/dev/null || fail "Biome 2 negated files.includes merge is missing, duplicated, or wrote obsolete files.ignore"

biome2_unset="$TMP/biome2-unset"
mkdir -p "$biome2_unset"
printf '{"$schema":"https://biomejs.dev/schemas/2.5.10/schema.json","files":{"ignoreUnknown":false}}\n' >"$biome2_unset/biome.json"
run_preflight "$biome2_unset"
jq -e '
  (.files.includes[0] == "**")
    and (.files | has("ignore") | not)
' "$biome2_unset/biome.json" >/dev/null || fail "Biome 2 config without includes received obsolete files.ignore"

sonar="$TMP/sonar"
mkdir -p "$sonar/specs/PROJ-1-sonar/3-4_plan"
printf '{"scripts":{"sonar":"set -a; . ./.env.local; set +a; pnpm dlx @sonar/scan@5.0.0"}}\n' >"$sonar/package.json"
printf '{"sonar_cmd":"pnpm sonar"}\n' >"$sonar/specs/PROJ-1-sonar/3-4_plan/wave-gate-config.json"
# A plan folder makes preflight run the hard worker-context check, so it needs a wave plan.
printf '# Wave 1\n\n**PRDs involved:** PROJ-1-PRD-1\n\n## User Stories in this Wave\n\n| US ID | Scope | Agent Type | Complexity | Can start when |\n|---|---|---|---|---|\n| PROJ-1-PRD-1-US-1 | backend | backend-implementer | sonnet | immediately |\n\n## PROJ-1-PRD-1-US-1: Story\n' \
  >"$sonar/specs/PROJ-1-sonar/3-4_plan/PROJ-1-wave-1-plan.md"
printf 'SONAR_TOKEN=test-token\n' >"$sonar/.env.local"
sonar_output="$(cd "$sonar" && \
  PATH="$FAKE_BIN:/usr/bin:/bin" \
  PREFLIGHT_SKIP_LIVE_PROBE=1 \
  PREFLIGHT_CODEX_INACTIVE=1 \
  PONYTAIL_ENFORCE=0 \
  PONYTAIL_CONFIG="$TMP/ponytail-config.json" \
  PONYTAIL_CLAUDE_REGISTRY="$TMP/no-claude-registry.json" \
  bash "$PREFLIGHT" 1 sonar)"
grep -q 'npm-wrapped scanner engine' <<<"$sonar_output" \
  || fail "npm-wrapped sonar_cmd was not accepted without standalone sonar-scanner"
grep -q '✓ worker context check' <<<"$sonar_output" \
  || fail "preflight did not run the worker context check on a plan folder"

# A lone project preflight can resolve the new compiler from an installed tree.
installed="$TMP/installed/5_executing"
mkdir -p "$installed/scripts" "$sonar/scripts"
cp "$ROOT/codex/skills/5_executing/scripts/env-local.sh" "$sonar/scripts/"
cp "$ROOT/codex/skills/5_executing/scripts/ponytail-check.sh" \
  "$ROOT/codex/skills/5_executing/scripts/compile-context.mjs" \
  "$ROOT/codex/skills/5_executing/scripts/document-parser.mjs" \
  "$ROOT/codex/skills/5_executing/scripts/architecture-parser.mjs" "$installed/scripts/"
cp -R "$ROOT/codex/skills/5_executing/manifests" "$installed/"
node - "$PREFLIGHT" "$sonar/scripts/preflight.sh" "$installed" <<'NODE'
const fs = require("node:fs");
let text = fs.readFileSync(process.argv[2], "utf8");
text = text.replaceAll('$HOME/.claude/skills/5_executing', process.argv[4]).replaceAll('$HOME/.codex/skills/5_executing', process.argv[4]);
fs.writeFileSync(process.argv[3], text);
NODE
fallback_output="$(cd "$sonar" && PATH="$FAKE_BIN:/usr/bin:/bin" \
  PREFLIGHT_SKIP_LIVE_PROBE=1 PREFLIGHT_CODEX_INACTIVE=1 PONYTAIL_ENFORCE=0 \
  PONYTAIL_CONFIG="$TMP/ponytail-config.json" PONYTAIL_CLAUDE_REGISTRY="$TMP/no-claude-registry.json" \
  bash scripts/preflight.sh 1 sonar)"
grep -q '✓ worker context check' <<<"$fallback_output" || fail "installed compiler fallback failed"

# No SubagentStart hook is installed, and settings.json is neither created nor changed.
fresh="$TMP/hook-fresh"
mkdir -p "$fresh"
run_preflight "$fresh"
[ ! -e "$fresh/.claude/settings.json" ] || fail "preflight created .claude/settings.json"
keep="$TMP/hook-keep"
mkdir -p "$keep/.claude"
printf '{"env":{"FOO":"1"}}\n' >"$keep/.claude/settings.json"
run_preflight "$keep"
[ "$(jq -c . "$keep/.claude/settings.json")" = '{"env":{"FOO":"1"}}' ] || fail "preflight changed .claude/settings.json"

cmp -s "$PREFLIGHT" "$ROOT/claude/skills/5_executing/scripts/preflight.sh" \
  || fail "preflight provider copies are not byte-identical"

echo "preflight compatibility tests: PASS"
