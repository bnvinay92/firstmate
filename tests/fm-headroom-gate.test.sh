#!/usr/bin/env bash
# Behavior tests for bin/fm-headroom-gate.sh, the check a running worker makes
# before heavy local work: it says go or wait from the machine's
# config/spawn-headroom and headroom-axi's verdict, waits boundedly, and never
# starves a worker past max-wait.
#
# Every case runs the real script against a temporary Firstmate home and a stub
# headroom-axi that logs each call and answers from a per-call sequence. Daemon
# reaping is off and the Gradle user home is a temporary one unless a case
# turns reaping on for its own stand-in daemons, so the suite never stops a
# real daemon of the machine running it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-headroom-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-headroom-gate)
WAIT_EXIT=75
export FM_DAEMON_REAP_DISABLE=1
export GRADLE_USER_HOME="$TMP_ROOT/gradle-user-home"
BACKGROUND=()
kill_background() {
  local pid
  for pid in "${BACKGROUND[@]:-}"; do
    [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
  done
}
trap 'kill_background; fm_test_cleanup' EXIT

# The stub answers its Nth call with the Nth word of FM_FAKE_HEADROOM_SEQ (the
# last word repeats): ok-normal | ok-warn | short | short-disk | error.
make_case() {  # <name> -> case dir with home/, fakebin/, headroom.log
  local case_dir="$TMP_ROOT/$1" fakebin
  mkdir -p "$case_dir/home/config" "$case_dir/home/state" "$case_dir/home/data"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/headroom.log"
  cat > "$fakebin/headroom-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_HEADROOM_LOG"
n=$(wc -l < "$FM_FAKE_HEADROOM_LOG" | tr -d ' ')
set -- $FM_FAKE_HEADROOM_SEQ
mode=${!#}
[ "$n" -gt "$#" ] || mode=${!n}
case "$mode" in
  ok-*)
    printf '{"ok":true,"line":"ok ram 9.0G disk 80.0G","ram":{"pressure":"%s","short":false},"disk":{"short":false}}\n' "${mode#ok-}"
    exit 0
    ;;
  short)
    printf '%s\n' '{"ok":false,"line":"short: ram 2.4G < 4.0G (pressure warn) · top: gradle-daemon [shared] 3.1G","ram":{"pressure":"warn","short":true},"disk":{"short":false}}'
    exit 1
    ;;
  short-disk)
    printf '%s\n' '{"ok":false,"line":"short: disk 9.0G < 20.0G","ram":{"pressure":"normal","short":false},"disk":{"short":true}}'
    exit 1
    ;;
  error)
    printf '%s\n' 'error: herdr pane list failed'
    exit 2
    ;;
esac
SH
  chmod +x "$fakebin/headroom-axi"
  printf '%s\n' "$case_dir"
}

run_gate() {  # <case-dir> <sequence> [args...]
  local case_dir=$1 seq=$2
  shift 2
  FM_HOME="$case_dir/home" FM_CONFIG_OVERRIDE='' \
    FM_FAKE_HEADROOM_SEQ="$seq" FM_FAKE_HEADROOM_LOG="$case_dir/headroom.log" \
    FM_HEADROOM_GATE_INTERVAL="${FM_HEADROOM_GATE_INTERVAL:-}" \
    PATH="$case_dir/fakebin:$PATH" "$GATE" "$@" 2>&1
}

calls() { wc -l < "$1/headroom.log" | tr -d ' '; }

# --- cases ------------------------------------------------------------------

test_no_declaration_says_go_without_measuring() {
  local case_dir out rc=0
  case_dir=$(make_case undeclared)
  out=$(run_gate "$case_dir" short) || rc=$?
  expect_code 0 "$rc" "an undeclared machine did not say go: $out"
  assert_equals "go: no headroom declaration on this machine" "$out" "an undeclared machine printed the wrong line"
  assert_equals 0 "$(calls "$case_dir")" "headroom-axi was asked without a declaration"
  rc=0
  run_gate "$case_dir" short --declared >/dev/null || rc=$?
  expect_code 1 "$rc" "--declared reported a declaration that does not exist"
  pass "a machine without a declaration says go and never measures"
}

test_headroom_ok_says_go() {
  local case_dir out rc=0
  case_dir=$(make_case ok)
  printf '%s\n' "min-ram 4G" "min-disk 20G" "pressure critical" > "$case_dir/home/config/spawn-headroom"
  out=$(run_gate "$case_dir" ok-warn) || rc=$?
  expect_code 0 "$rc" "a machine with headroom did not say go: $out"
  assert_equals "go: headroom ok" "$out" "a machine with headroom printed the wrong line"
  assert_equals "check --json --min-ram 4G --min-disk 20G" "$(cat "$case_dir/headroom.log")" \
    "headroom-axi was not asked with the declared thresholds"
  rc=0
  run_gate "$case_dir" ok-warn --declared >/dev/null || rc=$?
  expect_code 0 "$rc" "--declared missed an existing declaration"
  pass "a machine with headroom says go"
}

test_short_machine_says_wait_with_the_verdict_and_bound() {
  local case_dir out rc=0 since bound until
  case_dir=$(make_case short)
  printf '%s\n' "min-ram 4G" "max-wait 20" > "$case_dir/home/config/spawn-headroom"
  since=$(( $(date +%s) - 60 ))
  # The bound is since + max-wait, rounded up to the minute.
  bound=$(( (since + 1200 + 59) / 60 * 60 ))
  until=$(date -u -r "$bound" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$bound" +%Y-%m-%dT%H:%MZ)
  out=$(run_gate "$case_dir" short --since "$since") || rc=$?
  expect_code "$WAIT_EXIT" "$rc" "a short machine did not say wait: $out"
  assert_equals "wait: machine headroom is short - headroom-axi: short: ram 2.4G < 4.0G (pressure warn) · top: gradle-daemon [shared] 3.1G until $until" "$out" \
    "the wait line did not carry headroom-axi's verdict and the max-wait bound"
  assert_equals 1 "$(calls "$case_dir")" "a gate without --wait measured more than once"
  pass "a short machine says wait, carrying the verdict and the latest time it will wait"
}

test_wait_returns_go_once_headroom_frees() {
  local case_dir out rc=0
  case_dir=$(make_case frees)
  printf '%s\n' "min-ram 4G" > "$case_dir/home/config/spawn-headroom"
  out=$(FM_HEADROOM_GATE_INTERVAL=10 run_gate "$case_dir" "short ok-normal" --wait 30) || rc=$?
  expect_code 0 "$rc" "the bounded wait did not return go once headroom freed: $out"
  assert_equals "go: headroom ok" "$out" "the bounded wait printed the wrong line"
  assert_equals 2 "$(calls "$case_dir")" "the bounded wait did not re-measure exactly once"
  pass "a bounded wait returns go as soon as a re-measurement finds headroom"
}

test_wait_ends_with_wait_when_its_seconds_elapse() {
  local case_dir out rc=0
  case_dir=$(make_case elapses)
  printf '%s\n' "min-ram 4G" > "$case_dir/home/config/spawn-headroom"
  out=$(run_gate "$case_dir" short --wait 3) || rc=$?
  expect_code "$WAIT_EXIT" "$rc" "a bounded wait on a still-short machine did not end with wait: $out"
  assert_contains "$out" "wait: machine headroom is short" "the elapsed wait printed the wrong line"
  assert_equals 2 "$(calls "$case_dir")" "the bounded wait did not measure at its start and at its end"
  pass "a bounded wait on a machine that stays short ends with wait for the worker to rerun"
}

# A worker that has waited max-wait minutes starts its work anyway, so waiting
# workers whose idle build daemons hold the memory cannot starve each other.
test_max_wait_prevents_starvation() {
  local case_dir out rc=0
  case_dir=$(make_case starve)
  printf '%s\n' "min-ram 4G" "max-wait 5" > "$case_dir/home/config/spawn-headroom"
  out=$(run_gate "$case_dir" short --since "$(( $(date +%s) - 301 ))") || rc=$?
  expect_code 0 "$rc" "a worker past max-wait was still told to wait: $out"
  assert_contains "$out" "go: waited 5 minute(s) for headroom, at least the declared max-wait of 5, so start the work anyway - headroom-axi: short:" \
    "the starvation bound did not name the wait and the verdict"
  rm "$case_dir/home/config/spawn-headroom"
  printf '%s\n' "min-ram 4G" > "$case_dir/home/config/spawn-headroom"
  rc=0
  out=$(run_gate "$case_dir" short --since "$(( $(date +%s) - 29 * 60 ))") || rc=$?
  expect_code "$WAIT_EXIT" "$rc" "the default max-wait ended before 30 minutes: $out"
  rc=0
  out=$(run_gate "$case_dir" short --since "$(( $(date +%s) - 30 * 60 ))") || rc=$?
  expect_code 0 "$rc" "the default max-wait did not end at 30 minutes: $out"
  pass "max-wait, 30 minutes by default, ends every wait so a worker is never starved"
}

# A missing or failing headroom-axi, or an unreadable declaration, says go and
# names the problem, as spawn admission admits in the same cases.
test_unmeasurable_machine_says_go_and_names_the_problem() {
  local case_dir out rc=0 bare
  case_dir=$(make_case unmeasured)
  printf '%s\n' "min-ram 4G" > "$case_dir/home/config/spawn-headroom"
  out=$(run_gate "$case_dir" error) || rc=$?
  expect_code 0 "$rc" "an erroring headroom-axi did not say go: $out"
  assert_equals "go: not measured - headroom-axi check failed with exit 2: error: herdr pane list failed" "$out" \
    "an erroring headroom-axi did not name the error"
  rm "$case_dir/fakebin/headroom-axi"
  bare=$(fm_test_base_path_sans "$PATH" headroom-axi)
  rc=0
  out=$(FM_HOME="$case_dir/home" PATH="$case_dir/fakebin:$bare" "$GATE" 2>&1) || rc=$?
  expect_code 0 "$rc" "a missing headroom-axi did not say go: $out"
  assert_equals "go: not measured - headroom-axi is not installed, so this machine's headroom was not measured" "$out" \
    "a missing headroom-axi did not name the problem"
  printf '%s\n' "min-ram 4G" "max-wait 0" > "$case_dir/home/config/spawn-headroom"
  rc=0
  out=$(FM_HOME="$case_dir/home" PATH="$case_dir/fakebin:$bare" "$GATE" 2>&1) || rc=$?
  expect_code 0 "$rc" "an unreadable declaration did not say go: $out"
  assert_contains "$out" "go: not measured - the headroom declaration is unreadable ($case_dir/home/config/spawn-headroom line 2 gives max-wait" \
    "an unreadable declaration did not name the problem"
  pass "a missing or failing headroom-axi or an unreadable declaration says go and names the problem"
}

# The declaration belongs to the machine: a local secondmate home's worker reads
# the root home's file.
test_secondmate_home_reads_the_root_declaration() {
  local case_dir mate out rc=0
  case_dir=$(make_case machine)
  mate="$case_dir/mate"
  mkdir -p "$mate/config" "$mate/state" "$mate/data"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$case_dir/home" > "$mate/.fm-secondmate-parent"
  printf '%s\n' "min-ram 4G" > "$case_dir/home/config/spawn-headroom"
  out=$(FM_HOME="$mate" FM_FAKE_HEADROOM_SEQ=short FM_FAKE_HEADROOM_LOG="$case_dir/headroom.log" \
    PATH="$case_dir/fakebin:$PATH" "$GATE" 2>&1) || rc=$?
  expect_code "$WAIT_EXIT" "$rc" "a secondmate home's worker ignored the root home's declaration: $out"
  pass "a local secondmate home's worker is gated by the root home's declaration"
}

test_usage_errors() {
  local case_dir out rc
  case_dir=$(make_case usage)
  for args in "--wait" "--wait 0" "--wait 1x" "--since soon" "--bogus"; do
    rc=0
    # shellcheck disable=SC2086 # each row is deliberately split into arguments.
    out=$(run_gate "$case_dir" ok-normal $args) || rc=$?
    expect_code 2 "$rc" "'$args' was not a usage error: $out"
  done
  rc=0
  out=$(env -u FM_HOME "$GATE" 2>&1) || rc=$?
  expect_code 2 "$rc" "a gate without FM_HOME did not refuse: $out"
  rc=0
  "$GATE" --help >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "--help failed"
  pass "malformed arguments and a missing FM_HOME are usage errors"
}

# --- build slots and the --run wrapper --------------------------------------

# Run the gate with stdout in <case>/out and stderr in <case>/err.
run_split() {  # <case-dir> <sequence> [args...]
  local case_dir=$1 seq=$2
  shift 2
  FM_HOME="$case_dir/home" FM_CONFIG_OVERRIDE='' \
    FM_FAKE_HEADROOM_SEQ="$seq" FM_FAKE_HEADROOM_LOG="$case_dir/headroom.log" \
    FM_HEADROOM_GATE_INTERVAL="${FM_HEADROOM_GATE_INTERVAL:-}" \
    PATH="$case_dir/fakebin:$PATH" "$GATE" "$@" > "$case_dir/out" 2> "$case_dir/err"
}

# Start a wrapper in the background; prints its pid once it holds its slot and
# runs its command. Callers run it in a command substitution, so the wrapper is
# not their child: they poll its pid rather than wait for it.
start_holder() {  # <case-dir> <seconds>
  local case_dir=$1 pid
  FM_HOME="$case_dir/home" FM_CONFIG_OVERRIDE='' \
    FM_FAKE_HEADROOM_SEQ=ok-normal FM_FAKE_HEADROOM_LOG="$case_dir/holder.log" \
    PATH="$case_dir/fakebin:$PATH" "$GATE" --run -- sleep "$2" >/dev/null 2>&1 &
  pid=$!
  BACKGROUND+=("$pid")
  for _ in $(seq 1 50); do
    [ -e "$case_dir/home/state/build-slots/holder.$pid" ] && break
    sleep 0.1
  done
  [ -e "$case_dir/home/state/build-slots/holder.$pid" ] || fail "the background wrapper $pid never took its slot"
  for _ in $(seq 1 100); do
    pgrep -x -P "$pid" sleep >/dev/null 2>&1 && break
    sleep 0.1
  done
  pgrep -x -P "$pid" sleep >/dev/null 2>&1 || fail "the background wrapper $pid never started its command"
  printf '%s\n' "$pid"
}

holders() { find "$1/home/state/build-slots" -name 'holder.*' ! -name '*.tmp' 2>/dev/null | wc -l | tr -d ' '; }

test_run_without_declaration_runs_the_command_and_keeps_its_status() {
  local case_dir rc=0
  case_dir=$(make_case run-undeclared)
  run_split "$case_dir" short --run -- sh -c 'echo built; exit 3' || rc=$?
  expect_code 3 "$rc" "the wrapper did not exit with the command's status"
  assert_equals "built" "$(cat "$case_dir/out")" "the wrapper changed the command's stdout"
  assert_equals "go: no headroom declaration on this machine" "$(cat "$case_dir/err")" \
    "the wrapper's go line did not go to stderr"
  pass "--run on an undeclared machine runs the command, keeping its output and exit status"
}

test_run_holds_a_slot_for_the_commands_whole_run() {
  local case_dir rc=0 slots
  case_dir=$(make_case run-slot)
  printf '%s\n' "min-ram 4G" "max-builds 1" > "$case_dir/home/config/spawn-headroom"
  slots="$case_dir/home/state/build-slots"
  # shellcheck disable=SC2016 # expanded by the command's own shell.
  run_split "$case_dir" ok-normal --run -- sh -c 'ls "$1"; printf "slot=%s\n" "$FM_BUILD_SLOT"' _ "$slots" || rc=$?
  expect_code 0 "$rc" "a wrapper with a free slot did not run its command: $(cat "$case_dir/err")"
  assert_contains "$(cat "$case_dir/out")" "holder." "the command ran without its slot held"
  assert_contains "$(cat "$case_dir/out")" "slot=$slots/holder." "the command did not see the slot it runs under"
  assert_equals "go: headroom ok, build slot taken of 1" "$(cat "$case_dir/err")" "the wrapper printed the wrong go line"
  assert_equals 0 "$(holders "$case_dir")" "the slot was not released when the command exited"
  pass "--run holds a build slot while its command runs and releases it when the command exits"
}

# Slots never pile up: a full machine makes every new build wait, even a worker
# past max-wait; a holder that was killed outright is reclaimed.
test_full_slots_make_builds_wait_even_past_max_wait() {
  local case_dir rc=0 holder child
  case_dir=$(make_case slots-full)
  printf '%s\n' "min-ram 4G" "max-builds 1" "max-wait 5" > "$case_dir/home/config/spawn-headroom"
  holder=$(start_holder "$case_dir" 30)
  run_split "$case_dir" ok-normal || rc=$?
  expect_code "$WAIT_EXIT" "$rc" "a check with every slot in use did not say wait: $(cat "$case_dir/out")"
  assert_contains "$(cat "$case_dir/out")" "wait: all 1 build slot(s) are in use - pid $holder (sleep 30 in " \
    "the wait line did not name the build holding the slot"
  rc=0
  run_split "$case_dir" ok-normal --run -- touch "$case_dir/ran" || rc=$?
  expect_code "$WAIT_EXIT" "$rc" "a wrapper with every slot in use did not say wait"
  assert_absent "$case_dir/ran" "a wrapper ran its command with every slot in use"
  rc=0
  run_split "$case_dir" short --since "$(( $(date +%s) - 3600 ))" --run -- touch "$case_dir/ran" || rc=$?
  expect_code "$WAIT_EXIT" "$rc" "a wrapper past max-wait took a slot that was not free"
  assert_absent "$case_dir/ran" "max-wait let a build start past the slot count"
  # Kill the wrapper outright before its command, so it cannot release.
  child=$(pgrep -x -P "$holder" sleep | head -n 1)
  kill -KILL "$holder" 2>/dev/null || true
  while kill -0 "$holder" 2>/dev/null; do sleep 0.1; done
  [ -z "$child" ] || kill -KILL "$child" 2>/dev/null || true
  assert_equals 1 "$(holders "$case_dir")" "the killed holder's record was not left behind to reclaim"
  rc=0
  run_split "$case_dir" ok-normal --run -- touch "$case_dir/ran" || rc=$?
  expect_code 0 "$rc" "the slot of a killed holder was not reclaimed: $(cat "$case_dir/err")"
  assert_present "$case_dir/ran" "the wrapper did not run once the dead holder's slot was reclaimed"
  assert_equals 0 "$(holders "$case_dir")" "the reclaimed slot was not released after the run"
  pass "full slots make every build wait, max-wait included, and a dead holder's slot is reclaimed"
}

# A holder record whose pid now belongs to another process is reclaimed.
test_reused_pid_does_not_keep_a_slot() {
  local case_dir rc=0 slots
  case_dir=$(make_case slots-reuse)
  printf '%s\n' "min-ram 4G" "max-builds 1" > "$case_dir/home/config/spawn-headroom"
  slots="$case_dir/home/state/build-slots"
  mkdir -p "$slots"
  printf '%s\n' "pid=$$" "identity=not this process" "since=1" "cwd=/x" "command=old build" > "$slots/holder.$$"
  run_split "$case_dir" ok-normal --run -- true || rc=$?
  expect_code 0 "$rc" "a slot held by a reused pid was not reclaimed: $(cat "$case_dir/err")"
  assert_absent "$slots/holder.$$" "the reused pid's record survived"
  pass "a slot whose pid now names a different process is reclaimed"
}

# Concurrent wrappers race for the slots; at no moment do more commands run
# than the declared count, and every wrapper eventually runs.
test_concurrent_wrappers_never_exceed_the_slots() {
  local case_dir runs n pid max=0 seen rc
  local -a pids=()
  case_dir=$(make_case slots-race)
  printf '%s\n' "min-ram 4G" "max-builds 2" > "$case_dir/home/config/spawn-headroom"
  runs="$case_dir/runs"
  mkdir -p "$runs"
  for n in 1 2 3 4; do
    # shellcheck disable=SC2016 # expanded by the command's own shell.
    FM_HEADROOM_GATE_INTERVAL=10 run_split "$case_dir" ok-normal --wait 60 --run -- \
      sh -c 'touch "$1/running.$$"; ls "$1" | grep -c "^running\." > "$1/seen.$$"; sleep 1; rm -f "$1/running.$$"' _ "$runs" &
    pids+=("$!")
    BACKGROUND+=("$!")
  done
  for pid in "${pids[@]}"; do
    rc=0
    wait "$pid" || rc=$?
    expect_code 0 "$rc" "a concurrent wrapper did not run its command"
  done
  assert_equals 4 "$(find "$runs" -name 'seen.*' | wc -l | tr -d ' ')" "not every concurrent wrapper ran its command"
  for seen in "$runs"/seen.*; do
    n=$(cat "$seen")
    [ "$n" -le "$max" ] || max=$n
  done
  assert_equals 2 "$max" "the commands did not run two at a time and never more"
  assert_equals 0 "$(holders "$case_dir")" "a concurrent wrapper left its slot held"
  pass "concurrent wrappers never run more commands at once than the declared slots"
}

test_nested_run_uses_the_outer_slot() {
  local case_dir rc=0
  case_dir=$(make_case slots-nested)
  printf '%s\n' "min-ram 4G" "max-builds 1" > "$case_dir/home/config/spawn-headroom"
  run_split "$case_dir" ok-normal --run -- "$GATE" --run -- touch "$case_dir/ran" || rc=$?
  expect_code 0 "$rc" "a nested wrapper did not run under the outer slot: $(cat "$case_dir/err")"
  assert_present "$case_dir/ran" "the nested command did not run"
  assert_contains "$(cat "$case_dir/err")" "go: headroom ok; running inside the build slot already held by pid " \
    "the nested wrapper did not say it runs under the outer slot"
  assert_equals 2 "$(calls "$case_dir")" "the nested wrapper was not measured for headroom"
  pass "a wrapper nested in another wrapper's command is measured but runs under the outer slot"
}

# A signal to the wrapper does not release the slot while its command still runs.
test_signalled_wrapper_keeps_its_slot_until_the_command_exits() {
  local case_dir holder
  case_dir=$(make_case slots-signal)
  printf '%s\n' "min-ram 4G" "max-builds 1" > "$case_dir/home/config/spawn-headroom"
  holder=$(start_holder "$case_dir" 3)
  kill -TERM "$holder"
  sleep 1
  kill -0 "$holder" 2>/dev/null || fail "the wrapper exited on TERM while its command still ran"
  assert_equals 1 "$(holders "$case_dir")" "the slot was released while its command still ran"
  for _ in $(seq 1 100); do
    kill -0 "$holder" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$holder" 2>/dev/null && fail "the wrapper did not exit once its command finished"
  assert_equals 0 "$(holders "$case_dir")" "the slot was not released once the command exited"
  pass "a signalled wrapper keeps its slot until its command exits"
}

# Short of memory, the gate stops idle build daemons before it decides to wait;
# short only of disk, it stops none.
test_short_memory_reaps_idle_daemons_before_waiting() {
  local case_dir daemon out rc=0 now log stamp
  case_dir=$(make_case reap)
  printf '%s\n' "min-ram 4G" "min-disk 20G" > "$case_dir/home/config/spawn-headroom"
  (exec -a "java -cp gradle-launcher.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 9.8.1" sleep 600) >/dev/null 2>&1 &
  daemon=$!
  BACKGROUND+=("$daemon")
  now=$(( $(date +%s) - 600 ))
  stamp=$( { date -r "$now" +%Y-%m-%dT%H:%M:%S.000%z 2>/dev/null || date -d "@$now" +%Y-%m-%dT%H:%M:%S.000%z; } )
  log="$case_dir/gradle/daemon/9.8.1/daemon-$daemon.out.log"
  mkdir -p "${log%/*}"
  printf '%s [INFO] [x] Received command: Build{id=b, currentDir=/w}.\n%s [INFO] [x] Marking the daemon as idle, address: [a]\n' \
    "$stamp" "$stamp" > "$log"
  out=$(GRADLE_USER_HOME="$case_dir/gradle" FM_DAEMON_REAP_DISABLE=0 FM_DAEMON_REAP_PIDS="$daemon" \
    run_gate "$case_dir" short-disk) || rc=$?
  expect_code "$WAIT_EXIT" "$rc" "a disk-short machine did not say wait: $out"
  kill -0 "$daemon" 2>/dev/null || fail "a disk-short machine stopped a build daemon"
  : > "$case_dir/headroom.log"
  rc=0
  out=$(GRADLE_USER_HOME="$case_dir/gradle" FM_DAEMON_REAP_DISABLE=0 FM_DAEMON_REAP_PIDS="$daemon" \
    FM_DAEMON_REAP_EXIT_WAIT=5 run_gate "$case_dir" "short ok-normal") || rc=$?
  expect_code 0 "$rc" "reaping an idle daemon did not free the machine: $out"
  assert_contains "$out" "reaped: idle Gradle 9.8.1 daemon $daemon" "the gate did not report the daemon it stopped"
  assert_contains "$out" "go: headroom ok after reaping 1 idle build daemon(s)" "the go line did not say reaping freed the machine"
  kill -0 "$daemon" 2>/dev/null && fail "the idle daemon still runs after the gate reaped it"
  assert_equals 2 "$(calls "$case_dir")" "the gate did not re-measure after reaping"
  pass "short of memory, the gate stops idle build daemons and re-measures before it waits"
}

test_max_builds_must_be_a_positive_count() {
  local case_dir out rc=0
  case_dir=$(make_case max-builds-bad)
  printf '%s\n' "min-ram 4G" "max-builds 0" > "$case_dir/home/config/spawn-headroom"
  out=$(run_gate "$case_dir" ok-normal) || rc=$?
  expect_code 0 "$rc" "an unreadable max-builds did not say go: $out"
  assert_contains "$out" "line 2 gives max-builds a number of builds that is not a positive integer" \
    "an unreadable max-builds did not name the problem"
  pass "a max-builds that is not a positive count makes the declaration unreadable"
}

test_no_declaration_says_go_without_measuring
test_headroom_ok_says_go
test_short_machine_says_wait_with_the_verdict_and_bound
test_wait_returns_go_once_headroom_frees
test_wait_ends_with_wait_when_its_seconds_elapse
test_max_wait_prevents_starvation
test_unmeasurable_machine_says_go_and_names_the_problem
test_secondmate_home_reads_the_root_declaration
test_usage_errors
test_run_without_declaration_runs_the_command_and_keeps_its_status
test_run_holds_a_slot_for_the_commands_whole_run
test_full_slots_make_builds_wait_even_past_max_wait
test_reused_pid_does_not_keep_a_slot
test_concurrent_wrappers_never_exceed_the_slots
test_nested_run_uses_the_outer_slot
test_signalled_wrapper_keeps_its_slot_until_the_command_exits
test_short_memory_reaps_idle_daemons_before_waiting
test_max_builds_must_be_a_positive_count
