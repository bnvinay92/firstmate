#!/usr/bin/env bash
# fm-spawn-headroom-lib.sh - whether this machine has the memory and disk
# headroom to admit one more fresh worker spawn, measured by headroom-axi.
#
# A worker's memory and disk load - its build, its Gradle or Kotlin daemon, its
# simulator - lands on the whole machine rather than on one project, and a
# per-project worker count cannot follow it: the same number is too many while
# other heavy workers run and too few while the machine is idle. When the
# machine opts in, bin/fm-spawn.sh asks headroom-axi for a verdict before a
# fresh ship or scout launches and defers the spawn, exactly as a project
# capacity deferral does, while the machine is short. A deferred task keeps its
# queued backlog item and is dispatched again at Firstmate's ordinary queue
# re-evaluation (after a cleanup and at every heartbeat, AGENTS.md section 10);
# nothing here polls, so a short machine is measured once per attempt and never
# in a loop. Without the opt-in nothing changes.
#
# This file is the single owner of the declaration format and the admission
# verdict. docs/configuration.md "Spawn headroom" is the operator reference, and
# bin/fm-spawn.sh owns where the check runs. bin/fm-project-capacity-lib.sh
# remains the owner of per-project worker counts, which still suit a resource
# that is not memory or disk, such as a device.
#
# Declaration: config/spawn-headroom in the same config directory that
# fm_project_capacity_config_dir resolves (the local root Firstmate home's), so
# every home on this machine reads the same thresholds for the same machine.
# One `<key> <value>` setting per line; blank lines and lines whose first
# non-blank character is `#` are ignored:
#   min-ram <size>          defer while available memory is below <size>
#   min-disk <size>         defer while free disk on the data volume is below <size>
#   pressure warn|critical  defer while the kernel's memory pressure is at or
#                           above this level, whatever available memory says
# <size> is a positive number with an optional fraction and a K, M, G, or T unit
# (4G, 512M, 1.5G), the form `headroom-axi check` takes. At least one of min-ram
# and min-disk is required, because that is what headroom-axi checks; pressure
# is optional, and without it pressure alone never defers. An unknown key, a key
# given twice, a malformed value, a declaration with neither minimum, or an
# unreadable file makes the whole declaration unreadable, and bin/fm-spawn.sh
# then refuses every fresh ship or scout spawn from this machine's homes until
# it is fixed, rather than guessing which thresholds were meant.
#
# Verdict, from `headroom-axi check --json` bounded by
# FM_SPAWN_HEADROOM_TIMEOUT seconds:
#   - exit 1 (short): defer, naming headroom-axi's verdict line, which also
#     names the largest memory or disk consumers;
#   - exit 0 with a memory pressure at or above the declared level: defer,
#     naming the pressure and the verdict line;
#   - exit 0 otherwise: admit;
#   - anything else - headroom-axi or jq not installed, exit 2, a timeout, or a
#     verdict that cannot be parsed: admit, with a warning that names the
#     concrete problem. Measurement is a load guard, not a safety boundary: a
#     deferral here is retried at every re-evaluation, so deferring on a broken
#     or missing tool would hold every fresh spawn on this machine queued until
#     someone noticed, while admitting keeps dispatch moving, still bounded by
#     any project capacity, and puts the problem in front of the dispatcher on
#     every spawn until it is fixed.
#
# The verdict measures the moment of the spawn. A worker admitted a moment ago
# has not yet started its build, so consecutive spawns, such as a batch, can be
# admitted from the same measurement; set the minimums with that margin.
#
# Requires bin/fm-timeout-lib.sh (fm_run_timed) to be sourced first. No side
# effects on source.

# Exit status of a spawn deferred for headroom: the same sysexits "temporary
# failure" code as FM_PROJECT_CAPACITY_DEFER_EXIT, so a caller handles both
# deferrals alike.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_SPAWN_HEADROOM_DEFER_EXIT=75

# Read this machine's headroom declaration.
# Sets FM_SPAWN_HEADROOM_FILE to the declaration path, FM_SPAWN_HEADROOM_ACTIVE
# to 1 when the machine opts in (empty otherwise), and FM_SPAWN_HEADROOM_MIN_RAM,
# FM_SPAWN_HEADROOM_MIN_DISK, and FM_SPAWN_HEADROOM_PRESSURE to the declared
# values, each empty when not declared. Returns 1 with
# FM_SPAWN_HEADROOM_ERROR when the declaration is unreadable.
fm_spawn_headroom_lookup() {  # <config-dir>
  local line lineno=0 key value rest previous
  FM_SPAWN_HEADROOM_FILE="$1/spawn-headroom"
  FM_SPAWN_HEADROOM_ACTIVE=
  FM_SPAWN_HEADROOM_MIN_RAM=
  FM_SPAWN_HEADROOM_MIN_DISK=
  FM_SPAWN_HEADROOM_PRESSURE=
  FM_SPAWN_HEADROOM_ERROR=
  if [ ! -e "$FM_SPAWN_HEADROOM_FILE" ] && [ ! -L "$FM_SPAWN_HEADROOM_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_SPAWN_HEADROOM_FILE" ] || [ ! -r "$FM_SPAWN_HEADROOM_FILE" ]; then
    FM_SPAWN_HEADROOM_ERROR="$FM_SPAWN_HEADROOM_FILE is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in '' | '#'*) continue ;; esac
    key=${line%%[[:space:]]*}
    rest=${line#"$key"}
    value=${rest#"${rest%%[![:space:]]*}"}
    case "$value" in
      '' | *[[:space:]]*)
        FM_SPAWN_HEADROOM_ERROR="$FM_SPAWN_HEADROOM_FILE line $lineno is not '<key> <value>'"
        return 1
        ;;
    esac
    case "$key" in
      min-ram | min-disk)
        if ! fm_spawn_headroom_size_valid "$value"; then
          FM_SPAWN_HEADROOM_ERROR="$FM_SPAWN_HEADROOM_FILE line $lineno gives $key a size that is not like 4G or 512M"
          return 1
        fi
        ;;
      pressure)
        case "$value" in
          warn | critical) ;;
          *)
            FM_SPAWN_HEADROOM_ERROR="$FM_SPAWN_HEADROOM_FILE line $lineno gives pressure a level that is not warn or critical"
            return 1
            ;;
        esac
        ;;
      *)
        FM_SPAWN_HEADROOM_ERROR="$FM_SPAWN_HEADROOM_FILE line $lineno names unknown setting $key"
        return 1
        ;;
    esac
    case "$key" in
      min-ram) previous=$FM_SPAWN_HEADROOM_MIN_RAM ;;
      min-disk) previous=$FM_SPAWN_HEADROOM_MIN_DISK ;;
      pressure) previous=$FM_SPAWN_HEADROOM_PRESSURE ;;
    esac
    if [ -n "$previous" ]; then
      FM_SPAWN_HEADROOM_ERROR="$FM_SPAWN_HEADROOM_FILE line $lineno gives $key a second time"
      return 1
    fi
    case "$key" in
      min-ram) FM_SPAWN_HEADROOM_MIN_RAM=$value ;;
      min-disk) FM_SPAWN_HEADROOM_MIN_DISK=$value ;;
      pressure) FM_SPAWN_HEADROOM_PRESSURE=$value ;;
    esac
  done < "$FM_SPAWN_HEADROOM_FILE"
  if [ -z "$FM_SPAWN_HEADROOM_MIN_RAM" ] && [ -z "$FM_SPAWN_HEADROOM_MIN_DISK" ]; then
    FM_SPAWN_HEADROOM_ERROR="$FM_SPAWN_HEADROOM_FILE declares neither min-ram nor min-disk"
    FM_SPAWN_HEADROOM_PRESSURE=
    return 1
  fi
  FM_SPAWN_HEADROOM_ACTIVE=1
  return 0
}

# 0 iff <size> is a positive size headroom-axi check accepts: digits, an
# optional fraction, and one K, M, G, or T unit in either case.
fm_spawn_headroom_size_valid() {  # <size>
  local size=$1 number
  case "$size" in
    *[KkMmGgTt]) number=${size%?} ;;
    *) return 1 ;;
  esac
  case "$number" in
    '' | .* | *. | *.*.* | *[!0-9.]*) return 1 ;;
    *[1-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# Rank of a memory pressure level, so a measured level can be compared with
# the declared one; an unknown level prints nothing.
fm_spawn_headroom_pressure_rank() {  # <level>
  case "$1" in
    normal) printf '0\n' ;;
    warn) printf '1\n' ;;
    critical) printf '2\n' ;;
  esac
}

# Ask headroom-axi whether one more worker fits the declared thresholds
# (fm_spawn_headroom_lookup must have succeeded with the machine opted in).
# Returns 0 to admit, or FM_SPAWN_HEADROOM_DEFER_EXIT to defer with
# FM_SPAWN_HEADROOM_REASON naming headroom-axi's verdict. On an admit,
# FM_SPAWN_HEADROOM_WARNING is empty when the measurement succeeded and
# otherwise names why the machine could not be measured.
fm_spawn_headroom_admit() {
  local out rc=0 ok line pressure measured declared timeout
  local -a args=(check --json)
  FM_SPAWN_HEADROOM_REASON=
  FM_SPAWN_HEADROOM_WARNING=
  [ -z "$FM_SPAWN_HEADROOM_MIN_RAM" ] || args+=(--min-ram "$FM_SPAWN_HEADROOM_MIN_RAM")
  [ -z "$FM_SPAWN_HEADROOM_MIN_DISK" ] || args+=(--min-disk "$FM_SPAWN_HEADROOM_MIN_DISK")
  if ! command -v headroom-axi >/dev/null 2>&1; then
    FM_SPAWN_HEADROOM_WARNING="headroom-axi is not installed, so this machine's headroom was not measured"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    FM_SPAWN_HEADROOM_WARNING="jq is not installed, so headroom-axi's verdict could not be read"
    return 0
  fi
  timeout=${FM_SPAWN_HEADROOM_TIMEOUT:-30}
  case "$timeout" in '' | *[!0-9]* | 0*) timeout=30 ;; esac
  out=$(fm_run_timed "$timeout" headroom-axi "${args[@]}" 2>&1 </dev/null) || rc=$?
  if fm_timed_out "$rc"; then
    FM_SPAWN_HEADROOM_WARNING="headroom-axi check did not answer within ${timeout}s"
    return 0
  fi
  line=$(printf '%s\n' "$out" | jq -r 'if type == "object" and (.line | type) == "string" then .line else empty end' 2>/dev/null | head -n 1)
  case "$rc" in
    0 | 1) ;;
    *)
      FM_SPAWN_HEADROOM_WARNING="headroom-axi check failed with exit $rc: $(printf '%s\n' "$out" | head -n 1)"
      return 0
      ;;
  esac
  if [ "$rc" -eq 1 ]; then
    [ -n "$line" ] || line=$(printf '%s\n' "$out" | head -n 1)
    FM_SPAWN_HEADROOM_REASON="headroom-axi: $line"
    return "$FM_SPAWN_HEADROOM_DEFER_EXIT"
  fi
  ok=$(printf '%s\n' "$out" | jq -r 'if type == "object" and .ok == true then "yes" else empty end' 2>/dev/null)
  if [ "$ok" != yes ] || [ -z "$line" ]; then
    FM_SPAWN_HEADROOM_WARNING="headroom-axi check exited 0 without a readable verdict: $(printf '%s\n' "$out" | head -n 1)"
    return 0
  fi
  [ -n "$FM_SPAWN_HEADROOM_PRESSURE" ] || return 0
  pressure=$(printf '%s\n' "$out" | jq -r 'if type == "object" and (.ram.pressure | type) == "string" then .ram.pressure else empty end' 2>/dev/null)
  measured=$(fm_spawn_headroom_pressure_rank "$pressure")
  if [ -z "$measured" ]; then
    FM_SPAWN_HEADROOM_WARNING="headroom-axi check reported no known memory pressure level (${pressure:-none}), so pressure was not checked"
    return 0
  fi
  declared=$(fm_spawn_headroom_pressure_rank "$FM_SPAWN_HEADROOM_PRESSURE")
  if [ "$measured" -ge "$declared" ]; then
    FM_SPAWN_HEADROOM_REASON="memory pressure is $pressure, at or above the declared $FM_SPAWN_HEADROOM_PRESSURE; headroom-axi: $line"
    return "$FM_SPAWN_HEADROOM_DEFER_EXIT"
  fi
  return 0
}
