#!/usr/bin/env bash
# fm-decision.sh - answer or drop a decision waiting for the captain, from any
# terminal or view.
#
# Usage:
#   fm-decision.sh resolve [--source <provenance>] <task-id> <answer>...
#   fm-decision.sh resolve [--source <provenance>] <task-id> -   (answer on stdin)
#   fm-decision.sh drop [--source <provenance>] <task-id>
#
# A decision is a backlog task held for the captain in this home
# (.agents/skills/captain-hold-lifecycle/SKILL.md owns that policy). This
# command records the captain's choice through the one durable owner and then
# wakes Firstmate to act on it; it decides nothing else.
#
#   resolve  records the answer exactly as given through
#            `bin/fm-captain-hold.sh answer`. A question-shaped call (a task of
#            kind `captain`) closes there; a held work item is answered with
#            `--release`, which lifts the hold so the work can go on as the
#            answer directs. Either way Firstmate does what the answer asks.
#   drop     records the answer `Drop this.` the same way without `--release`,
#            so the call closes whatever its kind.
#
# After the answer is recorded, one `bin/fm-inbox.sh note` carrying the task,
# the outcome and the captain's words raises the check wake that tells
# Firstmate to act. Once answered the task no longer waits for the captain, so
# repeating the command is refused rather than recorded or woken twice.
# Nothing here dispatches, closes, or releases anything beyond what the answer
# path itself does.
#
# Refusals, with nothing recorded and no wake:
#   exit 2  bad usage, an answer that is empty or over 8192 bytes, or a backlog
#           that cannot be read;
#   exit 1  a task id this home's backlog does not hold, a task that is not
#           waiting for the captain, or an answer the owner refused.
# Exit 3 means the answer was recorded but the wake could not be raised; the
# message names the `fm-inbox.sh announce` that repairs it.
#
# --source names where the answer came from (default `a terminal`); it is
# provenance in the note, never a behavior switch.
#
# Environment: FM_HOME selects the home (default: the code root), and the
# FM_STATE_OVERRIDE / FM_DATA_OVERRIDE / FM_CONFIG_OVERRIDE overrides reach the
# owner scripts unchanged.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME="${FM_HOME:-$FM_ROOT}"

DROP_ANSWER='Drop this.'

usage() {
  sed -n '5,7p' "$0" | sed 's/^# \{0,1\}//'
}

die() {  # <code> <message>
  printf 'fm-decision: %s\n' "$2" >&2
  exit "$1"
}

verb=${1:-}
case "$verb" in
  resolve|drop) shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

source_name='a terminal'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      source_name=$(printf '%s' "$2" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-200)
      shift 2
      ;;
    --) shift; break ;;
    -?*) usage >&2; exit 2 ;;
    *) break ;;
  esac
done

id=${1:-}
[ -n "$id" ] || { usage >&2; exit 2; }
shift
case "$id" in
  *[!A-Za-z0-9._-]*) die 2 "task id must be a backlog slug: $id" ;;
esac

if [ "$verb" = drop ]; then
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  answer=$DROP_ANSWER
elif [ "$#" -eq 1 ] && [ "$1" = - ]; then
  answer=$(cat)
else
  answer="$*"
fi
[ -n "${answer//[[:space:]]/}" ] || die 2 "the answer is empty"
[ "$(printf '%s' "$answer" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] || die 2 "the answer is over 8192 bytes"

held_rc=0
"$SCRIPT_DIR/fm-captain-hold.sh" open "$id" --distinguish-absent || held_rc=$?
case "$held_rc" in
  0) ;;
  1) die 1 "task $id is not waiting for the captain" ;;
  3) die 1 "this home's backlog has no task $id" ;;
  *) die 2 "this home's backlog could not be read for $id" ;;
esac

release=''
if [ "$verb" = resolve ]; then
  shown=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" 2>/dev/null) || die 2 "task $id could not be read"
  kind=$(printf '%s\n' "$shown" | sed -n 's/^  kind: *//p' | head -n 1)
  [ "$kind" = captain ] || release=--release
fi

decision=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-decision.XXXXXX") || die 2 "cannot stage the answer"
trap 'rm -f -- "$decision"' EXIT
printf '%s\n' "$answer" > "$decision"

# shellcheck disable=SC2086  # release is empty or the single literal flag.
if ! recorded=$("$SCRIPT_DIR/fm-captain-hold.sh" answer "$id" --decision-file "$decision" $release 2>&1); then
  die 1 "the answer was not recorded on $id: $(printf '%s' "$recorded" | tr '\n' ' ' | sed 's/^fm-captain-hold: //')"
fi

if [ -n "$release" ]; then outcome='recorded; the hold is lifted for Firstmate to act on the answer'
else outcome='recorded; the call is closed'; fi
if command -v shasum >/dev/null 2>&1; then digest=$(printf '%s\n%s' "$id" "$answer" | shasum -a 256 | cut -c1-16)
else digest=$(printf '%s\n%s' "$id" "$answer" | sha256sum | cut -c1-16); fi
note=$(printf 'Decision %s answered through %s (%s).\nAnswer: %s\nAct on the answer.\n' \
  "$id" "$source_name" "$outcome" "$answer")
note_rc=0
saved=$(printf '%s' "$note" | "$SCRIPT_DIR/fm-inbox.sh" note --request-id "fm-decision:${id:0:100}:$digest" --json - 2>/dev/null) || note_rc=$?
case "$note_rc" in
  0) ;;
  3)
    note_id=$(printf '%s' "$saved" | sed -n 's/.*"note_id": *"\([^"]*\)".*/\1/p')
    printf 'fm-decision: %s: %s, but Firstmate was not woken; run: FM_HOME=%q %q announce %s\n' \
      "$id" "$outcome" "$FM_HOME" "$SCRIPT_DIR/fm-inbox.sh" "${note_id:-<note-id>}" >&2
    exit 3
    ;;
  *) printf 'fm-decision: %s: %s, but the note for Firstmate could not be saved; tell Firstmate in chat\n' "$id" "$outcome" >&2; exit 3 ;;
esac

if [ "$verb" = drop ]; then printf 'dropped: %s (%s); Firstmate is told\n' "$id" "$outcome"
else printf 'resolved: %s (%s); Firstmate is told\n' "$id" "$outcome"; fi
