#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
source "$ROOT/codex/skills/5_executing/scripts/compat.sh"
export SKILLCHAIN_MEMINFO_FILE="$TMP/mem" SKILLCHAIN_PSI_FILE="$TMP/psi" SKILLCHAIN_CGROUP_DIR="$TMP/cgroup" SKILLCHAIN_RESOURCE_LOCK_DIR="$TMP/locks"
mkdir "$SKILLCHAIN_CGROUP_DIR"
printf 'MemAvailable: 4194304 kB\n' >"$SKILLCHAIN_MEMINFO_FILE"
printf 'full avg10=0.00\n' >"$SKILLCHAIN_PSI_FILE"
printf '{"resources":{"wait_seconds":0,"max_parallel_commands":2,"test_workers":2}}' >"$TMP/config"
expect77() { local rc=0; "$@" || rc=$?; [[ "$rc" == 77 ]] || { echo "expected77 got $rc" >&2; exit 1; }; }
resource_run "$TMP/config" positive bash -c '[[ "$VITEST_MAX_WORKERS" == 2 ]]'
printf 'MemAvailable: 100 kB\n' >"$SKILLCHAIN_MEMINFO_FILE"
for label in build review; do expect77 resource_run "$TMP/config" "$label" touch "$TMP/$label"; [[ ! -e "$TMP/$label" ]]; done
printf 'MemAvailable: 4194304 kB\n' >"$SKILLCHAIN_MEMINFO_FILE"
printf '104857600\n' >"$SKILLCHAIN_CGROUP_DIR/memory.max"; printf '0\n' >"$SKILLCHAIN_CGROUP_DIR/memory.current"
expect77 resource_run "$TMP/config" cgroup touch "$TMP/cgroup-launched"; [[ ! -e "$TMP/cgroup-launched" ]]
# Self cgroup and limiting ancestors must cap host headroom too.
export SKILLCHAIN_CGROUP_MOUNT="$TMP/nested-cgroups" SKILLCHAIN_SELF_CGROUP_FILE="$TMP/self-cgroup"
mkdir -p "$SKILLCHAIN_CGROUP_MOUNT/slice/child"
printf '0::/slice/child\n' >"$SKILLCHAIN_SELF_CGROUP_FILE"
printf '104857600\n' >"$SKILLCHAIN_CGROUP_MOUNT/slice/memory.max"; printf '0\n' >"$SKILLCHAIN_CGROUP_MOUNT/slice/memory.current"
unset SKILLCHAIN_CGROUP_DIR
expect77 resource_run "$TMP/config" ancestor touch "$TMP/ancestor-launched"; [[ ! -e "$TMP/ancestor-launched" ]]
SKILLCHAIN_CGROUP_MOUNT="$SKILLCHAIN_CGROUP_MOUNT/" expect77 resource_run "$TMP/config" trailing-ancestor touch "$TMP/trailing-launched"
[[ ! -e "$TMP/trailing-launched" ]]
export SKILLCHAIN_CGROUP_DIR="$TMP/cgroup"
unset SKILLCHAIN_CGROUP_MOUNT SKILLCHAIN_SELF_CGROUP_FILE
printf '{"resources":{"wait_seconds":30,"max_parallel_commands":2}}'  >"$TMP/config"
export SKILLCHAIN_RESOURCE_HEARTBEAT_FILE="$TMP/heartbeat"
printf '0\n' >"$SKILLCHAIN_RESOURCE_HEARTBEAT_FILE"
(
  deadline=$((SECONDS + 20))
  while [[ $(cat "$SKILLCHAIN_RESOURCE_HEARTBEAT_FILE") -eq 0 && "$SECONDS" -lt "$deadline" ]]; do sleep 0.05; done
  [[ $(cat "$SKILLCHAIN_RESOURCE_HEARTBEAT_FILE") -gt 0 && ! -e "$TMP/recovered" ]] || touch "$TMP/heartbeat-failed"
  printf 'max\n' >"$SKILLCHAIN_CGROUP_DIR/memory.max"
) & recovery=$!
# Slow policy reads must not race a fixed-delay telemetry recovery on loaded hosts.
jq() { sleep 0.6; command jq "$@"; }
recovery_rc=0; resource_run "$TMP/config" recovery touch "$TMP/recovered" || recovery_rc=$?
unset -f jq
wait "$recovery"
[[ "$recovery_rc" == 0 && -e "$TMP/recovered" && ! -e "$TMP/heartbeat-failed" ]] || {
  echo "FAIL: recovery handshake rc=$recovery_rc heartbeat=$(cat "$SKILLCHAIN_RESOURCE_HEARTBEAT_FILE")" >&2; exit 1;
}
unset SKILLCHAIN_RESOURCE_HEARTBEAT_FILE
# Two commands overlap, a third cannot launch until a slot is released.
for n in 1 2; do resource_run "$TMP/config" "slot$n" bash -c 'touch "$1"; while [[ ! -e "$2" ]]; do sleep 0.05; done' _ "$TMP/started$n" "$TMP/release" & done
pids=$(jobs -p)
for ((i=0;i<100;i++)); do [[ ! -e "$TMP/started1" || ! -e "$TMP/started2" ]] || break; sleep 0.05; done
[[ -e "$TMP/started1" && -e "$TMP/started2" ]]
printf '{"resources":{"wait_seconds":0}}' >"$TMP/nowait"
expect77 resource_run "$TMP/nowait" overflow touch "$TMP/overflow"; [[ ! -e "$TMP/overflow" ]]
SKILLCHAIN_RESOURCE_ACTIVE=1 SKILLCHAIN_RESOURCE_LOCK_OWNER="$$" SKILLCHAIN_RESOURCE_LOCK_FILE="$SKILLCHAIN_RESOURCE_LOCK_DIR/slot-1" SKILLCHAIN_RESOURCE_LEASE_FILE="$TMP/forged-lease" expect77 resource_run "$TMP/nowait" forged touch "$TMP/forged"
[[ ! -e "$TMP/forged" ]]
touch "$TMP/release"; for pid in $pids; do wait "$pid"; done
resource_run "$TMP/config" released true
resource_run "$TMP/config" no-inherited-lock bash -c '[[ ! -e /dev/fd/19 ]]'
# Portable cleanup must not delete a new owner's directory after releasing its own lock.
(
  export SKILLCHAIN_RESOURCE_LOCK_DIR="$TMP/one-shot-locks"
  command() { if [[ "${1:-}" == -v && "${2:-}" == flock ]]; then return 1; else builtin command "$@"; fi; }
  rm() {
    builtin command rm "$@"
    if [[ "${*: -1}" == "$SKILLCHAIN_RESOURCE_LOCK_DIR/slot-1.d" ]]; then
      local count=0
      [[ ! -f "$TMP/unlock-count" ]] || count=$(cat "$TMP/unlock-count")
      count=$((count + 1)); printf '%s' "$count" >"$TMP/unlock-count"
      if [[ "$count" == 1 ]]; then mkdir "$SKILLCHAIN_RESOURCE_LOCK_DIR/slot-1.d"; touch "$SKILLCHAIN_RESOURCE_LOCK_DIR/slot-1.d/contender"; fi
    fi
  }
  resource_run "$TMP/config" one-shot-cleanup true
  [[ $(cat "$TMP/unlock-count") == 1 && -f "$SKILLCHAIN_RESOURCE_LOCK_DIR/slot-1.d/contender" ]] || {
    echo "FAIL: portable cleanup released a slot twice and removed its new owner" >&2; exit 1;
  }
)
# A detached descendant must not retain the guard's capacity lock after its command exits.
python3 - "$ROOT" "$TMP" <<'PY'
import os, pathlib, signal, subprocess, sys, time
root,tmp=map(pathlib.Path,sys.argv[1:])
config=tmp/'daemon-config';config.write_text('{"resources":{"wait_seconds":0,"max_parallel_commands":1}}')
pidfile=tmp/'daemon-pid'
receiptfile=tmp/'daemon-receipt'
helper=str(root/'codex/skills/5_executing/scripts/compat.sh')
zombie=os.fork()
if zombie==0: os._exit(0)
try:
 for _ in range(100):
  state=subprocess.run(['ps','-p',str(zombie),'-o','stat='],capture_output=True,text=True).stdout.strip()
  if state.startswith('Z'): break
  time.sleep(.02)
 assert state.startswith('Z'), 'zombie owner fixture did not become ready'
 result=subprocess.run(['bash','-c','source "$1"; _resource_owner_identity "$2"','_',helper,str(zombie)])
 assert result.returncode==1, 'zombie guard was accepted as a live lease owner'
finally: os.waitpid(zombie,0)
try:
 subprocess.run(['bash','-c','source "$1"; resource_run "$2" daemon bash -c \'printf "%s" "$SKILLCHAIN_RESOURCE_LEASE_FILE" > "$2"; sleep 30 & echo $! > "$1"\' _ "$3" "$4"','_',helper,str(config),str(pidfile),str(receiptfile)],check=True,stdout=subprocess.DEVNULL)
 pid=int(pidfile.read_text());os.kill(pid,0)
 assert not pathlib.Path(receiptfile.read_text()).exists(), 'guard receipt survived command completion'
 result=subprocess.run(['bash','-c','source "$1"; resource_run "$2" next-command true','_',helper,str(config)])
 assert result.returncode==0, 'daemon retained the guard capacity lock after command exit'
finally:
 if pidfile.exists():
  try:os.kill(int(pidfile.read_text()),signal.SIGKILL)
  except ProcessLookupError:pass
PY

ln -s "$SKILLCHAIN_RESOURCE_LOCK_DIR" "$TMP/unsafe-locks"
expect77 env SKILLCHAIN_RESOURCE_LOCK_DIR="$TMP/unsafe-locks" bash -c 'source "$1"; resource_run "$2" unsafe touch "$3"' _ "$ROOT/codex/skills/5_executing/scripts/compat.sh" "$TMP/config" "$TMP/unsafe-launched"
[[ ! -e "$TMP/unsafe-launched" ]]
resource_run "$TMP/config" nested resource_run "$TMP/config" nested-child true
# Stock macOS has no flock: nested commands share the live mkdir owner lease.
(
  command() { if [[ "${1:-}" == -v && "${2:-}" == flock ]]; then return 1; else builtin command "$@"; fi; }
  resource_run "$TMP/config" portable resource_run "$TMP/config" portable-child true
)
printf prompt | resource_run "$TMP/config" stdin bash -c '[[ $(cat) == prompt ]]'
for bad in '{"resources":false}' '{"resources":null}' '{"resources":{"wait_seconds":null}}' '{"resources":{"unknown":1}}'; do
  printf '%s' "$bad" >"$TMP/bad-policy"
  rc=0; resource_run "$TMP/bad-policy" invalid touch "$TMP/invalid-policy" || rc=$?
  [[ "$rc" == 64 && ! -e "$TMP/invalid-policy" ]]
done
printf '{"resources":{"test_workers":0}}' >"$TMP/bad"
rc=0; resource_run "$TMP/bad" invalid touch "$TMP/invalid" || rc=$?; [[ "$rc" == 64 && ! -e "$TMP/invalid" ]]
# Cancellation must terminate a resistant owned process tree and leave siblings alone.
python3 - "$ROOT" "$TMP" <<'PY'
import json, os, pathlib, signal, subprocess, sys, time
root, tmp = map(pathlib.Path, sys.argv[1:])
fixture = tmp / 'resistant.py'
fixture.write_text('''import json, os, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pid=os.fork()
if pid:
 with open(sys.argv[1], 'w') as f: json.dump([int(os.environ['SKILLCHAIN_RESOURCE_LOCK_OWNER']),os.getpid(),pid],f)
while True: time.sleep(0.1)
''')
record = tmp / 'resistant-pids'
config = tmp / 'cancel-config'
config.write_text('{"resources":{"wait_seconds":0,"max_parallel_commands":1}}')
sibling = subprocess.Popen(['sleep', '30'], start_new_session=True)
outer = subprocess.Popen(['bash','-c','source "$1"; resource_run "$2" resistant python3 "$3" "$4"', '_', str(root/'codex/skills/5_executing/scripts/compat.sh'),str(config),str(fixture),str(record)], start_new_session=True)
pids=[]
def running(pid):
 result=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
 return result.returncode==0 and not result.stdout.strip().startswith('Z')
try:
 for _ in range(100):
  if record.exists():
   try: pids=json.loads(record.read_text()); break
   except ValueError: pass
  time.sleep(.05)
 assert pids, 'resistant child did not start'
 os.kill(pids[0],signal.SIGTERM)
 try: rc=outer.wait(timeout=5)
 except subprocess.TimeoutExpired: raise AssertionError('resource wrapper hung after cancellation')
 assert rc==143, f'unexpected cancellation exit {rc}'
 for _ in range(50):
  if not any(running(p) for p in pids): break
  time.sleep(.05)
 assert not any(running(p) for p in pids), f'owned process survived: {pids}'
 assert sibling.poll() is None, 'unrelated sibling was terminated'
 subprocess.run(['bash','-c','source "$1"; resource_run "$2" released true','_',str(root/'codex/skills/5_executing/scripts/compat.sh'),str(config)],check=True,timeout=5)
finally:
 for pid in [outer.pid,sibling.pid]:
  try: os.killpg(pid,signal.SIGKILL)
  except ProcessLookupError: pass
 for pid in pids:
  try: os.kill(pid,signal.SIGKILL)
  except ProcessLookupError: pass
 outer.wait(); sibling.wait()
PY

rm "$SKILLCHAIN_MEMINFO_FILE"
export SKILLCHAIN_VMSTAT_FILE="$TMP/missing-vmstat"
resource_run "$TMP/config" missing touch "$TMP/missing"; [[ -e "$TMP/missing" ]]
echo 'resource_run tests: PASS'
