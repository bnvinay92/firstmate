#!/usr/bin/env bash
# Tests for bin/fm-decision.sh: resolving and dropping a decision waiting for
# the captain records the answer through bin/fm-captain-hold.sh and wakes
# Firstmate through one captain inbox note, and every refusal records nothing.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-decision)

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

run_in() {  # <home> <script> <args...>
  local home=$1 script=$2
  shift 2
  FM_HOME="$home" "$ROOT/bin/$script" "$@"
}

hold() {  # <home> <id> <reason> [--title <title>]
  local home=$1 id=$2 reason=$3
  shift 3
  run_in "$home" fm-captain-hold.sh hold "$id" --reason "$reason" --repo sample "$@" >/dev/null \
    || fail "holding $id failed"
}

show() {  # <home> <id>
  run_in "$1" fm-tasks-axi.sh show "$2" --full
}

note_count() {  # <home>
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

code_of() {  # <command...>: print the command's exit status, its output dropped
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

notes() {  # <home>
  cat "$1"/state/inbox/*.note 2>/dev/null
}

# --- resolve closes a question-shaped call and wakes Firstmate --------------

home=$(make_home resolve)
hold "$home" q-one "Pick the first template? Rec: the side basic." --title "Pick the first template?"
out=$(run_in "$home" fm-decision.sh resolve --source "a test" q-one "Go with the side basic") \
  || fail "resolve should succeed: $out"
assert_contains "$out" "resolved: q-one" "resolve reports the task"
assert_contains "$out" "the call is closed" "resolve says the question closed"
shown=$(show "$home" q-one)
assert_contains "$shown" "state: done" "a captain-kind call closes"
assert_contains "$shown" "Go with the side basic" "the captain's words are recorded on the task"
assert_equals "1" "$(note_count "$home")" "one note wakes Firstmate"
assert_contains "$(notes "$home")" "Decision q-one answered through a test" "the note names the task and the source"
assert_contains "$(notes "$home")" "Answer: Go with the side basic" "the note carries the answer"
assert_contains "$(cat "$home/state/.wake-queue")" "check" "the note raised a check wake"
pass "resolve records the answer, closes the question and wakes Firstmate"

# --- an answer on stdin keeps its line breaks -------------------------------

home=$(make_home stdin)
hold "$home" q-two "Which drills? Rec: all eleven." --title "Which drills?"
printf 'Drills one to five.\nThe rest later.\n' | run_in "$home" fm-decision.sh resolve q-two - >/dev/null \
  || fail "resolve from stdin should succeed"
shown=$(show "$home" q-two)
assert_contains "$shown" "Drills one to five." "the stdin answer is recorded"
assert_contains "$shown" "The rest later." "its second line is kept"
pass "resolve reads a multi-line answer from stdin"

# --- a held work item is released, not closed -------------------------------

home=$(make_home release)
(cd "$home" && tasks-axi add work-one "Build the tracks" --kind ship --repo sample >/dev/null) \
  || fail "adding the work item failed"
hold "$home" work-one "Start the tracks now? Rec: yes."
out=$(run_in "$home" fm-decision.sh resolve work-one "yes, start it") || fail "resolve on held work should succeed: $out"
assert_contains "$out" "the hold is lifted" "resolve says the hold was lifted"
shown=$(show "$home" work-one)
assert_contains "$shown" "state: queued" "the work item stays open"
assert_contains "$shown" "held: no" "its hold is lifted"
assert_contains "$shown" "Resolution mode: released" "the answer is recorded as a release"
pass "resolve releases a held work item instead of closing it"

# --- drop closes whatever the kind -----------------------------------------

home=$(make_home drop)
(cd "$home" && tasks-axi add work-two "Build the corpus" --kind ship --repo sample >/dev/null) \
  || fail "adding the work item failed"
hold "$home" work-two "Build the corpus now?"
out=$(run_in "$home" fm-decision.sh drop work-two) || fail "drop should succeed: $out"
assert_contains "$out" "dropped: work-two" "drop reports the task"
shown=$(show "$home" work-two)
assert_contains "$shown" "state: done" "a dropped work item closes"
assert_contains "$shown" "Drop this." "the drop is recorded in the captain's words"
assert_contains "$(notes "$home")" "Answer: Drop this." "the note says it was dropped"
pass "drop records 'Drop this.' and closes the call"

# --- refusals record nothing and wake no one --------------------------------

home=$(make_home refuse)
(cd "$home" && tasks-axi add plain "An ordinary task" --kind ship --repo sample >/dev/null) \
  || fail "adding the plain task failed"
before=$(cat "$home/data/backlog.md")

expect_code 1 "$(code_of run_in "$home" fm-decision.sh resolve nobody "yes")" "fm-decision.sh resolve nobody yes"
err=$(run_in "$home" fm-decision.sh resolve nobody "yes" 2>&1 >/dev/null)
assert_contains "$err" "has no task nobody" "an unknown task id is refused by name"

expect_code 1 "$(code_of run_in "$home" fm-decision.sh drop plain)" "fm-decision.sh drop plain"
err=$(run_in "$home" fm-decision.sh drop plain 2>&1 >/dev/null)
assert_contains "$err" "not waiting for the captain" "a task with no captain hold is refused"

hold "$home" q-three "Pick one?" --title "Pick one?"
expect_code 2 "$(code_of run_in "$home" fm-decision.sh resolve q-three "   ")" "fm-decision.sh resolve q-three    "
expect_code 2 "$(code_of run_in "$home" fm-decision.sh resolve "bad/id" "yes")" "fm-decision.sh resolve bad/id yes"
expect_code 2 "$(code_of run_in "$home" fm-decision.sh drop q-three "extra words")" "fm-decision.sh drop q-three extra words"
expect_code 2 "$(code_of run_in "$home" fm-decision.sh resolve q-three)" "fm-decision.sh resolve q-three"
expect_code 2 "$(code_of run_in "$home" fm-decision.sh answer q-three "yes")" "fm-decision.sh answer q-three yes"
assert_equals "0" "$(note_count "$home")" "no refusal writes a note"
assert_contains "$(show "$home" q-three)" "held: yes" "the held call is untouched by the refusals"
after=$(cat "$home/data/backlog.md")
assert_contains "$after" "q-three" "the backlog still holds the call"
assert_equals "$(printf '%s' "$before" | grep -c 'plain')" "$(printf '%s' "$after" | grep -c 'plain')" "the plain task is untouched"

run_in "$home" fm-decision.sh resolve q-three "the first" >/dev/null || fail "the first answer should be recorded"
expect_code 1 "$(code_of run_in "$home" fm-decision.sh resolve q-three "the first")" "fm-decision.sh resolve q-three the first"
assert_equals "1" "$(note_count "$home")" "repeating an answer neither records nor wakes twice"
pass "unknown, unheld, already answered, and malformed requests are refused without a record"
