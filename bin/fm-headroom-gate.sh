#!/usr/bin/env bash
# fm-headroom-gate.sh - the check a running worker makes before it starts heavy
# local work (a Gradle or Xcode build, a test suite, an emulator or simulator),
# so that memory and disk headroom governs that work and not only the spawn
# that launched the worker.
#
# Usage: fm-headroom-gate.sh [--wait <seconds>] [--since <epoch>]
#        fm-headroom-gate.sh --declared
#   FM_HOME must name the worker's Firstmate home; the generated brief renders
#   the exact command. The declaration is the machine's config/spawn-headroom,
#   read from the same root-home config directory spawn admission reads
#   (bin/fm-spawn-headroom-lib.sh owns its format and the verdict), so one file
#   opts the machine in to both.
#   It prints exactly one line on stdout and exits:
#     0   `go: ...` - start the work: the machine has headroom, the machine does
#         not opt in, the headroom could not be measured or the declaration is
#         unreadable (the line names the problem), or the worker has already
#         waited max-wait minutes since <epoch>;
#     75  `wait: ...` - do not start the work yet: the line carries
#         headroom-axi's verdict and `until <YYYY-MM-DDTHH:MMZ>`, the latest time
#         this gate will make the worker wait, for the worker's paused line;
#     2   a usage error.
#   --since <epoch> is when the worker's wait began (the epoch of its paused
#   line); without it the wait begins now. Once max-wait minutes have passed
#   since then, the gate says go even on a short machine, so a worker is never
#   starved, including when the memory it waits for is held by other waiting
#   workers' idle build daemons.
#   --wait <seconds> stays in this one command, re-measuring every
#   FM_HEADROOM_GATE_INTERVAL seconds (default 60, at least 10), until the
#   machine has headroom, max-wait passes, or <seconds> elapse; the worker
#   sizes it a little under its shell tool's timeout and reruns it while it
#   exits 75. Each wait is the worker's own declared paused wait, so Firstmate
#   gains no poller.
#   --declared exits 0 when this machine has a config/spawn-headroom at all and
#   1 otherwise, printing nothing; bin/fm-brief.sh uses it to decide whether a
#   brief carries the gate instruction.
#   The gate is advisory and runs only before work starts: nothing here stops,
#   signals, or interrupts work that is already running.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,/^set -eu$/{/^set -eu$/d;s/^# \{0,1\}//;p;}' "$0"
}

die_usage() {
  echo "error: $1" >&2
  echo "usage: fm-headroom-gate.sh [--wait <seconds>] [--since <epoch>] | --declared" >&2
  exit 2
}

WAIT=
SINCE=
DECLARED=0
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
    *) die_usage "unknown argument $1" ;;
  esac
  shift
done
case "$WAIT" in *[!0-9]* | 0*) die_usage "--wait must be a positive number of seconds" ;; esac
case "$SINCE" in *[!0-9]*) die_usage "--since must be a Unix epoch in seconds" ;; esac
[ -n "${FM_HOME:-}" ] || die_usage "FM_HOME must name this worker's Firstmate home"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-spawn-headroom-lib.sh
. "$SCRIPT_DIR/fm-spawn-headroom-lib.sh"

CONFIG_DIR=$(fm_project_capacity_config_dir "$FM_HOME" "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}") || {
  [ "$DECLARED" -eq 0 ] || exit 1
  echo "go: not measured - the root Firstmate home of $FM_HOME cannot be resolved, so its headroom declaration cannot be read"
  exit 0
}

if [ "$DECLARED" -eq 1 ]; then
  [ -e "$CONFIG_DIR/spawn-headroom" ] || [ -L "$CONFIG_DIR/spawn-headroom" ]
  exit
fi

if ! fm_spawn_headroom_lookup "$CONFIG_DIR"; then
  echo "go: not measured - the headroom declaration is unreadable ($FM_SPAWN_HEADROOM_ERROR)"
  exit 0
fi
if [ -z "$FM_SPAWN_HEADROOM_ACTIVE" ]; then
  echo "go: no headroom declaration on this machine"
  exit 0
fi

utc_minute() {  # <epoch> -> YYYY-MM-DDTHH:MMZ, rounded up to the minute
  local t=$(( ($1 + 59) / 60 * 60 ))
  date -u -r "$t" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$t" +%Y-%m-%dT%H:%MZ
}

now=$(date +%s)
[ -n "$SINCE" ] || SINCE=$now
cap=$((SINCE + FM_SPAWN_HEADROOM_MAX_WAIT * 60))
deadline=$now
[ -z "$WAIT" ] || deadline=$((now + WAIT))
interval=${FM_HEADROOM_GATE_INTERVAL:-60}
case "$interval" in '' | *[!0-9]*) interval=60 ;; esac
[ "$interval" -ge 10 ] || interval=10

while :; do
  rc=0
  fm_spawn_headroom_admit || rc=$?
  if [ "$rc" -ne "$FM_SPAWN_HEADROOM_DEFER_EXIT" ]; then
    if [ -n "$FM_SPAWN_HEADROOM_WARNING" ]; then
      echo "go: not measured - $FM_SPAWN_HEADROOM_WARNING"
    else
      echo "go: headroom ok"
    fi
    exit 0
  fi
  now=$(date +%s)
  if [ "$now" -ge "$cap" ]; then
    echo "go: waited $(( (now - SINCE) / 60 )) minute(s) for headroom, at least the declared max-wait of $FM_SPAWN_HEADROOM_MAX_WAIT, so start the work anyway - $FM_SPAWN_HEADROOM_REASON"
    exit 0
  fi
  if [ "$now" -ge "$deadline" ]; then
    echo "wait: machine headroom is short - $FM_SPAWN_HEADROOM_REASON until $(utc_minute "$cap")"
    exit "$FM_SPAWN_HEADROOM_DEFER_EXIT"
  fi
  pause=$interval
  [ $((deadline - now)) -ge "$pause" ] || pause=$((deadline - now))
  [ $((cap - now)) -ge "$pause" ] || pause=$((cap - now))
  sleep "$pause"
done
