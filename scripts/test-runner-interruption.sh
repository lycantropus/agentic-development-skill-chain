#!/usr/bin/env bash
# Isolated fake-provider lanes; never launch models or exhaust host resources.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE="$(mktemp -d)"
runner_pid=""; child_pid=""; daemon_pid=""
cleanup() {
  if [ -n "$runner_pid" ] && kill -0 "$runner_pid" 2>/dev/null; then kill -TERM "$runner_pid" 2>/dev/null || true; wait "$runner_pid" 2>/dev/null || true; fi
  if [ -n "$child_pid" ]; then kill -KILL -- "-$child_pid" 2>/dev/null || true; fi
  if [ -n "$daemon_pid" ]; then kill -KILL "$daemon_pid" 2>/dev/null || true; fi
  rm -rf "$CASE"
}
trap cleanup EXIT
fail() { echo "runner-interruption: $*" >&2; exit 1; }
mkdir -p "$CASE/repo/scripts" "$CASE/repo/bin"
cd "$CASE/repo"
git init -q -b main; git config user.name Test; git config user.email test@example.invalid
for f in chain state.sh compat.sh; do cp "$ROOT/codex/skills/5_executing/scripts/$f" scripts/; done
chmod +x scripts/*
git add -A; git commit -qm base
mkdir -p specs/PROJ-91-interrupted
bash scripts/chain state init 91 interrupted >/dev/null
for t in 'CP1 running' 'CP1 approved' 'P0 running' 'P0 done' 'P5 running'; do bash scripts/chain state transition 91 interrupted $t >/dev/null; done
cat > bin/codex <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = login ] && exit 0
exit 0
STUB
cat > bin/claude <<'STUB'
#!/usr/bin/env bash
# A receipt must already exist at provider entry.
find .git/skillchain-runs -name '*.json' -exec cat {} \; > "$FIXTURE_READY.receipts" 2>/dev/null || true
echo "$$" > "$FIXTURE_READY"
echo "$$" >> "$FIXTURE_READY.launches"
if [ "$FIXTURE_MODE" = kill ]; then kill -KILL "$$"; fi
if [ "$FIXTURE_MODE" = daemon ]; then
  # Cleanup owns this daemon's lifetime, including on slow CI runners.
  (while :; do sleep 1; done) </dev/null >/dev/null 2>&1 &
  echo "$!" > "$FIXTURE_READY.daemon"
  exit 1
fi
while :; do sleep .1; done
STUB
chmod +x bin/*
export PATH="$PWD/bin:$PATH" SKILLCHAIN_POLL_SECONDS=.02 FIXTURE_READY="$CASE/ready" FIXTURE_MODE=kill
mkdir -p specs/PROJ-91-interrupted/3-4_plan
printf '{"resources":{"min_available_mb":1024,"wait_seconds":0}}\n' > specs/PROJ-91-interrupted/3-4_plan/wave-gate-config.json
printf 'MemAvailable: 0 kB\n' > "$CASE/meminfo"
set +e
SKILLCHAIN_MEMINFO_FILE="$CASE/meminfo" "$ROOT/runner/run-phase.sh" P5 91 interrupted --timeout 5 > "$CASE/refused.out" 2>&1
refused_rc=$?
set -e
[ "$refused_rc" -ne 0 ] && [ ! -e "$FIXTURE_READY" ] || fail 'resource refusal launched provider'
journal="$PWD/.git/skillchain-runs/PROJ-91-interrupted"
jq -s -e 'any(.[]; .exit_code == 77 and .status == "failed" and .settled and .phase_outcome == "failed")' "$journal"/*.json >/dev/null || fail 'refusal77 receipt missing'
# Supported legacy plans must keep their configured budget, not silently default.
bash scripts/chain state transition 91 interrupted P5 running >/dev/null
mv specs/PROJ-91-interrupted/3-4_plan specs/PROJ-91-interrupted/6_plan
printf '{"resources":{"min_available_mb":32768,"max_memory_psi_full_avg10":100,"wait_seconds":0}}\n' > specs/PROJ-91-interrupted/6_plan/wave-gate-config.json
printf 'MemAvailable: 4194304 kB\n' > "$CASE/healthy-meminfo"
printf 'full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "$CASE/healthy-psi"
legacy_rc=0
SKILLCHAIN_MEMINFO_FILE="$CASE/healthy-meminfo" SKILLCHAIN_CGROUP_DIR="$CASE/no-cgroup" SKILLCHAIN_PSI_FILE="$CASE/healthy-psi" "$ROOT/runner/run-phase.sh" P5 91 interrupted --timeout 5 > "$CASE/legacy-refused.out" 2>&1 || legacy_rc=$?
[ "$legacy_rc" -ne 0 ] && [ ! -e "$FIXTURE_READY" ] || fail 'legacy resource budget ignored before provider launch'
mv specs/PROJ-91-interrupted/6_plan specs/PROJ-91-interrupted/3-4_plan
bash scripts/chain state transition 91 interrupted P5 running >/dev/null
printf '{"resources":{"min_available_mb":0,"max_memory_psi_full_avg10":100,"wait_seconds":0}}\n' > specs/PROJ-91-interrupted/3-4_plan/wave-gate-config.json
set +e
"$ROOT/runner/run-phase.sh" P5 91 interrupted --timeout 5 > "$CASE/killed.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'killed child accepted'
jq -s -e 'any(.[]; .status == "started")' "$FIXTURE_READY.receipts" >/dev/null || fail 'provider launched before durable started receipt'
journal="$PWD/.git/skillchain-runs/PROJ-91-interrupted"
jq -s -e 'any(.[]; .status == "interrupted" and .exit_code == 137 and .signal == "SIGKILL")' "$journal"/*.json >/dev/null || fail 'SIGKILL outcome missing'
# A provider's intentional long-lived child must not inherit the runner lease.
bash scripts/chain state transition 91 interrupted P5 running >/dev/null
export FIXTURE_MODE=daemon
set +e
"$ROOT/runner/run-phase.sh" P5 91 interrupted --timeout 5 > "$CASE/daemon.out" 2>&1
daemon_rc=$?
set -e
[ "$daemon_rc" -ne 0 ] || fail 'ordinary failed provider accepted'
jq -s -e 'any(.[]; .exit_code == 1 and .status == "failed")' "$journal"/*.json >/dev/null || fail 'ordinary failure mislabeled interrupted'
daemon_pid="$(cat "$FIXTURE_READY.daemon")"
kill -0 "$daemon_pid" || fail 'fixture daemon was killed'
# Kill the supervisor and its isolated lane after sealing stale state: restart must
# reconcile the receipt before skipping the apparently completed phase.
bash scripts/chain state transition 91 interrupted P5 running >/dev/null
rm -f "$FIXTURE_READY" "$FIXTURE_READY.launches"
export FIXTURE_MODE=wait
"$ROOT/runner/run-phase.sh" P5 91 interrupted --timeout 30 > "$CASE/parent.out" 2>&1 &
first_pid=$!
"$ROOT/runner/run-phase.sh" P5 91 interrupted --timeout 30 > "$CASE/simultaneous.out" 2>&1 &
second_pid=$!
for ((i=0;i<300;i++)); do [ -s "$FIXTURE_READY" ] && break; sleep .02; done
[ -s "$FIXTURE_READY" ] || fail 'fixture child not ready'
child_pid="$(cat "$FIXTURE_READY")"
runner_pid="$(ps -p "$child_pid" -o ppid= | tr -d ' ')"
if [ "$runner_pid" = "$first_pid" ]; then rejected_pid="$second_pid"; else [ "$runner_pid" = "$second_pid" ] || fail 'unexpected fixture parent'; rejected_pid="$first_pid"; fi
simultaneous_rc=0; wait "$rejected_pid" 2>/dev/null || simultaneous_rc=$?
[ "$simultaneous_rc" -ne 0 ] || fail 'simultaneous duplicate succeeded'
[ "$(wc -l < "$FIXTURE_READY.launches" | tr -d ' ')" = 1 ] || fail 'simultaneous runners launched competing writers'
child_pid="$(cat "$FIXTURE_READY")"
# A second runner must not mark the live owner's receipt interrupted.
set +e
"$ROOT/runner/run-phase.sh" P5 91 interrupted --timeout 1 > "$CASE/live.out" 2>&1
live_rc=$?
set -e
[ "$live_rc" -ne 0 ] || fail 'duplicate live runner accepted'
grep -q 'live supervisor' "$CASE/live.out" || fail 'live owner was not identified'
bash scripts/chain state transition 91 interrupted P5 done >/dev/null
kill -KILL "$runner_pid"
wait "$runner_pid" 2>/dev/null || true
# Exercise journal protection after the documented manual stale-lease removal
# on stock macOS; this touches only this isolated test repository.
if ! command -v flock >/dev/null 2>&1; then rm -rf "$journal/supervisor.lock.d"; fi
orphan_rc=0
"$ROOT/runner/run-phase.sh" P5 91 interrupted --timeout 1 > "$CASE/orphan.out" 2>&1 || orphan_rc=$?
[ "$orphan_rc" -ne 0 ] || fail 'live orphan allowed competing runner'
grep -q 'still running without its supervisor' "$CASE/orphan.out" || fail 'live orphan identity not checked'
kill -KILL -- "-$child_pid" 2>/dev/null || true
# Let the orphan be reaped by its new parent before reconciling.
for ((i=0;i<100;i++)); do child_state="$(ps -p "$child_pid" -o stat= 2>/dev/null || true)"; [[ -z "$child_state" || "$child_state" = Z* ]] && break; sleep .02; done
runner_pid=""; child_pid=""
set +e
"$ROOT/runner/run-phase.sh" P5 91 interrupted --timeout 1 > "$CASE/restart.out" 2>&1
restart_rc=$?
set -e
[ "$restart_rc" -ne 0 ] || fail 'restart skipped stale seal'
kill -0 "$daemon_pid" || fail 'unrelated fixture daemon was killed by restart'
[ "$(bash scripts/chain state get 91 interrupted .status)" = blocked ] || fail 'interrupted seal was not parked'
jq -s -e 'any(.[]; .status == "interrupted" and .reason == "supervisor ended without completing phase verification" and .signal == null)' "$journal"/*.json >/dev/null || fail 'restart interruption missing or guessed signal'
# An unrelated live process reusing an old PID is not its prior owner.
reuse_dir="$CASE/reused-pid"
reuse_id="$(node "$ROOT/runner/lane-journal.mjs" start "$reuse_dir" old-run "$$" P5 claude writer fixture.out)"
jq '.owner_identity = "old-boot:old-start"' "$reuse_dir/$reuse_id.json" > "$CASE/old-receipt"
mv "$CASE/old-receipt" "$reuse_dir/$reuse_id.json"
launch_rc=0
bash "$ROOT/runner/launch-lane.sh" "$reuse_dir" old-run "$reuse_id" touch "$CASE/should-not-launch" > "$CASE/preattach.out" 2>&1 || launch_rc=$?
[ "$launch_rc" -ne 0 ] && [ ! -e "$CASE/should-not-launch" ] || fail 'provider launched after supervisor identity changed'
reuse_rc=0
node "$ROOT/runner/lane-journal.mjs" reconcile "$reuse_dir" new-run > "$CASE/reused.out" 2>&1 || reuse_rc=$?
[ "$reuse_rc" -eq 2 ] || fail 'PID reuse mistaken for live owner'
echo 'runner-interruption: ok (refusal77, prelaunch receipt, killed child, simultaneous/live owners, orphan refusal, daemon lease isolation, killed supervisor restart, preattach/PID identity)'
