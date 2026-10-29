#!/usr/bin/env bash
# Host-local lifecycle verbs for individually placed ship and scout workers on a
# worker machine, run through fm-on.sh --machine in that machine's worker-host
# home.
#
# Usage:
#   fm-remote-worker-control.sh sync <commit>
#   fm-remote-worker-control.sh account claude            (stdin: credential payload)
#   fm-remote-worker-control.sh admit <id>                (stdin: the spawning home's headroom declaration for this machine, or nothing)
#   fm-remote-worker-control.sh prepare <project> <origin-url> <registry-line>
#   fm-remote-worker-control.sh brief <id> <project> <ship|scout> <mode> <branch-prefix> <base-branch> <forge> <machine>
#                                                         (stdin: the spawning home's filled brief)
#   fm-remote-worker-control.sh launch <id> <project> <ship|scout> <mode> <yolo> <branch-prefix> <base-branch> <harness> <model> <effort>
#   fm-remote-worker-control.sh route <id>
#   fm-remote-worker-control.sh state <id>
#   fm-remote-worker-control.sh crew-state <id>
#   fm-remote-worker-control.sh accept-done <id> <done-line>
#   fm-remote-worker-control.sh capture <id> [lines]
#   fm-remote-worker-control.sh observe <id>
#   fm-remote-worker-control.sh send <id> <message> [fire-and-forget]
#   fm-remote-worker-control.sh send-stdin <id> [fire-and-forget]  # message on stdin
#   fm-remote-worker-control.sh key <id> <key>
#   fm-remote-worker-control.sh control <id> interrupt|exit
#   fm-remote-worker-control.sh control <id> relaunch <harness> <model> <effort>   (stdin: progress note)
#   fm-remote-worker-control.sh retire <id> [--force|--captain-gate-passed]
# An argument shown as <mode>, <yolo>, <base-branch>, <forge>, <model>, or
# <effort> takes `-` for "none"; <branch-prefix> is passed verbatim and may be
# empty, exactly as bin/fm-brief.sh and bin/fm-spawn.sh accept it.
#
# This is the worker-host half of remote worker placement (docs/remote-workers.md
# owns the model; bin/fm-remote-worker-spawn.sh is the spawning home's half).
# FM_HOME is the worker-host home: a plain operational home holding this
# machine's project clones, Treehouse pools, and the host-local records of the
# workers placed here. Every lifecycle verb runs the ORDINARY local script
# against that home - fm-spawn.sh, fm-control.sh, fm-crew-state.sh,
# fm-teardown.sh - so the isolation assertion, slot claims, busy hooks,
# landed-work test, and control postconditions are the tested local ones. The
# host-local records carry no remote placement, so none of those scripts sees a
# remote record here.
#
# Workers run on the Herdr backend in the shared fm-remote session, the same
# session bin/fm-remote-doctor.sh owns readiness for, never in the user's
# interactive default session. The spawning home runs no-mistakes nowhere here:
# launch refuses every ship mode except direct-PR.
#
# sync fast-forwards this machine's Firstmate code root to the spawning home's
# default-branch commit when that is safe (clean, on its default branch, an
# ancestor of the target), because these scripts run from the code root itself;
# an unsafe or unreachable target is reported and left untouched.
#
# account installs the spawning home's current Claude login: stdin is one JSON
# object {"claudeAiOauth":{...},"oauthAccount":{...},"config":{...},"settings":{...}}
# (bin/fm-remote-worker-lib.sh owns which keys travel). It is written into an
# owner-only (0700 directory, 0600 files) Claude config root under the
# worker-host home, which config/claude-account then pins for every launch
# here (bin/fm-worker-account-lib.sh). Nothing is printed from the payload.
#
# admit is this machine's spawn headroom admission for one placement, run
# before anything else is staged for it. A non-empty stdin is the spawning
# home's declaration for this machine (config/spawn-headroom.<machine-id>
# there); it is validated and installed as this worker-host home's
# config/spawn-headroom, which is this machine's root-home declaration, so the
# ordinary spawn's admission, the brief's "Machine headroom" gate, and the
# machine-wide build slots all read it. Empty stdin keeps whatever declaration
# this machine already has. The verdict is the ordinary one
# (bin/fm-spawn-headroom-lib.sh owns the format and the verdict), measured with
# this machine's own headroom-axi. Output lines:
#   headroom: installed <path>     the sent declaration replaced this machine's
#   headroom: none <path>          no declaration here, so nothing is measured
#   warning: <why>                 admitted unmeasured (headroom-axi missing or failing)
#   deferred: <verdict>            exit 75: short of headroom, nothing staged
#   admit: ok | admit: placed      admitted, or <id> already runs here (a
#                                  rerun adopts it, so it is never re-measured)
# An unreadable declaration, sent or already here, refuses with exit 1.
#
# prepare clones a project into the worker-host home from its validated origin
# (bin/fm-project-origin-lib.sh). A clone runs detached in a staging directory
# and is published by rename once complete; until then prepare exits 75 with a
# `preparing:` line, so the spawning home defers the task exactly like a
# capacity deferral instead of holding a transport job open for a long clone.
#
# brief renders the ordinary scaffold for this home with bin/fm-brief.sh (so
# every path a worker reads names THIS machine), then splices in the spawning
# home's filled `# Task` section and its `# Home brief additions`, plus a short
# placement note. A scout is told to offer its report with a structured
# report=data/<id>/report.md pointer so the status mirror fetches it.
#
# observe is the per-cycle snapshot the spawning home's watcher reads, and it
# also takes one step of the ordinary steering-inbox re-ring ladder here
# (bin/fm-task-inbox-lib.sh), because the doorbell can only be typed on this
# machine. Its output is the header block below, then a `---` line, then the
# last 40 captured lines:
#   schema=fm-remote-worker-observe.v1
#   agent=<alive|dead|missing|unreadable>
#   busy=<busy|idle|unknown|dead ...>
#   inbox=<quiet|ring|retry|escalate <record> <count>|unavailable <record>>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET_HOME=${FM_HOME:?FM_HOME is required}
STATE="$TARGET_HOME/state"
DATA="$TARGET_HOME/data"
CONFIG="$TARGET_HOME/config"
PROJECTS="$TARGET_HOME/projects"
ACCOUNT_ROOT="$TARGET_HOME/accounts/claude"
REMOTE_HERDR_SESSION=fm-remote
SCHEMA=fm-remote-worker-control.v1

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-spawn-headroom-lib.sh
. "$SCRIPT_DIR/fm-spawn-headroom-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
validate_id() { case "$1" in ''|-*|*[!A-Za-z0-9._-]*) die "invalid task id: $1" ;; esac; }
validate_project() { case "$1" in ''|-*|.|..|*[!A-Za-z0-9._-]*) die "invalid project name: $1" ;; esac; }

ensure_home() {
  local dir
  [ ! -L "$TARGET_HOME" ] || die "worker-host home is a symlink"
  if [ ! -d "$TARGET_HOME" ]; then
    (umask 077; mkdir -p "$TARGET_HOME") || die "cannot create the worker-host home"
  fi
  for dir in "$STATE" "$DATA" "$CONFIG" "$PROJECTS"; do
    [ ! -L "$dir" ] || die "worker-host home has an unsafe operational directory: $dir"
    mkdir -p "$dir" || die "cannot create $dir"
  done
}

meta_path() { printf '%s/%s.meta\n' "$STATE" "$1"; }

# The host-local record of a placed worker. Every verb past launch requires it.
endpoint_load() { # <id>
  local id=$1 meta
  meta=$(meta_path "$id")
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 2
  fm_backend_validate_task_endpoint "$meta" "$id" 2>/dev/null || return 1
  ENDPOINT_META=$meta
  ENDPOINT_BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  ENDPOINT_TARGET=$FM_BACKEND_VALIDATED_TARGET
}

endpoint_require() { # <id>
  local rc=0
  endpoint_load "$1" || rc=$?
  case "$rc" in
    0) ;;
    2) die "no worker $1 is placed in this worker-host home" ;;
    *) die "worker $1's host-local record is invalid; refusing access until it is reconciled" ;;
  esac
}

host_env() {
  # The ordinary local scripts, pointed at the worker-host home. The guard and
  # supervision checks belong to the spawning home, which supervises.
  env HERDR_SESSION="$REMOTE_HERDR_SESSION" FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_SPAWN_NO_GUARD=1 FM_TEARDOWN_GUARD_DONE=1 "$@"
}

print_route() { # <id>
  local id=$1 key
  endpoint_require "$id"
  printf 'schema=%s\n' "$SCHEMA"
  printf 'backend=%s\n' "$ENDPOINT_BACKEND"
  printf 'target=%s\n' "$ENDPOINT_TARGET"
  for key in worktree harness model effort kind mode yolo branch base_branch spawn_gen account; do
    printf '%s=%s\n' "$key" "$(fm_meta_get "$ENDPOINT_META" "$key")"
  done
}

state_value() { # <id>
  local rc=0
  endpoint_load "$1" || rc=$?
  case "$rc" in
    0) fm_backend_agent_state "$ENDPOINT_BACKEND" "$ENDPOINT_TARGET" 2>/dev/null || printf 'unreadable\n' ;;
    2) printf 'missing-record\n' ;;
    *) printf 'unverified\n' ;;
  esac
}

cmd_sync() {
  local commit=$1 report out
  case "$commit" in *[!0-9a-f]*|'') die "sync target must be a full 40-character commit id" ;; esac
  [ "${#commit}" -eq 40 ] || die "sync target must be a full 40-character commit id"
  if ! git -C "$FM_ROOT" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$FM_ROOT" fetch --quiet --no-tags origin 2>/dev/null || true
    git -C "$FM_ROOT" cat-file -e "$commit^{commit}" 2>/dev/null \
      || die "this machine's Firstmate code root cannot reach $commit from its origin; push it or refresh the code root"
  fi
  report=$(mktemp "${TMPDIR:-/tmp}/fm-remote-worker-sync.XXXXXX") || die "cannot stage the sync report"
  ff_target "$FM_ROOT" "worker code root" "$commit" no no "" "" > "$report" 2>&1
  out=$(cat "$report")
  rm -f "$report"
  case "$FF_STATUS" in
    updated) printf 'synced: %s\n' "$commit" ;;
    current) printf 'current: %s\n' "$commit" ;;
    *) die "worker code root sync skipped: ${out#worker code root: skipped: }" ;;
  esac
}

cmd_account() {
  local runner=$1 tmp payload
  [ "$runner" = claude ] || die "only the claude runner's login can be installed on a worker machine"
  ensure_home
  (umask 077; mkdir -p "$ACCOUNT_ROOT") || die "cannot create the worker account root"
  [ ! -L "$TARGET_HOME/accounts" ] && [ ! -L "$ACCOUNT_ROOT" ] || die "worker account root is a symlink"
  chmod 700 "$TARGET_HOME/accounts" "$ACCOUNT_ROOT" || die "cannot restrict the worker account root"
  tmp=$(umask 077; mktemp -d "$ACCOUNT_ROOT/.install.XXXXXX") || die "cannot stage the worker account"
  payload="$tmp/payload"
  (umask 077; head -c 1048576 > "$payload") || { rm -rf -- "$tmp"; die "cannot read the account payload"; }
  if ! jq -e '(.claudeAiOauth | type) == "object" and (.claudeAiOauth.accessToken | type) == "string"
      and (.oauthAccount | type) == "object"' "$payload" >/dev/null 2>&1; then
    rm -rf -- "$tmp"
    die "the account payload is not a Claude login (expected claudeAiOauth and oauthAccount objects)"
  fi
  (umask 077; jq '{claudeAiOauth: .claudeAiOauth}' "$payload" > "$tmp/credentials") \
    || { rm -rf -- "$tmp"; die "cannot stage the worker credentials"; }
  # Existing keys (such as the trust records each launch adds) are kept; the
  # carried profile, onboarding, and theme state replace their own keys only.
  [ -f "$ACCOUNT_ROOT/.claude.json" ] && [ ! -L "$ACCOUNT_ROOT/.claude.json" ] \
    || printf '{"hasCompletedOnboarding":true,"theme":"dark"}\n' > "$tmp/base-config"
  [ -f "$tmp/base-config" ] || cp -- "$ACCOUNT_ROOT/.claude.json" "$tmp/base-config"
  (umask 077; jq --slurpfile p "$payload" \
    '. + ($p[0].config // {}) + {oauthAccount: $p[0].oauthAccount}' \
    "$tmp/base-config" > "$tmp/config") || { rm -rf -- "$tmp"; die "cannot stage the worker account config"; }
  [ -f "$ACCOUNT_ROOT/settings.json" ] && [ ! -L "$ACCOUNT_ROOT/settings.json" ] \
    && cp -- "$ACCOUNT_ROOT/settings.json" "$tmp/base-settings" || printf '{}\n' > "$tmp/base-settings"
  (umask 077; jq --slurpfile p "$payload" \
    '. + {skipDangerousModePermissionPrompt: (($p[0].settings // {}).skipDangerousModePermissionPrompt == true)}' \
    "$tmp/base-settings" > "$tmp/settings") || { rm -rf -- "$tmp"; die "cannot stage the worker account settings"; }
  chmod 600 "$tmp/credentials" "$tmp/config" "$tmp/settings" || { rm -rf -- "$tmp"; die "cannot restrict the worker account files"; }
  mv -f -- "$tmp/credentials" "$ACCOUNT_ROOT/.credentials.json" || { rm -rf -- "$tmp"; die "cannot install the worker credentials"; }
  mv -f -- "$tmp/config" "$ACCOUNT_ROOT/.claude.json" || { rm -rf -- "$tmp"; die "cannot install the worker account config"; }
  mv -f -- "$tmp/settings" "$ACCOUNT_ROOT/settings.json" || { rm -rf -- "$tmp"; die "cannot install the worker account settings"; }
  rm -rf -- "$tmp"
  if ! (umask 077; printf '%s\n' "$ACCOUNT_ROOT" > "$CONFIG/.claude-account.tmp") ||
    ! mv -f -- "$CONFIG/.claude-account.tmp" "$CONFIG/claude-account"; then
    die "cannot pin the worker account"
  fi
  printf 'account: claude installed\n'
}

cmd_admit() {
  local id=$1 tmp rc=0
  validate_id "$id"
  ensure_home
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-worker-admit.XXXXXX") || die "cannot stage the headroom declaration"
  head -c 65536 > "$tmp/spawn-headroom" || { rm -rf -- "$tmp"; die "cannot read the headroom declaration"; }
  if [ -s "$tmp/spawn-headroom" ]; then
    if ! fm_spawn_headroom_lookup "$tmp"; then
      rm -rf -- "$tmp"
      die "the spawn headroom declaration sent for this machine is unreadable (${FM_SPAWN_HEADROOM_ERROR#"$tmp/spawn-headroom "})"
    fi
    if ! cmp -s "$tmp/spawn-headroom" "$CONFIG/spawn-headroom" 2>/dev/null; then
      [ ! -L "$CONFIG/spawn-headroom" ] || { rm -rf -- "$tmp"; die "$CONFIG/spawn-headroom is a symlink; refusing to replace it"; }
      if ! cp -- "$tmp/spawn-headroom" "$CONFIG/.spawn-headroom.tmp.$$" ||
        ! mv -f -- "$CONFIG/.spawn-headroom.tmp.$$" "$CONFIG/spawn-headroom"; then
        rm -f -- "$CONFIG/.spawn-headroom.tmp.$$"
        rm -rf -- "$tmp"
        die "cannot install the spawn headroom declaration at $CONFIG/spawn-headroom"
      fi
      printf 'headroom: installed %s\n' "$CONFIG/spawn-headroom"
    fi
  fi
  rm -rf -- "$tmp"
  if [ -f "$(meta_path "$id")" ]; then
    printf 'admit: placed\n'
    return 0
  fi
  fm_spawn_headroom_lookup "$CONFIG" \
    || die "this machine's spawn headroom declaration is unreadable ($FM_SPAWN_HEADROOM_ERROR)"
  if [ -z "$FM_SPAWN_HEADROOM_ACTIVE" ]; then
    printf 'headroom: none %s\n' "$FM_SPAWN_HEADROOM_FILE"
    printf 'admit: ok\n'
    return 0
  fi
  fm_spawn_headroom_admit || rc=$?
  if [ "$rc" -eq "$FM_SPAWN_HEADROOM_DEFER_EXIT" ]; then
    printf 'deferred: short of headroom for another worker (%s): %s\n' "$FM_SPAWN_HEADROOM_FILE" "$FM_SPAWN_HEADROOM_REASON"
    exit "$FM_SPAWN_HEADROOM_DEFER_EXIT"
  fi
  [ -z "$FM_SPAWN_HEADROOM_WARNING" ] || printf 'warning: %s\n' "$FM_SPAWN_HEADROOM_WARNING"
  printf 'admit: ok\n'
}

clone_in_progress() { # <project>
  local pidfile="$PROJECTS/.clone-$1.pid" pid
  [ -f "$pidfile" ] || return 1
  pid=$(cat "$pidfile" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

cmd_prepare() {
  local project=$1 origin=$2 line=$3 dest current stage pidfile log reg tmp
  validate_project "$project"
  fm_project_origin_safe "$origin" || die "project origin is not acceptable: $origin"
  case "$line" in "- $project "*) ;; *) die "registry line does not name $project" ;; esac
  case "$line" in *[[:cntrl:]]*) die "registry line contains control characters" ;; esac
  ensure_home
  reg="$DATA/projects.md"
  if ! grep -Fxq -- "$line" "$reg" 2>/dev/null; then
    tmp="$reg.tmp.$$"
    { [ -f "$reg" ] && grep -v -- "^- $project [[-]" "$reg" || printf '# Projects\n\n'; } > "$tmp"
    printf '%s\n' "$line" >> "$tmp"
    mv -f -- "$tmp" "$reg" || die "cannot record $project in the worker-host registry"
  fi
  dest="$PROJECTS/$project"
  if [ -d "$dest/.git" ] || [ -f "$dest/.git" ]; then
    current=$(git -C "$dest" remote get-url origin 2>/dev/null || true)
    [ "$current" = "$origin" ] \
      || die "worker-host clone of $project has origin '${current:-none}', not '$origin'; reconcile it by hand"
    printf 'ready: %s\n' "$dest"
    return 0
  fi
  [ ! -e "$dest" ] && [ ! -L "$dest" ] || die "$dest exists but is not a git clone"
  stage="$PROJECTS/.clone-$project"
  pidfile="$PROJECTS/.clone-$project.pid"
  log="$PROJECTS/.clone-$project.log"
  if [ -f "$stage/.complete" ]; then
    rm -f -- "$stage/.complete"
    mv -- "$stage" "$dest" || die "cannot publish the clone of $project"
    rm -f -- "$pidfile" "$log"
    printf 'ready: %s\n' "$dest"
    return 0
  fi
  if clone_in_progress "$project"; then
    printf 'preparing: %s clone still running on this machine\n' "$project"
    return 75
  fi
  if [ -f "$log" ] && [ -d "$stage" ]; then
    printf 'warning: a previous clone of %s stopped before finishing: %s\n' "$project" "$(tail -n 1 "$log" 2>/dev/null)" >&2
  fi
  rm -rf -- "$stage"
  # Detached into its own session so a long first clone outlives this transport
  # job: the job worker treats a job as running while any member of its
  # process group lives, so a clone left in that group would hold the job
  # open until its timeout. The staging directory is published by rename on
  # the next prepare once it completes.
  # shellcheck disable=SC2016 # Positional parameters expand in the child sh.
  nohup perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"' -- \
    sh -c 'git clone --quiet -- "$1" "$2" && : > "$2/.complete"' _ "$origin" "$stage" \
    > "$log" 2>&1 < /dev/null &
  printf '%s\n' "$!" > "$pidfile"
  printf 'preparing: %s clone started on this machine\n' "$project"
  return 75
}

section_of() { # <file> <heading>; prints that top-level section, heading included
  awk -v h="$2" '
    $0 == h { on = 1; print; next }
    on && /^# / { exit }
    on { print }
  ' "$1"
}

cmd_brief() {
  local id=$1 project=$2 kind=$3 mode=$4 prefix=$5 base=$6 forge=$7 machine=$8
  local tmp src rendered task additions brief dir out
  local -a args
  validate_id "$id"
  validate_project "$project"
  case "$machine" in ''|-*|*[!A-Za-z0-9._-]*) die "invalid machine id: $machine" ;; esac
  ensure_home
  [ ! -f "$(meta_path "$id")" ] || die "worker $id is already placed here; its brief is not replaced while it runs"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-worker-brief.XXXXXX") || die "cannot stage the brief"
  src="$tmp/source.md"
  head -c 1048576 > "$src"
  task="$tmp/task.md"
  section_of "$src" '# Task' > "$task"
  [ -s "$task" ] || { rm -rf -- "$tmp"; die "the spawning home's brief has no # Task section"; }
  additions="$tmp/additions.md"
  section_of "$src" '# Home brief additions' > "$additions"
  dir="$DATA/$id"
  brief="$dir/brief.md"
  rm -f -- "$brief"
  args=("$id" "$project")
  case "$kind" in
    scout) args+=(--scout) ;;
    ship)
      args+=(--mode "$mode" --branch-prefix "$prefix")
      [ "$forge" = - ] || args+=(--forge "$forge")
      ;;
    *) rm -rf -- "$tmp"; die "kind must be ship or scout" ;;
  esac
  [ "$base" = - ] || args+=(--base-branch "$base")
  if ! out=$(env FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" "$SCRIPT_DIR/fm-brief.sh" "${args[@]}" 2>&1); then
    rm -rf -- "$tmp"
    printf '%s\n' "$out" >&2
    die "the worker-host brief scaffold failed"
  fi
  rendered="$tmp/rendered.md"
  # Replace the scaffold's own placeholder Task with the spawning home's
  # filled one, and put the placement note right after it.
  awk -v taskfile="$task" -v machine="$machine" -v kind="$kind" -v id="$id" '
    function emit_task(   l) {
      while ((getline l < taskfile) > 0) print l
      close(taskfile)
      print ""
      print "# Remote placement"
      print "This worker runs on worker machine `" machine "`, not on the machine that supervises it; every path in this brief is a path on this machine."
      if (kind == "scout")
        print "When the report is complete, end the `done:` status line with the structured pointer `report=data/" id "/report.md` so the supervising home receives a copy of the report."
      print ""
    }
    $0 == "# Task" { skipping = 1; emit_task(); next }
    skipping && /^# / { skipping = 0 }
    !skipping { print }
  ' "$brief" > "$rendered"
  if [ -s "$additions" ]; then
    printf '\n' >> "$rendered"
    cat "$additions" >> "$rendered"
  fi
  mv -f -- "$rendered" "$brief" || { rm -rf -- "$tmp"; die "cannot install the worker brief"; }
  rm -rf -- "$tmp"
  printf 'brief: %s\n' "$brief"
}

cmd_launch() {
  local id=$1 project=$2 kind=$3 mode=$4 yolo=$5 prefix=$6 base=$7 harness=$8 model=$9 effort=${10}
  local meta current proj rc=0 out
  local -a args
  validate_id "$id"
  validate_project "$project"
  ensure_home
  case "$harness" in claude) ;; *) die "a placed worker runs only on the claude harness in this release, not '$harness'" ;; esac
  case "$effort" in -|low|medium|high|xhigh|max|ultra) ;; *) die "invalid effort: $effort" ;; esac
  case "$model" in *[[:space:]]*) die "invalid model: $model" ;; esac
  meta=$(meta_path "$id")
  if [ -f "$meta" ]; then
    endpoint_require "$id"
    current=$(fm_backend_agent_state "$ENDPOINT_BACKEND" "$ENDPOINT_TARGET" 2>/dev/null || printf 'unreadable\n')
    case "$current" in
      alive) print_route "$id"; return 0 ;;
      *) die "worker $id already has a host-local record whose endpoint is $current; reconcile it with control relaunch or retire, never a second launch" ;;
    esac
  fi
  proj="$PROJECTS/$project"
  [ -d "$proj" ] || die "project $project is not prepared on this machine"
  [ -f "$DATA/$id/brief.md" ] || die "worker $id has no brief on this machine"
  args=("$id" "$proj" --harness "$harness" --backend herdr)
  case "$kind" in
    scout) args+=(--scout) ;;
    ship)
      [ "$mode" = direct-PR ] || die "a placed ship delivers only direct-PR in this release, not '$mode'"
      case "$yolo" in on|off) ;; *) die "invalid yolo: $yolo" ;; esac
      args+=(--mode "$mode" --yolo "$yolo" --branch-prefix "$prefix")
      ;;
    *) die "kind must be ship or scout" ;;
  esac
  [ "$base" = - ] || args+=(--base-branch "$base")
  [ "$model" = - ] || args+=(--model "$model")
  [ "$effort" = - ] || args+=(--effort "$effort")
  out=$(cd "$TARGET_HOME" && host_env "$SCRIPT_DIR/fm-spawn.sh" "${args[@]}" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    [ "$rc" -ne 75 ] || exit 75
    die "the worker-host spawn failed"
  fi
  [ -f "$meta" ] || die "the worker-host spawn returned without a task record"
  print_route "$id"
}

# The ship-done acceptance bin/fm-pr-check.sh applies (bin/fm-dod-lib.sh owns
# it), run here where the worker's copy and the project's refs live. Exit 0
# accepts; otherwise the refusal reason is printed.
cmd_accept_done() {
  local id=$1 line=$2 kind mode wt project
  validate_id "$id"
  endpoint_require "$id"
  case "$line" in *$'\n'*|*$'\r'*) die "the done line must be one line" ;; esac
  kind=$(fm_meta_get "$ENDPOINT_META" kind)
  mode=$(fm_meta_get "$ENDPOINT_META" mode)
  wt=$(fm_meta_get "$ENDPOINT_META" worktree)
  project=$(fm_meta_get "$ENDPOINT_META" project)
  # shellcheck source=bin/fm-dod-lib.sh
  . "$SCRIPT_DIR/fm-dod-lib.sh"
  fm_dod_accept_ship_done "${kind:-ship}" "$mode" "$wt" "$project" "$line" "$STATE" "$id" "$ENDPOINT_META"
}

cmd_capture() {
  local id=$1 lines=${2:-40}
  validate_id "$id"
  case "$lines" in ''|*[!0-9]*|0) die "capture line count must be positive" ;; esac
  [ "$lines" -le 100 ] || die "capture line count exceeds 100"
  endpoint_require "$id"
  fm_backend_capture "$ENDPOINT_BACKEND" "$ENDPOINT_TARGET" "$lines" "fm-$id" | head -c 65536
}

# One step of the ordinary re-ring ladder, taken where the pane lives. Prints
# the inbox= value for observe.
inbox_step() { # <id> <agent-state> <busy-verdict>
  local id=$1 agent=$2 busy=$3 action verb rec count ring_rc=0
  action=$(fm_task_inbox_due_action "$STATE" "$id" 2>/dev/null) || { printf 'quiet'; return 0; }
  verb=${action%% *}
  rec=${action#* }
  case "$verb" in
    quiet) printf 'quiet'; return 0 ;;
    escalate)
      count=${rec##* }
      rec=${rec% *}
      fm_task_inbox_record_escalated "$STATE" "$id" "$rec" || true
      printf 'escalate %s %s' "$rec" "$count"
      return 0
      ;;
  esac
  case "$agent" in
    dead|missing)
      if [ "$verb" = retry ]; then
        fm_task_inbox_clear_retry "$STATE" "$id" "$rec" || true
        printf 'quiet'
      else
        fm_task_inbox_record_escalated "$STATE" "$id" "$rec" || true
        printf 'unavailable %s' "$rec"
      fi
      return 0
      ;;
  esac
  if [ "${busy%% *}" = busy ]; then
    [ "$verb" = retry ] || fm_task_inbox_record_busy "$STATE" "$id" "$rec" >/dev/null 2>&1 || true
    printf 'quiet'
    return 0
  fi
  fm_task_inbox_ring "$ENDPOINT_BACKEND" "$ENDPOINT_TARGET" "$rec" "fm-$id" >/dev/null 2>&1 || ring_rc=$?
  if [ "$verb" = retry ]; then
    fm_task_inbox_clear_retry "$STATE" "$id" "$rec" || true
  else
    fm_task_inbox_clear_busy "$STATE" "$id" || true
    fm_task_inbox_record_ring "$STATE" "$id" "$rec" || true
  fi
  if [ "$ring_rc" -eq 3 ]; then
    printf 'unavailable %s' "$rec"
  else
    printf '%s' "$verb"
  fi
}

cmd_observe() {
  local id=$1 agent tail40 busy inbox
  validate_id "$id"
  endpoint_require "$id"
  agent=$(fm_backend_agent_state "$ENDPOINT_BACKEND" "$ENDPOINT_TARGET" 2>/dev/null || printf 'unreadable')
  tail40=$(fm_backend_capture "$ENDPOINT_BACKEND" "$ENDPOINT_TARGET" 40 "fm-$id" 2>/dev/null | head -c 65536 || true)
  busy=$(fm_busy_classify_meta "$ENDPOINT_META" "$id" "$STATE" "$tail40" 2>/dev/null || printf 'unknown')
  inbox=$(inbox_step "$id" "$agent" "$busy")
  printf 'schema=fm-remote-worker-observe.v1\n'
  printf 'agent=%s\n' "$agent"
  printf 'busy=%s\n' "$(printf '%s' "$busy" | head -n 1)"
  printf 'inbox=%s\n' "$inbox"
  printf -- '---\n'
  printf '%s\n' "$tail40"
}

cmd_send() {
  local id=$1 message=$2 delivery_mode=${3:-} rec ring_rc=0 meta meta_lock
  validate_id "$id"
  [ -z "$delivery_mode" ] || [ "$delivery_mode" = fire-and-forget ] || die "invalid send delivery mode"
  meta=$(meta_path "$id")
  meta_lock=$(fm_meta_lock_path "$meta") || die "worker metadata lock path is invalid"
  fm_task_inbox_lock_acquire "$meta_lock" || die "worker metadata could not be locked for final delivery validation"
  if ! endpoint_load "$id"; then
    fm_lock_release "$meta_lock"
    die "no valid worker $id is placed in this worker-host home"
  fi
  # The same durable-record delivery a remote secondmate steer uses: an
  # idempotent record in the worker's own steering inbox, then a best-effort
  # doorbell (bin/fm-task-inbox-lib.sh owns both).
  if ! rec=$(fm_task_inbox_write_idempotent "$STATE" "$id" "$message" "$delivery_mode"); then
    fm_lock_release "$meta_lock"
    die "steering-inbox record could not be written under $STATE/$id.inbox"
  fi
  fm_lock_release "$meta_lock"
  case "$rec" in
    */handled/*)
      printf 'notice: this steer was already delivered and acknowledged at %s; nothing re-rung\n' "$rec" >&2
      return 0
      ;;
  esac
  fm_task_inbox_ring "$ENDPOINT_BACKEND" "$ENDPOINT_TARGET" "$rec" "fm-$id" || ring_rc=$?
  case "$ring_rc" in
    1) printf 'notice: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at %s\n' "$rec" >&2 ;;
    2) printf 'notice: doorbell did not reach %s; the steer is durably recorded at %s\n' "$ENDPOINT_TARGET" "$rec" >&2 ;;
    3) printf 'notice: doorbell not typed because the agent in %s has exited; the steer is durably recorded at %s for recovery\n' "$ENDPOINT_TARGET" "$rec" >&2 ;;
  esac
}

# The message travels on stdin, as a remote secondmate steer's does
# (bin/fm-remote-secondmate-control.sh cmd_send_stdin), so its size is not
# bounded by the SSH exec argument limit.
cmd_send_stdin() {
  local id=$1 delivery_mode=${2:-} message
  IFS= read -r -d '' message < /dev/stdin || :
  [ -n "${message//[[:space:]]/}" ] || die "worker steer message must be nonempty"
  cmd_send "$id" "$message" "$delivery_mode"
}

cmd_key() {
  local id=$1 key=$2
  validate_id "$id"
  endpoint_require "$id"
  host_env "$SCRIPT_DIR/fm-send.sh" "$id" --key "$key"
}

cmd_control() {
  local id=$1 verb=$2 harness=${3:-} model=${4:-} effort=${5:-} note
  local -a args
  validate_id "$id"
  endpoint_require "$id"
  args=("$id" "$verb")
  case "$verb" in
    interrupt|exit) [ -z "$harness" ] || usage ;;
    relaunch)
      case "$harness" in claude) ;; *) die "a placed worker relaunches only on the claude harness in this release" ;; esac
      case "$effort" in -|default|low|medium|high|xhigh|max|ultra) ;; *) die "invalid effort: $effort" ;; esac
      case "$model" in *[[:space:]]*) die "invalid model: $model" ;; esac
      note=$(mktemp "${TMPDIR:-/tmp}/fm-remote-worker-note.XXXXXX") || die "cannot stage the progress note"
      head -c 65536 > "$note"
      [ -s "$note" ] || { rm -f -- "$note"; die "relaunch needs a progress note on stdin"; }
      [ "$model" != - ] || model=default
      [ "$effort" != - ] || effort=default
      args+=(--harness "$harness" --model "$model" --effort "$effort" --note-file "$note")
      if ! host_env "$SCRIPT_DIR/fm-control.sh" "${args[@]}"; then
        rm -f -- "$note"
        die "the worker-host relaunch failed"
      fi
      rm -f -- "$note"
      print_route "$id"
      return 0
      ;;
    *) die "unknown control verb: $verb" ;;
  esac
  host_env "$SCRIPT_DIR/fm-control.sh" "${args[@]}"
}

# A scout's captain-call completion gate is run by the supervising home, which
# holds the captain's calls and its copy of the report, before it asks for this
# cleanup; --captain-gate-passed records that, so the ordinary teardown here
# skips only that gate (bin/fm-teardown.sh) and keeps every other check.
cmd_retire() {
  local id=$1 option=${2:-} meta
  validate_id "$id"
  meta=$(meta_path "$id")
  if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
    printf 'already-retired: %s\n' "$id"
    return 0
  fi
  case "$option" in
    '') host_env "$SCRIPT_DIR/fm-teardown.sh" "$id" ;;
    --force) host_env "$SCRIPT_DIR/fm-teardown.sh" "$id" --force ;;
    --captain-gate-passed) host_env FM_TEARDOWN_CAPTAIN_GATE_VERIFIED=1 "$SCRIPT_DIR/fm-teardown.sh" "$id" ;;
    *) usage ;;
  esac
}

case "${1:-}" in
  sync) shift; [ "$#" -eq 1 ] || usage; cmd_sync "$@" ;;
  account) shift; [ "$#" -eq 1 ] || usage; cmd_account "$@" ;;
  admit) shift; [ "$#" -eq 1 ] || usage; cmd_admit "$@" ;;
  prepare) shift; [ "$#" -eq 3 ] || usage; cmd_prepare "$@" ;;
  brief) shift; [ "$#" -eq 8 ] || usage; cmd_brief "$@" ;;
  launch) shift; [ "$#" -eq 10 ] || usage; cmd_launch "$@" ;;
  route) shift; [ "$#" -eq 1 ] || usage; validate_id "$1"; print_route "$1" ;;
  state) shift; [ "$#" -eq 1 ] || usage; validate_id "$1"; state_value "$1" ;;
  crew-state) shift; [ "$#" -eq 1 ] || usage; validate_id "$1"; endpoint_require "$1"; host_env "$SCRIPT_DIR/fm-crew-state.sh" "$1" ;;
  accept-done) shift; [ "$#" -eq 2 ] || usage; cmd_accept_done "$@" ;;
  capture) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_capture "$@" ;;
  observe) shift; [ "$#" -eq 1 ] || usage; cmd_observe "$@" ;;
  send) shift; [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage; cmd_send "$@" ;;
  send-stdin) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_send_stdin "$@" ;;
  key) shift; [ "$#" -eq 2 ] || usage; cmd_key "$@" ;;
  control) shift; [ "$#" -eq 2 ] || [ "$#" -eq 5 ] || usage; cmd_control "$@" ;;
  retire) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
