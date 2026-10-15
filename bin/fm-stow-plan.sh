#!/usr/bin/env bash
# Draft, review, and apply-only-approved mechanics for the internal /stow skill.
# Usage:
#   fm-stow-plan.sh check [<plan-file>]
#   fm-stow-plan.sh draft-request [--clear]
#   fm-stow-plan.sh collect [--homes <id,...>]
#   fm-stow-plan.sh show [<review-or-plan-file>]
#   fm-stow-plan.sh approve (--all | --only <list> | --except <list>) [--edit <n>=<text>]...
#   fm-stow-plan.sh split
#   fm-stow-plan.sh request <secondmate-id> [--clear]
#   fm-stow-plan.sh apply [--clear] [--approved <file> | --from-request <file>]
#   fm-stow-plan.sh finish [--clear]
#   fm-stow-plan.sh --help
#
# The internal /stow skill owns what to propose; this command owns the plan
# format and the guarantee that nothing is written until the captain approved
# it, in the approved wording. Every path below is relative to FM_HOME.
#
# PLAN FORMAT. A draft is state/stow-plan.json in the home that drafted it:
#   {"version":1,"home":"<main|secondmate-id>","items":[<item>...]}
# Each item is one proposed write:
#   id        unique within the plan: 1-64 of letters, digits, '.', '_', '-'
#   section   memory   - startup-memory tiers (stamp, retier, decay, consolidate)
#             offload  - over-budget offload to an on-demand owner
#             knowledge - knowledge sweep and routing
#             records  - open-record persistence
#   action    add      - write entry as a new line in target (after the exact
#                        line "after" when given, else at the end)
#             rewrite  - replace the exact line "replaces" with entry
#             remove   - delete the exact line "replaces"; entry repeats it
#             archive  - delete the exact line "replaces" from target and add
#                        entry under today's "## YYYY-MM-DD stow" heading in
#                        data/memory-archive.md
#             record   - a write this command does not perform (a backlog item,
#                        a task note, a routed request); the agent applies it
#                        through that record's own owner, in the approved wording
#   target    add/rewrite/remove/archive: data/<name>.md; record: a one-line
#             owner reference such as "backlog" or "backlog:<task-id>"
#   entry     the exact one-line text to write; the only field review may edit
#   replaces  required for rewrite, remove, and archive
#   after     optional, add only
#   why       optional one-line reason shown beside the item
# A secondmate home may propose a data/captain-shared.md item, which collect
# routes to the primary's plan, but it never applies one.
#
# REVIEW. draft-request prints the marked request that asks a secondmate to
# draft its plan and reply with a pointer, or that its plan is empty. In a
# primary home, collect merges this home's draft (home "main") with each
# registered secondmate's draft into state/stow-review.json, or with only the
# secondmates --homes names (the homes that replied with a plan this round;
# main in that list, or an empty list, collects only this home):
#   {"version":1,"homes":[{"home":..,"items":[..]}..],"exceptions":[{"home":..,"reason":..}..]}
# A local secondmate's draft is read from its home; a remote one through
# fm-on.sh and fm-remote-file.sh get, bounded by FM_STOW_PLAN_TIMEOUT seconds
# (default 60). A home with no readable, valid draft becomes an exception. A
# secondmate item targeting data/captain-shared.md moves to "main" with the id
# "<secondmate-id>.<id>". Collect also removes any earlier approval.
# The review hands back state/stow-review.approved.json: the same shape holding
# only the approved items, each entry as approved. The stow-review Claude Code
# mod writes it from its pane; approve writes it from numbers chosen in chat,
# using the numbering show prints (home, then section, then target order).
#
# APPLY. split checks the approved review against the review: every approved
# item must exist there with only its entry changed (a remove's entry never
# changes). It writes state/stow-plan.approved.json for this home and
# state/stow-approved/<id>.json for every secondmate in the review, empty when
# nothing was approved there, so every home gets an answer. request <id> prints
# the marked request text that carries a secondmate's approved items.
# apply checks the approved items against this home's own reference again -
# state/stow-review.json's "main" entry in a primary home, state/stow-plan.json
# in a secondmate home - then writes only those items and prints one line each:
#   applied|skipped <id> <action> <target>: <entry or reason>
#   owner <id> <section> <target>: <entry>   (a record item for the agent)
# A line apply cannot find exactly once is skipped, never guessed.
# finish ends a round in which this home had nothing to save.
# Both consume the draft, the approval, and in a primary home the review, then
# record the round's end in state/stow-applied.json:
#   {"version":1,"at":<epoch>,"clear":<bool>,"homes":[{"home":..,"items":[..]}..]}
# naming the approved items (every home's, in a primary home), so they stay
# viewable afterwards. --clear marks a round the stow-review mod started; that
# mod clears the session of the home whose record it is, once per record.
#
# Exit status: 0 done; 3 apply skipped at least one approved item, or collect
# reported a home exception; 1 the input is unusable or refused; 2 invalid use.
set -u

usage() {
  sed -n '2,83{s/^# \{0,1\}//;p;}' "$0"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REGISTRY="$DATA/secondmates.md"
SUB_HOME_MARKER="${SUB_HOME_MARKER:-.fm-secondmate-home}"
PLAN="$STATE/stow-plan.json"
PLAN_APPROVED="$STATE/stow-plan.approved.json"
REVIEW="$STATE/stow-review.json"
REVIEW_APPROVED="$STATE/stow-review.approved.json"
SPLIT_DIR="$STATE/stow-approved"
APPLIED_RECORD="$STATE/stow-applied.json"
ARCHIVE_REL="data/memory-archive.md"
SHARED_REL="data/captain-shared.md"
BEGIN_MARK=FM_STOW_APPROVED_BEGIN
END_MARK=FM_STOW_APPROVED_END

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage_error() { usage >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is required"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-stow-plan.XXXXXX") || exit 1
# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap.
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

is_secondmate_home() { [ -e "$FM_HOME/$SUB_HOME_MARKER" ] || [ -L "$FM_HOME/$SUB_HOME_MARKER" ]; }

# This home's own name in a plan: "main", or the id its marker records.
home_name() {
  local id
  if is_secondmate_home; then
    id=$(head -1 "$FM_HOME/$SUB_HOME_MARKER" 2>/dev/null | tr -d '[:space:]')
    [ -n "$id" ] || die "the secondmate marker names no id: $FM_HOME/$SUB_HOME_MARKER"
    printf '%s\n' "$id"
  else
    printf 'main\n'
  fi
}

# jq definitions shared by every validator. plan_errors lists every problem
# with one {home, items} plan as a string, so an empty list means valid.
# shellcheck disable=SC2016 # jq, not the shell, reads these $ names.
JQ_DEFS='
def oneline: type == "string" and (test("[\n\r]") | not);
def nonempty: oneline and (gsub("\\s"; "") | length) > 0;
def ident: type == "string" and test("^[A-Za-z0-9._-]{1,64}$");
def sections: ["memory", "offload", "knowledge", "records"];
def actions: ["add", "rewrite", "remove", "archive", "record"];
def file_action: . == "add" or . == "rewrite" or . == "remove" or . == "archive";
def item_errors($where):
  . as $i
  | (if ($i | type) != "object" then ["\($where): an item must be an object"] else
      [ (if ($i.id | ident) then empty else "\($where): id must be 1-64 of letters, digits, ., _, -" end),
        (if (sections | index($i.section)) != null then empty else "\($where): section must be one of \(sections | join(", "))" end),
        (if (actions | index($i.action)) != null then empty else "\($where): action must be one of \(actions | join(", "))" end),
        (if ($i.target | nonempty) then empty else "\($where): target must be one nonempty line" end),
        (if ($i.entry | nonempty) then empty else "\($where): entry must be one nonempty line" end),
        (if ($i.action | type) == "string" and ($i.action | file_action) and ($i.target | type) == "string"
           and ($i.target | test("^data/[A-Za-z0-9._-]+\\.md$") | not)
         then "\($where): a \($i.action) target must be data/<name>.md" else empty end),
        (if ($i.action == "rewrite" or $i.action == "remove" or $i.action == "archive")
           and (($i.replaces | nonempty) | not)
         then "\($where): \($i.action) needs the exact line it replaces" else empty end),
        (if $i.action == "remove" and $i.replaces != $i.entry
         then "\($where): a remove entry must repeat the line it removes" else empty end),
        (if $i.action == "archive" and $i.target == "data/memory-archive.md"
         then "\($where): archive moves a line into the archive, not out of it" else empty end),
        (if has("after") | not then empty
         elif $i.action != "add" then "\($where): after applies to add only"
         elif ($i.after | nonempty) then empty
         else "\($where): after must be one nonempty line" end),
        (if ($i | has("replaces")) and $i.action != "rewrite" and $i.action != "remove" and $i.action != "archive"
         then "\($where): replaces applies to rewrite, remove, and archive only" else empty end),
        (if ($i | has("why")) and (($i.why | oneline) | not) then "\($where): why must be one line" else empty end),
        (($i | keys) - ["id", "section", "action", "target", "entry", "replaces", "after", "why"]
          | if length > 0 then "\($where): unknown field \(.[0])" else empty end)
      ] end);
def plan_errors:
  . as $p
  | if ($p | type) != "object" then ["the plan must be a JSON object"]
    elif ($p.home | ident | not) then ["home must be main or a secondmate id"]
    elif ($p.items | type) != "array" then ["items must be an array"]
    else
      [ $p.items[] | item_errors("\($p.home) item \(if type == "object" then .id // "?" else "?" end)")[] ] + [ $p.items
        | map(select(type == "object") | .id) | group_by(.) | map(select(length > 1) | .[0]) | .[]
        | "\($p.home): duplicate item id \(.)" ]
    end;
def section_label:
  {memory: "Startup-memory tiers", offload: "Over-budget offload",
   knowledge: "Knowledge routing", records: "Open-record persistence"}[.];
def ordered:
  [ .homes[] as $h
    | $h.items as $items
    | sections[] as $s
    | ($items | map(select(.section == $s))) as $in
    | ($in | map(.target) | reduce .[] as $t ([]; if index([$t]) then . else . + [$t] end))[] as $t
    | $in[] | select(.target == $t)
    | {home: $h.home, item: .} ]
  | to_entries | map(.value + {n: (.key + 1)});
def review_errors:
  if type != "object" or .version != 1 then ["the review must be a version 1 object"]
  elif (.homes | type) != "array" then ["homes must be an array"]
  else
    ([ .homes[] | {home, items} | plan_errors[] ])
    + [ .homes | map(.home) | group_by(.) | map(select(length > 1) | .[0]) | .[] | "duplicate home \(.)" ]
  end;
'

# check_plan_file <file> [expected-home]: validate a draft; print errors on stderr.
check_plan_file() {
  local file=$1 expected=${2:-} errors
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'error: no plan file: %s\n' "$file" >&2; return 1; }
  if ! errors=$(jq -r "$JQ_DEFS"'
      if type != "object" or .version != 1 then "the plan must be a version 1 object"
      else plan_errors[] end' "$file" 2>&1); then
    printf 'error: %s is not valid JSON: %s\n' "$file" "$errors" >&2
    return 1
  fi
  if [ -z "$errors" ] && [ -n "$expected" ]; then
    [ "$(jq -r '.home' "$file")" = "$expected" ] \
      || errors="the plan names home $(jq -r '.home' "$file"), not $expected"
  fi
  if [ -n "$errors" ]; then
    printf '%s\n' "$errors" | sed "s|^|error: $file: |" >&2
    return 1
  fi
}

# Atomic replacement inside the destination's own directory.
write_atomic() { # <dest> <source-file>
  local dest=$1 src=$2 tmp
  mkdir -p "$(dirname "$dest")" || return 1
  tmp=$(mktemp "$(dirname "$dest")/.fm-stow-plan.XXXXXX") || return 1
  if cat "$src" > "$tmp" && mv -f "$tmp" "$dest"; then return 0; fi
  rm -f "$tmp"
  return 1
}

cmd_check() {
  [ "$#" -le 1 ] || usage_error
  local file=${1:-$PLAN}
  check_plan_file "$file" || return 1
  printf 'ok %s: %s items\n' "$file" "$(jq '.items | length' "$file")"
}

# Read one secondmate's draft into <out>; set FETCH_REASON on failure.
FETCH_REASON=
fetch_secondmate_plan() { # <id> <home> <remote 0|1> <out>
  local id=$1 home=$2 remote=$3 out=$4 rc=0 bound=${FM_STOW_PLAN_TIMEOUT:-60}
  FETCH_REASON=
  if [ "$remote" -eq 1 ]; then
    fm_run_timed "$bound" "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-file.sh get state/stow-plan.json \
      < /dev/null > "$out" 2>/dev/null || rc=$?
    if [ "$rc" -eq 124 ]; then FETCH_REASON="reading its plan exceeded the ${bound}s bound"; return 1; fi
    if [ "$rc" -ne 0 ]; then FETCH_REASON="no plan could be read from the remote home"; return 1; fi
    return 0
  fi
  if ! validate_secondmate_home "$id" "$home"; then
    FETCH_REASON=$VALIDATION_ERROR
    return 1
  fi
  if [ ! -f "$VALIDATED_HOME/state/stow-plan.json" ] || [ -L "$VALIDATED_HOME/state/stow-plan.json" ]; then
    FETCH_REASON="no plan drafted in that home"
    return 1
  fi
  cat "$VALIDATED_HOME/state/stow-plan.json" > "$out"
}

cmd_collect() {
  local only='' only_set=0
  case "${1:-}" in
    '') [ "$#" -eq 0 ] || usage_error ;;
    --homes) [ "$#" -eq 2 ] || usage_error; only=",$2,"; only_set=1 ;;
    *) usage_error ;;
  esac
  # main is always collected, so naming it (or nothing) asks for no secondmate.
  while :; do
    case "$only" in *,main,*) only=${only/,main,/,} ;; *) break ;; esac
  done
  [ "$only" != ,, ] || only=,
  is_secondmate_home && die "collect runs in a primary home; a secondmate drafts its own plan only"
  check_plan_file "$PLAN" main || return 1
  local review="$TMP/review.json" exceptions=0 line id home remote out
  jq '{version: 1, homes: [{home: "main", items: .items}], exceptions: []}' "$PLAN" > "$review" || return 1

  if [ -e "$REGISTRY" ] || [ -L "$REGISTRY" ]; then
    # shellcheck source=bin/fm-ff-lib.sh
    . "$SCRIPT_DIR/fm-ff-lib.sh"
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$SCRIPT_DIR/fm-timeout-lib.sh"
    secondmate_registry_validate_bindings "$REGISTRY" secondmate_registry_path_key \
      || die "$SECONDMATE_REGISTRY_ERROR"
    grep '^- ' "$REGISTRY" > "$TMP/records" 2>/dev/null || : > "$TMP/records"
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      secondmate_registry_parse_line "$line" || die "malformed secondmate registry entry: $line"
      id=$SECONDMATE_REGISTRY_ID
      if [ "$only_set" -eq 1 ]; then
        case "$only" in *",$id,"*) only=${only/,$id,/,} ;; *) continue ;; esac
      fi
      home=$SECONDMATE_REGISTRY_HOME
      remote=$SECONDMATE_REGISTRY_REMOTE
      out="$TMP/plan-$id.json"
      if [ "$id" = main ]; then
        FETCH_REASON='a secondmate named main cannot be told apart from the primary'
      elif fetch_secondmate_plan "$id" "$home" "$remote" "$out"; then
        if check_plan_file "$out" "$id" 2> "$TMP/check.err"; then
          # A shared-preference item belongs to the primary's own plan.
          jq --slurpfile p "$out" --arg id "$id" --arg shared "$SHARED_REL" '
            ($p[0].items | map(select(.target != $shared))) as $own
            | ($p[0].items | map(select(.target == $shared) | .id = "\($id).\(.id)")) as $routed
            | .homes += [{home: $id, items: $own}]
            | .homes[0].items += $routed' "$review" > "$TMP/next.json" && mv "$TMP/next.json" "$review"
          continue
        fi
        FETCH_REASON="its plan is invalid: $(head -1 "$TMP/check.err" | sed 's/^error: //')"
      fi
      jq --arg id "$id" --arg reason "$FETCH_REASON" '.exceptions += [{home: $id, reason: $reason}]' \
        "$review" > "$TMP/next.json" && mv "$TMP/next.json" "$review"
      exceptions=$((exceptions + 1))
    done < "$TMP/records"
  fi

  case "$only" in
    ''|,) ;;
    *) die "not a registered secondmate: $(printf '%s' "$only" | sed 's/^,//; s/,$//')" ;;
  esac
  local errors
  errors=$(jq -r "$JQ_DEFS"'review_errors[]' "$review")
  [ -z "$errors" ] || die "the collected review is invalid: $errors"
  rm -f "$REVIEW_APPROVED"
  write_atomic "$REVIEW" "$review" || die "could not write $REVIEW"
  jq -r '(.homes[] | "home=\(.home) items=\(.items | length)"),
         (.exceptions[] | "exception home=\(.home) reason=\(.reason)")' "$REVIEW"
  printf 'review=%s\n' "$REVIEW"
  [ "$exceptions" -eq 0 ] || return 3
}

# The default file show reads: the review in a primary home, the draft otherwise.
as_review() { # <file> -> review-shaped JSON on stdout
  jq 'if has("homes") then . else {version: 1, homes: [{home, items}], exceptions: []} end' "$1"
}

cmd_show() {
  [ "$#" -le 1 ] || usage_error
  local file=${1:-}
  if [ -z "$file" ]; then
    if is_secondmate_home; then file=$PLAN; else file=$REVIEW; fi
  fi
  [ -f "$file" ] || die "nothing to show: $file does not exist"
  as_review "$file" > "$TMP/show.json" || die "$file is not valid JSON"
  local errors
  errors=$(jq -r "$JQ_DEFS"'review_errors[]' "$TMP/show.json")
  [ -z "$errors" ] || die "$file is invalid: $errors"
  jq -r "$JQ_DEFS"'
    . as $r
    | ordered as $rows
    | if ($rows | length) == 0 then "No proposed writes." else
        reduce $rows[] as $row ({out: [], home: null, section: null, target: null};
          (if $row.home != .home then .out += ["", "Home: \($row.home)"] | .section = null | .target = null else . end)
          | (if $row.item.section != .section then .out += ["  \($row.item.section | section_label)"] | .target = null else . end)
          | (if $row.item.target != .target then .out += ["    \($row.item.target)"] else . end)
          | .home = $row.home | .section = $row.item.section | .target = $row.item.target
          | .out += ["      \($row.n). [\($row.item.action)] \($row.item.entry)"]
          | (if $row.item.replaces and $row.item.action != "remove" then .out += ["         replaces: \($row.item.replaces)"] else . end)
          | (if $row.item.why then .out += ["         why: \($row.item.why)"] else . end))
        | .out[1:] | .[]
      end,
      ($r.exceptions // [] | .[] | "Not reviewable: \(.home) - \(.reason)")' "$TMP/show.json"
}

# Expand "1,3,5-7" into one number per line.
expand_list() { # <list>
  local part a b
  local IFS=,
  for part in $1; do
    case "$part" in
      *[!0-9-]*|''|-*|*-) die "not a number or range: $part" ;;
      *-*) a=${part%-*}; b=${part#*-}
        [ "$a" -le "$b" ] || die "backwards range: $part"
        seq "$a" "$b" ;;
      *) printf '%s\n' "$part" ;;
    esac
  done
}

cmd_approve() {
  local mode='' list='' edits="$TMP/edits.jsonl" n text
  : > "$edits"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all) [ -z "$mode" ] || usage_error; mode=all; shift ;;
      --only|--except) [ -z "$mode" ] && [ "$#" -ge 2 ] || usage_error; mode=${1#--}; list=$2; shift 2 ;;
      --edit) [ "$#" -ge 2 ] || usage_error
        n=${2%%=*}; text=${2#*=}
        case "$n" in ''|*[!0-9]*) die "an edit is <number>=<text>: $2" ;; esac
        [ "$n" != "$2" ] || die "an edit is <number>=<text>: $2"
        jq -cn --argjson n "$n" --arg text "$text" '{n: $n, text: $text}' >> "$edits"
        shift 2 ;;
      *) usage_error ;;
    esac
  done
  [ -n "$mode" ] || usage_error
  is_secondmate_home && die "approve runs in a primary home, where the captain reviews"
  [ -f "$REVIEW" ] || die "no review to approve: run collect first"
  local numbers="$TMP/numbers.json"
  if [ "$mode" = all ]; then
    printf '[]\n' > "$numbers"
  else
    expand_list "$list" > "$TMP/numbers.txt" || return 1
    jq -s '.' "$TMP/numbers.txt" > "$numbers" 2>/dev/null || jq -n '[]' > "$numbers"
  fi
  jq -s '.' "$edits" > "$TMP/edits.json"
  if ! jq "$JQ_DEFS"'
      ordered as $rows
      | ($rows | length) as $max
      | (($numbers[0] + ($edits[0] | map(.n))) | map(select(. < 1 or . > $max))) as $bad
      | if ($bad | length) > 0 then error("no item numbered \($bad[0]); the review has \($max)") else . end
      | ($rows | map(.n)) as $all
      | (if $mode == "all" then $all elif $mode == "only" then $numbers[0] else $all - $numbers[0] end) as $keep
      | ($edits[0] | map(select(.n as $n | $keep | index($n) | not))) as $stray
      | if ($stray | length) > 0 then error("item \($stray[0].n) is edited but not approved") else . end
      | ($edits[0] | map(select(.n as $n | $rows[$n - 1].item.action == "remove"))) as $rm
      | if ($rm | length) > 0 then error("item \($rm[0].n) removes a line; its text cannot be edited") else . end
      | ($rows | map(select(.n as $n | $keep | index($n)))
          | map(.n as $n | .item.entry = (($edits[0] | map(select(.n == $n)) | last | .text) // .item.entry))) as $chosen
      | {version: 1,
         homes: [ .homes[] | .home as $h
                  | {home: $h, items: [ $chosen[] | select(.home == $h) | .item ]}
                  | select(.items | length > 0) ]}' \
      --argjson numbers "[$(cat "$numbers")]" --slurpfile edits "$TMP/edits.json" --arg mode "$mode" \
      "$REVIEW" > "$TMP/approved.json" 2> "$TMP/approve.err"; then
    die "$(sed 's/^jq: error[^:]*: //' "$TMP/approve.err" | head -1)"
  fi
  local errors
  errors=$(jq -r "$JQ_DEFS"'review_errors[]' "$TMP/approved.json")
  [ -z "$errors" ] || die "the approved review is invalid: $errors"
  write_atomic "$REVIEW_APPROVED" "$TMP/approved.json" || die "could not write $REVIEW_APPROVED"
  jq -r '.homes[] | .home as $h | .items[] | "approved \($h) \(.id) [\(.action)] \(.target): \(.entry)"' "$REVIEW_APPROVED"
  printf 'approved=%s\n' "$REVIEW_APPROVED"
}

# approved_errors <reference-plan> <approved-plan>: one line per approved item
# that is not in the reference with only its entry changed.
# shellcheck disable=SC2016 # jq, not the shell, reads these $ names.
APPROVED_CHECK='
  ($ref[0].items | map({key: .id, value: .}) | from_entries) as $byid
  | [ (.items | map(.id) | group_by(.) | map(select(length > 1) | "duplicate approved id \(.[0])") | .[]),
      (.items[] as $a
       | ($byid[$a.id]) as $d
       | if $d == null then "\($a.id) is not in the plan that was reviewed"
         elif ($a | del(.entry)) != ($d | del(.entry)) then "\($a.id) changes more than its entry"
         elif $a.action == "remove" and $a.entry != $d.entry then "\($a.id) removes a line, so its entry cannot change"
         else empty end) ]
  | .[]'

approved_errors() { # <reference> <approved>
  jq -r --slurpfile ref "$1" "$APPROVED_CHECK" "$2"
}

cmd_split() {
  [ "$#" -eq 0 ] || usage_error
  is_secondmate_home && die "split runs in a primary home"
  [ -f "$REVIEW" ] || die "no review: run collect first"
  [ -f "$REVIEW_APPROVED" ] || die "no approved review: nothing was approved yet"
  local errors home
  errors=$(jq -r "$JQ_DEFS"'review_errors[]' "$REVIEW_APPROVED" 2>&1) || die "the approved review is not valid JSON"
  [ -z "$errors" ] || die "the approved review is invalid: $errors"
  errors=$(jq -r --slurpfile r "$REVIEW" '
      .homes[].home as $h | select(($r[0].homes | map(.home) | index($h)) == null)
      | "home \($h) was not in the review"' "$REVIEW_APPROVED")
  [ -z "$errors" ] || die "$errors"
  rm -rf "$SPLIT_DIR"
  mkdir -p "$SPLIT_DIR" || die "could not create $SPLIT_DIR"
  for home in $(jq -r '.homes[].home' "$REVIEW"); do
    jq --arg h "$home" '{version: 1, home: $h, items: (.homes[] | select(.home == $h) | .items)}' \
      "$REVIEW" > "$TMP/ref.json"
    jq --arg h "$home" '{version: 1, home: $h, items: ([.homes[] | select(.home == $h) | .items[]])}' \
      "$REVIEW_APPROVED" > "$TMP/one.json"
    errors=$(approved_errors "$TMP/ref.json" "$TMP/one.json")
    [ -z "$errors" ] || die "$home: $errors"
    if [ "$home" = main ]; then
      write_atomic "$PLAN_APPROVED" "$TMP/one.json" || die "could not write $PLAN_APPROVED"
    else
      write_atomic "$SPLIT_DIR/$home.json" "$TMP/one.json" || die "could not write $SPLIT_DIR/$home.json"
    fi
    printf 'home=%s approved=%s\n' "$home" "$(jq '.items | length' "$TMP/one.json")"
  done
}

# A request's own words: the secondmate's agent reads them, and apply reads
# only the JSON line between the markers.
cmd_draft_request() {
  local clear=''
  case "${1:-}" in
    '') [ "$#" -eq 0 ] || usage_error ;;
    --clear) [ "$#" -eq 1 ] || usage_error; clear=' --clear' ;;
    *) usage_error ;;
  esac
  printf '%s\n' \
    "Draft your /stow plan for the captain's review: run the stow pass in draft mode, write every proposed write to state/stow-plan.json, and write nothing else." \
    "When the plan has items, reply with one correlated line: bin/fm-secondmate-report.sh --doc done <corr> state/stow-plan.json \"<n> items drafted\"." \
    "When nothing is worth filing, run bin/fm-stow-plan.sh finish$clear and reply with one correlated line saying your plan is empty."
}

cmd_request() {
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage_error
  local id=$1 file clear=''
  case "${2:-}" in '') ;; --clear) clear=' --clear' ;; *) usage_error ;; esac
  case "$id" in ''|main|*[!A-Za-z0-9._-]*) die "not a secondmate id: $id" ;; esac
  file="$SPLIT_DIR/$id.json"
  [ -f "$file" ] || die "no approved split for $id: run split first"
  printf '%s\n' \
    "The captain reviewed your stow plan; apply only the approved items below, in their approved wording, and write nothing else from that plan." \
    "Run bin/fm-stow-plan.sh apply$clear --from-request <this message's file>, apply any owner lines it prints through their owners, then report one correlated line with bin/fm-secondmate-report.sh naming what you wrote." \
    "$(jq '.items | length' "$file") items approved." \
    "$BEGIN_MARK"
  jq -c '.' "$file"
  printf '%s\n' "$END_MARK"
}

# Exact-line edits. Every comparison is whole-line equality, so an entry's own
# characters are never read as a pattern.
count_line() { # <file> <line>
  [ -f "$1" ] || { printf '0\n'; return 0; }
  LINE=$2 awk 'BEGIN { n = 0 } $0 == ENVIRON["LINE"] { n++ } END { print n }' "$1"
}

edit_file() { # <file> <mode: replace|delete|after> <match> [text]
  local file=$1 mode=$2 tmp
  tmp=$(mktemp "$(dirname "$file")/.fm-stow-plan.XXXXXX") || return 1
  MODE=$mode MATCH=$3 TEXT=${4:-} awk '
    $0 == ENVIRON["MATCH"] {
      if (ENVIRON["MODE"] == "replace") { print ENVIRON["TEXT"]; next }
      if (ENVIRON["MODE"] == "delete") { next }
      if (ENVIRON["MODE"] == "after") { print; print ENVIRON["TEXT"]; next }
    }
    { print }' "$file" > "$tmp" && mv -f "$tmp" "$file" && return 0
  rm -f "$tmp"
  return 1
}

append_line() { # <file> <line>
  local file=$1
  mkdir -p "$(dirname "$file")" || return 1
  if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then printf '\n' >> "$file" || return 1; fi
  printf '%s\n' "$2" >> "$file"
}

archive_line() { # <entry>
  local archive="$FM_HOME/$ARCHIVE_REL" heading last
  heading="## $(date +%Y-%m-%d) stow"
  last=$(grep '^## ' "$archive" 2>/dev/null | tail -1)
  if [ "$last" != "$heading" ]; then
    if [ -s "$archive" ]; then append_line "$archive" "" || return 1; fi
    append_line "$archive" "$heading" || return 1
  fi
  append_line "$archive" "$1"
}

APPLIED=0
SKIPPED=0
OWNER=0
apply_item() { # <item-json>
  local item=$1 id action target entry replaces after file n
  id=$(jq -r '.id' <<<"$item")
  action=$(jq -r '.action' <<<"$item")
  target=$(jq -r '.target' <<<"$item")
  entry=$(jq -r '.entry' <<<"$item")
  replaces=$(jq -r '.replaces // ""' <<<"$item")
  after=$(jq -r '.after // ""' <<<"$item")
  skip() { printf 'skipped %s %s %s: %s\n' "$id" "$action" "$target" "$1"; SKIPPED=$((SKIPPED + 1)); }
  if [ "$action" = record ]; then
    printf 'owner %s %s %s: %s\n' "$id" "$(jq -r '.section' <<<"$item")" "$target" "$entry"
    OWNER=$((OWNER + 1))
    return 0
  fi
  if is_secondmate_home && [ "$target" = "$SHARED_REL" ]; then
    skip "a secondmate never writes the primary-owned shared preferences"
    return 0
  fi
  file="$FM_HOME/$target"
  if [ -L "$file" ] || { [ -e "$file" ] && [ ! -f "$file" ]; }; then
    skip "the target is not a regular file"
    return 0
  fi
  case "$action" in
    add)
      if [ "$(count_line "$file" "$entry")" -gt 0 ]; then skip "the line is already there"; return 0; fi
      if [ -n "$after" ]; then
        n=$(count_line "$file" "$after")
        [ "$n" -eq 1 ] || { skip "the line to add after appears $n times"; return 0; }
        edit_file "$file" after "$after" "$entry" || { skip "the write failed"; return 0; }
      else
        append_line "$file" "$entry" || { skip "the write failed"; return 0; }
      fi
      ;;
    rewrite|remove|archive)
      n=$(count_line "$file" "$replaces")
      [ "$n" -eq 1 ] || { skip "the line it replaces appears $n times"; return 0; }
      case "$action" in
        rewrite) edit_file "$file" replace "$replaces" "$entry" || { skip "the write failed"; return 0; } ;;
        remove) edit_file "$file" delete "$replaces" || { skip "the write failed"; return 0; } ;;
        archive)
          archive_line "$entry" || { skip "the archive write failed"; return 0; }
          edit_file "$file" delete "$replaces" || { skip "archived, but the source line could not be removed"; return 0; }
          ;;
      esac
      ;;
  esac
  printf 'applied %s %s %s: %s\n' "$id" "$action" "$target" "$entry"
  APPLIED=$((APPLIED + 1))
}

# end_round <clear 0|1> <home-items-json-file>: consume this home's round files
# and record its end, every home's approved items included in a primary home.
end_round() {
  local clear=$1 items=$2 at
  at=$(date +%s)
  if ! is_secondmate_home && [ -f "$REVIEW_APPROVED" ]; then
    jq --argjson at "$at" --argjson clear "$clear" --slurpfile own "$items" '
      {version: 1, at: $at, clear: ($clear == 1),
       homes: ([{home: "main", items: $own[0]}] + [.homes[] | select(.home != "main")])}' \
      "$REVIEW_APPROVED" > "$TMP/applied.json"
  else
    jq --argjson at "$at" --argjson clear "$clear" --arg home "$(home_name)" \
      '{version: 1, at: $at, clear: ($clear == 1), homes: [{home: $home, items: .}]}' "$items" > "$TMP/applied.json"
  fi
  rm -f "$PLAN" "$PLAN_APPROVED"
  if ! is_secondmate_home; then rm -f "$REVIEW" "$REVIEW_APPROVED"; fi
  write_atomic "$APPLIED_RECORD" "$TMP/applied.json" || die "could not record the end of this round in $APPLIED_RECORD"
}

cmd_apply() {
  local approved=$PLAN_APPROVED reference home errors item clear=0
  if [ "${1:-}" = --clear ]; then clear=1; shift; fi
  case "${1:-}" in
    '') [ "$#" -eq 0 ] || usage_error ;;
    --approved) [ "$#" -eq 2 ] || usage_error; approved=$2 ;;
    --from-request) [ "$#" -eq 2 ] || usage_error
      [ -f "$2" ] || die "no request file: $2"
      awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0 == e { inside = 0 } inside { print } $0 == b { inside = 1 }' \
        "$2" > "$TMP/request.json"
      [ -s "$TMP/request.json" ] || die "the request carries no approved stow items between $BEGIN_MARK and $END_MARK"
      approved="$TMP/request.json" ;;
    *) usage_error ;;
  esac
  home=$(home_name)
  if is_secondmate_home; then
    reference=$PLAN
    check_plan_file "$reference" "$home" || die "this home has no valid stow plan to apply against"
  else
    [ -f "$REVIEW" ] || die "no review in this home: collect, review, and split before apply"
    reference="$TMP/reference.json"
    jq '{version: 1, home: "main", items: (.homes[] | select(.home == "main") | .items)}' "$REVIEW" > "$reference" \
      || die "the review is unreadable"
  fi
  check_plan_file "$approved" "$home" || die "the approved items are not a valid plan for this home"
  errors=$(approved_errors "$reference" "$approved")
  [ -z "$errors" ] || die "refusing to apply: $(printf '%s' "$errors" | tr '\n' ';' | sed 's/;$//; s/;/; /g')"

  while IFS= read -r item; do
    [ -n "$item" ] || continue
    apply_item "$item"
  done < <(jq -c '.items[]' "$approved")

  jq '.items' "$approved" > "$TMP/own-items.json"
  end_round "$clear" "$TMP/own-items.json"
  printf 'summary home=%s applied=%s skipped=%s owner=%s\n' "$home" "$APPLIED" "$SKIPPED" "$OWNER"
  [ "$SKIPPED" -eq 0 ] || return 3
}

cmd_finish() {
  local clear=0
  case "${1:-}" in
    '') [ "$#" -eq 0 ] || usage_error ;;
    --clear) [ "$#" -eq 1 ] || usage_error; clear=1 ;;
    *) usage_error ;;
  esac
  printf '[]\n' > "$TMP/own-items.json"
  end_round "$clear" "$TMP/own-items.json"
  printf 'summary home=%s applied=0 skipped=0 owner=0\n' "$(home_name)"
}

sub=${1:-}
[ "$#" -eq 0 ] || shift
case "$sub" in
  -h|--help) usage; exit 0 ;;
  check) cmd_check "$@" ;;
  collect) cmd_collect "$@" ;;
  show) cmd_show "$@" ;;
  approve) cmd_approve "$@" ;;
  split) cmd_split "$@" ;;
  draft-request) cmd_draft_request "$@" ;;
  request) cmd_request "$@" ;;
  apply) cmd_apply "$@" ;;
  finish) cmd_finish "$@" ;;
  *) usage_error ;;
esac
