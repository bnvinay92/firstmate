#!/usr/bin/env bash
# fm-decision.sh - answer or drop a decision waiting for the captain, or pass a
# batch of answers and pull request actions on together, from any terminal or
# view.
#
# Usage:
#   fm-decision.sh resolve [--source <provenance>] <task-id> <answer>...
#   fm-decision.sh resolve [--source <provenance>] <task-id> -   (answer on stdin)
#   fm-decision.sh drop [--source <provenance>] <task-id>
#   fm-decision.sh batch [--source <provenance>]   (one line per answer on stdin)
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
#   batch    reads one line per answer from stdin and passes them all on with
#            one note:
#              resolve <task-id> <answer...>   as resolve, on one line
#              drop <task-id>                  as drop
#              merge <pull-request-url>        the captain's go to merge it
#              fix <pull-request-url> [<note...>]
#                                              have its worker fix what keeps
#                                              it from merging
#              close <pull-request-url>        close it without merging
#            Blank lines are skipped. Every line is checked before anything is
#            recorded: one malformed line, a repeated target, or a decision not
#            waiting for the captain refuses the whole batch, naming each line,
#            with nothing recorded. The pull request actions record nothing
#            here; the note asks Firstmate to act, and a merge still goes
#            through Firstmate's guarded merge path, which refuses a red or
#            unready pull request.
#
# After the answers are recorded, one `bin/fm-inbox.sh note` carrying each
# task or pull request, the outcome and the captain's words raises the one
# check wake that tells Firstmate to act. Once answered a task no longer waits
# for the captain, so repeating the command is refused rather than recorded or
# woken twice.
# Nothing here dispatches, merges, closes, or releases anything beyond what the
# answer path itself does.
#
# Output: one stdout line per answer passed on, `<verb>: <task-id or url>
# (<outcome>)`, printed before the wake is raised, then for a batch
# `Firstmate is told: one note for <n> answer(s)` once it is (a single resolve or
# drop says it on its own line). Refusals go to stderr as
# `fm-decision: <target>: <reason>`.
#
# Refusals, with nothing recorded and no wake:
#   exit 2  bad usage, a malformed or empty batch, an answer that is empty or
#           over 8192 bytes, or a backlog that cannot be read;
#   exit 1  a task id this home's backlog does not hold, a task that is not
#           waiting for the captain, or an answer the owner refused.
# A batch whose answer the owner refuses after every line was checked (another
# writer answered it in between) still passes on the others it recorded, names
# the refused one, and exits 1.
# Exit 3 means the answers were recorded but the wake could not be raised; the
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
PR_URL_RE='^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+$'

usage() {
  sed -n '7,10p' "$0" | sed 's/^# \{0,1\}//'
}

die() {  # <code> <message>
  printf 'fm-decision: %s\n' "$2" >&2
  exit "$1"
}

verb=${1:-}
case "$verb" in
  resolve|drop|batch) shift ;;
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

# check_answer <answer>: the shared answer limits; prints the refusal reason.
check_answer() {
  if [ -z "${1//[[:space:]]/}" ]; then printf 'the answer is empty'; return 1; fi
  if [ "$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')" -gt 8192 ]; then printf 'the answer is over 8192 bytes'; return 1; fi
  return 0
}

# check_held <task-id> <verb>: whether the task waits for the captain. Sets
# REASON and returns 1 (refused) or 2 (unreadable) on failure; on success sets
# RELEASE to the answer flag the verb needs.
check_held() {
  local id=$1 kind held_rc=0 shown
  RELEASE=''
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$id" --distinguish-absent || held_rc=$?
  case "$held_rc" in
    0) ;;
    1) REASON="task $id is not waiting for the captain"; return 1 ;;
    3) REASON="this home's backlog has no task $id"; return 1 ;;
    *) REASON="this home's backlog could not be read for $id"; return 2 ;;
  esac
  [ "$2" = resolve ] || return 0
  shown=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" 2>/dev/null) || { REASON="task $id could not be read"; return 2; }
  kind=$(printf '%s\n' "$shown" | sed -n 's/^  kind: *//p' | head -n 1)
  [ "$kind" = captain ] || RELEASE=--release
  return 0
}

# record <task-id> <answer> <release>: record one answer through the owner.
# Sets OUTCOME on success and REASON on refusal.
record() {
  local decision recorded
  decision=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-decision.XXXXXX") || { REASON="cannot stage the answer"; return 1; }
  printf '%s\n' "$2" > "$decision"
  # shellcheck disable=SC2086  # release is empty or the single literal flag.
  if ! recorded=$("$SCRIPT_DIR/fm-captain-hold.sh" answer "$1" --decision-file "$decision" $3 2>&1); then
    rm -f -- "$decision"
    REASON="the answer was not recorded on $1: $(printf '%s' "$recorded" | tr '\n' ' ' | sed 's/^fm-captain-hold: //')"
    return 1
  fi
  rm -f -- "$decision"
  if [ -n "$3" ]; then OUTCOME='recorded; the hold is lifted for Firstmate to act on the answer'
  else OUTCOME='recorded; the call is closed'; fi
  return 0
}

digest_of() {  # <text>: a short stable digest for the note's request id.
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | cut -c1-16
  else printf '%s' "$1" | sha256sum | cut -c1-16; fi
}

# tell <request-id> <note> <what was recorded>: raise the one wake; exits 3
# when the note or its wake could not be saved.
tell() {
  local saved note_rc=0 note_id
  saved=$(printf '%s' "$2" | "$SCRIPT_DIR/fm-inbox.sh" note --request-id "$1" --json - 2>/dev/null) || note_rc=$?
  case "$note_rc" in
    0) return 0 ;;
    3)
      note_id=$(printf '%s' "$saved" | sed -n 's/.*"note_id": *"\([^"]*\)".*/\1/p')
      printf 'fm-decision: %s, but Firstmate was not woken; run: FM_HOME=%q %q announce %s\n' \
        "$3" "$FM_HOME" "$SCRIPT_DIR/fm-inbox.sh" "${note_id:-<note-id>}" >&2
      ;;
    *) printf 'fm-decision: %s, but the note for Firstmate could not be saved; tell Firstmate in chat\n' "$3" >&2 ;;
  esac
  exit 3
}

valid_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

if [ "$verb" != batch ]; then
  id=${1:-}
  [ -n "$id" ] || { usage >&2; exit 2; }
  shift
  valid_id "$id" || die 2 "task id must be a backlog slug: $id"
  if [ "$verb" = drop ]; then
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    answer=$DROP_ANSWER
  elif [ "$#" -eq 1 ] && [ "$1" = - ]; then
    answer=$(cat)
  else
    answer="$*"
  fi
  REASON=$(check_answer "$answer") || die 2 "$REASON"
  held_rc=0
  check_held "$id" "$verb" || held_rc=$?
  [ "$held_rc" = 0 ] || die "$held_rc" "$REASON"
  record "$id" "$answer" "$RELEASE" || die 1 "$REASON"
  note=$(printf 'Decision %s answered through %s (%s).\nAnswer: %s\nAct on the answer.\n' \
    "$id" "$source_name" "$OUTCOME" "$answer")
  tell "fm-decision:${id:0:100}:$(digest_of "$(printf '%s\n%s' "$id" "$answer")")" "$note" "$id: $OUTCOME"
  if [ "$verb" = drop ]; then printf 'dropped: %s (%s); Firstmate is told\n' "$id" "$OUTCOME"
  else printf 'resolved: %s (%s); Firstmate is told\n' "$id" "$OUTCOME"; fi
  exit 0
fi

# --- batch -------------------------------------------------------------------

[ "$#" -eq 0 ] || { usage >&2; exit 2; }
verbs=() targets=() answers=() releases=() refused=() worst=0 seen=' '
refuse() {  # <code> <target> <reason>
  refused+=("$2: $3")
  [ "$1" -le "$worst" ] || worst=$1
}
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  [ -n "${line//[[:space:]]/}" ] || continue
  read -r one target rest <<< "$line"
  target=${target:-}
  rest=${rest:-}
  case "$one" in
    resolve|drop)
      if ! valid_id "$target"; then refuse 2 "${target:-<none>}" "task id must be a backlog slug"; continue; fi
      if [ "$one" = drop ]; then
        [ -z "$rest" ] || { refuse 2 "$target" "drop takes no answer"; continue; }
        rest=$DROP_ANSWER
      fi
      REASON=$(check_answer "$rest") || { refuse 2 "$target" "$REASON"; continue; }
      ;;
    merge|close)
      [[ "$target" =~ $PR_URL_RE ]] || { refuse 2 "${target:-<none>}" "$one needs a GitHub pull request URL"; continue; }
      [ -z "$rest" ] || { refuse 2 "$target" "$one takes no note"; continue; }
      ;;
    fix)
      [[ "$target" =~ $PR_URL_RE ]] || { refuse 2 "${target:-<none>}" "fix needs a GitHub pull request URL"; continue; }
      [ "$(printf '%s' "$rest" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] || { refuse 2 "$target" "the note is over 8192 bytes"; continue; }
      ;;
    *) refuse 2 "${one:0:40}" "not a batch verb (resolve, drop, merge, fix, close)"; continue ;;
  esac
  case "$seen" in
    *" $target "*) refuse 2 "$target" "named twice in this batch"; continue ;;
  esac
  seen="$seen$target "
  verbs+=("$one") targets+=("$target") answers+=("$rest") releases+=('')
done
[ "${#verbs[@]}" -gt 0 ] || [ "${#refused[@]}" -gt 0 ] || die 2 "the batch is empty"

# Check every decision is still waiting before recording any answer.
for i in "${!verbs[@]}"; do
  case "${verbs[$i]}" in resolve|drop) ;; *) continue ;; esac
  held_rc=0
  check_held "${targets[$i]}" "${verbs[$i]}" || held_rc=$?
  if [ "$held_rc" = 0 ]; then releases[i]=$RELEASE
  else refuse "$held_rc" "${targets[$i]}" "$REASON"; fi
done
if [ "${#refused[@]}" -gt 0 ]; then
  for one in "${refused[@]}"; do printf 'fm-decision: %s\n' "$one" >&2; done
  for target in "${targets[@]}"; do
    case " ${refused[*]} " in
      *" $target: "*) ;;
      *) printf 'fm-decision: %s: not recorded, because another line in this batch was refused\n' "$target" >&2 ;;
    esac
  done
  exit "$worst"
fi

note=$(printf 'Answers submitted together through %s; act on each:' "$source_name")
said=() late=0
for i in "${!verbs[@]}"; do
  one=${verbs[$i]} target=${targets[$i]} answer=${answers[$i]}
  case "$one" in
    resolve|drop)
      if ! record "$target" "$answer" "${releases[$i]}"; then
        printf 'fm-decision: %s: %s\n' "$target" "$REASON" >&2
        late=1
        continue
      fi
      past=resolved
      [ "$one" = resolve ] || past=dropped
      note=$(printf '%s\n- Decision %s %s (%s). Answer: %s' "$note" "$target" "$past" "$OUTCOME" "$answer")
      said+=("$past: $target ($OUTCOME)")
      ;;
    merge)
      note=$(printf '%s\n- Pull request %s: merge it. This is the captain'"'"'s go; land it through the guarded merge path, which refuses it unless it is green and ready.' "$note" "$target")
      said+=("merge: $target (passed to Firstmate)")
      ;;
    fix)
      if [ -n "$answer" ]; then
        note=$(printf '%s\n- Pull request %s: have its worker fix what keeps it from merging (failing checks, conflicts, review comments). Note: %s' "$note" "$target" "$answer")
      else
        note=$(printf '%s\n- Pull request %s: have its worker fix what keeps it from merging (failing checks, conflicts, review comments).' "$note" "$target")
      fi
      said+=("fix: $target (passed to Firstmate)")
      ;;
    close)
      note=$(printf '%s\n- Pull request %s: close it without merging.' "$note" "$target")
      said+=("close: $target (passed to Firstmate)")
      ;;
  esac
done
[ "${#said[@]}" -gt 0 ] || exit 1
note=$(printf '%s\n' "$note")
printf '%s\n' "${said[@]}"
tell "fm-decision:batch:$(digest_of "$note")" "$note" "${#said[@]} answers were passed on"
plural=s
[ "${#said[@]}" -gt 1 ] || plural=''
printf 'Firstmate is told: one note for %d answer%s\n' "${#said[@]}" "$plural"
exit "$late"
