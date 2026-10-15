#!/usr/bin/env bash
# chain check ponytail: parity ok / different versions accepted / absent plugin (enforce on and off) / mode off /
# scoped subagent matcher / single-provider run, with stubbed plugin registries and a stubbed codex binary.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "test-ponytail-check: $*" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/repo"; printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/codex"; chmod +x "$TMP/bin/codex"
PT="$TMP/pt"
fixture() { # healthy parity on both providers, mode full
  rm -rf "$PT"; mkdir -p "$PT/cache/4.8.4/.codex-plugin" "$PT/cfg"
  echo '{"version":2,"plugins":{"ponytail@ponytail":[{"version":"4.8.4"}]}}' >"$PT/claude.json"
  echo '{"version":"4.8.4"}' >"$PT/cache/4.8.4/.codex-plugin/plugin.json"
  printf '[plugins."ponytail@ponytail"]\nenabled = true\n' >"$PT/codex.toml"
  echo '{"defaultMode":"full"}' >"$PT/cfg/config.json"
}
cd "$TMP/repo"

for provider in claude codex; do
  CHAIN="$ROOT/$provider/skills/5_executing/scripts/chain"
  ptc() { PATH="$TMP/bin:$PATH" PONYTAIL_CLAUDE_REGISTRY="$PT/claude.json" PONYTAIL_CODEX_CACHE="$PT/cache" \
          PONYTAIL_CODEX_CONFIG="$PT/codex.toml" PONYTAIL_CONFIG="$PT/cfg/config.json" bash "$CHAIN" check ponytail "$@"; }
  ok() { local rc=0; ptc "$@" >"$TMP/out" 2>"$TMP/err" || rc=$?; [ "$rc" = 0 ] || fail "$provider: expected exit 0, got $rc ($*): $(cat "$TMP/err")"; }
  no() { local rc=0; ptc "$@" >"$TMP/out" 2>"$TMP/err" || rc=$?; [ "$rc" = 1 ] || fail "$provider: expected exit 1, got $rc ($*)"; }

  fixture; ok; grep -q 'ponytail parity ok — claude 4.8.4, codex 4.8.4, mode full' "$TMP/out" || fail "$provider: parity line wrong: $(cat "$TMP/out")"
  ptc --json | jq -e '.parity_ok == true and .enforced == true and .claude.version == "4.8.4" and .codex.version == "4.8.4" and .codex.active == true' >/dev/null || fail "$provider: --json shape wrong"

  fixture; mkdir -p "$PT/cache/4.9.0/.codex-plugin"; echo '{"version":"4.9.0"}' >"$PT/cache/4.9.0/.codex-plugin/plugin.json"
  ok --json
  jq -e '.parity_ok == true and .enforced == true and .claude.version == "4.8.4" and .codex.version == "4.9.0"' "$TMP/out" >/dev/null || fail "$provider: different versions must pass and remain visible"

  fixture; echo '{"version":2,"plugins":{}}' >"$PT/claude.json"
  no; grep -q 'claude: ponytail not installed' "$TMP/err" || fail "$provider: absent claude plugin not reported"
  PONYTAIL_ENFORCE=0 ok; PONYTAIL_ENFORCE=0 ptc --json 2>/dev/null | jq -e '.enforced == false and .parity_ok == false' >/dev/null || fail "$provider: enforce-off must record enforced:false"
  grep -q 'continuing WITHOUT the minimalism ladder' "$TMP/err" || fail "$provider: the enforce-off escape hatch must be loud"

  fixture; rm -f "$PT/codex.toml"; no; grep -q 'codex: ponytail not installed' "$TMP/err" || fail "$provider: absent codex plugin not reported"
  ok --codex-inactive; grep -q 'codex inactive' "$TMP/out" || fail "$provider: single-provider run not marked degraded"

  fixture; echo '{"defaultMode":"off"}' >"$PT/cfg/config.json"; no; grep -q "mode 'off' != required 'full'" "$TMP/err" || fail "$provider: mode off passed"
  fixture; PONYTAIL_DEFAULT_MODE=lite no; fixture; PONYTAIL_DEFAULT_MODE=full ok

  fixture; PONYTAIL_SUBAGENT_MATCHER='implementer|micro-fixer' no; grep -q 'PONYTAIL_SUBAGENT_MATCHER is set' "$TMP/err" || fail "$provider: scoped matcher not reported"
  fixture; mkdir -p .claude; echo '{"env":{"PONYTAIL_SUBAGENT_MATCHER":"implementer"}}' >.claude/settings.json; no
  rm -rf .claude

  fixture; rm "$PT/cfg/config.json"; ok; [ "$(jq -r .defaultMode "$PT/cfg/config.json")" = full ] || fail "$provider: absent config must be persisted as full"
  grep -q "persisted default mode 'full'" "$TMP/err" || fail "$provider: the one mutation must be logged"

  rc=0; ptc --bogus >/dev/null 2>&1 || rc=$?; [ "$rc" = 64 ] || fail "$provider: unknown option should exit 64, got $rc"
done
echo "test-ponytail-check: ok"
