#!/usr/bin/env bash
# Behavior tests for bin/fm-headroom-gate.sh, the check a running worker makes
# before heavy local work: it says go or wait from the machine's
# config/spawn-headroom and headroom-axi's verdict, waits boundedly, and never
# starves a worker past max-wait.
#
# Every case runs the real script against a temporary Firstmate home and a stub
# headroom-axi that logs each call and answers from a per-call sequence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-headroom-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-headroom-gate)
WAIT_EXIT=75

# The stub answers its Nth call with the Nth word of FM_FAKE_HEADROOM_SEQ (the
# last word repeats): ok-normal | ok-warn | short | error.
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

test_no_declaration_says_go_without_measuring
test_headroom_ok_says_go
test_short_machine_says_wait_with_the_verdict_and_bound
test_wait_returns_go_once_headroom_frees
test_wait_ends_with_wait_when_its_seconds_elapse
test_max_wait_prevents_starvation
test_unmeasurable_machine_says_go_and_names_the_problem
test_secondmate_home_reads_the_root_declaration
test_usage_errors
