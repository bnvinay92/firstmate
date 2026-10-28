#!/usr/bin/env bash
# Pin the recovery-loop fix: a handling successor keeps supervising instead of
# going blind.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)

# T2: a handling successor must enter its poll loop and surface a real crew
# event within a bounded startup-and-poll budget instead of sitting in a
# pre-loop wait that refreshes the liveness beacon and then exits with a
# synthetic rearm-resurface.
test_handling_successor_does_not_go_blind() {
  local dir home state fakebin child event_start now out
  dir=$(make_case recovery-gap-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  sleep 0.4
  printf 'done: crew finished its task\n' >> "$state/crew.status"
  event_start=$(date +%s)
  now=0
  while [ "$now" -lt 20 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within the bounded startup-and-poll budget (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
  fi
  grep -F 'crew.status' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not name the crew status file: $(cat "$out")"; }
  grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not enqueue a durable row for the crew event"; }
  ! grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor emitted synthetic recovery instead of supervising: $(cat "$out")"; }
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T2_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T2_QUEUE_ROW=%s\n' "$(grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" | tail -1)"
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a resurfacing handling successor stays alive and supervises instead of going blind"
}

# T3: a row appended after the predecessor closes but before its handling
# successor can inspect the queue must survive the handoff and reach main.
test_handling_successor_resurfaces_a_row_appended_during_startup() {
  local dir home state fakebin child blocker now out
  dir=$(make_case recovery-startup-append)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  printf 'pending:downtime:later.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  printf '%s\t1\tstale\tfm-demo\tstale: fm-demo (the delivered wake)\n' "$(date +%s)" > "$state/.wake-queue"
  printf '1\n' > "$state/.wake-queue.seq"
  out="$dir/watch.out"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1
    : > "$2/queue-held"
    while [ ! -e "$2/append-now" ]; do sleep 0.02; done
    fm_wake_append_locked check inbox:n1 "check: captain inbox note n1 - from Basecamp" || exit 1
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" &
  blocker=$!
  now=0
  while [ "$now" -lt 100 ] && [ ! -e "$state/queue-held" ]; do
    sleep 0.02
    now=$((now + 1))
  done
  [ -e "$state/queue-held" ] || { kill "$blocker" 2>/dev/null || true; fail "fixture: queue lock was not held"; }

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" "$blocker" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  : > "$state/append-now"
  wait "$blocker" || { kill -TERM "$child" 2>/dev/null || true; fail "fixture: startup append failed"; }
  now=0
  while [ "$now" -lt 40 ] && [ ! -e "$state/.last-watcher-beat" ]; do
    sleep 0.1
    now=$((now + 1))
  done
  [ -e "$state/.last-watcher-beat" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "fixture: handling successor never finished startup"; }
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_recovery_marker_begin_handling "$2/.watcher-down" later.1.aaa || exit 1
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1
    awk -F "\t" "\$2 != 1" "$FM_WAKE_QUEUE" > "$FM_WAKE_QUEUE.tmp" \
      && mv -f "$FM_WAKE_QUEUE.tmp" "$FM_WAKE_QUEUE" || exit 1
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    fm_recovery_marker_handling_settled "$2/.watcher-down"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "fixture: handled-turn settlement failed"; }

  now=0
  while [ "$now" -lt 40 ] && kill -0 "$child" 2>/dev/null; do
    sleep 0.25
    now=$((now + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor never resurfaced the startup-window row: $(cat "$out"; cat "$state/.watcher-down")"
  fi
  wait "$child" 2>/dev/null || true
  [ "$(grep -c '^check: rearm-resurface$' "$out")" -eq 1 ] \
    || fail "handling successor did not close once with the recovery wake: $(cat "$out")"
  grep "$(printf '\tcheck\tinbox:n1\t')" "$state/.wake-queue" >/dev/null \
    || fail "the resurfaced inbox row must stay queued for main"
  grep -E '^(pending|announced):downtime:' "$state/.watcher-down" >/dev/null \
    || fail "the resurfaced close must leave a deliverable downtime episode: $(cat "$state/.watcher-down")"
  pass "a handling successor resurfaces a row appended during startup"
}

test_handling_successor_does_not_go_blind
test_handling_successor_resurfaces_a_row_appended_during_startup
