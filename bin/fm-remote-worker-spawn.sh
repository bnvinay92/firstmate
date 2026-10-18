#!/usr/bin/env bash
# Place one fresh ship or scout worker on a registered worker machine.
#
# Usage (normally reached through bin/fm-spawn.sh --machine, which validates
# the delivery flags first and then hands over here):
#   fm-remote-worker-spawn.sh <task-id> <project-dir> <machine-id> <ship|scout> <mode|-> <yolo|-> <branch-prefix> <base-branch|-> <harness> <model|-> <effort|->
#
# docs/remote-workers.md owns the model. The spawning home keeps the task: its
# backlog item, brief, mirrored status stream, steering record, and a thin task
# record that routes every lifecycle verb to the machine. The machine runs the
# ordinary host-local spawn in its worker-host home through
# bin/fm-remote-worker-control.sh, so the worktree isolation assertion, slot
# claim, busy hooks, and launch are the tested local ones.
#
# Scope of this release: from the main home only (a secondmate home refuses),
# scouts and direct-PR ships only (no-mistakes and local-only refuse), the
# claude harness only, explicit placement only - firstmate chooses the machine
# at intake and nothing picks one automatically.
#
# Sequence, each step before any record exists here:
#   1. The usual fresh-spawn gates: one spawn per task id, the home's task-set
#      lock, no existing record, and a dispatchable backlog item when this home
#      keeps a backlog.
#   2. The machine's readiness through bin/fm-remote-doctor.sh (read-only, then
#      --fix, then a read-only verdict; bin/fm-remote-readiness-lib.sh).
#   3. The machine's Firstmate code root follows this home's default-branch
#      commit when that is safe; a skipped sync warns and continues.
#   4. The current Claude login of this machine is installed there for this
#      launch (bin/fm-remote-worker-lib.sh owns which login; the control
#      script owns where it is stored).
#   5. The project is cloned there from its validated origin. A first clone
#      that is still running defers the spawn: one `deferred:` line and exit 75,
#      the same contract a capacity deferral uses, so the task stays queued.
#   6. The brief is re-rendered there with the filled Task section spliced in.
#   7. The worker is launched there; the machine's own capacity and headroom
#      declarations can defer it the same way.
# Then the spawning home publishes window=remote:<id> with remote_kind=worker,
# remote_machine=, remote_host=, remote_root=, remote_home=, remote_target=,
# and the machine's worktree, moves the backlog item to In flight, and arms the
# status mirror (bin/fm-procevent-remote-reply.sh). SSH exit 255 at any step
# means completion is unknown: nothing is published here, and rerunning the
# same spawn is safe because a launched worker is adopted rather than launched
# twice.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-worker-machine-lib.sh
. "$SCRIPT_DIR/fm-worker-machine-lib.sh"
# shellcheck source=bin/fm-remote-worker-lib.sh
. "$SCRIPT_DIR/fm-remote-worker-lib.sh"
# shellcheck source=bin/fm-remote-readiness-lib.sh
. "$SCRIPT_DIR/fm-remote-readiness-lib.sh"
# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"

DEFER_EXIT=75
die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ "$#" -eq 11 ] || usage
ID=$1 PROJ_ARG=$2 MACHINE=$3 KIND=$4 MODE=$5 YOLO=$6 BRANCH_PREFIX=$7 BASE_BRANCH=$8 HARNESS=$9 MODEL=${10} EFFORT=${11}

case "$ID" in ''|-*|*[!A-Za-z0-9._-]*) die "invalid task id: $ID" ;; esac
case "$KIND" in ship|scout) ;; *) die "a worker machine takes ship and scout tasks only, not '$KIND'" ;; esac
if [ "$KIND" = ship ] && [ "$MODE" != direct-PR ]; then
  die "a placed ship delivers only direct-PR in this release (no-mistakes and local-only stay on this machine); got --mode $MODE"
fi
[ "$HARNESS" = claude ] || die "a placed worker runs only on the claude harness in this release, not '$HARNESS'"
if [ -f "$FM_HOME/.fm-secondmate-home" ]; then
  die "only the main home places workers on another machine in this release; this is a secondmate home"
fi
fm_lease_forbid_branch "remote worker placement (fm-spawn --machine)"
fm_worker_machine_resolve "$CONFIG" "$MACHINE" || die "$FM_WORKER_MACHINE_ERROR"
HOST=$FM_WORKER_MACHINE_HOST
ROOT=$FM_WORKER_MACHINE_ROOT
WHH=$FM_WORKER_MACHINE_HOME

PROJ_ABS=$(CDPATH='' cd -- "$PROJ_ARG" 2>/dev/null && pwd -P) || die "project directory cannot be resolved: $PROJ_ARG"
PROJ_NAME=$(basename "$PROJ_ABS")
case "$PROJ_NAME" in ''|-*|*[!A-Za-z0-9._-]*) die "project directory name is not a safe project name: $PROJ_NAME" ;; esac
ORIGIN=$(git -C "$PROJ_ABS" remote get-url origin 2>/dev/null) || die "project $PROJ_NAME has no origin remote for the worker machine to clone"
fm_project_origin_safe "$ORIGIN" || die "project $PROJ_NAME's origin is not an acceptable clone URL: $ORIGIN"
REG_LINE=$(grep -m 1 -E "^- $PROJ_NAME( \\[| - )" "$DATA/projects.md" 2>/dev/null || true)
[ -n "$REG_LINE" ] || REG_LINE="- $PROJ_NAME - placed from another home (added $(date +%Y-%m-%d))"
FORGE=-
if [ "$KIND" = ship ]; then
  FORGE=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-project-mode.sh" --forge "$PROJ_NAME" 2>/dev/null) || FORGE=none
fi

BRIEF="$DATA/$ID/brief.md"
[ -f "$BRIEF" ] || die "no brief at $BRIEF; scaffold it with bin/fm-brief.sh and fill its Task section first"
if [ "$KIND" = ship ]; then
  BRIEF_MODE=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$BRIEF" | head -n 1)
  [ "$BRIEF_MODE" = "$MODE" ] \
    || die "delivery mismatch for $ID: the brief says mode=${BRIEF_MODE:-none} but this spawn passed --mode $MODE"
fi

mkdir -p "$STATE" || die "could not create the state directory"
SPAWN_TASK_LOCK="$STATE/.spawn-$ID.lock"
TASK_SET_LOCK=
META_LOCK=
release_locks() {
  local status=$?
  [ -z "$META_LOCK" ] || fm_lock_release "$META_LOCK" || true
  [ -z "$TASK_SET_LOCK" ] || fm_lock_release "$TASK_SET_LOCK" || true
  fm_lock_release "$SPAWN_TASK_LOCK" 2>/dev/null || true
  return "$status"
}
fm_lock_try_acquire "$SPAWN_TASK_LOCK" || die "another spawn is already creating task $ID"
trap release_locks EXIT
TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") || die "could not resolve the task-set lock for $STATE"
if ! fm_lock_try_acquire "$TASK_SET_LOCK"; then
  TASK_SET_LOCK=
  die "this home's task set is locked by another operation; refusing to create task $ID rather than racing it"
fi
fm_lock_set_role "$TASK_SET_LOCK" task-spawn || die "could not record the task-set lock holder for $ID"
META="$STATE/$ID.meta"
[ ! -e "$META" ] && [ ! -L "$META" ] || die "task $ID already has a record at $META; relaunch or clean it up instead of spawning it again"

BACKLOG_TRANSITION=0
if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
  BACKLOG_TRANSITION=1
  if fm_backlog_row_probe "$DATA" "$ID"; then
    fm_backlog_row_dispatchable "$FM_BACKLOG_ROW_STATE" \
      || die "this home's backlog item $ID is not dispatchable in state $FM_BACKLOG_ROW_STATE"
  elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    die "task $ID has no backlog item in this home; add it first (bin/fm-tasks-axi.sh add $ID '<title>' --kind $KIND)"
  else
    die "task $ID's backlog item could not be read before dispatch ($FM_BACKLOG_ROW_ERROR)"
  fi
else
  [ "$?" -ne 2 ] || die "task $ID cannot be dispatched because its backlog data directory is inaccessible: $DATA"
fi

remote() { # <verb> [args...]; stdin closed
  "$SCRIPT_DIR/fm-on.sh" --machine "$MACHINE" fm-remote-worker-control.sh "$@" < /dev/null
}
unknown() { # <step>
  die "machine $MACHINE did not answer during $1 (completion unknown); nothing was recorded here - rerun the same spawn once the machine is reachable, which adopts a worker that did launch" 255
}

rc=0
fm_remote_readiness_ensure_route "$SCRIPT_DIR" --machine "$MACHINE" || rc=$?
case "$rc" in
  0) ;;
  255) unknown "the readiness check" ;;
  *)
    [ -z "$FM_REMOTE_READINESS_OUT" ] || printf '%s\n' "$FM_REMOTE_READINESS_OUT" >&2
    die "machine $MACHINE ($HOST) is not ready for placed workers; the doctor's remaining gaps are above"
    ;;
esac

if head=$(primary_head_commit "$FM_ROOT"); then
  rc=0
  out=$(remote sync "$head" 2>&1) || rc=$?
  if [ "$rc" -eq 255 ]; then
    unknown "the code-root sync"
  elif [ "$rc" -ne 0 ]; then
    echo "warning: machine $MACHINE code root sync skipped before launch: $(printf '%s' "$out" | tail -n 1)" >&2
  fi
else
  echo "warning: machine $MACHINE code root sync skipped before launch: this home's default-branch commit cannot be resolved" >&2
fi

if ! PAYLOAD=$(fm_remote_worker_claude_payload "$CONFIG"); then
  die "the worker machine needs a Claude login and none is usable here: $FM_REMOTE_ACCOUNT_ERROR"
fi
rc=0
out=$(printf '%s\n' "$PAYLOAD" | "$SCRIPT_DIR/fm-on.sh" --stdin --machine "$MACHINE" \
  fm-remote-worker-control.sh account claude 2>&1) || rc=$?
PAYLOAD=
[ "$rc" -ne 255 ] || unknown "the account install"
[ "$rc" -eq 0 ] || { printf '%s\n' "$out" >&2; die "the Claude login could not be installed on machine $MACHINE"; }

rc=0
out=$(remote prepare "$PROJ_NAME" "$ORIGIN" "$REG_LINE" 2>&1) || rc=$?
case "$rc" in
  0) ;;
  255) unknown "project preparation" ;;
  "$DEFER_EXIT")
    printf 'deferred: %s waits for machine %s to finish cloning %s (%s); the task stays queued - spawn it again shortly\n' \
      "$ID" "$MACHINE" "$PROJ_NAME" "$(printf '%s' "$out" | tail -n 1)"
    exit "$DEFER_EXIT"
    ;;
  *) printf '%s\n' "$out" >&2; die "project $PROJ_NAME could not be prepared on machine $MACHINE" ;;
esac

rc=0
out=$("$SCRIPT_DIR/fm-on.sh" --stdin --machine "$MACHINE" fm-remote-worker-control.sh brief \
  "$ID" "$PROJ_NAME" "$KIND" "$MODE" "$BRANCH_PREFIX" "$BASE_BRANCH" "$FORGE" "$MACHINE" < "$BRIEF" 2>&1) || rc=$?
[ "$rc" -ne 255 ] || unknown "the brief transfer"
if [ "$rc" -ne 0 ]; then
  case "$out" in
    *"is already placed here"*) ;;
    *) printf '%s\n' "$out" >&2; die "the brief could not be rendered on machine $MACHINE" ;;
  esac
fi

rc=0
out=$(remote launch "$ID" "$PROJ_NAME" "$KIND" "$MODE" "$YOLO" "$BRANCH_PREFIX" "$BASE_BRANCH" \
  "$HARNESS" "$MODEL" "$EFFORT" 2>&1) || rc=$?
case "$rc" in
  0) ;;
  255) unknown "the launch" ;;
  "$DEFER_EXIT")
    printf '%s\n' "$out" | grep -v '^deferred:' >&2 || true
    printf 'deferred: %s on machine %s: %s\n' "$ID" "$MACHINE" \
      "$(printf '%s\n' "$out" | sed -n 's/^deferred: //p' | tail -n 1)"
    exit "$DEFER_EXIT"
    ;;
  *) printf '%s\n' "$out" >&2; die "the worker could not be launched on machine $MACHINE" ;;
esac

route_value() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | tail -n 1; }
[ "$(route_value schema)" = fm-remote-worker-control.v1 ] \
  || die "machine $MACHINE returned an unrecognized launch result; its code root may predate remote workers - update it, then reconcile task $ID there" 1
R_BACKEND=$(route_value backend)
R_TARGET=$(route_value target)
R_WT=$(route_value worktree)
R_GEN=$(route_value spawn_gen)
R_BRANCH=$(route_value branch)
R_BASE=$(route_value base_branch)
R_ACCOUNT=$(route_value account)
[ -n "$R_TARGET" ] && [ -n "$R_WT" ] && [ -n "$R_GEN" ] \
  || die "machine $MACHINE returned an incomplete launch result for $ID; reconcile it there with fm-remote-worker-control.sh route $ID"

META_LOCK=$(fm_meta_lock_path "$META") || die "could not resolve the record lock for $ID"
fm_lock_acquire_wait "$META_LOCK"
tmp="$STATE/.$ID.meta.remote.$$"
{
  echo "window=remote:$ID"
  echo "endpoint_task_id=$ID"
  echo "worktree=$R_WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  if [ "$KIND" = ship ]; then
    echo "mode=$MODE"
    echo "yolo=$YOLO"
    echo "branch=$R_BRANCH"
  fi
  [ -z "$R_BASE" ] || echo "base_branch=$R_BASE"
  echo "tasktmp="
  echo "model=${MODEL#-}"
  echo "effort=${EFFORT#-}"
  [ -z "$R_ACCOUNT" ] || echo "account=$R_ACCOUNT"
  echo "spawn_gen=$R_GEN"
  echo "remote_kind=worker"
  echo "remote_machine=$MACHINE"
  echo "remote_host=$HOST"
  echo "remote_root=$ROOT"
  echo "remote_home=$WHH"
  echo "remote_backend=$R_BACKEND"
  echo "remote_target=$R_TARGET"
} > "$tmp"
if ! fm_backlog_atomic_transition publish "$tmp" "$META" "task record" "$STATE"; then
  rm -f -- "$tmp"
  die "worker $ID launched on machine $MACHINE, but its task record could not be published here ($FM_BACKLOG_TRANSITION_ERROR); rerun the same spawn to adopt it"
fi
if [ "$BACKLOG_TRANSITION" = 1 ]; then
  if ! fm_backlog_atomic_transition dispatch "$META" "$DATA" "$ID" "$STATE"; then
    echo "error: worker $ID is running on machine $MACHINE and recorded here, but its backlog item could not be moved to In flight ($FM_BACKLOG_TRANSITION_ERROR); move it by hand - the record is kept so supervision continues" >&2
  fi
fi
fm_lock_release "$META_LOCK"
META_LOCK=
fm_lock_release "$TASK_SET_LOCK" || true
TASK_SET_LOCK=
"$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort >/dev/null 2>&1 || true
if ! "$SCRIPT_DIR/fm-procevent-remote-reply.sh" arm "$ID" >/dev/null; then
  echo "error: worker $ID launched on machine $MACHINE, but its status mirror could not be armed; run bin/fm-procevent-remote-reply.sh arm $ID" >&2
fi
[ ! -e "$CONFIG/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG \
  "$SCRIPT_DIR/fm-fleet-ledger.sh" dispatched "$ID" "$KIND" "$PROJ_NAME" "$HARNESS" "${MODEL#-}" || true
DELIVERY=
[ "$KIND" != ship ] || DELIVERY=" mode=$MODE yolo=$YOLO"
echo "spawned $ID harness=$HARNESS kind=$KIND$DELIVERY window=remote:$ID worktree=$R_WT machine=$MACHINE"
