#!/usr/bin/env bash
# Behavior tests for bin/fm-daemon-reap.sh, which stops only this user's IDLE
# Gradle and Kotlin build daemons.
#
# Every case runs the real script against stand-in daemon processes - real
# processes whose command line names the Gradle or Kotlin daemon main class -
# and fixture daemon logs in a temporary Gradle user home shaped like the logs
# Gradle 9.x writes. FM_DAEMON_REAP_PIDS limits the script to each case's
# stand-ins, so the real daemons of the machine running the suite are never
# touched; a case judges the outcome by which stand-ins are still alive.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REAP="$ROOT/bin/fm-daemon-reap.sh"
TMP_ROOT=$(fm_test_tmproot fm-daemon-reap)
GRADLE_CLASS=org.gradle.launcher.daemon.bootstrap.GradleDaemon
KOTLIN_CLASS=org.jetbrains.kotlin.daemon.KotlinCompileDaemon
STANDINS=()

kill_standins() {
  local pid
  for pid in "${STANDINS[@]:-}"; do
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
  done
}
trap 'kill_standins; fm_test_cleanup' EXIT

# A stand-in daemon: a sleeping process whose command line carries the daemon
# main class. Prints its pid.
standin() {  # gradle|kotlin|kotlin-busy
  local pid
  case "$1" in
    gradle) (exec -a "java -Xmx64m -cp gradle-launcher.jar $GRADLE_CLASS 9.8.1" sleep 600) >/dev/null 2>&1 & pid=$! ;;
    kotlin) (exec -a "java -cp kotlin-daemon.jar $KOTLIN_CLASS --daemon-runFilesPath x" sleep 600) >/dev/null 2>&1 & pid=$! ;;
    kotlin-busy) (exec -a "java -cp kotlin-daemon.jar $KOTLIN_CLASS --daemon-runFilesPath x" bash -c 'while :; do :; done') >/dev/null 2>&1 & pid=$! ;;
  esac
  STANDINS+=("$pid")
  printf '%s\n' "$pid"
}

alive() { kill -0 "$1" 2>/dev/null; }

# A daemon log timestamp, in local time with its zone, as Gradle writes it.
stamp() {  # <epoch>
  { date -r "$1" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d "@$1" +%Y-%m-%dT%H:%M:%S; } | tr -d '\n'
  printf '.%03d' 0
  date -r "$1" +%z 2>/dev/null || date -d "@$1" +%z
}

# Write daemon-<pid>.out.log for one build in <dir> that went idle <idle-ago>
# seconds ago, then optionally append a later event. The file itself is fresh,
# as a live daemon's periodic health check keeps it.
write_log() {  # <guh> <pid> <dir> <idle-ago> [busy|received]
  local guh=$1 pid=$2 dir=$3 ago=$4 extra=${5:-} now log start idle
  now=$(date +%s)
  idle=$((now - ago))
  start=$((idle - 60))
  log="$guh/daemon/9.8.1/daemon-$pid.out.log"
  mkdir -p "${log%/*}"
  {
    printf '%s [INFO] [org.gradle.launcher.daemon.server.Daemon] start() called on daemon - DefaultDaemonContext[uid=x,pid=%s,idleTimeout=10800000]\n' "$(stamp "$start")" "$pid"
    printf '%s [INFO] [org.gradle.launcher.daemon.server.DefaultIncomingConnectionHandler] Received command: Build{id=b1, currentDir=%s}.\n' "$(stamp "$start")" "$dir"
    printf '%s [INFO] [org.gradle.launcher.daemon.server.DaemonRegistryUpdater] Marking the daemon as busy, address: [a port:1, addresses:[localhost/127.0.0.1]]\n' "$(stamp "$start")"
    printf '%s [INFO] [org.gradle.launcher.daemon.server.DaemonRegistryUpdater] Marking the daemon as idle, address: [a port:1, addresses:[localhost/127.0.0.1]]\n' "$(stamp "$idle")"
    printf '%s [DEBUG] [org.gradle.launcher.daemon.registry.PersistentDaemonRegistry] Marking busy by address: [a port:1, addresses:[localhost/127.0.0.1]]\n' "$(stamp "$idle")"
    case "$extra" in
      busy) printf '%s [INFO] [org.gradle.launcher.daemon.server.DaemonRegistryUpdater] Marking the daemon as busy, address: [a port:1, addresses:[localhost/127.0.0.1]]\n' "$(stamp "$now")" ;;
      received) printf '%s [INFO] [org.gradle.launcher.daemon.server.DefaultIncomingConnectionHandler] Received command: Build{id=b2, currentDir=%s}.\n' "$(stamp "$now")" "$dir" ;;
    esac
    printf '%s [DEBUG] [org.gradle.launcher.daemon.server.Daemon] Finished periodic daemon health check.\n' "$(stamp "$now")"
  } > "$log"
  printf '%s\n' "$log"
}

run_reap() {  # <guh> <pids> [args...]
  local guh=$1 pids=$2
  shift 2
  GRADLE_USER_HOME="$guh" FM_DAEMON_REAP_PIDS="$pids" FM_DAEMON_REAP_CPU_SAMPLE=1 \
    FM_DAEMON_REAP_EXIT_WAIT=5 "$REAP" "$@" 2>&1
}

new_guh() { mkdir -p "$TMP_ROOT/$1/gradle" "$TMP_ROOT/$1/work"; printf '%s\n' "$TMP_ROOT/$1"; }

# --- cases ------------------------------------------------------------------

test_idle_gradle_daemon_is_reaped() {
  local c pid out rc=0
  c=$(new_guh idle)
  pid=$(standin gradle)
  write_log "$c/gradle" "$pid" "$c/work/app" 600 >/dev/null
  out=$(run_reap "$c/gradle" "$pid") || rc=$?
  expect_code 0 "$rc" "an idle daemon was not reaped: $out"
  assert_contains "$out" "reaped: idle Gradle 9.8.1 daemon $pid, idle 10 min, last build in $c/work/app" \
    "the reaped line did not name the daemon, its idle time, and its last build"
  alive "$pid" && fail "the idle daemon is still running after it was reaped"
  pass "a daemon idle past the threshold is stopped"
}

test_busy_or_recent_daemons_are_never_reaped() {
  local c busy recent received out rc=0
  c=$(new_guh busy)
  busy=$(standin gradle)
  recent=$(standin gradle)
  received=$(standin gradle)
  write_log "$c/gradle" "$busy" "$c/work/a" 600 busy >/dev/null
  write_log "$c/gradle" "$recent" "$c/work/b" 30 >/dev/null
  write_log "$c/gradle" "$received" "$c/work/c" 600 received >/dev/null
  out=$(run_reap "$c/gradle" "$busy $recent $received") || rc=$?
  expect_code 1 "$rc" "a busy or recently active daemon was reaped: $out"
  assert_equals "" "$out" "nothing reaped still printed a line"
  alive "$busy" || fail "a daemon whose last state is busy was stopped"
  alive "$recent" || fail "a daemon idle for less than the threshold was stopped"
  alive "$received" || fail "a daemon that had just received a build command was stopped"
  pass "busy, recently idle, and just-contacted daemons are never stopped"
}

# A daemon log written by an earlier process with the same pid, or no log at
# all, never proves the live process idle.
test_daemon_without_its_own_log_is_never_reaped() {
  local c stale nolog log out rc=0
  c=$(new_guh nolog)
  stale=$(standin gradle)
  nolog=$(standin gradle)
  log=$(write_log "$c/gradle" "$stale" "$c/work/a" 600)
  fm_touch_epoch $(( $(date +%s) - 86400 )) "$log"
  out=$(run_reap "$c/gradle" "$stale $nolog") || rc=$?
  expect_code 1 "$rc" "a daemon without its own log was reaped: $out"
  alive "$stale" || fail "a daemon was stopped on a log older than the process"
  alive "$nolog" || fail "a daemon with no log was stopped"
  pass "a daemon with no log of its own incarnation is never stopped"
}

test_longest_idle_goes_first_and_max_bounds_the_count() {
  local c older newer out rc=0
  c=$(new_guh order)
  newer=$(standin gradle)
  older=$(standin gradle)
  write_log "$c/gradle" "$newer" "$c/work/a" 600 >/dev/null
  write_log "$c/gradle" "$older" "$c/work/b" 1200 >/dev/null
  out=$(run_reap "$c/gradle" "$newer $older" --max 1) || rc=$?
  expect_code 0 "$rc" "--max 1 reaped nothing: $out"
  alive "$older" && fail "the longest-idle daemon was not the one stopped"
  alive "$newer" || fail "--max 1 stopped more than one daemon"
  pass "the longest-idle daemon goes first and --max bounds how many stop"
}

# Worker cleanup reaps only daemons whose last build ran inside that worker's
# copy, matched through a symlinked path too, and never a Kotlin daemon.
test_inside_reaps_only_that_copys_daemons() {
  local c mine other kotlin out rc=0
  c=$(new_guh inside)
  mkdir -p "$c/work/task/app" "$c/work/task-sibling"
  ln -s "$c/work/task" "$c/link"
  mine=$(standin gradle)
  other=$(standin gradle)
  kotlin=$(standin kotlin)
  write_log "$c/gradle" "$mine" "$c/work/task/app" 600 >/dev/null
  write_log "$c/gradle" "$other" "$c/work/task-sibling" 600 >/dev/null
  out=$(run_reap "$c/gradle" "$mine $other $kotlin" --inside "$c/link") || rc=$?
  expect_code 0 "$rc" "--inside did not reap the copy's own daemon: $out"
  alive "$mine" && fail "the daemon whose last build ran in the copy is still running"
  alive "$other" || fail "a daemon of a sibling directory was stopped"
  alive "$kotlin" || fail "--inside stopped a Kotlin daemon"
  pass "--inside stops only daemons whose last build ran in that copy, never a Kotlin daemon"
}

test_kotlin_daemon_is_reaped_only_when_idle_and_no_build_runs() {
  local c kotlin hot busy out rc=0
  c=$(new_guh kotlin)
  kotlin=$(standin kotlin)
  hot=$(standin kotlin-busy)
  busy=$(standin gradle)
  write_log "$c/gradle" "$busy" "$c/work/a" 600 busy >/dev/null
  out=$(run_reap "$c/gradle" "$kotlin $hot $busy") || rc=$?
  expect_code 1 "$rc" "a Kotlin daemon was reaped while a Gradle build ran: $out"
  alive "$kotlin" || fail "an idle Kotlin daemon was stopped while a Gradle daemon was busy"
  rc=0
  out=$(run_reap "$c/gradle" "$kotlin $hot") || rc=$?
  expect_code 0 "$rc" "an idle Kotlin daemon with no Gradle build running was not reaped: $out"
  assert_contains "$out" "reaped: idle Kotlin daemon $kotlin" "the Kotlin reaped line did not name the daemon"
  alive "$kotlin" && fail "the idle Kotlin daemon is still running"
  alive "$hot" || fail "a Kotlin daemon using CPU was stopped"
  pass "a Kotlin daemon stops on its own only when CPU-idle and no Gradle daemon is busy"
}

test_disable_and_usage() {
  local c pid out rc=0 args
  c=$(new_guh disable)
  pid=$(standin gradle)
  write_log "$c/gradle" "$pid" "$c/work/a" 600 >/dev/null
  out=$(FM_DAEMON_REAP_DISABLE=1 run_reap "$c/gradle" "$pid") || rc=$?
  expect_code 1 "$rc" "FM_DAEMON_REAP_DISABLE=1 still reaped: $out"
  alive "$pid" || fail "FM_DAEMON_REAP_DISABLE=1 stopped a daemon"
  for args in "--max 0" "--max x" "--min-idle soon" "--inside" "--bogus"; do
    rc=0
    # shellcheck disable=SC2086 # each row is deliberately split into arguments.
    out=$(run_reap "$c/gradle" "$pid" $args) || rc=$?
    expect_code 2 "$rc" "'$args' was not a usage error: $out"
  done
  rc=0
  "$REAP" --help >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "--help failed"
  pass "FM_DAEMON_REAP_DISABLE stops nothing, and malformed arguments are usage errors"
}

test_idle_gradle_daemon_is_reaped
test_busy_or_recent_daemons_are_never_reaped
test_daemon_without_its_own_log_is_never_reaped
test_longest_idle_goes_first_and_max_bounds_the_count
test_inside_reaps_only_that_copys_daemons
test_kotlin_daemon_is_reaped_only_when_idle_and_no_build_runs
test_disable_and_usage
