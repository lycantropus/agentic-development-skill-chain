#!/usr/bin/env bash
# Proves the helpers run on a macOS-like userland without a Mac: PATH holds only a shim dir that
# lacks timeout/flock/setsid/realpath and whose date/ps reject or mangle what BSD rejects or mangles
# (date -I/-d fail, %N/%3N print a literal "N"/"3N", ps has no etimes). Then the fast suites run on it.
set -euo pipefail
[ "$(uname)" = Linux ] || { echo "portability (shim userland): skipped, not Linux (the real macOS CI job covers it)"; exit 0; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
COMPAT="$ROOT/claude/skills/5_executing/scripts/compat.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "portability test: $*" >&2; exit 1; }

SHIM="$TMP/bin"; mkdir "$SHIM"
REAL_DATE=$(command -v date); REAL_PS=$(command -v ps)
for f in /usr/bin/* /bin/*; do
  b=${f##*/}
  case "$b" in timeout|gtimeout|flock|setsid|realpath|date|ps|sha1sum|sha256sum|md5sum) continue ;; esac
  [ -e "$SHIM/$b" ] || ln -s "$f" "$SHIM/$b"
done
for tool in node jq git perl; do [ -e "$SHIM/$tool" ] || ln -s "$(command -v "$tool")" "$SHIM/$tool"; done
cat >"$SHIM/date" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in -I*|-d|--date*|--iso*) echo "date: illegal option -- \${a#-}" >&2; exit 1 ;; esac; done
args=(); for a in "\$@"; do a=\${a//%3N/3N}; a=\${a//%N/N}; args+=("\$a"); done
exec "$REAL_DATE" "\${args[@]}"
EOF
cat >"$SHIM/ps" <<EOF
#!/usr/bin/env bash
case "\$*" in *etimes*) echo "ps: etimes: keyword not found" >&2; exit 1 ;; esac
exec "$REAL_PS" "\$@"
EOF
chmod +x "$SHIM/date" "$SHIM/ps"

# The shim must really behave like BSD, otherwise the run proves nothing.
export PATH="$SHIM"
! command -v timeout >/dev/null && ! command -v flock >/dev/null && ! command -v setsid >/dev/null && ! command -v realpath >/dev/null || fail "shim still provides a GNU tool"
! date -Iseconds >/dev/null 2>&1 || fail "shim date accepts -I"
[ "$(date +%s%3N | tail -c 3)" = "3N" ] || fail "shim date does not print a literal 3N"
! ps -p $$ -o etimes= >/dev/null 2>&1 || fail "shim ps accepts etimes"

# --- compat.sh fallbacks ---
source "$COMPAT"
[ "${TIMEOUT_BIN[0]}" = perl ] || fail "expected the perl timeout shim"
[ "${SETSID_BIN[0]}" = perl ] || fail "expected the perl setsid shim"
[[ "$(now_ms)" =~ ^[0-9]{13}$ ]] || fail "now_ms: $(now_ms)"
[[ "$(now_iso)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$ ]] || fail "now_iso: $(now_iso)"
[[ "$(proc_age_seconds $$)" =~ ^[0-9]+$ ]] || fail "proc_age_seconds: '$(proc_age_seconds $$)'"
[ "$(abspath "$TMP/a/../b/c")" = "$(cd -P "$TMP" && pwd)/b/c" ] || fail "abspath: $(abspath "$TMP/a/../b/c")"
[ "$(relpath "$TMP/x/y" "$TMP/z")" = "../../z" ] || fail "relpath: $(relpath "$TMP/x/y" "$TMP/z")"
rc=0; "${TIMEOUT_BIN[@]}" 1 sleep 5 || rc=$?; [ "$rc" -eq 124 ] || fail "timeout rc $rc, expected 124"
rc=0; "${TIMEOUT_BIN[@]}" --foreground 5 bash -c 'exit 7' || rc=$?; [ "$rc" -eq 7 ] || fail "timeout lost the exit code ($rc)"
"${TIMEOUT_BIN[@]}" --kill-after=5s 30 sleep 31 & tpid=$!
sleep 0.3; kill -- "-$tpid"; wait "$tpid" 2>/dev/null || true
! pgrep -x -f 'sleep 31' >/dev/null || fail "group kill left the timed command running"
"${SETSID_BIN[@]}" bash -c 'sleep 0.3' & spid=$!
[ "$(ps -o pid= -p "$spid" | tr -d ' ')" = "$spid" ] || fail "setsid shim changed the pid"
wait "$spid"
printf 'source "%s"\nlock_acquire 9 exclusive "$1" "$2"\n' "$COMPAT" >"$TMP/try.sh"
printf 'source "%s"\nlock_acquire 9 exclusive 0 "$1" || exit 9\nbash "%s" 0 "$1"; echo "contender rc=$?"\n[ -d "$1.d" ] && echo held\n' "$COMPAT" "$TMP/try.sh" >"$TMP/hold.sh"
out=$(bash "$TMP/hold.sh" "$TMP/l")
[[ "$out" == *"contender rc=1"* && "$out" == *held* ]] || fail "mkdir lock does not exclude: $out"
[ ! -d "$TMP/l.d" ] || fail "mkdir lock not released on exit"
mkdir "$TMP/l.d"; echo 99999999 >"$TMP/l.d/pid"; bash "$TMP/try.sh" 0 "$TMP/l" || fail "stale mkdir lock was not reaped"

# --- fast suites on the shim userland ---
for suite in test-wave-gate test-shared-lock test-worktree test-wave-plan-validator test-chain-dispatcher; do
  ( bash "$ROOT/scripts/$suite.sh" >"$TMP/$suite.log" 2>&1 ) & pids+=("$!"); names+=("$suite")
done
bad=0
for i in "${!pids[@]}"; do
  wait "${pids[$i]}" || { echo "--- ${names[$i]} (shim userland) ---" >&2; tail -20 "$TMP/${names[$i]}.log" >&2; bad=1; }
done
[ "$bad" -eq 0 ] || fail "suite(s) failed on the macOS-like userland"
echo "portability (macOS-like userland): PASS"
