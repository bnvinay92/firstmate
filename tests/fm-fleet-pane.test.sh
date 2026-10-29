#!/usr/bin/env bash
# Tests for bin/fm-fleet-pane.py, the fleet pane: its pull request and decision
# rows, collapsed and expanded decision rendering, the read-only snapshot and
# batched GitHub reads, and opening it as a Herdr pane. Every case drives the
# executable: `render` prints one frame, `open` runs a stand-in Herdr.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

PANE="$ROOT/bin/fm-fleet-pane.py"
TMP_ROOT=$(fm_test_tmproot fm-fleet-pane)

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  # A stand-in gh answers the state query and the checks query from fixture
  # files and logs each call, so the read budget can be counted.
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$*" in
  *statusCheckRollup*) cat "$FM_TEST_GH_CHECKS" ;;
  *) cat "$FM_TEST_GH_STATES" ;;
esac
SH
  chmod +x "$home/fakebin/gh"
  printf '{}' > "$home/gh-states.json"
  printf '{}' > "$home/gh-checks.json"
  printf '%s\n' "$home"
}

render() {  # <home> <render args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_TEST_GH_LOG="$home/gh.log" \
    FM_TEST_GH_STATES="$home/gh-states.json" FM_TEST_GH_CHECKS="$home/gh-checks.json" \
    python3 "$PANE" render "$@"
}

url() { printf 'https://github.com/example/app/pull/%s' "$1"; }

# A GitHub pullRequest answer: <title> <state> [jq overrides on the object].
pr_answer() {
  jq -n --arg title "$1" --arg state "$2" '{
    title: $title, state: $state, isDraft: false, mergeable: "MERGEABLE",
    mergeStateStatus: "CLEAN", reviewDecision: null,
    baseRef: {branchProtectionRule: null, rules: {nodes: []}},
    commits: {nodes: [{commit: {statusCheckRollup: {contexts: {nodes: [
      {__typename: "CheckRun", name: "ci", status: "COMPLETED", conclusion: "SUCCESS", isRequired: false}]}}}}]}
  }' | jq "${3:-.}"
}

# --- pull request rows -------------------------------------------------------

home=$(make_home prs)
jq -n --arg u1 "$(url 1)" --arg u2 "$(url 2)" --arg u3 "$(url 3)" --arg u4 "$(url 4)" '{
  schema: "fm-fleet-snapshot.v1",
  tasks: [{id: "stack", pr: {url: $u1, urls: [$u1, $u2, ($u2 + "/")]}, backlog: {title: "Stack work", unresolved_blocker_ids: ["base"]}}],
  backlog: {records: [{id: "old", state: "done", pr_url: $u3, links: [$u3, $u4, "https://example.org/x"]}]}
}' > "$home/snapshot.json"
jq -n --argjson a "$(pr_answer 'First change' OPEN)" --argjson b "$(pr_answer 'Second change' OPEN)" \
  --argjson c "$(pr_answer 'Merged change' MERGED)" --argjson d "$(pr_answer 'Fourth change' OPEN)" \
  '{data: {p0: {pullRequest: $a}, p1: {pullRequest: $b}, p2: {pullRequest: $c}, p3: {pullRequest: $d}}}' > "$home/gh-states.json"
jq -n --argjson a "$(pr_answer 'First change' OPEN '.isDraft = true | .mergeable = "CONFLICTING" | .reviewDecision = "CHANGES_REQUESTED" | .mergeStateStatus = "BEHIND"')" \
  --argjson b "$(pr_answer 'Second change' OPEN)" --argjson d "$(pr_answer 'Fourth change' OPEN '.mergeStateStatus = "BLOCKED" | .baseRef.rules.nodes = [{type: "REQUIRED_STATUS_CHECKS", parameters: {requiredStatusChecks: [{context: "ci"}]}}]')" \
  '{data: {p0: {pullRequest: $a}, p1: {pullRequest: $b}, p2: {pullRequest: $d}}}' > "$home/gh-checks.json"
out=$(render "$home" --snapshot "$home/snapshot.json" --width 200) || fail "render failed"
assert_contains "$out" "Open pull requests (3)" "three open pull requests, the merged one dropped"
assert_contains "$out" "app: First change · passing · still a draft; merge conflict; changes requested in review; behind its base branch; waits on base" "every blocker shows, most basic first"
assert_contains "$out" "app: Second change · passing · waits on base" "a task's other pull requests carry what it waits on"
assert_contains "$out" "app: Fourth change · passing · GitHub reports it blocked" "a pull request GitHub reports blocked is never ready"
assert_not_contains "$out" "Merged change" "a merged pull request drops off"
assert_equals "2" "$(wc -l < "$home/gh.log" | tr -d ' ')" "GitHub is asked in two batched queries"
assert_equals "4" "$(head -n 1 "$home/gh.log" | grep -o 'pullRequest(number:' | wc -l | tr -d ' ')" "the state query covers every recorded pull request"
assert_not_contains "$(head -n 1 "$home/gh.log")" "statusCheckRollup" "the state query asks for no checks"
assert_equals "3" "$(sed -n 2p "$home/gh.log" | grep -o 'pullRequest(number:' | wc -l | tr -d ' ')" "the checks query covers only the open ones"
pass "pull request rows: inventory, dedupe, blockers, and the two-query read"

# --- required checks decide what blocks --------------------------------------

home=$(make_home checks)
jq -n --arg u1 "$(url 11)" --arg u2 "$(url 12)" --arg u3 "$(url 13)" --arg u4 "$(url 14)" '{
  schema: "fm-fleet-snapshot.v1",
  tasks: [{id: "a", pr: {url: $u1}}, {id: "b", pr: {url: $u2}}, {id: "c", pr: {url: $u3}}, {id: "d", pr: {url: $u4}}]
}' > "$home/snapshot.json"
running='{__typename: "CheckRun", name: "build", status: "IN_PROGRESS", conclusion: null, isRequired: false}'
failing='{__typename: "CheckRun", name: "lint", status: "COMPLETED", conclusion: "FAILURE", isRequired: false}'
required_ci='.baseRef.rules.nodes = [{type: "REQUIRED_STATUS_CHECKS", parameters: {requiredStatusChecks: [{context: "ci"}, {context: "e2e"}]}}]'
jq -n --argjson a "$(pr_answer A OPEN)" '{data: {p0: {pullRequest: $a}, p1: {pullRequest: $a}, p2: {pullRequest: $a}, p3: {pullRequest: $a}}}' > "$home/gh-states.json"
jq -n --argjson a "$(pr_answer 'Advisory failing' OPEN ".baseRef.rules.nodes = [{type: \"REQUIRED_STATUS_CHECKS\", parameters: {requiredStatusChecks: [{context: \"ci\"}]}}] | .commits.nodes[0].commit.statusCheckRollup.contexts.nodes += [$failing]")" \
  --argjson b "$(pr_answer 'Required missing' OPEN "$required_ci")" \
  --argjson c "$(pr_answer 'Rules unknown' OPEN ".baseRef = null | .commits.nodes[0].commit.statusCheckRollup.contexts.nodes += [$running]")" \
  --argjson d "$(pr_answer 'Clean' OPEN '.reviewDecision = "REVIEW_REQUIRED"')" \
  '{data: {p0: {pullRequest: $a}, p1: {pullRequest: $b}, p2: {pullRequest: $c}, p3: {pullRequest: $d}}}' > "$home/gh-checks.json"
out=$(render "$home" --snapshot "$home/snapshot.json" --width 200) || fail "render failed"
assert_contains "$out" "Advisory failing · 1 failing · ready - waiting for your word to merge" "an advisory failure does not block when required checks pass"
assert_contains "$out" "Required missing · passing · a required check not reported yet" "a required check that has not reported blocks"
assert_contains "$out" "Rules unknown · 1 running · checks still running" "with the rules unknown, a running check blocks"
assert_contains "$out" "Clean · passing · needs an approving review" "a needed review blocks"
pass "required checks alone block when the base branch names them"

# --- decisions: collapsed and expanded ----------------------------------------

home=$(make_home decisions)
reason=$'Pick the first template.\nRec: the side basic (out, back, tap).\nOr: the travelling basic. See data/drill/plan.md'
jq -n --arg reason "$reason" --arg long "$(printf 'word %.0s' $(seq 1 60))" '{
  schema: "fm-fleet-snapshot.v1",
  secondmate_current: {records: [{id: "mate", home: "/mate", provenance: {selected: "structured-home"},
    decisions_open: [{id: "foot", verb: "captain-hold", source: "backlog", summary: "Choose the foot model", reason: "Rec: the second detector."}]}]},
  tasks: [{id: "worker", hints: {open_decisions: [
    {key: "device", verb: "needs-decision", summary: "Unlock the phone, or close out on JVM evidence?"},
    {key: "stuck", verb: "blocked", summary: "the worker cannot reach the device"}]}}],
  backlog: {path: "/fm/data/backlog.md", records: [
    {id: "plan-q1", title: ("First template: " + $long), captain_actionable: true, hold_reason: $reason},
    {id: "later", title: "Deferred", captain_actionable: false, hold_reason: "not yet"}]}
}' > "$home/snapshot.json"
out=$(render "$home" --snapshot "$home/snapshot.json" --width 60) || fail "render failed"
assert_contains "$out" "Decisions waiting for you (3)" "open decisions and live holds are listed, a worker blocker and a deferred hold are not"
assert_contains "$out" "▸ mate · foot: Choose the foot model" "a second mate's hold shows its own title"
assert_contains "$out" "▸ worker: device" "a keyed question shows its key"
assert_contains "$out" "▸ plan-q1: First template: word" "a held task shows its title"
assert_not_contains "$out" "Rec:" "a collapsed decision never shows its reason"
assert_not_contains "$out" "the worker cannot reach" "a worker's own blocker is not listed"
while IFS= read -r line; do
  [ "${#line}" -le 60 ] || fail "a collapsed line is wider than the pane: $line"
done <<< "$out"
assert_equals "1" "$(grep -c 'plan-q1' <<< "$out")" "a collapsed decision is one line"
pass "collapsed decisions are one line each, within the width, without their reason"

out=$(render "$home" --snapshot "$home/snapshot.json" --width 60 --expand 3 --select 3) || fail "render failed"
assert_contains "$out" "> ▾ plan-q1: First template:" "the expanded decision is marked open and selected"
assert_contains "$out" "    Pick the first template." "the reason shows in full"
assert_contains "$out" "    Rec: the side basic (out, back, tap)." "its line breaks are kept"
assert_contains "$out" "    Or: the travelling basic. See data/drill/plan.md" "its last line shows"
assert_contains "$out" "word word" "the full title shows"
title=$(sed -n '/▾ plan-q1/,/Pick the first/p' <<< "$out" | sed '1d;$d')
assert_equals "62" "$(wc -w <<< "$title" | tr -d ' ')" "the full title wraps whole: 'First template:' and sixty words"
assert_not_contains "$title" "…" "the expanded title is not ellipsized"
assert_contains "$out" "    Document:" "the document is named"
wide=$(render "$home" --snapshot "$home/snapshot.json" --width 300 --expand 3) || fail "render failed"
assert_contains "$wide" $'\n'"    $home/data/drill/plan.md"$'\n' "its path is plain text under the home, on a line of its own"
assert_contains "$out" "y take the recommendation · a type an answer · d drop" "a held task offers resolve and drop"
while IFS= read -r line; do
  [ "${#line}" -le 60 ] || fail "an expanded line is wider than the pane: $line"
done <<< "$out"
out=$(render "$home" --snapshot "$home/snapshot.json" --width 60 --expand 1 --expand 2) || fail "render failed"
assert_contains "$out" "    Rec: the second detector." "a second mate's reason shows"
assert_contains "$out" "    Unlock the phone, or close out on JVM evidence?" "a worker's question shows"
assert_equals "2" "$(grep -c 'Answer this one in chat with Firstmate' <<< "$out")" "a call this home's backlog does not hold is answered in chat"
assert_not_contains "$out" "d drop" "no drop is offered for a call this home cannot record"
pass "an expanded decision shows its full title, reason, and document, wrapped to the pane"

# --- the real snapshot read: decoded reasons, nothing written ----------------

home=$(make_home live)
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" hold q-one --title "Keep the count-in?" --repo sample \
  --reason $'Keep it (for the boards)?\nRec: yes.' >/dev/null || fail "holding q-one failed"
before=$(find "$home" -type f -newer "$home/data/backlog.md" -o -type f -name 'backlog.md' | sort; cat "$home/data/backlog.md")
out=$(render "$home" --width 80 --expand 1) || fail "render on the real snapshot failed"
assert_contains "$out" "▾ q-one: Keep the count-in?" "the held call shows"
assert_contains "$out" "    Keep it (for the boards)?" "the stored reason is decoded, parentheses and all"
assert_contains "$out" "    Rec: yes." "its line break survives the store"
after=$(find "$home" -type f -newer "$home/data/backlog.md" -o -type f -name 'backlog.md' | sort; cat "$home/data/backlog.md")
assert_equals "$before" "$after" "a read writes nothing in the home"
[ ! -e "$home/gh.log" ] || fail "no pull request means GitHub is not asked"
pass "the real snapshot read decodes stored reasons and writes nothing"

home=$(make_home broken)
printf 'not json' > "$home/snapshot.json"
out=$(render "$home" --snapshot "$home/snapshot.json") || fail "render failed"
assert_contains "$out" "The task records could not be read just now." "a failed read says so"
pass "a failed read says what could not be read"

# --- opening the pane in Herdr -----------------------------------------------

home=$(make_home herdr)
cat > "$home/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_HERDR_LOG"
case "$1 $2" in
  "pane list") cat "$FM_TEST_HERDR_LIST" ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w1:t1"}}}\n' "$3" ;;
  "pane split") printf '{"result":{"pane":{"pane_id":"w1:p9","tab_id":"w1:t1"}}}\n' ;;
  *) printf '{"result":{}}\n' ;;
esac
SH
chmod +x "$home/fakebin/herdr"
printf '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}\n' > "$home/panes.json"
open_pane() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_HERDR_BIN="$home/fakebin/herdr" FM_TEST_HERDR_LOG="$home/herdr.log" \
    FM_TEST_HERDR_LIST="$home/panes.json" python3 "$PANE" open "$@"
}
out=$(open_pane "$home" --session fm-lab-x --pane w1:p1) || fail "open failed: $out"
assert_equals "opened: pane w1:p9" "$out" "open names the new pane"
log=$(cat "$home/herdr.log")
assert_contains "$log" "pane split w1:p1 --direction right --ratio 0.65 --cwd $home --no-focus --session fm-lab-x" "it splits beside the firstmate pane without taking focus"
assert_contains "$log" "pane rename w1:p9 fleet-pane --session fm-lab-x" "it labels the pane"
assert_contains "$log" "pane run w1:p9 FM_HOME='$home' '$PANE' --session fm-lab-x" "it runs the view for this home"
while IFS= read -r line; do
  assert_contains "$line" "--session fm-lab-x" "every Herdr call names the session"
done <<< "$log"
printf '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"},{"pane_id":"w1:p9","tab_id":"w1:t1","label":"fleet-pane"}]}}\n' > "$home/panes.json"
: > "$home/herdr.log"
out=$(open_pane "$home" --session fm-lab-x --pane w1:p1) || fail "a second open failed"
assert_equals "already open: pane w1:p9" "$out" "a second open reuses the pane"
assert_not_contains "$(cat "$home/herdr.log")" "pane split" "a second open splits nothing"
rc=0
FM_HOME="$home" FM_HERDR_BIN="$home/fakebin/herdr" HERDR_SESSION='' HERDR_PANE_ID='' python3 "$PANE" open >/dev/null 2>&1 || rc=$?
assert_equals "2" "$rc" "open outside Herdr, with no session or pane, is refused"
touch "$home/.fm-secondmate-home"
rc=0
open_pane "$home" --session fm-lab-x --pane w1:p1 >/dev/null 2>&1 || rc=$?
assert_not_equals "0" "$rc" "a second mate's home does not open the fleet pane"
pass "open splits a labelled pane beside firstmate's, once, naming the session on every call"
