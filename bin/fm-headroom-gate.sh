#!/usr/bin/env bash
# fm-headroom-gate.sh - the check a running worker makes before it starts heavy
# local work (a Gradle or Xcode build, a test suite, an emulator or simulator),
# so that memory and disk headroom, and the machine's heavy-build slots, govern
# that work and not only the spawn that launched the worker.
#
# Usage: fm-headroom-gate.sh [--wait <seconds>] [--since <epoch>] --run [--] <command> [args...]
#        fm-headroom-gate.sh [--wait <seconds>] [--since <epoch>]
#        fm-headroom-gate.sh --declared
#   FM_HOME must name the worker's Firstmate home; the generated brief renders
#   the exact command. The declaration is the machine's config/spawn-headroom,
#   read from the same root-home config directory spawn admission reads
#   (bin/fm-spawn-headroom-lib.sh owns its format and the verdict), so one file
#   opts the machine in to both.
#
#   --run is the wrapper form every heavy command goes through: one wrapper per
#   command. It waits as below for headroom and, when the declaration sets
#   max-builds, for one of the machine's build slots; then it runs <command>
#   while holding that slot, releases the slot when <command> exits, and exits
#   with <command>'s own status. Its go or wait line goes to stderr, so the
#   command's output stays its own. Exit 75 with a `wait:` line means
#   <command> did not start.
#   Without --run the gate only checks: it prints its line on stdout and holds
#   nothing, so a free slot it reports can be taken by the next build.
#   Either form exits:
#     0   `go: ...` - start the work (with --run: the work ran, and the exit
#         status is the command's): the machine has headroom and a free slot,
#         the machine does not opt in, the headroom could not be measured or
#         the declaration is unreadable (the line names the problem), or the
#         worker has already waited max-wait minutes for memory or disk since
#         <epoch> and a slot is free;
#     75  `wait: ...` - do not start the work yet: the line carries
#         headroom-axi's verdict and `until <YYYY-MM-DDTHH:MMZ>`, the latest time
#         this gate will make the worker wait for memory or disk, or names the
#         builds holding every slot, for the worker's paused line;
#     2   a usage error.
#   --since <epoch> is when the worker's wait began (the epoch of its paused
#   line); without it the wait begins now. Once max-wait minutes have passed
#   since then, the gate stops waiting for memory and disk, so a worker is never
#   starved by memory it cannot free.
#   max-wait never applies to a slot wait. Slots exist so heavy builds never
#   pile up past the declared count, and starting past max-wait would recreate
#   exactly the pile-up the slots prevent. A slot wait cannot starve: every
#   held slot belongs to a running build that releases it when it exits, and a
#   slot whose holder process is gone is reclaimed.
#   --wait <seconds> stays in this one command, re-measuring every
#   FM_HEADROOM_GATE_INTERVAL seconds (default 60, at least 10), until the
#   machine has headroom and a slot, max-wait passes for memory and disk, or
#   <seconds> elapse; the worker sizes it a little under its shell tool's
#   timeout and reruns it while it exits 75. Each wait is the worker's own
#   declared paused wait, so Firstmate gains no poller.
#   --declared exits 0 when this machine has a config/spawn-headroom at all and
#   1 otherwise, printing nothing; bin/fm-brief.sh uses it to decide whether a
#   brief carries the gate instruction.
#
# Build slots. With max-builds <n>, at most <n> --run commands hold a slot at
# once across every local home on the machine: the slots live in the root
# Firstmate home's state/build-slots/, one holder record per running wrapper,
# naming its process identity, start time, directory, and command. Taking a
# slot counts the live holders and writes this wrapper's record inside one
# critical section under a portable lock (bin/fm-wake-lib.sh's
# fm_lock_try_acquire), so two concurrent wrappers can never both take the last
# slot. A holder record whose process is gone, or whose pid now belongs to a
# different process, is reclaimed inside that same section. The wrapper stays
# alive for as long as its command does - INT, TERM, and HUP are deferred until
# the command exits - so the slot is held for the build's whole lifetime; a
# wrapper killed outright with SIGKILL loses its slot while an orphaned command
# may still run. A --run nested inside another --run's command (for example a
# script that wraps its own build) is still measured for headroom but runs
# under the outer slot instead of waiting for a second one, through the
# FM_BUILD_SLOT variable the outer wrapper exports.
#
# Reaping. When the machine is short of memory, before deciding to wait, the
# gate stops this user's idle Gradle and Kotlin build daemons one at a time,
# longest idle first, through bin/fm-daemon-reap.sh (which owns the idle-only
# rule), re-measuring after each, until the machine has headroom or no idle
# daemon is left. Its `reaped:` lines go to stderr. Reaping never touches a busy
# daemon, and nothing here stops, signals, or interrupts work that is already
# running.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -eu$/{/^set -eu$/d;s/^# \{0,1\}//;p;}' "$0"
}

die_usage() {
  echo "error: $1" >&2
  echo "usage: fm-headroom-gate.sh [--wait <seconds>] [--since <epoch>] [--run [--] <command>...] | --declared" >&2
  exit 2
}

WAIT=
SINCE=
DECLARED=0
RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --declared) DECLARED=1 ;;
    --wait)
      [ "$#" -ge 2 ] || die_usage "--wait needs a number of seconds"
      WAIT=$2
      shift
      ;;
    --since)
      [ "$#" -ge 2 ] || die_usage "--since needs an epoch"
      SINCE=$2
      shift
      ;;
    --run)
      RUN=1
      shift
      [ "${1:-}" != -- ] || shift
      [ "$#" -gt 0 ] || die_usage "--run needs a command"
      break
      ;;
    *) die_usage "unknown argument $1" ;;
  esac
  shift
done
case "$WAIT" in *[!0-9]* | 0*) die_usage "--wait must be a positive number of seconds" ;; esac
case "$SINCE" in *[!0-9]*) die_usage "--since must be a Unix epoch in seconds" ;; esac
[ "$DECLARED" -eq 0 ] || [ "$RUN" -eq 0 ] || die_usage "--declared takes no command"
[ -n "${FM_HOME:-}" ] || die_usage "FM_HOME must name this worker's Firstmate home"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-spawn-headroom-lib.sh
. "$SCRIPT_DIR/fm-spawn-headroom-lib.sh"

# Print the gate's line: on stdout for a check, on stderr for --run.
say() {
  if [ "$RUN" -eq 1 ]; then
    printf '%s\n' "$1" >&2
  else
    printf '%s\n' "$1"
  fi
}

SLOT_FILE=
release_slot() {
  [ -z "$SLOT_FILE" ] || rm -f "$SLOT_FILE" 2>/dev/null || true
  SLOT_FILE=
}

# Say go, then either exit 0 (a check) or run the command under the slot this
# wrapper may hold and exit with its status.
go() {  # <line> [command...]
  local rc=0
  say "$1"
  shift
  [ "$RUN" -eq 1 ] || exit 0
  [ -z "$SLOT_FILE" ] || export FM_BUILD_SLOT="$SLOT_FILE"
  trap release_slot EXIT
  trap ':' INT TERM HUP
  "$@" || rc=$?
  release_slot
  exit "$rc"
}

COMMAND=("$@")
run_go() { go "$1" ${COMMAND[@]+"${COMMAND[@]}"}; }

CONFIG_DIR=$(fm_project_capacity_config_dir "$FM_HOME" "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}") || {
  [ "$DECLARED" -eq 0 ] || exit 1
  run_go "go: not measured - the root Firstmate home of $FM_HOME cannot be resolved, so its headroom declaration cannot be read"
}

if [ "$DECLARED" -eq 1 ]; then
  [ -e "$CONFIG_DIR/spawn-headroom" ] || [ -L "$CONFIG_DIR/spawn-headroom" ]
  exit
fi

if ! fm_spawn_headroom_lookup "$CONFIG_DIR"; then
  run_go "go: not measured - the headroom declaration is unreadable ($FM_SPAWN_HEADROOM_ERROR)"
fi
if [ -z "$FM_SPAWN_HEADROOM_ACTIVE" ]; then
  run_go "go: no headroom declaration on this machine"
fi

utc_minute() {  # <epoch> -> YYYY-MM-DDTHH:MMZ, rounded up to the minute
  local t=$(( ($1 + 59) / 60 * 60 ))
  date -u -r "$t" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$t" +%Y-%m-%dT%H:%MZ
}

utc_time() {  # <epoch> -> HH:MMZ
  date -u -r "$1" +%H:%MZ 2>/dev/null || date -u -d "@$1" +%H:%MZ
}

# --- build slots -----------------------------------------------------------

MAX_BUILDS=$FM_SPAWN_HEADROOM_MAX_BUILDS
SLOTS_DIR=
if [ -n "$MAX_BUILDS" ]; then
  slots_root=$(fm_firstmate_root_home "$FM_HOME") || slots_root=
  if [ -n "$slots_root" ] && mkdir -p "$slots_root/state/build-slots" 2>/dev/null; then
    SLOTS_DIR="$slots_root/state/build-slots"
  else
    MAX_BUILDS=
    SLOTS_NOTE="build slots not enforced - the root home's state/build-slots directory of $FM_HOME is unavailable"
  fi
fi

holder_field() {  # <holder-file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# 0 iff <holder-file>'s process is still the wrapper that wrote it. A pid that
# is alive but whose identity cannot be read now counts as live, so a slot is
# never reclaimed from a build on a guess.
holder_live() {  # <holder-file>
  local pid identity now_identity
  pid=$(holder_field "$1" pid)
  fm_pid_alive "$pid" || return 1
  identity=$(holder_field "$1" identity)
  [ -n "$identity" ] || return 0
  now_identity=$(fm_pid_identity "$pid" 2>/dev/null | head -n 1) || return 0
  [ -n "$now_identity" ] || return 0
  [ "$now_identity" = "$identity" ]
}

# Count live holders, reclaiming dead ones. Call only under the slots lock.
# Sets SLOTS_USED and SLOTS_HELD (a description of each live holder).
slots_scan() {
  local f pid since cwd command
  SLOTS_USED=0
  SLOTS_HELD=
  for f in "$SLOTS_DIR"/holder.*; do
    [ -f "$f" ] || continue
    case "$f" in *.tmp) continue ;; esac
    if ! holder_live "$f"; then
      rm -f "$f" 2>/dev/null || true
      continue
    fi
    SLOTS_USED=$((SLOTS_USED + 1))
    pid=$(holder_field "$f" pid)
    since=$(holder_field "$f" since)
    cwd=$(holder_field "$f" cwd)
    command=$(holder_field "$f" command)
    SLOTS_HELD="${SLOTS_HELD:+$SLOTS_HELD; }pid $pid ($command in $cwd) since $(utc_time "${since:-0}")"
  done
}

# Take a slot for this wrapper (--run) or only check that one is free; 0 when
# a slot was taken or is free.
slot_claim() {  # take|check
  local rc=1 tmp command identity me
  fm_lock_acquire_wait "$SLOTS_DIR/.lock"
  slots_scan
  if [ "$SLOTS_USED" -lt "$MAX_BUILDS" ]; then
    rc=0
    if [ "$1" = take ]; then
      fm_current_pid me
      identity=$(fm_pid_identity "$me" 2>/dev/null | head -n 1) || identity=
      command="${COMMAND[*]}"
      command=$(printf '%s' "${command:0:120}" | tr '\n' ' ')
      SLOT_FILE="$SLOTS_DIR/holder.$me"
      tmp="$SLOT_FILE.tmp"
      if printf 'pid=%s\nidentity=%s\nsince=%s\ncwd=%s\ncommand=%s\n' \
          "$me" "$identity" "$(date +%s)" "$PWD" "$command" > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$SLOT_FILE" 2>/dev/null; then
        trap release_slot EXIT
      else
        rm -f "$tmp" 2>/dev/null || true
        SLOT_FILE=
        rc=1
        SLOTS_HELD="this wrapper could not write its holder record in $SLOTS_DIR"
      fi
    fi
  fi
  fm_lock_release "$SLOTS_DIR/.lock"
  return "$rc"
}

# A --run or check nested inside a wrapper's command runs under the outer
# slot, still measured for headroom.
if [ -n "$MAX_BUILDS" ] && [ -n "${FM_BUILD_SLOT:-}" ] \
  && [ "${FM_BUILD_SLOT%/*}" = "$SLOTS_DIR" ] && [ -f "$FM_BUILD_SLOT" ] && holder_live "$FM_BUILD_SLOT"; then
  MAX_BUILDS=
  SLOTS_NOTE="running inside the build slot already held by pid $(holder_field "$FM_BUILD_SLOT" pid)"
fi

# --- the wait ----------------------------------------------------------------

REAPED=0
# Stop idle build daemons one at a time while memory stays short; leaves the
# last admission verdict in rc.
# A daemon that ignores its SIGTERM is offered again, so the attempts are
# bounded.
reap_while_short() {
  local attempts=0
  while [ "$rc" -eq "$FM_SPAWN_HEADROOM_DEFER_EXIT" ] && [ -n "$FM_SPAWN_HEADROOM_MEMORY_SHORT" ] \
    && [ "$attempts" -lt 16 ]; do
    attempts=$((attempts + 1))
    "$SCRIPT_DIR/fm-daemon-reap.sh" --max 1 >&2 </dev/null || return 0
    REAPED=$((REAPED + 1))
    rc=0
    fm_spawn_headroom_admit || rc=$?
  done
}

reaped_note() {
  [ "$REAPED" -eq 0 ] || printf ' after reaping %s idle build daemon(s)' "$REAPED"
}

now=$(date +%s)
[ -n "$SINCE" ] || SINCE=$now
cap=$((SINCE + FM_SPAWN_HEADROOM_MAX_WAIT * 60))
deadline=$now
[ -z "$WAIT" ] || deadline=$((now + WAIT))
interval=${FM_HEADROOM_GATE_INTERVAL:-60}
case "$interval" in '' | *[!0-9]*) interval=60 ;; esac
[ "$interval" -ge 10 ] || interval=10
slot_mode=check
[ "$RUN" -eq 0 ] || slot_mode=take

while :; do
  waiting=
  memory_wait=0
  if [ -n "$MAX_BUILDS" ] && ! slot_claim "$slot_mode"; then
    waiting="wait: all $MAX_BUILDS build slot(s) are in use - ${SLOTS_HELD:-held by running builds}"
  else
    slot_note=
    [ -z "$MAX_BUILDS" ] || slot_note=", build slot $([ "$RUN" -eq 1 ] && echo taken || echo free) of $MAX_BUILDS"
    [ -z "${SLOTS_NOTE:-}" ] || slot_note="; ${SLOTS_NOTE}"
    rc=0
    fm_spawn_headroom_admit || rc=$?
    reap_while_short
    if [ "$rc" -ne "$FM_SPAWN_HEADROOM_DEFER_EXIT" ]; then
      if [ -n "$FM_SPAWN_HEADROOM_WARNING" ]; then
        run_go "go: not measured - $FM_SPAWN_HEADROOM_WARNING$slot_note"
      fi
      run_go "go: headroom ok$(reaped_note)$slot_note"
    fi
    now=$(date +%s)
    if [ "$now" -ge "$cap" ]; then
      run_go "go: waited $(( (now - SINCE) / 60 )) minute(s) for headroom, at least the declared max-wait of $FM_SPAWN_HEADROOM_MAX_WAIT, so start the work anyway - $FM_SPAWN_HEADROOM_REASON$slot_note"
    fi
    release_slot
    memory_wait=1
    waiting="wait: machine headroom is short$(reaped_note) - $FM_SPAWN_HEADROOM_REASON until $(utc_minute "$cap")"
  fi
  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    say "$waiting"
    exit "$FM_SPAWN_HEADROOM_DEFER_EXIT"
  fi
  pause=$interval
  [ $((deadline - now)) -ge "$pause" ] || pause=$((deadline - now))
  if [ "$memory_wait" -eq 1 ] && [ $((cap - now)) -lt "$pause" ] && [ "$cap" -gt "$now" ]; then
    pause=$((cap - now))
  fi
  sleep "$pause"
done
