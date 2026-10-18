#!/usr/bin/env bash
# fm-routine-pr-lib.sh - the single owner of the routine PR outcomes opt-in
# (docs/configuration.md "Routine PR outcomes") and of the facts every
# consumer of it tests before it keeps a PR-only event off MAIN.
#
# The opt-in is the local, gitignored file config/routine-pr-outcomes: a
# regular file (not a symlink) opts the home in, whatever it holds. It is never
# inferred from whether a pane or mod is installed. Without it every consumer
# behaves exactly as before.
#
# A parked PR is an ordinary ship task waiting on the captain's merge call that
# nothing but its PR state can change: its record says kind=ship (or no kind),
# yolo=off, and a delivery mode other than local-only, and its merge poll is
# armed and valid for the PR its record names (bin/fm-pr-lib.sh
# fm_pr_poll_artifacts_valid), so a merge or a close still wakes this home.
# A yolo=on ship is never parked, because MAIN merges that one itself.
#
# A task still working is one whose newest status event is a working or
# paused line: its worker took on more work after the PR it reported, so a
# merge of that PR is not the task's end and a cleanup that refuses is expected.
#
# Consumers, each owning its own use:
#   bin/fm-branch-report.sh      a host-recorded PR-ready or merge-landed outcome
#   bin/fm-branch-dispatch.mjs   the attended offer of a merge-landed check, read
#                                in a fresh process at every close so a host
#                                started before an update still sees the gate
#   bin/fm-inactive-reconcile.sh an inactive done ship with a parked PR
#   bin/fm-contributions.sh      a review with no body, or an automated
#                                review that leaves no open finding
#
# Sourced only; no side effects on source beyond bin/fm-pr-lib.sh.

_FM_ROUTINE_PR_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
command -v fm_pr_poll_artifacts_valid >/dev/null 2>&1 || {
  # shellcheck source=bin/fm-pr-lib.sh
  . "$_FM_ROUTINE_PR_LIB_DIR/fm-pr-lib.sh"
}

# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_ROUTINE_PR_URL=

# 0 when <config-dir> opts this home in.
fm_routine_pr_outcomes_enabled() {  # <config-dir>
  [ -f "$1/routine-pr-outcomes" ] && [ ! -L "$1/routine-pr-outcomes" ]
}

# 0 when <task> in <state> is a parked PR (see above). With <pr-url>, that URL
# must also name the PR the armed poll watches. On success FM_ROUTINE_PR_URL
# holds the armed poll's canonical PR URL.
fm_routine_pr_task_parked() {  # <state> <task> [<pr-url>]
  local state=$1 task=$2 want=${3-} meta kind yolo mode
  # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
  FM_ROUTINE_PR_URL=
  fm_pr_task_id_valid "$task" || return 1
  meta="$state/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  kind=$(sed -n 's/^kind=//p' "$meta" 2>/dev/null | tail -n 1)
  yolo=$(sed -n 's/^yolo=//p' "$meta" 2>/dev/null | tail -n 1)
  mode=$(sed -n 's/^mode=//p' "$meta" 2>/dev/null | tail -n 1)
  case "$kind" in ''|ship) ;; *) return 1 ;; esac
  [ "$yolo" = off ] || return 1
  [ "$mode" != local-only ] || return 1
  fm_pr_poll_artifacts_valid "$state" "$task" "$_FM_ROUTINE_PR_LIB_DIR/fm-pr-poll.sh" || return 1
  [ -n "$FM_PR_DATA_URL" ] || return 1
  if [ -n "$want" ]; then
    fm_pr_url_parse "$want" || return 1
    [ "$FM_PR_URL" = "$FM_PR_DATA_URL" ] || return 1
  fi
  # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
  FM_ROUTINE_PR_URL=$FM_PR_DATA_URL
}

# 0 when <task>'s newest status event in <state> is a working or paused line
# (see above).
fm_routine_pr_task_working() {  # <state> <task>
  local last plain head
  fm_pr_task_id_valid "$2" || return 1
  command -v last_status_line >/dev/null 2>&1 || {
    # shellcheck source=bin/fm-classify-lib.sh
    . "$_FM_ROUTINE_PR_LIB_DIR/fm-classify-lib.sh"
  }
  last=$(last_status_line "$1/$2.status")
  [ -n "$last" ] || return 1
  _fm_status_unstamped "$last" plain
  head=${plain%%:*}
  case "${head%% *}" in
    working|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}") return 0 ;;
  esac
  return 1
}

# 0 when a contribution signal is routine news. <signal-json> is one pending
# contribution signal joined to its observed review:
#   {type, body, state, login, user_type, inline}
# where body is the review's full body, state its review state, login and
# user_type its author, and inline the number of inline review comments that
# review carries (absent on a signal recorded before that count existed).
# Two kinds of review are routine; comments and inline review comments always
# carry text and never are:
#   - A review with no body, in any review state: the body holds nothing but
#     whitespace, so its only news is the review state the PR itself shows.
#   - An automated review that leaves no open finding: a COMMENTED or APPROVED
#     review with a recorded inline count of zero, whose author is automated
#     (GitHub user type Bot, a login ending in [bot], or a login listed in
#     <config-dir>/review-bots), and whose body reports zero findings or only
#     resolved ones. The body test is deliberately conservative, because a
#     signal it misjudges as routine never wakes: no list item may name a
#     severity (a red, orange, or yellow marker, or an upper-case CRITICAL,
#     HIGH, MEDIUM, LOW, NIT, BLOCKER, MAJOR, MINOR, or P0-P3) without also
#     saying it is resolved (a check mark, or fixed, resolved, or addressed in
#     a resolved form such as "(fixed in ...", "is fixed", or "now resolved"),
#     either on the item itself or on its section lead, the nearest earlier
#     line that is neither blank nor a list item ("Resolved since last review").
#     When a line opens with a "Findings:" label holding counts, their sum must
#     not exceed the resolved list items; without such a line the body must say
#     "no findings", "0 findings", "no new findings", "no new issues", or an
#     equivalent with open, remaining, further, or outstanding. Any other review,
#     a human's included, stays an ordinary signal.
# <config-dir>/review-bots is optional: one GitHub login per line, compared
# case-insensitively, with blank lines and #-comments ignored. It names
# machine accounts the forge reports as ordinary users. A symlink is ignored.
fm_routine_pr_contribution_event() {  # <config-dir> <signal-json>
  local bots=
  if [ -f "$1/review-bots" ] && [ ! -L "$1/review-bots" ]; then
    bots=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1/review-bots" | tr '[:upper:]' '[:lower:]' | grep -v '^$') || bots=
  fi
  printf '%s' "$2" | jq -e --arg bots "$bots" '
    def item: test("^\\s*([-*+\u2022]|[0-9]+[.)])\\s");
    def severity: test("\ud83d\udd34|\ud83d\udfe0|\ud83d\udfe1|\\b(CRITICAL|HIGH|MEDIUM|LOW|NIT|BLOCKER|MAJOR|MINOR|P[0-3])\\b");
    def resolved: test("\u2705|\\((fixed|resolved|addressed)\\b|\\b(is|are|now|was|were|been)\\s+(fixed|resolved|addressed)\\b|\\b(fixed|resolved|addressed)\\s+(in|by|since|on)\\b"; "i");
    def zero: test("\\b(no|zero|0)\\s+((new|open|remaining|further|outstanding)\\s+)?findings?\\b|\\bno\\s+(new|open|remaining|further|outstanding)\\s+issues\\b"; "i");
    (.body // "") as $body
    | if .type != "review" then false
      elif ($body | test("\\S") | not) then true
      else
        (.login // "" | ascii_downcase) as $login
        # Each list item carries its section lead: the nearest earlier line
        # that is neither blank nor a list item.
        | (reduce ($body | split("\n")[]) as $line ({lead:"",items:[]};
            if ($line | item) then .items += [{text:$line,lead:.lead}]
            elif ($line | test("\\S")) then .lead = $line else . end) | .items) as $items
        | ([$items[] | select((.text | resolved) or (.lead | resolved))] | length) as $fixed
        | ([$body | split("\n")[] | select(test("^[\\s*_#>]*findings[\\s*_]*:"; "i"))] | first) as $count_line
        | ([($count_line // "") | scan("[0-9]+") | tonumber]) as $counts
        | (.state | IN("COMMENTED","APPROVED"))
          and (.inline == 0)
          and (.user_type == "Bot" or ($login | endswith("[bot]"))
               or ($login != "" and ([$bots | split("\n")[] | select(. != "")] | index($login)) != null))
          and ([$items[] | select((.text | severity) and ((.text | resolved) or (.lead | resolved) | not))] | length) == 0
          and (if ($counts | length) > 0 then ($counts | add) <= $fixed else ($body | zero) end)
      end' >/dev/null 2>&1
}
