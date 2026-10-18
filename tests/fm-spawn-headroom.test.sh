#!/usr/bin/env bash
# Behavior tests for spawn headroom admission: when this machine opts in, a
# fresh worker is never launched while headroom-axi reports the machine short
# of memory or disk or under the declared memory pressure
# (bin/fm-spawn-headroom-lib.sh owns the contract; bin/fm-spawn.sh runs the
# check).
#
# Every case drives the real bin/fm-spawn.sh against a real project clone with
# an origin, fake tmux and treehouse binaries that log every call, a stub
# headroom-axi that logs its arguments and answers as the case directs, and a
# real markdown backlog when tasks-axi is installed. A deferred spawn is judged
# by what it left behind - no task record, no rendered launch brief, no
# endpoint, no worktree allocation, and a backlog item still queued - never by
# wording alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-headroom)
DEFER_EXIT=75
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# --- fixture ----------------------------------------------------------------

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Build the heavy project for $2.

## Firstmate spec
Exercise spawn headroom admission.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
}

add_item() {  # <home> <id>
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

make_home() {  # <home> [task-id...]
  local home=$1 id
  shift
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
      > "$home/data/backlog.md"
    cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  fi
  for id in "$@"; do
    write_brief "$home" "$id"
    add_item "$home" "$id"
  done
}

# The stub headroom-axi answers by FM_FAKE_HEADROOM:
#   ok-normal | ok-warn | ok-critical  exit 0 with that memory pressure
#   short                              exit 1, short of memory
#   error                              exit 2 with an error message
#   garbage                            exit 0 with output that is not a verdict
#   hang                               never answers
write_headroom_stub() {  # <fakebin>
  cat > "$1/headroom-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_HEADROOM_LOG"
case "${FM_FAKE_HEADROOM:-ok-normal}" in
  ok-*)
    pressure=${FM_FAKE_HEADROOM#ok-}
    printf '{"ok":true,"line":"ok ram 9.0G disk 80.0G","ram":{"availableBytes":9663676416,"pressure":"%s","short":false},"disk":{"short":false,"freeBytes":85899345920}}\n' "$pressure"
    exit 0
    ;;
  short)
    printf '%s\n' '{"ok":false,"line":"short: ram 2.4G < 4.0G (pressure warn) · top: rides-map 6.7G, gradle-daemon [shared] 3.1G · more: headroom-axi ram --top 20","ram":{"availableBytes":2576980378,"pressure":"warn","short":true},"disk":{"short":false}}'
    exit 1
    ;;
  error)
    printf '%s\n' 'error: herdr pane list failed' 'code: RUNTIME_ERROR'
    exit 2
    ;;
  garbage)
    printf '%s\n' 'not a verdict'
    exit 0
    ;;
  hang)
    sleep 30
    exit 0
    ;;
esac
SH
  chmod +x "$1/headroom-axi"
}

make_case() {  # <name> [task-id...]
  local name=$1 case_dir fakebin
  shift
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  : > "$case_dir/headroom.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in display-message) printf 'firstmate\n' ;; esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  write_headroom_stub "$fakebin"
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  make_home "$case_dir/home" "$@"
  printf '%s\n' "$case_dir"
}

declare_headroom() {  # <home> <line>...
  local home=$1
  shift
  printf '%s\n' "$@" > "$home/config/spawn-headroom"
}

new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

# HEADROOM_PATH, when set, replaces the PATH tail after the fakebin, so a case
# can hide the stub and any real headroom-axi on this host.
run_spawn() {  # <case-dir> <home> <pane-path> <headroom-mode> <args...>
  local case_dir=$1 home=$2 pane=$3 mode=$4 fakebin_path
  shift 4
  fakebin_path="$case_dir/fakebin:$PATH"
  [ -z "${HEADROOM_PATH:-}" ] || fakebin_path=$HEADROOM_PATH
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    FM_FAKE_HEADROOM="$mode" FM_FAKE_HEADROOM_LOG="$case_dir/headroom.log" \
    FM_SPAWN_HEADROOM_TIMEOUT="${FM_SPAWN_HEADROOM_TIMEOUT:-}" \
    PATH="$fakebin_path" \
    "$SPAWN" "$@" 2>&1
}

spawn_ship() {  # <case-dir> <id> <headroom-mode> [pane-path]
  local case_dir=$1 id=$2 mode=$3 pane=${4:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  run_spawn "$case_dir" "$case_dir/home" "$pane" "$mode" "$id" "$case_dir/project" --mode no-mistakes --yolo off
}

call_count() { wc -l < "$1/calls.log" | tr -d ' '; }

worktree_list() { git -C "$1/project" worktree list --porcelain; }

assert_nothing_created() {  # <case-dir> <home> <id> <calls-before> <worktrees-before>
  local case_dir=$1 home=$2 id=$3 before=$4 worktrees=$5 after
  assert_absent "$home/state/$id.meta" "a deferred spawn published a task record for $id"
  assert_absent "$home/data/$id/launch-brief.md" "a deferred spawn rendered a launch brief for $id"
  after=$(call_count "$case_dir")
  [ "$after" -eq "$before" ] ||
    fail "a deferred spawn touched the terminal or worktree pool for $id: $(tail -n +"$((before + 1))" "$case_dir/calls.log")"
  assert_equals "$worktrees" "$(worktree_list "$case_dir")" "a deferred spawn left a git worktree for $id"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" "$id")" = queued ] ||
      fail "a deferred spawn moved $id's backlog item: $(row_state "$home" "$id")"
  fi
}

assert_admitted() {  # <home> <id> <rc> <out> <label>
  expect_code 0 "$3" "$5: the spawn was not admitted: $4"
  assert_contains "$4" "spawned $2" "$5: the worker was not launched"
  assert_not_contains "$4" "deferred:" "$5: an admitted spawn reported a deferral"
  assert_present "$1/state/$2.meta" "$5: an admitted spawn published no record"
}

# --- cases ------------------------------------------------------------------

# Without the opt-in nothing changes: headroom-axi is never asked, even when it
# would report the machine short.
test_no_declaration_never_measures() {
  local case_dir out rc=0
  case_dir=$(make_case undeclared task-c)
  out=$(spawn_ship "$case_dir" task-c short) || rc=$?
  assert_admitted "$case_dir/home" task-c "$rc" "$out" "no declaration"
  assert_equals "" "$(cat "$case_dir/headroom.log")" "headroom-axi was asked without a declaration"
  pass "a machine without a headroom declaration keeps today's unmeasured dispatch"
}

test_ok_verdict_admits_the_worker() {
  local case_dir home out rc=0
  case_dir=$(make_case ok task-c)
  home="$case_dir/home"
  declare_headroom "$home" "# heavy Gradle builds" "min-ram 4G" "  min-disk 30G" "" "pressure critical"
  out=$(spawn_ship "$case_dir" task-c ok-warn) || rc=$?
  assert_admitted "$home" task-c "$rc" "$out" "ok verdict"
  assert_not_contains "$out" "warning: spawn headroom" "a measured ok verdict warned"
  assert_equals "check --json --min-ram 4G --min-disk 30G" "$(cat "$case_dir/headroom.log")" \
    "headroom-axi was not asked with the declared thresholds"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" task-c)" = in_flight ] || fail "an admitted spawn did not move its item In flight"
  fi
  pass "an ok verdict below the declared pressure admits the worker"
}

test_short_verdict_defers_without_leaving_anything_behind() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case short task-c)
  home="$case_dir/home"
  declare_headroom "$home" "min-ram 4G"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship "$case_dir" task-c short "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a short machine did not defer the spawn: $out"
  assert_contains "$out" "deferred: this machine is short of headroom for another worker ($home/config/spawn-headroom): headroom-axi: short: ram 2.4G < 4.0G (pressure warn) · top: rides-map 6.7G" \
    "the deferral did not name headroom-axi's verdict"
  assert_contains "$out" "task task-c was not launched and its backlog item stays queued" \
    "the deferral did not say the task stays queued"
  assert_equals "check --json --min-ram 4G" "$(cat "$case_dir/headroom.log")" \
    "headroom-axi was asked more than once or with the wrong thresholds"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  pass "a short machine defers the spawn before any record, brief, endpoint, worktree, or backlog move exists"
}

test_declared_pressure_defers() {
  local case_dir home out rc label decl mode want
  case_dir=$(make_case pressure task-c task-d task-e task-f)
  home="$case_dir/home"
  while IFS='|' read -r label decl mode want; do
    [ -n "$label" ] || continue
    declare_headroom "$home" "min-disk 10G" "$decl"
    rc=0
    out=$(spawn_ship "$case_dir" task-c "$mode" "$case_dir/unused") || rc=$?
    if [ "$want" = defer ]; then
      expect_code "$DEFER_EXIT" "$rc" "$label: the pressure did not defer the spawn: $out"
      assert_contains "$out" "memory pressure is ${mode#ok-}, at or above the declared ${decl#pressure }; headroom-axi: ok ram 9.0G disk 80.0G" \
        "$label: the deferral did not name the pressure and the verdict"
      assert_absent "$home/state/task-c.meta" "$label: a pressure deferral published a record"
    else
      expect_code 0 "$rc" "$label: a pressure below the declared level deferred the spawn: $out"
      rm -f "$home/state/task-c.meta"
    fi
  done <<'ROWS'
warn at warn|pressure warn|ok-warn|defer
critical above warn|pressure warn|ok-critical|defer
critical at critical|pressure critical|ok-critical|defer
ROWS
  declare_headroom "$home" "min-disk 10G" "pressure critical"
  rc=0
  out=$(spawn_ship "$case_dir" task-d ok-warn) || rc=$?
  assert_admitted "$home" task-d "$rc" "$out" "warn below critical"
  declare_headroom "$home" "min-disk 10G"
  rc=0
  out=$(spawn_ship "$case_dir" task-e ok-critical) || rc=$?
  assert_admitted "$home" task-e "$rc" "$out" "no declared pressure"
  pass "memory pressure at or above the declared level defers, and below it or undeclared admits"
}

# A missing, failing, hung, or unreadable headroom-axi admits the spawn with a
# warning naming the problem, so a broken measurement never holds dispatch.
test_unmeasurable_machine_admits_with_a_warning() {
  local case_dir home out rc=0
  case_dir=$(make_case unmeasured task-c task-d task-e task-f)
  home="$case_dir/home"
  declare_headroom "$home" "min-ram 4G" "pressure warn"

  out=$(spawn_ship "$case_dir" task-c error) || rc=$?
  assert_admitted "$home" task-c "$rc" "$out" "headroom-axi error"
  assert_contains "$out" "warning: spawn headroom was not checked for task task-c, which is admitted without it: headroom-axi check failed with exit 2: error: herdr pane list failed" \
    "an erroring headroom-axi did not warn with its error"

  rc=0
  out=$(spawn_ship "$case_dir" task-d garbage) || rc=$?
  assert_admitted "$home" task-d "$rc" "$out" "unreadable verdict"
  assert_contains "$out" "headroom-axi check exited 0 without a readable verdict: not a verdict" \
    "an unreadable verdict did not warn"

  rc=0
  out=$(FM_SPAWN_HEADROOM_TIMEOUT=1 spawn_ship "$case_dir" task-e hang) || rc=$?
  assert_admitted "$home" task-e "$rc" "$out" "hung headroom-axi"
  assert_contains "$out" "headroom-axi check did not answer within 1s" "a hung headroom-axi did not warn"

  rc=0
  rm "$case_dir/fakebin/headroom-axi"
  out=$(HEADROOM_PATH="$case_dir/fakebin:$(fm_test_base_path_sans "$PATH" headroom-axi)" \
    spawn_ship "$case_dir" task-f short) || rc=$?
  assert_admitted "$home" task-f "$rc" "$out" "missing headroom-axi"
  assert_contains "$out" "headroom-axi is not installed, so this machine's headroom was not measured" \
    "a missing headroom-axi did not warn"
  pass "a missing, failing, hung, or unreadable headroom-axi admits the spawn and names the problem"
}

test_unreadable_declaration_refuses_every_spawn() {
  local case_dir home out rc label body before worktrees
  case_dir=$(make_case unreadable task-c)
  home="$case_dir/home"
  while IFS='|' read -r label body; do
    [ -n "$label" ] || continue
    printf '%b' "$body" > "$home/config/spawn-headroom"
    before=$(call_count "$case_dir")
    worktrees=$(worktree_list "$case_dir")
    rc=0
    out=$(spawn_ship "$case_dir" task-c ok-normal "$case_dir/unused") || rc=$?
    expect_code 1 "$rc" "$label: an unreadable declaration did not refuse: $out"
    assert_contains "$out" "the spawn headroom declaration is unreadable" "$label: the refusal did not name the declaration"
    assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  done <<'ROWS'
no minimum|pressure warn\n
empty|# nothing declared\n
zero size|min-ram 0G\n
unitless size|min-ram 4096\n
bad size|min-disk lots\n
bad pressure|min-ram 4G\npressure high\n
unknown key|min-ram 4G\nmax-ram 8G\n
missing value|min-ram\n
trailing text|min-ram 4G # leave room\n
named twice|min-ram 4G\nmin-ram 6G\n
ROWS
  assert_equals "" "$(cat "$case_dir/headroom.log")" "headroom-axi was asked under an unreadable declaration"
  rm -f "$home/config/spawn-headroom"
  mkdir "$home/config/spawn-headroom"
  rc=0
  out=$(spawn_ship "$case_dir" task-c ok-normal "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a declaration that is not a file did not refuse: $out"
  pass "an unreadable declaration refuses every fresh spawn rather than guessing the thresholds"
}

# Headroom belongs to the machine: a local secondmate home's worker is measured
# against the root home's declaration, while the secondmate home declares none.
test_declaration_is_shared_by_every_local_home() {
  local case_dir root mate out rc=0 mate_project
  case_dir=$(make_case machine)
  root="$case_dir/home"
  mate="$case_dir/mate"
  make_home "$mate" task-m
  mate_project="$mate/projects/project"
  git clone -q "$(git -C "$case_dir/project" remote get-url origin)" "$mate_project"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$root" > "$mate/.fm-secondmate-parent"
  printf -- '- mate - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' "$mate" \
    > "$root/data/secondmates.md"
  declare_headroom "$root" "min-ram 4G"
  git -C "$mate_project" worktree add --quiet -b wt-m "$case_dir/wt-m"
  out=$(run_spawn "$case_dir" "$mate" "$case_dir/wt-m" short task-m "$mate_project" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a local secondmate's worker launched on a short machine: $out"
  assert_contains "$out" "deferred: this machine is short of headroom for another worker ($root/config/spawn-headroom)" \
    "the secondmate's worker was not measured against the root home's declaration"
  assert_absent "$mate/state/task-m.meta" "the deferred secondmate-home spawn published a record"
  pass "every local home on the machine reads the root home's headroom declaration"
}

test_batch_reports_a_deferred_pair() {
  local case_dir home out rc=0
  case_dir=$(make_case batch task-c)
  home="$case_dir/home"
  declare_headroom "$home" "min-ram 4G"
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" short "task-c=$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a batch whose only pair was deferred did not exit with the deferral status: $out"
  assert_contains "$out" "batch: DEFERRED task-c ($case_dir/project) - its project is at capacity or this machine is short of headroom, so it stays queued" \
    "the batch did not report the deferral"
  assert_not_contains "$out" "batch: FAILED" "the batch reported a deferral as a failure"
  pass "a batch reports a headroom deferral as deferred, not failed"
}

test_no_declaration_never_measures
test_ok_verdict_admits_the_worker
test_short_verdict_defers_without_leaving_anything_behind
test_declared_pressure_defers
test_unmeasurable_machine_admits_with_a_warning
test_unreadable_declaration_refuses_every_spawn
test_declaration_is_shared_by_every_local_home
test_batch_reports_a_deferred_pair
