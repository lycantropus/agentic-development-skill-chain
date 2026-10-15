# compat.sh — portable primitives for GNU/Linux and macOS (BSD) userlands, sourced (not run).
# The only place in the helpers that may name GNU-only tools (timeout, flock, setsid,
# realpath -m, date %N/-I, ps etimes); scripts/check-portability.sh enforces it.
# Every function prefers the GNU tool when it works, so Linux behaviour is unchanged.
# Needs bash >= 4.4 (macOS: `brew install bash`) and node (already a framework prerequisite).

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "bash >= 4.4 required (found $BASH_VERSION). macOS: brew install bash, and put it before /bin on PATH." >&2
  exit 1
fi

# Epoch milliseconds. BSD date prints a literal "3N", so fall back to node.
now_ms() {
  local ms
  ms="$(date +%s%3N 2>/dev/null)"
  case "$ms" in ''|*[!0-9]*) ms="$(node -p 'Date.now()')" ;; esac
  echo "$ms"
}

# ISO-8601 with a +HH:MM offset, identical to GNU `date -Iseconds` (BSD %z has no colon).
now_iso() { date +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([0-9]{2})$/:\1/'; }

# realpath -m (non-existing paths allowed) and realpath -m --relative-to.
if realpath -m / >/dev/null 2>&1; then
  abspath() { realpath -m -- "$1"; }
  relpath() { realpath -m --relative-to="$1" -- "$2"; }
else
  abspath() { # resolve the deepest existing ancestor physically (cd -P), then normalise the rest
    local p="$1" rest=""
    case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
    while [ ! -d "$p" ]; do rest="/${p##*/}$rest"; p="${p%/*}"; [ -n "$p" ] || p=/; done
    node -p 'require("path").resolve(process.argv[1])' "$(cd -P "$p" && pwd)$rest"
  }
  relpath() { node -p 'require("path").relative(process.argv[1], process.argv[2])' "$(abspath "$1")" "$(abspath "$2")"; }
fi

# timeout: GNU timeout, then coreutils' gtimeout, else a perl shim with GNU semantics
# (--foreground, --kill-after=Ns, exit 124 on timeout). Use as: "${TIMEOUT_BIN[@]}" [opts] <secs> cmd…
# Without --foreground the command runs in the shim's own process group (shim = group leader),
# so `kill -- -$pid` of a backgrounded call reaches the whole tree, as with GNU timeout.
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=(timeout)
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=(gtimeout)
else
  # ponytail: seconds only (no m/h suffix, no fractions); extend if a caller needs them.
  TIMEOUT_BIN=(perl -e '
    use POSIX qw(:sys_wait_h); no warnings "exec";
    my ($fg, $ka) = (0, 0);
    while (@ARGV && $ARGV[0] =~ /^--/) {
      my $o = shift @ARGV;
      if ($o eq "--foreground") { $fg = 1 } elsif ($o =~ /^--kill-after=(\d+)s?$/) { $ka = $1 }
    }
    my $secs = shift @ARGV; $secs =~ s/s$//;
    setpgrp(0, 0) unless $fg;
    my $pid = fork(); defined $pid or die "timeout: fork: $!\n";
    if (!$pid) { exec @ARGV or do { print STDERR "timeout: $ARGV[0]: $!\n"; POSIX::_exit($!{ENOENT} ? 127 : 126) } }
    my ($timed_out, $target) = (0, $fg ? $pid : -$pid);
    $SIG{ALRM} = sub {
      if (!$timed_out) { $timed_out = 1; local $SIG{TERM} = "IGNORE"; kill "TERM", $target; alarm($ka) if $ka }
      else { local $SIG{TERM} = "IGNORE"; kill "KILL", $target }
    };
    $SIG{$_} = sub { local $SIG{TERM} = "IGNORE"; kill $_[0], $target } for qw(TERM INT HUP);
    alarm $secs;
    my $r; do { $r = waitpid($pid, 0) } while ($r == -1 && $!{EINTR});
    my $st = $?;
    exit 124 if $timed_out;
    exit(WIFEXITED($st) ? WEXITSTATUS($st) : 128 + WTERMSIG($st));
  ' --)
fi

# setsid: new session so `kill -- -$pid` reaches the whole tree. perl's exec keeps the pid.
# Use as: "${SETSID_BIN[@]}" cmd… &   (empty = plain background, SETSID_GROUP=false: kill the pid only)
SETSID_GROUP=true
if command -v setsid >/dev/null 2>&1; then SETSID_BIN=(setsid)
elif command -v perl >/dev/null 2>&1; then SETSID_BIN=(perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "setsid: $ARGV[0]: $!\n"' --)
else SETSID_BIN=(); SETSID_GROUP=false
fi

# Seconds since a process started: GNU etimes, else parse etime ([[dd-]hh:]mm:ss). Empty if unknown.
proc_age_seconds() {
  local v
  v="$(ps -p "$1" -o etimes= 2>/dev/null | tr -d ' ')"
  case "$v" in ''|*[!0-9]*)
    v="$(ps -p "$1" -o etime= 2>/dev/null | tr -d ' ' | awk -F'[-:]' '
      NF == 2 { print $1 * 60 + $2 }
      NF == 3 { print ($1 * 60 + $2) * 60 + $3 }
      NF == 4 { print (($1 * 24 + $2) * 60 + $3) * 60 + $4 }')" ;;
  esac
  echo "$v"
}

# lock_acquire <fd> <shared|exclusive> <timeout-seconds|0 = try once> <file>
# Held until the process exits. 0 acquired · 1 timed out · 2 cannot open the lock.
# With flock: the kernel lock on <fd>. Without it (stock macOS): a mkdir lock "<file>.d" that is
# always exclusive (a shared request degrades to exclusive: safe, slower), stale when the owner pid is dead.
lock_acquire() {
  local fd="$1" mode="$2" secs="$3" file="$4" dir deadline owner
  if command -v flock >/dev/null 2>&1; then
    eval "exec $fd>>\"\$file\"" 2>/dev/null || return 2
    if [ "$secs" -eq 0 ]; then flock "--$mode" -n "$fd"; else flock "--$mode" -w "$secs" "$fd"; fi
    return
  fi
  # ponytail: two waiters can both reap one stale lock and both acquire; flock (brew install flock) has no such race.
  : >>"$file" || return 2 # keep the lock file itself present, as flock would
  dir="$file.d"; deadline=$((SECONDS + secs))
  while ! mkdir "$dir" 2>/dev/null; do
    owner="$(cat "$dir/pid" 2>/dev/null)"
    if [ "${COMPAT_LOCK_NO_REAP:-0}" != 1 ] && [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$dir"; continue; fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.2
  done
  echo "$BASHPID" >"$dir/pid"
  _COMPAT_LOCK_DIRS+=("$dir")
  if [ -z "$_COMPAT_TRAPPED" ]; then # chain onto an existing EXIT trap (trap -p prints it already single-quote-escaped)
    owner="$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")"
    eval "trap -- '${owner:+$owner; }_compat_unlock' EXIT"
    _COMPAT_TRAPPED=1
  fi
}
_COMPAT_LOCK_DIRS=() _COMPAT_TRAPPED=
_compat_unlock() { local d; for d in ${_COMPAT_LOCK_DIRS[@]+"${_COMPAT_LOCK_DIRS[@]}"}; do rm -rf "$d"; done; }

# macOS headroom in MiB: (free + inactive + speculative) pages x page size from vm_stat. No PSI counterpart on macOS.
vm_stat_available_mb() {
  local out
  if [[ -n "${SKILLCHAIN_VMSTAT_FILE:-}" ]]; then out=$(cat "$SKILLCHAIN_VMSTAT_FILE") || return 1; else out=$(vm_stat 2>/dev/null) || return 1; fi
  awk '/page size of/ {for(i=1;i<=NF;i++) if($i=="of") ps=$(i+1)} /^Pages (free|inactive|speculative):/ {gsub(/\./,"",$NF); n+=$NF} END {if (ps>0 && n>0) print int(n*ps/1048576); else exit 1}' <<<"$out"
}

# Memory headroom in MiB: MemAvailable, capped by a cgroup v2 limit (Linux), or vm_stat (macOS). The *_FILE/_DIR overrides let tests mock telemetry.
available_mem_mb() {
  local kb max cur dir root group avail
  if [[ -n "${SKILLCHAIN_VMSTAT_FILE:-}" || ! -r "${SKILLCHAIN_MEMINFO_FILE:-/proc/meminfo}" ]]; then vm_stat_available_mb; return; fi
  kb=$(awk '/^MemAvailable:/{print $2}' "${SKILLCHAIN_MEMINFO_FILE:-/proc/meminfo}" 2>/dev/null) || return 1
  [[ "$kb" =~ ^[0-9]+$ ]] || return 1
  avail=$((kb / 1024))
  root=$(abspath "${SKILLCHAIN_CGROUP_DIR:-${SKILLCHAIN_CGROUP_MOUNT:-/sys/fs/cgroup}}") || return 1; dir="$root"
  if [[ -z "${SKILLCHAIN_CGROUP_DIR:-}" ]]; then
    group=$(awk -F: '$1=="0" && $2=="" {print $3; exit}' "${SKILLCHAIN_SELF_CGROUP_FILE:-/proc/self/cgroup}" 2>/dev/null) || group=""
    case "$group" in /*) [[ "$group" == *'/../'* || "$group" == */.. ]] || dir=$(abspath "${root%/}${group%/}") ;; esac
  fi
  while :; do
    max=$(cat "$dir/memory.max" 2>/dev/null || true); cur=$(cat "$dir/memory.current" 2>/dev/null || true)
    if [[ "$max" =~ ^[0-9]+$ && "$cur" =~ ^[0-9]+$ && $(( (max - cur) / 1048576 )) -lt "$avail" ]]; then avail=$(( (max - cur) / 1048576 )); fi
    [[ "$dir" != "$root" && "$dir" != / ]] || break
    dir=${dir%/*}; dir=${dir:-/}
    [[ "$dir" == "$root" || "$dir" == "${root%/}/"* ]] || break
  done
  echo "$avail"
}

# Pressure-stall "full avg10" of the memory resource (whole percent); empty without PSI.
memory_psi_full() {
  awk '/^full/{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){v=substr($i,7); print int(v)}}' "${SKILLCHAIN_PSI_FILE:-/proc/pressure/memory}" 2>/dev/null || true
}

# A nested command may share only a live inherited kernel or portable owner lease.
resource_lease_held() {
  [[ "${SKILLCHAIN_RESOURCE_ACTIVE:-}" == 1 && -n "${SKILLCHAIN_RESOURCE_LOCK_FILE:-}" ]] || return 1
  [[ /dev/fd/19 -ef "$SKILLCHAIN_RESOURCE_LOCK_FILE" ]] ||
    { [[ "$(cat "$SKILLCHAIN_RESOURCE_LOCK_FILE.d/pid" 2>/dev/null)" == "${SKILLCHAIN_RESOURCE_LOCK_OWNER:-none}" ]] && kill -0 "${SKILLCHAIN_RESOURCE_LOCK_OWNER:-}" 2>/dev/null; }
}

# Called only by resource_run's signal traps; child is its owned process-group leader.
_resource_cancel() {
  local code="$1" until
  trap '' TERM INT HUP
  if [[ -n "$child" ]]; then
    kill -TERM -- "-$child" 2>/dev/null || true
    until=$((SECONDS + 2))
    while kill -0 -- "-$child" 2>/dev/null && [[ "$SECONDS" -lt "$until" ]]; do sleep 0.1; done
    kill -KILL -- "-$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  exit "$code"
}

# resource_run CONFIG LABEL command args… — one host slot for a heavy process tree.
# Missing config uses defaults; missing telemetry warns (never invents an OOM diagnosis).
# Nested calls share the outer slot. Limits cover participating commands, not unrelated processes.
resource_run() (
  local cfg="$1" label="$2" policy min psi_limit wait workers cap deadline avail psi problem slot rc child=""
  shift 2
  policy='{}'
  if [[ -f "$cfg" ]]; then policy=$(cat "$cfg") || return 64; fi
  if ! jq -e '
    def whole: type=="number" and floor==. and .>=0;
    (if has("resources") then .resources else {} end) as $r | ($r|type=="object") and
    ($r | keys - ["min_available_mb","max_memory_psi_full_avg10","wait_seconds","test_workers","max_parallel_commands"] | length==0) and
    all(["min_available_mb","max_memory_psi_full_avg10","wait_seconds"][]; . as $k | (($r|has($k)|not) or ($r[$k]|whole))) and
    all(["test_workers","max_parallel_commands"][]; . as $k | (($r|has($k)|not) or ($r[$k]|whole and .>0)))
  ' <<<"$policy" >/dev/null 2>&1; then echo "invalid resources policy: $cfg" >&2; return 64; fi
  read -r min psi_limit wait workers cap < <(jq -r '[.resources.min_available_mb // 1024,.resources.max_memory_psi_full_avg10 // 20,.resources.wait_seconds // 300,.resources.test_workers // 0,.resources.max_parallel_commands // 2]|@tsv' <<<"$policy")
  deadline=$((SECONDS + wait))
  local lockdir="${SKILLCHAIN_RESOURCE_LOCK_DIR:-${TMPDIR:-/tmp}/skillchain-resources-${UID}}"
  (umask 077; mkdir -p "$lockdir") || return 77
  node -e 'const fs=require("fs"),s=fs.lstatSync(process.argv[1]);if(!s.isDirectory()||s.isSymbolicLink()||s.uid!==process.getuid()||(s.mode&0o077))process.exit(1)' "$lockdir" || { echo "unsafe resource lock directory: $lockdir" >&2; return 77; }
  # Kernel locks release on exit; the portable mkdir fallback deliberately never reaps a racing owner.
  local COMPAT_LOCK_NO_REAP=1
  _COMPAT_LOCK_DIRS=(); _COMPAT_TRAPPED=""
  trap '_compat_unlock' EXIT
  trap '_resource_cancel 143' TERM
  trap '_resource_cancel 130' INT
  trap '_resource_cancel 129' HUP
  while :; do
    problem=""
    if avail=$(available_mem_mb); then
      [[ "$avail" -ge "$min" ]] || problem="MemAvailable ${avail} MiB < ${min} MiB"
      psi=$(memory_psi_full); psi=${psi:-0}
      [[ "$psi" -le "$psi_limit" ]] || problem="memory PSI full avg10=${psi} > ${psi_limit}"
    else
      echo "resource telemetry unavailable before ${label}; continuing with command capacity guard" >&2
    fi
    if [[ -z "$problem" ]]; then
      [[ "${SKILLCHAIN_RESOURCE_CHECK_ONLY:-}" != 1 ]] || return 0
      if resource_lease_held; then "$@"; return; fi
      for ((slot=1; slot<=cap; slot++)); do
        if lock_acquire 19 exclusive 0 "$lockdir/slot-$slot"; then
          export SKILLCHAIN_RESOURCE_ACTIVE=1 SKILLCHAIN_RESOURCE_LOCK_FILE="$lockdir/slot-$slot" SKILLCHAIN_RESOURCE_LOCK_OWNER="$BASHPID"
          if [[ "$workers" -gt 0 ]]; then export VITEST_MAX_WORKERS="${VITEST_MAX_WORKERS:-$workers}"; fi
          # Job control gives external commands and shell functions an owned group; disable notifications before waiting.
          set -m
          (set +m; "$@") <&0 & child=$!
          set +m
          rc=0; wait "$child" || rc=$?; child=""
          return "$rc"
        fi
        exec 19>&-
      done
      problem="shared command capacity ${cap} exhausted"
    fi
    if [[ "$SECONDS" -ge "$deadline" ]]; then echo "host resource pressure before ${label}: ${problem}; command not started" >&2; return 77; fi
    echo "waiting before ${label}: ${problem}" >&2
    [[ -z "${SKILLCHAIN_RESOURCE_HEARTBEAT_FILE:-}" ]] || date +%s >"$SKILLCHAIN_RESOURCE_HEARTBEAT_FILE" || return 77
    sleep 0.2
  done
)

# Admission only for orchestrators: do not occupy a child-command slot.
resource_check() ( SKILLCHAIN_RESOURCE_CHECK_ONLY=1 resource_run "$1" "$2" true; )
