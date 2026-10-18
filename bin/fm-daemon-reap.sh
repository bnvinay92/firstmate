#!/usr/bin/env bash
# fm-daemon-reap.sh - stop this user's IDLE Gradle and Kotlin build daemons, so
# the memory a finished build leaves resident (often 9-13 GB, for the hours
# until each daemon's own idle timeout) returns to the machine.
#
# Usage: fm-daemon-reap.sh [--inside <dir>] [--max <n>] [--min-idle <seconds>]
#   Prints one `reaped: ...` line per daemon it stopped and exits 0 when it
#   stopped at least one, 1 when it stopped none, and 2 on a usage error.
#   --inside <dir>  only Gradle daemons whose last build ran in <dir> or below
#                   it (a worker's task copy at cleanup); Kotlin daemons are
#                   never reaped in this mode.
#   --max <n>       stop at most <n> daemons (default: every idle one).
#   --min-idle <s>  how long a Gradle daemon must have been idle since its last
#                   build (default FM_DAEMON_REAP_MIN_IDLE, else 120 seconds).
#
# Callers: bin/fm-headroom-gate.sh, oldest idle first, when the machine is
# short of memory, before it decides to wait; and bin/fm-teardown.sh with
# --inside the task's copy at worker cleanup. Both treat a failure as nothing
# reaped and carry on.
#
# The idle-only rule. Nothing here ever stops a daemon that may be building:
#   - Only processes owned by the current user are considered, and the owner is
#     checked again immediately before the signal.
#   - A GradleDaemon (main class org.gradle.launcher.daemon.bootstrap.GradleDaemon)
#     is idle only when its log, the newest
#     ${GRADLE_USER_HOME:-~/.gradle}/daemon/<version>/daemon-<pid>.out.log written
#     since that process started, has `Marking the daemon as idle` as its last
#     build event - no `Received command: Build{...}` and no `Marking the daemon
#     as busy` after it - AND that idle line's own timestamp is at least
#     --min-idle seconds old. The daemon logs a build command the moment a
#     client sends one, so an idle last event that old means no client has
#     asked it to build since. The log file's age cannot stand in for this: a
#     live daemon appends a periodic health-check line about every 10 seconds,
#     so its log is never quiet. A daemon with no such log (another Gradle user
#     home, an unreadable log, an unparseable timestamp) is never idle. The
#     event and its age are read again immediately before the signal; the
#     remaining race is a client connecting in the milliseconds between that
#     re-check and the signal, which costs one failed build the worker reruns.
#   - A Kotlin daemon (org.jetbrains.kotlin.daemon.KotlinCompileDaemon) usually
#     exits with its Gradle daemon. One is reaped on its own only when no
#     GradleDaemon of this user is left that is not provably idle, and it used
#     at most 5% of one CPU over a FM_DAEMON_REAP_CPU_SAMPLE-second sample
#     (default 3); both are checked again immediately before the signal.
#   - The signal is SIGTERM, which a JVM handles by shutting down cleanly; this
#     script then waits up to FM_DAEMON_REAP_EXIT_WAIT seconds (default 10) for
#     the process to exit, so a caller re-measuring memory sees it freed. It
#     never sends SIGKILL and never runs `gradle --stop`, which force-stops
#     every daemon of that Gradle version, busy ones included.
#
# FM_DAEMON_REAP_DISABLE=1 makes this script stop nothing and exit 1, and
# FM_DAEMON_REAP_PIDS="<pid> ..." limits every view of running daemons,
# including the busy view that guards Kotlin daemons, to those pids; both exist
# so tests never touch the real daemons of the machine they run on.
set -eu

usage() {
  sed -n '2,/^set -eu$/{/^set -eu$/d;s/^# \{0,1\}//;p;}' "$0"
}

die_usage() {
  echo "error: $1" >&2
  echo "usage: fm-daemon-reap.sh [--inside <dir>] [--max <n>] [--min-idle <seconds>]" >&2
  exit 2
}

INSIDE=
MAX=
MIN_IDLE=${FM_DAEMON_REAP_MIN_IDLE:-120}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --inside)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die_usage "--inside needs a directory"
      INSIDE=$2
      shift
      ;;
    --max)
      [ "$#" -ge 2 ] || die_usage "--max needs a number"
      MAX=$2
      shift
      ;;
    --min-idle)
      [ "$#" -ge 2 ] || die_usage "--min-idle needs a number of seconds"
      MIN_IDLE=$2
      shift
      ;;
    *) die_usage "unknown argument $1" ;;
  esac
  shift
done
case "$MAX" in *[!0-9]* | 0*) die_usage "--max must be a positive number" ;; esac
case "$MIN_IDLE" in '' | *[!0-9]*) die_usage "--min-idle must be a number of seconds" ;; esac

[ "${FM_DAEMON_REAP_DISABLE:-}" != 1 ] || exit 1

DAEMON_DIR="${GRADLE_USER_HOME:-$HOME/.gradle}/daemon"
CPU_SAMPLE=${FM_DAEMON_REAP_CPU_SAMPLE:-3}
case "$CPU_SAMPLE" in '' | *[!0-9]* | 0*) CPU_SAMPLE=3 ;; esac
EXIT_WAIT=${FM_DAEMON_REAP_EXIT_WAIT:-10}
case "$EXIT_WAIT" in '' | *[!0-9]*) EXIT_WAIT=10 ;; esac
UNAME=$(uname 2>/dev/null || echo unknown)
ME=$(id -u)
GRADLE_CLASS=org.gradle.launcher.daemon.bootstrap.GradleDaemon
KOTLIN_CLASS=org.jetbrains.kotlin.daemon.KotlinCompileDaemon

mtime() {  # <path>
  if [ "$UNAME" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

etime_seconds() {  # <[[dd-]hh:]mm:ss>
  local e=$1 d=0 h=0 m=0 s=0 IFS=:
  local -a f
  case "$e" in *-*) d=${e%%-*}; e=${e#*-} ;; esac
  read -r -a f <<< "$e"
  case "${#f[@]}" in
    3) h=${f[0]} m=${f[1]} s=${f[2]} ;;
    2) m=${f[0]} s=${f[1]} ;;
    *) return 1 ;;
  esac
  printf '%s\n' $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

pid_wanted() {  # <pid>
  [ -n "${FM_DAEMON_REAP_PIDS:-}" ] || return 0
  case " $FM_DAEMON_REAP_PIDS " in *" $1 "*) return 0 ;; esac
  return 1
}

# This user's live daemons, one `<kind> <pid> <start-epoch>` line each, where
# kind is gradle or kotlin.
list_daemons() {
  local now pid etime command start
  now=$(date +%s)
  COLUMNS=10000 LC_ALL=C ps -ww -U "$ME" -o pid= -o etime= -o command= 2>/dev/null |
    while read -r pid etime command; do
      case "$pid" in '' | *[!0-9]*) continue ;; esac
      [ "$pid" != "$$" ] || continue
      pid_wanted "$pid" || continue
      start=$(etime_seconds "$etime") || continue
      start=$((now - start))
      case "$command" in
        *"$GRADLE_CLASS"*) printf 'gradle %s %s\n' "$pid" "$start" ;;
        *"$KOTLIN_CLASS"*) printf 'kotlin %s %s\n' "$pid" "$start" ;;
      esac
    done
}

# The log of the GradleDaemon incarnation <pid> that started at <start>: the
# newest daemon-<pid>.out.log modified since then, allowing for the
# one-second resolution of the process's elapsed time.
gradle_log() {  # <pid> <start-epoch>
  local log m best='' best_m=0
  for log in "$DAEMON_DIR"/*/daemon-"$1".out.log; do
    [ -f "$log" ] || continue
    m=$(mtime "$log") || continue
    [ "$m" -ge $(($2 - 2)) ] || continue
    if [ -z "$best" ] || [ "$m" -gt "$best_m" ]; then
      best=$log
      best_m=$m
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# Epoch of a daemon log line's leading `YYYY-MM-DDTHH:MM:SS.mmm+zzzz` stamp.
line_epoch() {  # <log-line>
  local stamp=${1:0:19} zone=${1:23:5}
  case "$stamp$zone" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][+-][0-9][0-9][0-9][0-9]) ;;
    *) return 1 ;;
  esac
  if [ "$UNAME" = Darwin ]; then
    LC_ALL=C date -j -f '%Y-%m-%dT%H:%M:%S%z' "$stamp$zone" +%s 2>/dev/null
  else
    LC_ALL=C date -d "$stamp$zone" +%s 2>/dev/null
  fi
}

# Whether <log> proves its daemon idle for at least MIN_IDLE seconds; on
# success sets IDLE_FOR to how long ago it last went idle.
log_proves_idle() {  # <log>
  local event since
  IDLE_FOR=
  event=$(grep -E 'Marking the daemon as (busy|idle)|Received command: Build\{' "$1" 2>/dev/null | tail -n 1) || return 1
  case "$event" in *'Marking the daemon as idle'*) ;; *) return 1 ;; esac
  since=$(line_epoch "$event") || return 1
  [ -n "$since" ] || return 1
  IDLE_FOR=$(( $(date +%s) - since ))
  [ "$IDLE_FOR" -ge "$MIN_IDLE" ]
}

last_build_dir() {  # <log>
  grep -oE 'Build\{id=[^,]*, currentDir=[^}]*\}' "$1" 2>/dev/null | tail -n 1 |
    sed -e 's/^.*currentDir=//' -e 's/}$//'
}

dir_is_inside() {  # <dir> <root>...
  local dir=${1%/} root
  shift
  for root in "$@"; do
    root=${root%/}
    [ -n "$root" ] || continue
    case "$dir" in "$root" | "$root"/*) return 0 ;; esac
  done
  return 1
}

owned_by_me() {  # <pid> <class>
  local uid command
  read -r uid command < <(COLUMNS=10000 LC_ALL=C ps -ww -p "$1" -o uid= -o command= 2>/dev/null) || return 1
  [ "$uid" = "$ME" ] || return 1
  case "$command" in *"$2"*) return 0 ;; esac
  return 1
}

# Cumulative CPU time of <pid>, in hundredths of a second.
cpu_centis() {  # <pid>
  local stat ticks hz t m s c=0
  local -a f
  if [ -r "/proc/$1/stat" ]; then
    stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    read -r -a f <<< "${stat##*)}"
    ticks=$(( f[11] + f[12] ))
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    printf '%s\n' $(( ticks * 100 / hz ))
    return 0
  fi
  t=$(LC_ALL=C ps -p "$1" -o time= 2>/dev/null | tr -d ' ') || return 1
  [ -n "$t" ] || return 1
  case "$t" in *.*) c=${t##*.}; c=${c:0:2}; t=${t%.*} ;; esac
  s=$(etime_seconds "$t") || return 1
  m=$((10#${c:-0}))
  printf '%s\n' $(( s * 100 + m ))
}

# Every GradleDaemon still alive is provably idle, so no build is running that
# a Kotlin daemon could be serving.
no_gradle_busy() {
  local kind pid start log
  while read -r kind pid start; do
    [ "$kind" = gradle ] || continue
    log=$(gradle_log "$pid" "$start") || return 1
    log_proves_idle "$log" || return 1
  done < <(list_daemons)
  return 0
}

wait_exit() {  # <pid>
  local waited=0
  while kill -0 "$1" 2>/dev/null; do
    [ "$waited" -lt "$EXIT_WAIT" ] || return 1
    sleep 1
    waited=$((waited + 1))
  done
}

REAPED=0
room() { [ -z "$MAX" ] || [ "$REAPED" -lt "$MAX" ]; }

report() {  # <pid> <description>
  REAPED=$((REAPED + 1))
  if wait_exit "$1"; then
    printf 'reaped: %s\n' "$2"
  else
    printf 'reaped: %s (still exiting after %ss)\n' "$2" "$EXIT_WAIT"
  fi
}

roots=()
if [ -n "$INSIDE" ]; then
  roots+=("$INSIDE")
  canonical=$(CDPATH='' cd -- "$INSIDE" 2>/dev/null && pwd -P) || canonical=
  [ -z "$canonical" ] || [ "$canonical" = "${INSIDE%/}" ] || roots+=("$canonical")
fi

# Idle Gradle daemons, longest idle first.
candidates=$(
  list_daemons | while read -r kind pid start; do
    [ "$kind" = gradle ] || continue
    log=$(gradle_log "$pid" "$start") || continue
    log_proves_idle "$log" || continue
    if [ "${#roots[@]}" -gt 0 ]; then
      dir=$(last_build_dir "$log")
      { [ -n "$dir" ] && dir_is_inside "$dir" "${roots[@]}"; } || continue
    fi
    printf '%s %s %s\n' "$IDLE_FOR" "$pid" "$log"
  done | sort -rn
)
while read -r _ pid log; do
  [ -n "$pid" ] || continue
  room || break
  # Re-check everything immediately before acting.
  owned_by_me "$pid" "$GRADLE_CLASS" || continue
  log_proves_idle "$log" || continue
  version=${log%/*}
  version=${version##*/}
  dir=$(last_build_dir "$log")
  kill -TERM "$pid" 2>/dev/null || continue
  report "$pid" "idle Gradle $version daemon $pid, idle $((IDLE_FOR / 60)) min, last build in ${dir:-an unknown directory}"
done <<EOF
$candidates
EOF

if [ "${#roots[@]}" -eq 0 ] && room && no_gradle_busy; then
  kotlin=$(list_daemons | while read -r kind pid start; do
    [ "$kind" = kotlin ] && printf '%s %s\n' "$start" "$pid"
  done | sort -n | while read -r _ pid; do printf '%s\n' "$pid"; done)
  if [ -n "$kotlin" ]; then
    before=
    for pid in $kotlin; do
      before="$before $pid:$(cpu_centis "$pid" || echo x)"
    done
    sleep "$CPU_SAMPLE"
    for entry in $before; do
      pid=${entry%%:*}
      t0=${entry#*:}
      room || break
      [ "$t0" != x ] || continue
      t1=$(cpu_centis "$pid") || continue
      # At most 5% of one CPU over the sample: centiseconds <= sample * 5.
      [ $((t1 - t0)) -le $((CPU_SAMPLE * 5)) ] || continue
      owned_by_me "$pid" "$KOTLIN_CLASS" || continue
      no_gradle_busy || break
      kill -TERM "$pid" 2>/dev/null || continue
      report "$pid" "idle Kotlin daemon $pid, $(( (t1 - t0) / CPU_SAMPLE ))% of a CPU over ${CPU_SAMPLE}s, no Gradle build running"
    done
  fi
fi

[ "$REAPED" -gt 0 ]
