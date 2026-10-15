#!/usr/bin/env bash
# Behavioral coverage for the /stow draft-review-apply helper: the plan format,
# the guarantee that apply writes only approved items in their approved wording,
# secondmate plan routing into one review, and the round-end record the
# stow-review mod reads to show what was saved and to clear a session once.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLAN_CMD="$ROOT/bin/fm-stow-plan.sh"
TMP_ROOT=$(fm_test_tmproot fm-stow-plan)
TODAY=$(date +%Y-%m-%d)

new_primary() { # <name>
  local home="$TMP_ROOT/primaries/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf '%s\n' "$home"
}

new_secondmate() { # <id>
  local home="$TMP_ROOT/homes/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/bin" "$home/projects"
  printf '%s' "$1" > "$home/.fm-secondmate-home"
  printf '%s\n' '# secondmate instructions' > "$home/AGENTS.md"
  printf '%s\n' "$home"
}

local_record() { # <id> <home>
  printf -- '- %s - domain summary (home: %s; scope: %s work; projects: alpha; added 2026-08-07)\n' \
    "$1" "$2" "$1"
}

# plan <home> <items-json>: write a draft plan for <home>.
plan() {
  jq -n --arg home "$1" --argjson items "$2" '{version: 1, home: $home, items: $items}'
}

run_plan() { # <home> <args...>
  local home=$1
  shift
  env FM_HOME="$home" PATH="$PATH" "$PLAN_CMD" "$@"
}

test_the_plan_format_is_enforced() {
  local home out rc bad
  home=$(new_primary format)
  plan main '[
    {"id":"m1","section":"memory","action":"rewrite","target":"data/learnings.md",
     "entry":"- fact <!--a:2026-10-14-->","replaces":"- fact <!--a:2026-08-01-->"},
    {"id":"k1","section":"knowledge","action":"add","target":"data/captain.md","entry":"- likes short PRs"},
    {"id":"r1","section":"records","action":"record","target":"backlog","entry":"file: follow up on the flaky test"}
  ]' > "$home/state/stow-plan.json"
  out=$(run_plan "$home" check 2>&1) || fail "a valid plan was refused: $out"
  assert_contains "$out" '3 items' "check did not count the items"

  for bad in \
    '[{"id":"x","section":"memory","action":"rewrite","target":"data/learnings.md","entry":"new"}]|needs the exact line' \
    '[{"id":"x","section":"memory","action":"add","target":"data/learnings.md","entry":"two\nlines"}]|entry must be one nonempty line' \
    '[{"id":"x","section":"memory","action":"add","target":"projects/a/AGENTS.md","entry":"e"}]|target must be data/<name>.md' \
    '[{"id":"x","section":"vibes","action":"add","target":"data/learnings.md","entry":"e"}]|section must be one of' \
    '[{"id":"x","section":"memory","action":"remove","target":"data/learnings.md","entry":"a","replaces":"b"}]|must repeat the line' \
    '[{"id":"x","section":"memory","action":"add","target":"data/learnings.md","entry":"e","owner":"me"}]|unknown field owner' \
    '[{"id":"x","section":"memory","action":"add","target":"data/a.md","entry":"e"},{"id":"x","section":"memory","action":"add","target":"data/b.md","entry":"f"}]|duplicate item id x'; do
    plan main "${bad%%|*}" > "$home/state/stow-plan.json"
    set +e
    out=$(run_plan "$home" check 2>&1)
    rc=$?
    set -e
    expect_code 1 "$rc" "an invalid plan was accepted (${bad#*|})"
    assert_contains "$out" "${bad#*|}" "the refusal did not name the problem"
  done
  pass "the plan format accepts well-formed items and names every malformed one"
}

test_apply_writes_only_approved_items_in_approved_wording() {
  local home out rc
  home=$(new_primary approve)
  printf '%s\n' '# Learnings' '- old fact <!--a:2026-08-01-->' '- stale fact <!--a:2026-07-01-->' > "$home/data/learnings.md"
  printf '%s\n' '# Captain' > "$home/data/captain.md"
  plan main '[
    {"id":"m1","section":"memory","action":"rewrite","target":"data/learnings.md",
     "entry":"- old fact <!--a:'"$TODAY"'-->","replaces":"- old fact <!--a:2026-08-01-->"},
    {"id":"m2","section":"memory","action":"archive","target":"data/learnings.md",
     "entry":"- (from learnings.md, tier: aging, reinforced: 2026-07-01) stale fact [archived: unreinforced 105d]",
     "replaces":"- stale fact <!--a:2026-07-01-->"},
    {"id":"k1","section":"knowledge","action":"add","target":"data/captain.md","entry":"- prefers terse replies"},
    {"id":"k2","section":"knowledge","action":"add","target":"data/learnings.md","entry":"- unapproved fact <!--a:'"$TODAY"'-->"},
    {"id":"r1","section":"records","action":"record","target":"backlog","entry":"file: follow up on the flaky test"}
  ]' > "$home/state/stow-plan.json"
  out=$(run_plan "$home" collect) || fail "collect failed: $out"

  # show numbers by home, then section, then target, the order approve uses.
  out=$(run_plan "$home" show)
  assert_contains "$out" 'Startup-memory tiers' "show did not group by section"
  assert_contains "$out" '1. [rewrite] - old fact' "show did not number the first item"
  assert_contains "$out" '4. [add] - unapproved fact' "show did not number the learnings add fourth"
  assert_contains "$out" '5. [record] file: follow up' "show did not number the record item"

  # Nothing is written before an approval comes back.
  assert_grep '- old fact <!--a:2026-08-01-->' "$home/data/learnings.md" "drafting changed a memory file"
  assert_absent "$home/data/memory-archive.md" "drafting archived something"

  out=$(run_plan "$home" approve --except 4 --edit 3='- prefers terse, direct replies') \
    || fail "approve failed: $out"
  run_plan "$home" split > /dev/null || fail "split refused a faithful approval"
  set +e
  out=$(run_plan "$home" apply --clear)
  rc=$?
  set -e
  expect_code 0 "$rc" "apply of approved items should succeed: $out"
  assert_grep "- old fact <!--a:$TODAY-->" "$home/data/learnings.md" "the approved rewrite was not written"
  assert_no_grep '- stale fact' "$home/data/learnings.md" "the archived line stayed in its source"
  assert_grep "## $TODAY stow" "$home/data/memory-archive.md" "the archive heading is missing"
  assert_grep 'stale fact [archived: unreinforced 105d]' "$home/data/memory-archive.md" "the archive entry is missing"
  assert_grep '- prefers terse, direct replies' "$home/data/captain.md" "the edited wording was not the one written"
  assert_no_grep '- prefers terse replies' "$home/data/captain.md" "the unedited wording was written"
  assert_no_grep 'unapproved fact' "$home/data/learnings.md" "an unticked item was written"
  assert_contains "$out" 'owner r1 records backlog: file: follow up on the flaky test' "the record item was not handed to its owner"
  assert_contains "$out" 'summary home=main applied=3 skipped=0 owner=1' "apply did not print what it wrote"
  assert_absent "$home/state/stow-plan.json" "apply left the draft behind"
  assert_absent "$home/state/stow-review.json" "apply left the review behind"
  [ "$(jq -r '.clear' "$home/state/stow-applied.json")" = true ] || fail "the round end did not record its clear"
  [ "$(jq -r '.homes[0].items | map(.id) | join(",")' "$home/state/stow-applied.json")" = m1,m2,k1,r1 ] \
    || fail "the round end did not record exactly the approved items"
  pass "apply writes only approved items, in their approved wording, and records the round"
}

test_apply_refuses_anything_the_review_did_not_show() {
  local home out rc
  home=$(new_primary tamper)
  printf '%s\n' '- a line' > "$home/data/learnings.md"
  plan main '[{"id":"m1","section":"memory","action":"rewrite","target":"data/learnings.md","entry":"- a better line","replaces":"- a line"}]' \
    > "$home/state/stow-plan.json"
  run_plan "$home" collect > /dev/null || fail "collect failed"

  plan main '[{"id":"m1","section":"memory","action":"rewrite","target":"data/captain.md","entry":"- a better line","replaces":"- a line"}]' \
    > "$home/state/stow-plan.approved.json"
  set +e
  out=$(run_plan "$home" apply 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "an approval that moved an item to another file was applied"
  assert_contains "$out" 'm1 changes more than its entry' "the refusal did not name the changed item"

  plan main '[{"id":"new","section":"memory","action":"add","target":"data/learnings.md","entry":"- smuggled"}]' \
    > "$home/state/stow-plan.approved.json"
  set +e
  out=$(run_plan "$home" apply 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "an item the review never showed was applied"
  assert_contains "$out" 'new is not in the plan that was reviewed' "the refusal did not name the unknown item"
  assert_no_grep 'smuggled' "$home/data/learnings.md" "a refused approval still wrote"
  assert_grep '- a line' "$home/data/learnings.md" "a refused approval changed the file"

  # A line that is no longer there exactly once is skipped, never guessed.
  printf '%s\n' '- a line' '- a line' > "$home/data/learnings.md"
  run_plan "$home" approve --all > /dev/null || fail "approve --all failed"
  run_plan "$home" split > /dev/null || fail "split failed"
  set +e
  out=$(run_plan "$home" apply)
  rc=$?
  set -e
  expect_code 3 "$rc" "an ambiguous line should be reported as skipped"
  assert_contains "$out" 'skipped m1 rewrite data/learnings.md: the line it replaces appears 2 times' \
    "the skip did not say why"
  assert_no_grep 'a better line' "$home/data/learnings.md" "an ambiguous rewrite guessed a line"
  pass "apply refuses items the review did not show and never guesses a line"
}

test_secondmate_plans_route_into_one_review_and_back() {
  local primary mate other out rc request
  primary=$(new_primary routing)
  mate=$(new_secondmate mate-a)
  other=$(new_secondmate mate-b)
  {
    local_record mate-a "$mate"
    local_record mate-b "$other"
  } > "$primary/data/secondmates.md"
  plan main '[]' > "$primary/state/stow-plan.json"
  printf '%s\n' '- mate fact <!--a:2026-08-01-->' > "$mate/data/learnings.md"
  printf '%s\n' '- shared pref' > "$mate/data/captain-shared.md"
  plan mate-a '[
    {"id":"m1","section":"memory","action":"rewrite","target":"data/learnings.md",
     "entry":"- mate fact <!--a:'"$TODAY"'-->","replaces":"- mate fact <!--a:2026-08-01-->"},
    {"id":"k1","section":"knowledge","action":"add","target":"data/captain-shared.md","entry":"- captain likes bullet lists"}
  ]' > "$mate/state/stow-plan.json"
  cp "$mate/state/stow-plan.json" "$TMP_ROOT/mate-a-draft.json"

  # Only the homes asked this round are gathered.
  out=$(run_plan "$primary" collect --homes mate-a) || fail "collect of one asked home failed: $out"
  assert_contains "$out" 'home=mate-a items=1' "the secondmate's own items were not gathered"
  assert_contains "$out" 'home=main items=1' "the shared-preference item did not move to main"
  assert_not_contains "$out" 'mate-b' "a home that was not asked was gathered"
  [ "$(jq -r '.homes[0].items[0].id' "$primary/state/stow-review.json")" = mate-a.k1 ] \
    || fail "the routed item does not carry its home in its id"

  # Naming only main, or no home at all, gathers this home alone.
  for homes in main ''; do
    out=$(run_plan "$primary" collect --homes "$homes") || fail "collect --homes '$homes' failed: $out"
    assert_contains "$out" 'home=main items=0' "collect --homes '$homes' did not gather main"
    assert_not_contains "$out" 'mate-' "collect --homes '$homes' gathered a secondmate"
  done
  out=$(run_plan "$primary" collect --homes main,mate-a) || fail "collect of main and one home failed: $out"
  assert_contains "$out" 'home=mate-a items=1' "naming main hid an asked secondmate"
  set +e
  out=$(run_plan "$primary" collect --homes main,mate-z 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unknown secondmate name was accepted"
  assert_contains "$out" 'not a registered secondmate: mate-z' "the unknown name was not refused"

  # A home asked but with no plan is an exception, and the rest still review.
  set +e
  out=$(run_plan "$primary" collect)
  rc=$?
  set -e
  expect_code 3 "$rc" "a registered home with no plan should be reported"
  assert_contains "$out" 'exception home=mate-b reason=no plan drafted in that home' "the missing plan was not named"
  assert_contains "$out" 'home=mate-a items=1' "one home's exception blocked another's review"

  out=$(run_plan "$primary" approve --all) || fail "approve failed: $out"
  out=$(run_plan "$primary" split) || fail "split failed: $out"
  assert_contains "$out" 'home=mate-a approved=1' "the secondmate's approved items were not split out"
  request=$(run_plan "$primary" request mate-a --clear) || fail "request failed"
  assert_contains "$request" 'apply --clear --from-request' "the request did not carry the clear"
  printf '%s\n' "$request" > "$TMP_ROOT/request.msg"

  # The secondmate applies only what came back, checked against its own draft.
  out=$(run_plan "$mate" apply --clear --from-request "$TMP_ROOT/request.msg") || fail "secondmate apply failed: $out"
  assert_grep "- mate fact <!--a:$TODAY-->" "$mate/data/learnings.md" "the secondmate's approved rewrite was not written"
  assert_no_grep 'bullet lists' "$mate/data/captain-shared.md" "a secondmate wrote the shared preferences"
  [ "$(jq -r '.homes[0].home' "$mate/state/stow-applied.json")" = mate-a ] \
    || fail "the secondmate did not record its own round end"

  # Even an approval that names the shared file is never applied there.
  cp "$TMP_ROOT/mate-a-draft.json" "$mate/state/stow-plan.json"
  plan mate-a '[{"id":"k1","section":"knowledge","action":"add","target":"data/captain-shared.md","entry":"- captain likes bullet lists"}]' \
    > "$mate/state/stow-plan.approved.json"
  set +e
  out=$(run_plan "$mate" apply)
  rc=$?
  set -e
  expect_code 3 "$rc" "a shared-preference write in a secondmate should be skipped"
  assert_contains "$out" 'a secondmate never writes the primary-owned shared preferences' "the skip did not say why"
  assert_no_grep 'bullet lists' "$mate/data/captain-shared.md" "a secondmate wrote the shared preferences"

  # The routed item is main's to apply.
  out=$(run_plan "$primary" apply) || fail "main apply failed: $out"
  assert_grep '- captain likes bullet lists' "$primary/data/captain-shared.md" "main did not write the routed preference"
  pass "secondmate plans gather into one review, shared preferences route to main, and each home applies its own"
}

test_an_empty_round_still_ends_and_requests_explain_themselves() {
  local mate out
  mate=$(new_secondmate mate-empty)
  plan mate-empty '[]' > "$mate/state/stow-plan.json"
  out=$(run_plan "$mate" finish --clear) || fail "finish failed: $out"
  assert_contains "$out" 'applied=0' "finish claimed to write something"
  assert_absent "$mate/state/stow-plan.json" "finish left the draft behind"
  [ "$(jq -c '[.clear, (.homes[0].items | length)]' "$mate/state/stow-applied.json")" = '[true,0]' ] \
    || fail "an empty round did not record a clearing end with nothing saved"

  out=$(run_plan "$mate" draft-request --clear)
  assert_contains "$out" 'state/stow-plan.json' "the draft request did not name the plan file"
  assert_contains "$out" 'finish --clear' "the draft request did not say how an empty plan ends"
  pass "an empty plan saves nothing but still ends its round"
}

test_the_plan_format_is_enforced
test_apply_writes_only_approved_items_in_approved_wording
test_apply_refuses_anything_the_review_did_not_show
test_secondmate_plans_route_into_one_review_and_back
test_an_empty_round_still_ends_and_requests_explain_themselves
