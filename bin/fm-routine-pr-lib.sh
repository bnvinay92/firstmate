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
# Consumers, each owning its own use:
#   bin/fm-branch-report.sh     a host-recorded PR-ready outcome
#   bin/fm-supervision-host.sh  the attended offer of a merge-landed check
#   bin/fm-inactive-reconcile.sh an inactive done ship with a parked PR
#   bin/fm-contributions.sh     an approval review with no body
#
# Sourced only; no side effects on source beyond bin/fm-pr-lib.sh.

_FM_ROUTINE_PR_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
command -v fm_pr_poll_artifacts_valid >/dev/null 2>&1 || {
  # shellcheck source=bin/fm-pr-lib.sh
  . "$_FM_ROUTINE_PR_LIB_DIR/fm-pr-lib.sh"
}

# 0 when <config-dir> opts this home in.
fm_routine_pr_outcomes_enabled() {  # <config-dir>
  [ -f "$1/routine-pr-outcomes" ] && [ ! -L "$1/routine-pr-outcomes" ]
}

# 0 when <task> in <state> is a parked PR (see above). With <pr-url>, that URL
# must also name the PR the armed poll watches. On success FM_ROUTINE_PR_URL
# holds the armed poll's canonical PR URL.
fm_routine_pr_task_parked() {  # <state> <task> [<pr-url>]
  local state=$1 task=$2 want=${3-} meta kind yolo mode
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
  FM_ROUTINE_PR_URL=$FM_PR_DATA_URL
}

# 0 when a contribution signal is an approval review with no body: the type is
# review, the event token's final field (the review state) is APPROVED, and
# the body holds nothing but whitespace.
fm_routine_pr_contribution_event() {  # <type> <token> <body>
  [ "$1" = review ] || return 1
  [ "${2##*:}" = APPROVED ] || return 1
  case "$3" in *[![:space:]]*) return 1 ;; esac
  return 0
}
