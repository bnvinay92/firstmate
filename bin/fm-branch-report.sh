#!/usr/bin/env bash
# fm-branch-report.sh - the supervision branch's report surface off Pi: the
# command twin of the Pi branch extension's fm_branch_report tool, for a
# branch session run by the supervision host (docs/supervision-host.md).
#
# It records exactly one handled fleet event in the durable outcome store
# (bin/fm-branch-outcome.sh owns the store) and gives the host the receipt it
# requires before it counts a wake handled. It enforces the same scoping the
# Pi tool does (docs/pi-supervision-branch.md "Components and their owners"):
# while the host's current turn claims signal or stale rows, only the tasks
# those rows resolve to may be reported - `fleet` and any remembered task are
# refused before the store is touched - and a claim that names no task (a
# heartbeat review, or a claimed heartbeat or check row) is unscoped. The
# claimed task set comes from .pi/extensions/lib/fm-branch-dispatch.ts through
# the host's turn record; this script only compares against it.
#
# Usage:
#   fm-branch-report.sh --task <id|fleet> --verdict routine|captain \
#       --summary <text> [--silent true|false] [--wake <text>]
#
# The verdict criteria are owned by bin/fm-branch-prompt.sh ("Verdict: routine
# or captain"); --silent true is legal only for a routine outcome.
# --wake defaults to the wake reason the host recorded for the turn.
#
# Routine child outcomes (docs/configuration.md "Routine child outcomes"): when
# config/routine-child-outcomes lists the reported task, the task's meta says
# kind=secondmate, and every row the turn claims is still queued as a plain
# signal row (no stale, check, heartbeat, or needs-decision row), a captain
# report is appended with --routine-child-outcomes, so bin/fm-branch-outcome.sh
# stores it routine exactly when the status lines it covers are all that
# secondmate's per-child child-outcome-* lines. The receipt and response carry
# the stored verdict, so such an outcome never opens a MAIN turn.
#
# Routine PR outcomes (docs/configuration.md "Routine PR outcomes"): while
# config/routine-pr-outcomes opts the home in (bin/fm-routine-pr-lib.sh owns the
# gate and the parked-PR test), a captain report is stored routine in two cases.
# PR ready: the reported task is a parked PR and every claimed row is still
# queued as a plain signal row; the report is appended with --routine-pr-ready
# and the armed PR's URL, so bin/fm-branch-outcome.sh stores it routine exactly
# when the status lines it covers are that PR's ready line and working lines.
# Merge landed: every claimed row is a `check: merge landed: <task> ...` row for
# the reported task and that task's record is already gone, which only a
# completed bin/fm-teardown.sh leaves (its landed-work test, clone refresh, and
# backlog completion all ran); a refused or skipped cleanup keeps the record
# and so keeps the captain verdict.
#
# Only the branch actor of a live host turn may report: FM_SUPERVISION_ACTOR
# must be "branch" and FM_BRANCH_REPORT_TURN must name the host's current turn
# record ($STATE/.supervision-host-turn), so a report typed after its turn
# ended, or from any other shell, is refused. Exit codes: 0 recorded, 1 the
# store refused or failed (nothing recorded), 2 usage, 3 refused (actor, turn,
# or scope).
#
# A non-silent row an away turn recorded after the captain returned (the turn
# record says posture=away, or predates the posture field, and no away record
# remains: none, or quiet mode's, whose captain is present; bin/fm-afk-contract.sh
# AWAY OR QUIET) may be missing from the return brief, so it is also queued
# for MAIN as a durable check wake keyed supervision-host-return:<seq>,
# presented by the drain until MAIN acknowledges it. bin/fm-afk-return.sh
# archives the record before it reads the store and this check follows the
# append, so every visible row is in the brief, queued, or both: the relay does
# not depend on the host surviving its turn or on its owner delivering the
# host's own handback. Silent outcomes remain in the store but are not queued
# or relayed as notes. An attended turn queues nothing: its captain rows reach
# MAIN through the host's branch-outcome exit and the drain's BRANCH OUTCOMES
# section (bin/fm-wake-drain.sh), and its routine rows stay in the store.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
TURN_FILE="$STATE/.supervision-host-turn"
RECEIPTS="$STATE/.supervision-host-receipts"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"
# shellcheck source=bin/fm-routine-pr-lib.sh
. "$SCRIPT_DIR/fm-routine-pr-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^# --wake/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

refuse() {
  printf 'report refused: %s\n' "$1" >&2
  exit 3
}

TASK='' VERDICT='' SUMMARY='' SILENT=false WAKE='' WAKE_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task) TASK=${2:-}; shift 2 || usage ;;
    --verdict) VERDICT=${2:-}; shift 2 || usage ;;
    --summary) SUMMARY=${2:-}; shift 2 || usage ;;
    --silent) SILENT=${2:-}; shift 2 || usage ;;
    --wake) WAKE=${2:-}; WAKE_SET=1; shift 2 || usage ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

TASK=$(printf '%s' "$TASK" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
SUMMARY=$(printf '%s' "$SUMMARY" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
case "$VERDICT" in routine|captain) ;; *) VERDICT= ;; esac
case "$SILENT" in true|false) ;; *) usage ;; esac
if [ -z "$TASK" ] || [ -z "$SUMMARY" ] || [ -z "$VERDICT" ]; then
  echo "invalid report: --task, --verdict (routine|captain), and --summary are required" >&2
  exit 2
fi
if [ "$SILENT" = true ] && [ "$VERDICT" != routine ]; then
  echo "invalid report: --silent true requires the routine verdict" >&2
  exit 2
fi

[ "${FM_SUPERVISION_ACTOR:-}" = branch ] \
  || refuse "only the supervision branch reports outcomes; MAIN acts on them instead"
TURN=${FM_BRANCH_REPORT_TURN:-}
case "$TURN" in
  ''|*[!A-Za-z0-9._-]*) refuse "no supervision wake is being handled by this shell" ;;
esac

turn_field() {  # <name>
  sed -n "s/^$1=//p" "$TURN_FILE" 2>/dev/null | head -n 1
}

[ -f "$TURN_FILE" ] && [ ! -L "$TURN_FILE" ] \
  || refuse "the wake this shell was handling is over; report only while handling a wake"
[ "$(turn_field turn)" = "$TURN" ] \
  || refuse "the wake this shell was handling is over; report only while handling a wake"

if [ "$(turn_field unscoped)" != 1 ]; then
  TASKS=$(turn_field tasks)
  case " $TASKS " in
    *" $TASK "*) ;;
    *)
      refuse "the wake being handled (row $(turn_field rows)) names ${TASKS:-no task}, not $TASK; report only that task, never fleet or a task from memory"
      ;;
  esac
fi

[ "$WAKE_SET" -eq 1 ] || WAKE=$(turn_field wake)

# 0 when every row the turn claims is still queued and is, for <shape> signal,
# a plain signal row (no stale, check, heartbeat, or needs-decision row), or,
# for <shape> merge, a merge-landed check row naming the reported task.
claimed_rows_are() {  # signal|merge
  local rows queue
  rows=$(turn_field rows)
  queue=${FM_WAKE_QUEUE:-$STATE/.wake-queue}
  [ -n "$rows" ] && [ -f "$queue" ] || return 1
  awk -F '\t' -v seqs="$rows" -v shape="$1" -v merged="check: merge landed: $TASK " '
    BEGIN { n = split(seqs, list, " "); for (i = 1; i <= n; i++) want[list[i]] = 1 }
    NF >= 5 && ($2 in want) {
      if (shape == "signal" && ($3 != "signal" || $5 ~ /^needs-decision:/)) bad = 1
      if (shape == "merge" && ($3 != "check" || index($5, merged) != 1)) bad = 1
      delete want[$2]
    }
    END { for (s in want) bad = 1; exit bad }
  ' "$queue"
}

# 0 when this captain report may have its verdict decided by the covered span;
# see "Routine child outcomes" above.
routine_child_outcomes_eligible() {
  [ "$VERDICT" = captain ] && [ "$(turn_field unscoped)" != 1 ] || return 1
  [ -f "$CONFIG/routine-child-outcomes" ] \
    && sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' "$CONFIG/routine-child-outcomes" 2>/dev/null \
      | grep -qxF -- "$TASK" || return 1
  [ "$(sed -n 's/^kind=//p' "$STATE/$TASK.meta" 2>/dev/null | tail -n 1)" = secondmate ] || return 1
  claimed_rows_are signal
}

# 0 when this captain report may be stored routine as a PR-ready outcome, with
# FM_ROUTINE_PR_URL naming the armed PR; see "Routine PR outcomes" above.
routine_pr_ready_eligible() {
  [ "$VERDICT" = captain ] && [ "$(turn_field unscoped)" != 1 ] || return 1
  fm_routine_pr_outcomes_enabled "$CONFIG" || return 1
  fm_routine_pr_task_parked "$STATE" "$TASK" || return 1
  claimed_rows_are signal
}

# 0 when this captain report is a completed merge-landed cleanup; see "Routine
# PR outcomes" above.
routine_merge_landed() {
  [ "$VERDICT" = captain ] && [ "$(turn_field unscoped)" != 1 ] || return 1
  fm_routine_pr_outcomes_enabled "$CONFIG" || return 1
  fm_pr_task_id_valid "$TASK" || return 1
  [ ! -e "$STATE/$TASK.meta" ] && [ ! -L "$STATE/$TASK.meta" ] || return 1
  claimed_rows_are merge
}

set -- append --task "$TASK" --verdict "$VERDICT" --summary "$SUMMARY" --silent "$SILENT"
[ -z "$WAKE" ] || set -- "$@" --wake "$WAKE"
DEMOTABLE=0 DEMOTED_WHY=
if routine_child_outcomes_eligible; then
  DEMOTABLE=1
  DEMOTED_WHY="$TASK is listed in config/routine-child-outcomes and these status lines are only its per-child outcomes"
  set -- "$@" --routine-child-outcomes
elif routine_pr_ready_eligible; then
  DEMOTABLE=1
  DEMOTED_WHY="config/routine-pr-outcomes is set and these status lines only say $TASK's PR is ready"
  set -- "$@" --routine-pr-ready "$FM_ROUTINE_PR_URL"
elif routine_merge_landed; then
  VERDICT=routine
  set -- append --task "$TASK" --verdict routine --summary "$SUMMARY" --silent "$SILENT"
  [ -z "$WAKE" ] || set -- "$@" --wake "$WAKE"
  DEMOTED_WHY="config/routine-pr-outcomes is set and $TASK's PR merged and its cleanup completed"
fi
if ! SEQ=$("$SCRIPT_DIR/fm-branch-outcome.sh" "$@"); then
  echo "outcome store append failed (nothing recorded)" >&2
  exit 1
fi
[ "$DEMOTABLE" -eq 1 ] || [ -z "$DEMOTED_WHY" ] || printf 'stored as routine: %s\n' "$DEMOTED_WHY"
if [ "$DEMOTABLE" -eq 1 ]; then
  STORED=${SEQ#* }
  SEQ=${SEQ%% *}
  if [ "$STORED" = routine ]; then
    VERDICT=routine
    printf 'stored as routine: %s\n' "$DEMOTED_WHY"
  fi
fi
printf '%s\t%s\t%s\t%s\n' "$TURN" "$SEQ" "$VERDICT" "$TASK" >> "$RECEIPTS" || {
  echo "recorded seq $SEQ, but the host receipt could not be written; the host will hand this wake to MAIN" >&2
  exit 1
}
if [ "$SILENT" = true ]; then
  printf 'recorded seq %s [routine]; silent outcome remains in the outcome store\n' "$SEQ"
  exit 0
fi
if [ "$(turn_field posture)" = attended ]; then
  if [ "$VERDICT" = captain ] && ! fm_afk_contract_away_present "$STATE"; then
    printf 'recorded seq %s [captain]; MAIN processes it from its next drain\n' "$SEQ"
  else
    printf 'recorded seq %s [%s]; it waits in the outcome store for MAIN\n' "$SEQ" "$VERDICT"
  fi
  exit 0
fi
if ! fm_afk_contract_away_present "$STATE"; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if ! fm_wake_append check "supervision-host-return:$SEQ" \
    "check: supervision-host outcome $SEQ for $TASK [$VERDICT] was recorded after the captain returned, so the return brief may not show it; relay it to the captain: $SUMMARY"; then
    printf 'recorded seq %s [%s], but the captain has returned and its relay to MAIN could not be queued; the host hands this turn to MAIN\n' "$SEQ" "$VERDICT" >&2
    exit 0
  fi
  printf 'recorded seq %s [%s]; the captain has returned, so it is queued for MAIN to relay\n' "$SEQ" "$VERDICT"
  exit 0
fi
printf 'recorded seq %s [%s]; it waits in the outcome store for MAIN\n' "$SEQ" "$VERDICT"
