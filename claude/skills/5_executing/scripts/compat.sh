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
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$dir"; continue; fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.2
  done
  echo $$ >"$dir/pid"
  _COMPAT_LOCK_DIRS+=("$dir")
  if [ -z "$_COMPAT_TRAPPED" ]; then # chain onto an existing EXIT trap (trap -p prints it already single-quote-escaped)
    owner="$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")"
    eval "trap -- '${owner:+$owner; }_compat_unlock' EXIT"
    _COMPAT_TRAPPED=1
  fi
}
_COMPAT_LOCK_DIRS=() _COMPAT_TRAPPED=
_compat_unlock() { local d; for d in ${_COMPAT_LOCK_DIRS[@]+"${_COMPAT_LOCK_DIRS[@]}"}; do rm -rf "$d"; done; }
