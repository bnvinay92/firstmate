#!/usr/bin/env bash
# Behavior tests for the supervision host's park (bin/fm-supervision-host.sh,
# docs/supervision-host.md): its exit probing, boundary, test clock, and limit,
# the first cycle's status and owner options, the held-outcome cadence, and the
# stand-down of a host that does not own supervision.
# tests/supervision-host-helpers.sh owns the fixture homes, fake harness, and
# stub engine these cases share.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

test_park_exit_probe_uses_half_second_child_sleeps() {
  local home host_pid
  home=$(make_home park-cadence attended)
  cat > "$home/fakebin/sleep" <<'SH'
#!/bin/bash
pid=''
if [ -f "$FM_HOME/probe-host" ]; then
  IFS= read -r pid < "$FM_HOME/probe-host" || true
  if [ "$PPID" = "$pid" ]; then
    printf '%s\n' "$1" >> "$FM_HOME/park-sleeps"
  fi
fi
exec /bin/sleep "$@"
SH
  chmod +x "$home/fakebin/sleep"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "park-cadence: no watcher started"
  host_pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
  [ -n "$host_pid" ] || fail "park-cadence: no recorded host"
  printf '%s\n' "$host_pid" > "$home/probe-host"
  wait_until 100 test -s "$home/park-sleeps" || fail "park-cadence: no child sleep observed"
  [ "$(sort -u "$home/park-sleeps")" = 0.5 ] || fail "park-cadence: exit probing did not use half-second sleeps"
  stop_home_processes "$home"
  pass "host: parked child-exit sampling uses ordinary half-second sleeps"
}

test_park_boundary_ends_the_park_before_the_hook_timeout() {
  local home token
  home=$(make_home boundary attended)
  # The wall-clock bound must sit past the exit check: only the injected clock
  # can reach the boundary in time, so a host ignoring it fails instead of
  # passing on real elapsed seconds.
  FM_SUPERVISION_HOST_PARK_SECONDS=60 FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "boundary: the host never started a watcher cycle"
  echo 60 > "$home/park-clock"
  wait_until 150 host_exited "$home" || fail "boundary: the host did not end its park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "the park boundary must reach main as a host line"
  watcher_live "$home" && fail "the park boundary left the watcher running"
  token=$(cat "$home/state/.watcher-down")
  case "$token" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "the park boundary must publish downtime for the owner's rewake, got: $token" ;;
  esac
  pass "host: the park ends itself with a boundary wake and a stopped watcher"
}

# A close that lands while a turn is running can only wait: the host ends its
# park at the bound regardless of how many closes are queued behind it. The
# park runs on the test clock (FM_TEST_SUPERVISION_HOST_CLOCK), which the test
# moves to the refusal window's opening (park bound minus the turn bound and
# grace) before it releases the held turn, so the second close can never take
# a turn of its own on any machine speed. The bound also stays well past every
# wall-clock check in the case: a host that ignored the test clock would start
# the second turn instead of silently passing at a wall-clock boundary.
test_park_boundary_holds_under_back_to_back_closes() {
  # The turn bound is the one wall-clock bound left: it must cover the stub's
  # report work after release, so the product never kills the held turn.
  local home park=300 turn=19 grace=1
  home=$(make_home boundary-busy away)
  echo held > "$home/stub-mode"
  mkfifo "$home/stub-release"
  echo 0 > "$home/park-clock"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=$park \
    FM_SUPERVISION_HOST_TURN_TIMEOUT=$turn FM_SUPERVISION_ENGINE_GRACE=$grace start_host "$home"
  wait_until 150 watcher_live "$home" || fail "boundary-busy: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'the first of many'
  wait_until 450 sh -c '[ -e "$1/engine-call.1" ] || [ -s "$1/host.rc" ]' _ "$home" \
    || fail "boundary-busy: the host never started the first turn: $(cat "$home/host.out" "$home/state/.supervision-host.log" 2>/dev/null)"
  [ -e "$home/engine-call.1" ] \
    || fail "boundary-busy: the host exited without starting the first turn: $(cat "$home/host.out" "$home/state/.supervision-host.log" 2>/dev/null)"
  append_status "$home" 'queued while the first close is still handled'
  echo $((park - turn - grace)) > "$home/park-clock"
  exec 3<> "$home/stub-release"
  printf 'release\n' >&3
  wait_until 450 host_exited "$home" \
    || fail "the host kept handling back-to-back closes past its park boundary: $(cat "$home/state/.supervision-host.log")"
  exec 3>&-
  ! grep -q '	failed	' "$home/state/.supervision-host.log" \
    || fail "the held turn hit its turn bound or failed: $(cat "$home/state/.supervision-host.log")"
  [ "$(handled_count "$home")" -eq 1 ] || fail "the held turn did not complete once released: $(cat "$home/state/.supervision-host.log")"
  [ ! -e "$home/engine-call.2" ] || fail "a close waiting at the boundary still got an engine turn"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "the park boundary must reach main as a host line"
  [ "$(tail -n 1 "$home/host.out")" = "$(grep '^supervision-host: cycle boundary - ' "$home/host.out")" ] \
    || fail "a close read at the boundary must be printed ahead of the boundary line: $(cat "$home/host.out")"
  assert_grep 'demo.status' "$home/state/.wake-queue" "a close waiting at the boundary must stay queued for main"
  watcher_live "$home" && fail "the park boundary left the watcher running"
  pass "host: waiting closes cannot carry the park past its boundary"
}

# Rendering the wake prompt runs after the successor cycle has started; the
# shim holds the render on a FIFO, and the test moves the park's test clock to
# the refusal window's opening before releasing it, so the close passes the
# arrival check and the pre-turn recheck must refuse on any machine speed. The
# snapshot proves the successor arm it started can be checked afterwards. The
# park bound stays past the case's wall-clock checks, so an ignored test clock
# would let the turn run and the engine-call assertions catch it.
test_park_boundary_rechecked_just_before_the_engine_turn() {
  local home real_node pid park=120 turn=3 grace=1
  home=$(make_home boundary-late away)
  real_node=$(command -v node)
  mkfifo "$home/render-release"
  echo 0 > "$home/park-clock"
  cat > "$home/fakebin/node" <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = wake-prompt ]; then
  cp "\$FM_HOME/state/.supervision-host" "\$FM_HOME/host-record-at-render" 2>/dev/null
  read -r _ < "\$FM_HOME/render-release"
fi
exec "$real_node" "\$@"
SH
  chmod +x "$home/fakebin/node"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=$park \
    FM_SUPERVISION_HOST_TURN_TIMEOUT=$turn FM_SUPERVISION_ENGINE_GRACE=$grace start_host "$home"
  wait_until 150 watcher_live "$home" || fail "boundary-late: the host never started a watcher cycle"
  append_status "$home" 'arrives with just enough margin'
  wait_until 300 sh -c '[ -s "$1/host-record-at-render" ] || [ -s "$1/host.rc" ]' _ "$home" \
    || fail "boundary-late: the host neither reached the wake render nor exited: $(cat "$home/host.out" "$home/state/.supervision-host.log" 2>/dev/null)"
  [ -s "$home/host-record-at-render" ] \
    || fail "the close was stopped before the successor started: $(cat "$home/host.out")"
  echo $((park - turn - grace)) > "$home/park-clock"
  exec 3<> "$home/render-release"
  printf 'release\n' >&3
  wait_until 300 host_exited "$home" || fail "boundary-late: the host did not end its park"
  exec 3>&-
  assert_re '^signal: .*demo.status' "$home/host.out" "the close read at the boundary must reach main"
  [ "$(tail -n 1 "$home/host.out")" = "$(grep '^supervision-host: cycle boundary - ' "$home/host.out")" ] \
    || fail "the close must be printed ahead of the boundary line: $(cat "$home/host.out")"
  ! ls "$home"/engine-call.* >/dev/null 2>&1 || fail "an engine turn started that could run past the boundary"
  assert_no_re '	(handled|failed)	turn=' "$home/state/.supervision-host.log" "no engine turn may be logged"
  assert_grep 'demo.status' "$home/state/.wake-queue" "a close refused at the boundary must stay queued for main"
  while IFS= read -r pid; do
    kill -0 "$pid" 2>/dev/null && fail "the boundary left the successor arm $pid running"
  done < <(awk -F '\t' '$1 == "arm" { print $2 }' "$home/host-record-at-render")
  watcher_live "$home" && fail "the boundary left the watcher running"
  pass "host: a close whose margin runs out while the successor starts reaches main at the boundary without a turn"
}

# A leaked test clock in a real primary's environment must stay inert: the
# host reads it only alongside the FM_TEST_SEAM marker that test suites set.
test_park_test_clock_requires_the_marker() {
  local home
  home=$(make_home clock-armed away)
  echo 99999 > "$home/park-clock"
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 host_exited "$home" || fail "clock-armed: the marked test clock did not end the park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "the marked test clock must drive the boundary"

  home=$(make_home clock-unmarked away)
  echo 99999 > "$home/park-clock"
  FM_TEST_SEAM='' FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" start_host "$home"
  wait_until 150 watcher_live "$home" || fail "clock-unmarked: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'handled on the wall clock'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "a test clock without FM_TEST_SEAM changed the park: $(cat "$home/host.out" "$home/state/.supervision-host.log")"
  [ ! -s "$home/host.rc" ] || fail "a test clock without FM_TEST_SEAM ended the park: $(cat "$home/host.out")"
  assert_no_re 'cycle boundary' "$home/host.out" "a test clock without FM_TEST_SEAM reached the boundary"
  pass "host: the park's test clock is inert without the test marker"
}

# A park at or beyond the hook registration is refused for the default. The
# default is observable through the pre-turn margin: a turn bound plus grace of
# 27000 seconds crosses a 27000-second park, so the close goes to main at the
# boundary, while under a 28799-second park the same turn runs.
park_outcome() {  # <name> <park-seconds>; sets PARK_OUTCOME to boundary or handled
  local home
  home=$(make_home "$1" away)
  FM_SUPERVISION_HOST_PARK_SECONDS=$2 FM_SUPERVISION_HOST_TURN_TIMEOUT=26990 FM_SUPERVISION_ENGINE_GRACE=10 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "$1: the host never started a watcher cycle"
  append_status "$home" 'one close'
  wait_until 250 sh -c '[ -s "$1/host.rc" ] || grep -q "	handled	" "$1/state/.supervision-host.log" 2>/dev/null' _ "$home" \
    || fail "$1: the close was neither handled nor handed to main: $(cat "$home/state/.supervision-host.log")"
  if host_exited "$home"; then
    grep -q '^supervision-host: cycle boundary - ' "$home/host.out" || fail "$1: the host exited without the boundary: $(cat "$home/host.out")"
    ! ls "$home"/engine-call.* >/dev/null 2>&1 || fail "$1: an engine turn ran before the boundary exit"
    PARK_OUTCOME=boundary
  else
    kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
    wait_until 200 host_exited "$home" || fail "$1: the host did not stop on TERM"
    PARK_OUTCOME=handled
  fi
}

test_park_seconds_at_or_beyond_the_hook_registration_fall_back_to_the_default() {
  park_outcome park-28799 28799
  [ "$PARK_OUTCOME" = handled ] || fail "a park just under the registration must be honored"
  park_outcome park-28800 28800
  [ "$PARK_OUTCOME" = boundary ] || fail "a park at the registration must fall back to the default"
  park_outcome park-huge 100000000000000000000
  [ "$PARK_OUTCOME" = boundary ] || fail "a park far beyond the registration must fall back to the default"
  pass "host: a park at or beyond the Stop-hook registration falls back to the default boundary"
}

# An owner whose own bound is the park lets a turn run past the boundary up to
# its limit; a limit below the boundary or at the registration is the boundary.
test_park_limit_lets_a_turn_outlive_the_boundary() {
  local cases name limit want home
  cases='limit-later:28000:handled limit-earlier:50:boundary limit-registration:28800:boundary limit-absent::boundary'
  for c in $cases; do
    name=${c%%:*}; limit=${c#*:}; want=${limit#*:}; limit=${limit%%:*}
    home=$(make_home "$name" away)
    FM_SUPERVISION_HOST_PARK_SECONDS=100 FM_SUPERVISION_HOST_PARK_LIMIT=$limit FM_SUPERVISION_HOST_TURN_TIMEOUT=200 \
      FM_SUPERVISION_ENGINE_GRACE=10 start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$name: the host never started a watcher cycle"
    append_status "$home" 'one close'
    wait_until 250 sh -c '[ -s "$1/host.rc" ] || grep -q "	handled	" "$1/state/.supervision-host.log" 2>/dev/null' _ "$home" \
      || fail "$name: the close was neither handled nor handed to main: $(cat "$home/state/.supervision-host.log")"
    if host_exited "$home"; then
      grep -q '^supervision-host: cycle boundary - ' "$home/host.out" || fail "$name: the host exited without the boundary: $(cat "$home/host.out")"
      [ "$want" = boundary ] || fail "$name: a turn inside the owner's limit was refused at the boundary"
    else
      [ "$want" = handled ] || fail "$name: a turn past the boundary ran without a later limit"
      kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
      wait_until 200 host_exited "$home" || fail "$name: the host did not stop on TERM"
    fi
  done
  pass "host: an owner's later park limit lets a turn outlive the boundary, and no other limit does"
}

# The first cycle's status line reaches the owner before any close and only
# once; --restart replaces a watcher it would otherwise attach to, and the
# owner's predecessor arm makes the first cycle a handling successor. The home
# names no usable engine, so every attended close passes straight to main.
test_first_cycle_status_streams_and_owner_options_reach_it() {
  local home stale fresh generation predecessor
  home=$(make_home stream attended pi)
  start_host "$home"
  wait_until 150 grep -qs '^watcher: started pid=' "$home/host.out" \
    || fail "stream: the first cycle's status did not reach the owner before a close: $(cat "$home/host.out")"
  host_exited "$home" && fail "stream: the host exited before any close: $(cat "$home/host.out")"
  append_status "$home" 'fixture finished' 'done'
  wait_until 200 host_exited "$home" || fail "stream: the attended close did not reach main"
  [ "$(grep -c '^watcher: ' "$home/host.out")" -eq 1 ] || fail "stream: the status line must be printed once: $(cat "$home/host.out")"
  [ "$(sed -n '1p' "$home/host.out" | cut -c1-17)" = 'watcher: started ' ] || fail "stream: the status line must come first"
  assert_re '^signal: .*demo.status' "$home/host.out" "stream: the close must follow the status line"
  # Main handles that close, so the next cycle has no episode to resurface.
  FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$home/drain.err" || fail "stream: main's drain failed"
  ack_drain_err "$home/state" "$home/drain.err" >/dev/null 2>&1 || fail "stream: main's acknowledgement failed: $(cat "$home/drain.err")"
  # Pass-through can leave a successor watcher running. Retire that cycle so
  # the orphan-arm fixture below owns the watcher we later ask --restart to replace.
  FM_HOME="$home" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null || fail "stream: could not stop the prior cycle"

  # A watcher a dead arm left behind, holding this home's watcher lock.
  FM_HOME="$home" PATH="$home/fakebin:$PATH" perl -e 'setpgrp(0, 0); exec @ARGV' "$ROOT/bin/fm-watch-arm.sh" \
    > "$home/stale-arm.out" 2>&1 &
  wait_until 150 grep -qs '^watcher: started pid=' "$home/stale-arm.out" \
    || fail "stream: the fixture arm never started its watcher: $(cat "$home/stale-arm.out")"
  wait_until 150 watcher_live "$home" || fail "stream: the fixture watcher never started"
  kill -KILL "$!" 2>/dev/null || true
  wait "$!" 2>/dev/null || true
  stale=$(cat "$home/state/.watch.lock/pid")
  rm -f "$home/host.out" "$home/host.rc"
  start_host "$home" --restart
  # Stopping the old watcher opens a downtime episode, so the fresh cycle may
  # close on its resurface before the arm confirms it, and the arm then prints
  # only that close (bin/fm-watch-arm.sh): either order is the owner's cycle.
  wait_until 150 sh -c 'grep -qs "^watcher: started pid=" "$1/host.out" || [ -s "$1/host.rc" ]' _ "$home" \
    || fail "stream: the restarting host never reported its cycle: $(cat "$home/host.out" "$home/claude.err" 2>/dev/null)"
  fresh=$(sed -n 's/^watcher: started pid=\([0-9]*\).*/\1/p' "$home/host.out")
  [ "$fresh" != "$stale" ] || fail "stream: --restart attached to the watcher it should have replaced"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$stale" || fail "stream: --restart left the old watcher running"
  wait_until 200 host_exited "$home" || append_status "$home" 'second close' 'done'
  wait_until 200 host_exited "$home" || fail "stream: the restarting host's close did not reach main"
  assert_re '^(signal: .*demo.status|check: rearm-resurface)$' "$home/host.out" "stream: the restarting host's close must reach main"

  # That close left an unacknowledged downtime episode; a host the owner starts
  # as the closed arm's successor takes it over as a handling successor
  # instead of re-announcing it.
  generation=$(sed -n 's/^[a-z]*:[a-z]*://p' "$home/state/.watcher-down")
  [ -n "$generation" ] || fail "fixture: the close left no downtime episode: $(cat "$home/state/.watcher-down")"
  predecessor=$(sed -n '1p' "$home/claude-pids")
  rm -f "$home/host.out" "$home/host.rc"
  FM_WATCH_PREDECESSOR_ARM_PID=$predecessor start_host "$home" --restart
  wait_until 150 grep -qs '^watcher: started pid=' "$home/host.out" || fail "stream: the successor host never reported its cycle"
  assert_re "^watcher: started pid=[0-9]+ \\(beacon fresh\\) recovery-generation=$generation\$" "$home/host.out" \
    "the owner's predecessor must make the first cycle a handling successor of the pending generation"
  sleep 3
  host_exited "$home" && fail "a handling successor re-announced the pending episode: $(cat "$home/host.out")"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "stream: the successor host did not stop on TERM"
  pass "host: the first cycle's status streams once, --restart replaces a stale watcher, and an owner predecessor makes a handling successor"
}

# The 2026-09-25 away-window flood: a held, green PR on a finished task was
# re-escalated on every inactive-outcome cadence, because the branch
# acknowledgement consumed the check row but left its terminal-outcome receipt
# pending, so each later scan re-queued the same fingerprint. Through the real
# watcher cadence, host, report surface, and drain, that unchanged situation
# now reaches the captain exactly once, and a new event on the same task - a
# decision - still reaches the captain path afterwards.
scan_marker_age() {  # <home> -> seconds since the last inactive-outcome scan
  perl -e 'my @s = stat $ARGV[0] or exit 1; print time - $s[9]' "$1/state/.inactive-outcome-reconcile"
}

scan_ran() { [ "$(scan_marker_age "$1" 2>/dev/null || echo 999999)" -lt 60 ]; }

scan_idle() {  # <home>
  [ ! -e "$1/state/.inactive-outcome-reconcile.lock" ] && [ ! -L "$1/state/.inactive-outcome-reconcile.lock" ]
}

captain_rows() {  # <home>
  local rows
  rows=$(grep -c '"verdict":"captain"' "$1/state/branch-outcomes.jsonl" 2>/dev/null)
  printf '%s\n' "${rows:-0}"
}

captain_rows_at_least() { [ "$(captain_rows "$1")" -ge "$2" ]; }

flood_signal() {  # <home>
  captain_rows_at_least "$1" 2 || grep -qs '	inactive-outcome:' "$1/state/.wake-queue"
}

test_unchanged_held_outcome_reaches_the_captain_once_until_a_new_event() {
  local home cycle old pid watcher
  home=$(make_home away-held-once away)
  echo captain > "$home/stub-mode"
  mkdir -p "$home/projects/held"
  git -C "$home/projects/held" init -q
  git -C "$home/projects/held" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m init
  fm_write_meta "$home/state/held.meta" \
    'window=fm-held' "worktree=$home/projects/held" "project=$home/projects/held" \
    'harness=claude' 'kind=ship' 'mode=no-mistakes' 'yolo=off' 'spawn_gen=g1' \
    'pr=https://example.test/o/r/pull/153'
  printf 'done: PR https://example.test/o/r/pull/153 open, green, mergeable\n' > "$home/state/held.status"
  old=$(( $(date +%s) - 600 ))
  perl -e 'my $t = shift; utime $t, $t, @ARGV or exit 1' "$old" \
    "$home/state/held.meta" "$home/state/held.status" \
    || fail "fixture: could not age the held task's records"
  prime_status_seen "$home/state" "$home/state/held.status"

  export FM_FAKE_CREW_STATE_held='state: done · source: fake'
  export FM_INACTIVE_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" FM_INACTIVE_RECONCILE_SECS=60
  start_host "$home"
  wait_until 250 captain_rows_at_least "$home" 1 \
    || fail "held: the first cadence never escalated the held outcome: $(cat "$home/state/.supervision-host.log" 2>/dev/null)"
  assert_grep 'child=held' "$home/state/branch-outcomes.jsonl" "held: the escalation did not name the held task's outcome: $(cat "$home"/engine-drain.* "$home/state/.supervision-host.log")"
  wait_until 150 handled_at_least "$home" 1 || fail "held: the escalating turn never finished"
  assert_no_grep '	inactive-outcome:' "$home/state/.wake-queue" "held: the branch acknowledgement left the presentation row queued"

  for cycle in 1 2 3 4; do
    old=$(( $(date +%s) - 120 ))
    perl -e 'my $t = shift; utime $t, $t, @ARGV or exit 1' "$old" "$home/state/.inactive-outcome-reconcile" \
      || fail "held: could not age the scan marker before cadence $cycle"
    wait_until 150 scan_ran "$home" || fail "held: cadence $cycle never rescanned"
    wait_until 150 scan_idle "$home" || fail "held: cadence $cycle never finished its scan"
    ! wait_until 10 flood_signal "$home" \
      || fail "held: cadence $cycle re-escalated the unchanged held outcome: $(cat "$home/state/branch-outcomes.jsonl")"
  done
  [ "$(captain_rows "$home")" -eq 1 ] || fail "held: the unchanged situation reached the captain $(captain_rows "$home") times"
  [ -s "$home/host.rc" ] && fail "held: the host handed a wake to main: $(cat "$home/host.out")"

  printf 'needs-decision [key=merge-153]: merge PR 153 now or hold it for the return?\n' >> "$home/state/held.status"
  wait_until 250 captain_rows_at_least "$home" 2 \
    || fail "held: the new decision never reached the captain path: $(cat "$home/state/branch-outcomes.jsonl")"
  [ "$(captain_rows "$home")" -eq 2 ] || fail "held: the decision escalated $(captain_rows "$home") rows, not one"
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" list --recent 1 | sed -n 's/.*"task":"\([^"]*\)".*"verdict":"\([a-z]*\)".*/\1 \2/p')" = 'held captain' ] \
    || fail "held: the decision was not recorded as a captain outcome for the held task: $(cat "$home/state/branch-outcomes.jsonl")"
  unset FM_FAKE_CREW_STATE_held FM_INACTIVE_CREW_STATE_BIN FM_INACTIVE_RECONCILE_SECS
  # Stop the host and its watcher here, so no cadence scan is still writing
  # into this home while the suite's cleanup removes it.
  pid=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -TERM "$pid"
  wait_until 200 host_exited "$home" || fail "held: the host did not stop on TERM"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" || fail "held: a stopped host left its watcher running"
  pass "host: an unchanged held outcome reaches the captain once across cadences, and a later decision on the task still does"
}

test_unverified_engine_hands_every_away_wake_to_main() {
  local home
  home=$(make_home no-engine away 'pi')
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "no engine: the host never started a watcher cycle"
  append_status "$home" 'anything'
  wait_until 200 host_exited "$home" || fail "no engine: the wake did not reach main"
  assert_re "^supervision-host: no supervision engine runs here: config/supervision-host names 'pi', which is not a verified supervision engine" \
    "$home/host.out" "an unverified engine must be named on the wake it hands to main"
  ! ls "$home"/engine-call.* >/dev/null 2>&1 || fail "no engine: an engine ran"
  pass "host: a home naming an unverified engine hands every away wake to main with the reason"
}

test_host_outside_the_lock_owner_stands_down() {
  local home out rc other
  home=$(make_home not-owner attended)
  "$FAKE_CLAUDE" -c 'sleep 30' &
  other=$!
  printf '%s\n' "$other" >> "$home/claude-pids"
  printf '%s\n' "$other" > "$home/state/.lock"
  out=$(FM_HOME="$home" PATH="$home/fakebin:$PATH" "$HOST" park 2>&1); rc=$?
  expect_code 0 "$rc" "a host that does not own supervision exits 0"
  assert_contains "$out" "supervision-host stood down: this session does not own supervision" "the stand-down must say why"
  watcher_live "$home" && fail "a host that does not own supervision started a watcher"
  kill -TERM "$other" 2>/dev/null || true
  pass "host: a host outside the session-lock owner stands down without arming"
}

test_superseded_host_leaves_the_owner_untouched() {
  local home owner watcher lock_pid
  home=$(make_home superseded away)
  # One fake harness runs the owner host, then, on a signal file, a second host
  # under an auto-arm generation the ledger has already superseded.
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
    "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
      "$0" park > "$FM_HOME/host.out" 2>&1 &
      while [ ! -e "$FM_HOME/go-second" ]; do sleep 0.1; done
      FM_SUPERVISION_HOST_AUTOARM_GEN=1 FM_SUPERVISION_HOST_OWNER_PID=$$ "$0" park > "$FM_HOME/host2.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/host2.rc"
      wait
    ' "$HOST" 2>> "$home/claude.err" &
  wait_until 150 watcher_live "$home" || fail "superseded: the owner host never started a watcher cycle"
  owner=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  lock_pid=$(cat "$home/state/.lock")
  printf 'epoch=2 owner_pid=%s outcome=arming\n' "$lock_pid" > "$home/state/.claude-autoarm-epoch"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID="$lock_pid" "$LEASE" claim demo >/dev/null 2>&1 \
    || fail "fixture: could not hold a branch lease"
  : > "$home/go-second"
  wait_until 200 sh -c '[ -s "$1" ]' _ "$home/host2.rc" || fail "superseded: the second host did not return"
  expect_code 0 "$(cat "$home/host2.rc")" "a superseded host exits 0"
  assert_grep 'supervision-host stood down: this session does not own supervision' "$home/host2.out" "the stand-down must say why"
  kill -0 "$owner" 2>/dev/null || fail "a superseded host stopped the owner host"
  [ "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")" = "$owner" ] \
    || fail "a superseded host took the owner's host record"
  if [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null)" != "$watcher" ] || ! kill -0 "$watcher" 2>/dev/null; then
    fail "a superseded host stopped the owner's watcher"
  fi
  FM_HOME="$home" "$LEASE" check demo 2>/dev/null | grep -q '^branch ' || fail "a superseded host released the owner's branch leases"
  kill -TERM "$owner"
  wait_until 200 sh -c '! kill -0 "$1" 2>/dev/null && ! kill -0 "$2" 2>/dev/null' _ "$owner" "$watcher" \
    || fail "superseded: the owner host did not stop on TERM"
  pass "host: a host under a superseded auto-arm generation stands down without touching the owner"
}

run_case test_park_exit_probe_uses_half_second_child_sleeps
run_case test_park_boundary_ends_the_park_before_the_hook_timeout
run_case test_park_boundary_holds_under_back_to_back_closes
run_case test_park_boundary_rechecked_just_before_the_engine_turn
run_case test_park_test_clock_requires_the_marker
run_case test_park_seconds_at_or_beyond_the_hook_registration_fall_back_to_the_default
run_case test_park_limit_lets_a_turn_outlive_the_boundary
run_case test_first_cycle_status_streams_and_owner_options_reach_it
run_case test_unchanged_held_outcome_reaches_the_captain_once_until_a_new_event
run_case test_unverified_engine_hands_every_away_wake_to_main
run_case test_host_outside_the_lock_owner_stands_down
run_case test_superseded_host_leaves_the_owner_untouched
