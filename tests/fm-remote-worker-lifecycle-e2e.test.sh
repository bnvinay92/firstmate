#!/usr/bin/env bash
# A ship and a scout placed on a worker machine, end to end over the
# deterministic SSH boundary (docs/remote-workers.md): placement, account
# install, project preparation and its deferral, brief rendering, status mirror
# and report copy, steering, peek, crew-state, watcher observe, control,
# unreachable-machine behavior, and cleanup.
#
# The real fm-on.sh transport, fixed entrypoint, job worker, and
# fm-remote-worker-control.sh run on the "machine" side. The ordinary host-local
# fm-spawn.sh, fm-control.sh, fm-teardown.sh, and fm-crew-state.sh are replaced
# there by recording fakes that write the same host-local records, because
# those scripts own their own suites; this test owns what the placement does
# with them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-worker-e2e)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
WHH="$TMP_ROOT/worker-homes/main"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
HOST_LOG="$TMP_ROOT/host.log"
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" \
  "$TMP_ROOT/worker-homes" "$CLAIMS"

cleanup() {
  local worker_pid=''
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    . "$ROOT/bin/fm-remote-job-lib.sh"
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
}
trap 'cleanup; fm_test_cleanup' EXIT

# --- the worker machine -----------------------------------------------------

(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"

# Recording stand-ins for the ordinary host-local lifecycle scripts. They write
# the same Herdr endpoint record shape a real launch publishes.
cat > "$REMOTE_ROOT/bin/fm-spawn.sh" <<SH
#!/usr/bin/env bash
set -eu
HSTATE='$HERDR_STATE'
printf 'spawn %s HERDR_SESSION=%s\n' "\$*" "\${HERDR_SESSION:-}" >> '$HOST_LOG'
if [ -f '$TMP_ROOT/host-spawn.defer' ]; then
  echo "deferred: alpha is at capacity on this machine (1 of 1 places held)"
  exit 75
fi
id=\$1 proj=\$2
shift 2
kind=ship mode= yolo= prefix=fm/ base=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --scout) kind=scout ;;
    --mode) mode=\$2; shift ;;
    --yolo) yolo=\$2; shift ;;
    --branch-prefix) prefix=\$2; shift ;;
    --base-branch) base=\$2; shift ;;
  esac
  shift
done
[ -f "\$FM_HOME/data/\$id/brief.md" ] || { echo "error: no brief for \$id" >&2; exit 1; }
n=\$(jq -r '.next' "\$HSTATE")
pane="w9:p\$n"
jq --arg t "w9:t\$n" --arg p "\$pane" \
  '(if ([.workspaces[] | select(.workspace_id == "w9")] | length) == 0
    then .workspaces += [{workspace_id:"w9", label:"firstmate", cwd:"/"}] else . end)
   | .tabs += [{tab_id:\$t, label:"fm", workspace_id:"w9", pane_id:\$p}]
   | .typed[\$p] = true | .next = (.next + 1)' "\$HSTATE" > "\$HSTATE.tmp"
mv "\$HSTATE.tmp" "\$HSTATE"
wt="\$FM_HOME/pool/\$id"
mkdir -p "\$wt" "\$FM_HOME/state"
{
  echo "window=fm-remote:\$pane"
  echo "endpoint_task_id=\$id"
  echo "backend=herdr"
  echo "herdr_session=fm-remote"
  echo "herdr_workspace_id=w9"
  echo "herdr_tab_id=w9:t\$n"
  echo "herdr_pane_id=\$pane"
  echo "worktree=\$wt"
  echo "project=\$proj"
  echo "harness=claude"
  echo "kind=\$kind"
  if [ -n "\$mode" ]; then echo "mode=\$mode"; echo "yolo=\$yolo"; echo "branch=\$prefix\$id"; fi
  [ -z "\$base" ] || echo "base_branch=\$base"
  echo "model=default"
  echo "effort=default"
  echo "spawn_gen=s\$(date +%s).\$\$.host\$n"
  echo "account=\$(cat "\$FM_HOME/config/claude-account" 2>/dev/null || true)"
} > "\$FM_HOME/state/\$id.meta"
echo "spawned \$id harness=claude kind=\$kind window=fm-remote:\$pane worktree=\$wt"
SH
cat > "$REMOTE_ROOT/bin/fm-control.sh" <<SH
#!/usr/bin/env bash
set -eu
HSTATE='$HERDR_STATE'
id=\$1 verb=\$2
note=
prev=
for arg in "\$@"; do
  [ "\$prev" != --note-file ] || note=\$(cat "\$arg")
  prev=\$arg
done
printf 'control %s note=%s\n' "\$*" "\$note" >> '$HOST_LOG'
[ "\$verb" = relaunch ] || exit 0
meta="\$FM_HOME/state/\$id.meta"
n=\$(jq -r '.next' "\$HSTATE")
pane="w9:p\$n"
jq --arg t "w9:t\$n" --arg p "\$pane" \
  '.tabs += [{tab_id:\$t, label:"fm", workspace_id:"w9", pane_id:\$p}] | .typed[\$p] = true | .next = (.next + 1)' \
  "\$HSTATE" > "\$HSTATE.tmp"
mv "\$HSTATE.tmp" "\$HSTATE"
grep -vE '^(window|herdr_tab_id|herdr_pane_id|spawn_gen)=' "\$meta" > "\$meta.tmp"
{
  echo "window=fm-remote:\$pane"
  echo "herdr_tab_id=w9:t\$n"
  echo "herdr_pane_id=\$pane"
  echo "spawn_gen=s\$(date +%s).\$\$.relaunch\$n"
} >> "\$meta.tmp"
mv "\$meta.tmp" "\$meta"
echo "relaunched \$id"
SH
cat > "$REMOTE_ROOT/bin/fm-teardown.sh" <<SH
#!/usr/bin/env bash
set -eu
printf 'teardown %s\n' "\$*" >> '$HOST_LOG'
if [ -f '$TMP_ROOT/host-teardown.refuse' ]; then
  echo "REFUSED: branch has unpushed commits" >&2
  exit 1
fi
rm -f "\$FM_HOME/state/\$1.meta"
echo "teardown \$1 complete"
SH
cat > "$REMOTE_ROOT/bin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
printf 'crew-state %s\n' "\$*" >> '$HOST_LOG'
printf 'state: working · source: pane · host crew-state for %s\n' "\$1"
SH
chmod +x "$REMOTE_ROOT/bin/fm-spawn.sh" "$REMOTE_ROOT/bin/fm-control.sh" \
  "$REMOTE_ROOT/bin/fm-teardown.sh" "$REMOTE_ROOT/bin/fm-crew-state.sh"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'worker machine code root'

# --- the spawning home ------------------------------------------------------

git init -q --bare "$TMP_ROOT/alpha.git"
git -C "$PARENT/projects" init -q -b main alpha
git -C "$PARENT/projects/alpha" config user.email test@example.com
git -C "$PARENT/projects/alpha" config user.name Test
printf 'alpha\n' > "$PARENT/projects/alpha/README.md"
git -C "$PARENT/projects/alpha" add README.md
git -C "$PARENT/projects/alpha" commit -qm init
git -C "$PARENT/projects/alpha" remote add origin "file://$TMP_ROOT/alpha.git"
git -C "$PARENT/projects/alpha" push -q -u origin main
printf -- '- alpha [direct-PR] - alpha project (added 2026-10-18)\n' > "$PARENT/data/projects.md"
printf 'pc host=worker-pc root=%s home=%s prefer=android,jvm\n' "$REMOTE_ROOT" "$WHH" > "$PARENT/config/worker-machines"
ACCOUNT="$TMP_ROOT/claude-account"
mkdir -p "$ACCOUNT"
printf '{"claudeAiOauth":{"accessToken":"tok-e2e","refreshToken":"ref-e2e","expiresAt":1},"mcpOAuth":{"x":"mcp-secret"}}\n' \
  > "$ACCOUNT/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"worker@example.com"},"projects":{}}\n' > "$ACCOUNT/.claude.json"
printf '%s\n' "$ACCOUNT" > "$PARENT/config/claude-account"

write_brief() { # <id> <ship|scout>
  mkdir -p "$PARENT/data/$1"
  {
    [ "$2" = scout ] || printf 'Delivery contract: mode=direct-PR\n\n'
    printf '# Task\n## Captain'"'"'s intent\nInspect alpha for the e2e (%s).\n\n## Firstmate spec\nWrite what you find.\n\n' "$1"
    printf '# Setup\nprimary-only setup text\n\n'
    printf '# Home brief additions\nKeep a goal record for %s.\n' "$1"
  } > "$PARENT/data/$1/brief.md"
}

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = worker-pc ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
[ "${FM_FAKE_SSH_MODE:-normal}" != unreachable ] || exit 255
cd "$FM_FAKE_REMOTE_CWD" || exit 93
command_name=$(perl -MMIME::Base64=decode_base64 -e 'my @a=split(/\0/, decode_base64($ARGV[0])); print $a[0]' "$4")
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf 'check herdr=ok: fixture\n'
  printf 'ok: remote readiness confirmed on this host\n'
  exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

w_env() {
  FM_HOME="$PARENT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_FAKE_SSH_MODE="${FM_FAKE_SSH_MODE:-normal}" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_SPAWN_NO_GUARD=1 FM_TEARDOWN_GUARD_DONE=1 \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}

reply_owner() { # <source-id>
  w_env "$ROOT/bin/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$1" 'NR > 1 && $1 == id { print $3; exit }'
}

await_mirror() { # <source-id> <parent-status-file> <text>
  local sid=$1 status=$2 text=$3 _
  for _ in $(seq 1 600); do
    grep -F -- "$text" "$status" >/dev/null 2>&1 && return 0
    if [ "$(reply_owner "$sid")" != live ]; then
      w_env "$ROOT/bin/fm-procevent.sh" start "$sid" >/dev/null 2>&1 &
    fi
    sleep 0.1
  done
  return 1
}

# --- place a scout ----------------------------------------------------------

write_brief scout1 scout
rc=0
w_env "$ROOT/bin/fm-spawn.sh" scout1 "$PARENT/projects/alpha" --scout --harness claude --machine pc \
  > "$TMP_ROOT/spawn1.out" 2>&1 || rc=$?
expect_code 75 "$rc" "the first placement while the machine clones the project"
assert_grep 'deferred: scout1 waits for machine pc to finish cloning alpha' "$TMP_ROOT/spawn1.out" \
  "a first clone did not defer the placement"
assert_absent "$PARENT/state/scout1.meta" "a deferred placement published a task record"
for _ in $(seq 1 300); do
  [ -f "$WHH/projects/.clone-alpha/.complete" ] && break
  sleep 0.1
done
assert_present "$WHH/projects/.clone-alpha/.complete" "the detached clone did not finish on the machine"
pass "a first project clone runs detached on the machine and defers the placement"

w_env "$ROOT/bin/fm-spawn.sh" scout1 "$PARENT/projects/alpha" --scout --harness claude --machine pc \
  > "$TMP_ROOT/spawn2.out" 2>&1 || fail "placing the scout failed: $(cat "$TMP_ROOT/spawn2.out")"
assert_grep 'spawned scout1 harness=claude kind=scout window=remote:scout1' "$TMP_ROOT/spawn2.out" \
  "the placement did not report its spawn"
assert_grep 'machine=pc' "$TMP_ROOT/spawn2.out" "the spawn line did not name the machine"
META="$PARENT/state/scout1.meta"
for line in window=remote:scout1 remote_kind=worker remote_machine=pc remote_host=worker-pc \
  "remote_home=$WHH" "remote_root=$REMOTE_ROOT" "worktree=$WHH/pool/scout1" "project=$PARENT/projects/alpha" \
  remote_backend=herdr kind=scout; do
  assert_grep "$line" "$META" "the placement record lacks $line"
done
grep -q '^remote_target=fm-remote:w9:p' "$META" || fail "the placement record lacks the machine's endpoint"
grep -q '^spawn_gen=s' "$META" || fail "the placement record lacks the machine's incarnation"
assert_grep "origin" "$WHH/projects/alpha/.git/config" "the machine has no clone of the project"
[ "$(git -C "$WHH/projects/alpha" remote get-url origin)" = "file://$TMP_ROOT/alpha.git" ] \
  || fail "the machine cloned the wrong origin"
assert_grep '--scout' "$HOST_LOG" "the host-local spawn was not a scout"
assert_grep '--backend herdr' "$HOST_LOG" "the host-local spawn did not select Herdr"
assert_grep 'HERDR_SESSION=fm-remote' "$HOST_LOG" "the host-local spawn did not run in the fm-remote session"
pass "a scout is placed through the machine's ordinary spawn and recorded here"

REMOTE_BRIEF="$WHH/data/scout1/brief.md"
assert_grep 'Inspect alpha for the e2e (scout1).' "$REMOTE_BRIEF" "the filled Task was not spliced into the machine's brief"
assert_grep '# Remote placement' "$REMOTE_BRIEF" "the machine's brief has no placement note"
assert_grep 'report=data/scout1/report.md' "$REMOTE_BRIEF" "the scout was not told to offer its report"
assert_grep "$WHH/state/scout1.status" "$REMOTE_BRIEF" "the machine's brief does not name the machine's status file"
assert_grep 'Keep a goal record for scout1.' "$REMOTE_BRIEF" "the home brief additions did not travel"
assert_no_grep 'primary-only setup text' "$REMOTE_BRIEF" "the spawning home's own setup section leaked into the machine's brief"
assert_no_grep '{TASK}' "$REMOTE_BRIEF" "the machine's brief kept a placeholder"
pass "the brief is rendered for the machine with the filled task spliced in"

CREDS="$WHH/accounts/claude/.credentials.json"
assert_present "$CREDS" "the Claude login was not installed on the machine"
[ "$(jq -r '.claudeAiOauth.accessToken' "$CREDS")" = tok-e2e ] || fail "the machine has the wrong Claude credentials"
assert_no_grep 'mcp-secret' "$CREDS" "credentials beyond the Claude login were copied"
[ -n "$(find "$CREDS" -perm 0600)" ] || fail "the copied credentials are not owner-only"
[ -n "$(find "$WHH/accounts/claude" -maxdepth 0 -perm 0700)" ] || fail "the account root is not owner-only"
[ "$(jq -r '.oauthAccount.emailAddress' "$WHH/accounts/claude/.claude.json")" = worker@example.com ] \
  || fail "the account profile was not installed"
[ "$(cat "$WHH/config/claude-account")" = "$WHH/accounts/claude" ] || fail "the machine does not pin the installed account"
assert_no_grep 'tok-e2e' "$TMP_ROOT/spawn2.out" "the placement printed the credentials"
printf '{"claudeAiOauth":{"accessToken":"tok-switched","refreshToken":"r2"}}\n' > "$ACCOUNT/.credentials.json"
pass "the spawning machine's Claude login is installed owner-only and pinned"

# --- steering, reads, and the watcher -----------------------------------------

w_env "$ROOT/bin/fm-send.sh" scout1 'also list the modules in alpha' > "$TMP_ROOT/send.out" 2>&1 \
  || fail "steering the placed scout failed: $(cat "$TMP_ROOT/send.out")"
grep -l 'also list the modules in alpha' "$WHH"/state/scout1.inbox/*.msg >/dev/null 2>&1 \
  || fail "the steer did not land in the worker's inbox on the machine"
assert_grep 'Firstmate instruction waiting' "$HERDR_LOG" "the doorbell did not ring on the machine"
assert_no_grep 'also list the modules' "$HERDR_LOG" "the steer payload was typed into the pane"
pass "a steer is a durable record in the worker's inbox on the machine plus a doorbell"

out=$(w_env "$ROOT/bin/fm-crew-state.sh" scout1) || fail "crew-state of the placed scout failed"
assert_contains "$out" "host crew-state for scout1" "crew-state did not run on the machine"
assert_contains "$out" "on machine pc" "crew-state did not name the machine"
w_env "$ROOT/bin/fm-peek.sh" scout1 5 > /dev/null || fail "peek of the placed scout failed"
out=$(w_env "$ROOT/bin/fm-on.sh" --machine pc fm-remote-worker-control.sh observe scout1) \
  || fail "observe of the placed scout failed"
assert_contains "$out" "schema=fm-remote-worker-observe.v1" "observe did not answer its schema"
assert_contains "$out" "agent=alive" "observe did not see the live agent"
# shellcheck disable=SC2016 # Expanded by the child bash that sources the watcher.
out=$(w_env bash -c '. "$1"; remote_worker_observe remote:scout1 scout1 \
  && printf "agent=%s\n" "$REMOTE_OBSERVE_AGENT"' _ "$ROOT/bin/fm-watch.sh" 2>&1) \
  || fail "the watcher's remote observe failed: $out"
assert_contains "$out" "agent=alive" "the watcher did not read the machine's agent state"
pass "crew-state, peek, and the watcher read the worker on its machine"

# --- the status mirror and the scout report ---------------------------------

SID='remote-reply-scout1'
w_env "$ROOT/bin/fm-procevent.sh" list 2>/dev/null | grep -q "^$SID " \
  || fail "the placement did not arm the status mirror"
printf 'working [at=%s]: reading alpha on the machine\n' "$(date +%s)" >> "$WHH/state/scout1.status"
await_mirror "$SID" "$PARENT/state/scout1.status" 'reading alpha on the machine' \
  || fail "a worker status line did not mirror into this home"
mkdir -p "$WHH/data/scout1"
printf '# Report\nalpha has one module.\n' > "$WHH/data/scout1/report.md"
printf 'done [at=%s]: report ready report=data/scout1/report.md\n' "$(date +%s)" >> "$WHH/state/scout1.status"
await_mirror "$SID" "$PARENT/state/scout1.status" 'done [at=' \
  || fail "the scout's done line did not mirror"
assert_present "$PARENT/data/scout1/report.md" "the offered report was not copied to this home"
assert_grep 'alpha has one module.' "$PARENT/data/scout1/report.md" "the copied report differs"
assert_no_grep 'remote-secondmates' "$PARENT/state/scout1.status" "a worker report was filed as a secondmate document"
pass "status lines mirror into this home and an offered report lands at data/<id>/report.md"

# --- control --------------------------------------------------------------

w_env "$ROOT/bin/fm-control.sh" scout1 interrupt > /dev/null 2>&1 || fail "interrupting the placed scout failed"
assert_grep 'control scout1 interrupt' "$HOST_LOG" "interrupt did not run on the machine"
old_target=$(grep '^remote_target=' "$META" | cut -d= -f2-)
w_env "$ROOT/bin/fm-control.sh" scout1 relaunch --note 'read README already' > "$TMP_ROOT/relaunch.out" 2>&1 \
  || fail "relaunching the placed scout failed: $(cat "$TMP_ROOT/relaunch.out")"
assert_grep 'note=read README already' "$HOST_LOG" "the progress note did not reach the machine"
new_target=$(grep '^remote_target=' "$META" | cut -d= -f2-)
[ -n "$new_target" ] && [ "$new_target" != "$old_target" ] || fail "relaunch did not republish this home's record"
[ "$(grep -c '^spawn_gen=' "$META")" -eq 1 ] || fail "relaunch left an ambiguous incarnation"
pass "interrupt and relaunch run on the machine and a relaunch republishes the record"

# --- an unreachable machine ---------------------------------------------------

out=$(FM_FAKE_SSH_MODE=unreachable w_env "$ROOT/bin/fm-crew-state.sh" scout1)
assert_contains "$out" "unknown-remote: machine pc unreachable" "an unreachable machine was not unknown"
rc=0
FM_FAKE_SSH_MODE=unreachable w_env "$ROOT/bin/fm-teardown.sh" scout1 > "$TMP_ROOT/td-unreach.out" 2>&1 || rc=$?
expect_code 255 "$rc" "cleanup while the machine is unreachable"
assert_present "$META" "an unreachable cleanup removed this home's record"
assert_present "$WHH/state/scout1.meta" "an unreachable cleanup removed the machine's record"
# shellcheck disable=SC2016 # Expanded by the child bash that sources the watcher.
out=$(FM_FAKE_SSH_MODE=unreachable w_env bash -c '. "$1"; remote_worker_observe remote:scout1 scout1' \
  _ "$ROOT/bin/fm-watch.sh" 2>&1) || true
assert_contains "$out" "machine pc unreachable" "the watcher did not report the unreachable machine"
assert_present "$PARENT/state/.remote-unreachable-pc" "the unreachable episode was not recorded"
# shellcheck disable=SC2016 # Expanded by the child bash that sources the watcher.
out=$(FM_FAKE_SSH_MODE=unreachable w_env bash -c '. "$1"; remote_worker_observe remote:scout1 scout1; echo rc=$?' \
  _ "$ROOT/bin/fm-watch.sh" 2>&1) || true
assert_not_contains "$out" "unreachable or unreadable" "the watcher repeated the unreachable report within one episode"
assert_contains "$out" "rc=1" "an unreachable observe did not skip the window"
pass "an unreachable machine is unknown, reported once, and keeps every record"

# --- cleanup ---------------------------------------------------------------

touch "$TMP_ROOT/host-teardown.refuse"
rc=0
w_env "$ROOT/bin/fm-teardown.sh" scout1 > "$TMP_ROOT/td-refuse.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a cleanup the machine refused was reported as done"
assert_present "$META" "a refused cleanup removed this home's record"
w_env "$ROOT/bin/fm-procevent.sh" list 2>/dev/null | grep -q "^$SID " \
  || fail "a refused cleanup did not re-arm the status mirror"
rm -f "$TMP_ROOT/host-teardown.refuse" "$PARENT/data/scout1/report.md"
w_env "$ROOT/bin/fm-teardown.sh" scout1 > "$TMP_ROOT/td.out" 2>&1 \
  || fail "cleaning up the placed scout failed: $(cat "$TMP_ROOT/td.out")"
assert_grep 'teardown scout1 complete (machine pc' "$TMP_ROOT/td.out" "cleanup did not report the machine"
assert_absent "$META" "cleanup left this home's record"
assert_absent "$WHH/state/scout1.meta" "cleanup left the machine's record"
assert_grep 'alpha has one module.' "$PARENT/data/scout1/report.md" "cleanup did not copy the report back first"
w_env "$ROOT/bin/fm-procevent.sh" list 2>/dev/null | grep -q "^$SID " \
  && fail "cleanup left the status mirror registered"
pass "cleanup runs on the machine first, copies the report, and only then removes this home's record"

# --- a direct-PR ship ---------------------------------------------------------

write_brief ship1 ship
touch "$TMP_ROOT/host-spawn.defer"
rc=0
w_env "$ROOT/bin/fm-spawn.sh" ship1 "$PARENT/projects/alpha" --mode direct-PR --yolo off --harness claude --machine pc \
  > "$TMP_ROOT/ship-defer.out" 2>&1 || rc=$?
expect_code 75 "$rc" "a placement the machine's own capacity defers"
assert_grep 'deferred: ship1 on machine pc: alpha is at capacity' "$TMP_ROOT/ship-defer.out" \
  "the machine's deferral was not relayed"
assert_absent "$PARENT/state/ship1.meta" "a deferred ship published a record"
rm -f "$TMP_ROOT/host-spawn.defer"
w_env "$ROOT/bin/fm-spawn.sh" ship1 "$PARENT/projects/alpha" --mode direct-PR --yolo off --harness claude --machine pc \
  > "$TMP_ROOT/ship.out" 2>&1 || fail "placing the ship failed: $(cat "$TMP_ROOT/ship.out")"
assert_grep 'kind=ship mode=direct-PR yolo=off window=remote:ship1' "$TMP_ROOT/ship.out" "the ship placement line is wrong"
assert_grep 'branch=fm/ship1' "$PARENT/state/ship1.meta" "the ship's branch was not recorded"
assert_grep 'Delivery contract: mode=direct-PR' "$WHH/data/ship1/brief.md" "the machine's ship brief has no delivery contract"
[ "$(jq -r '.claudeAiOauth.accessToken' "$CREDS")" = tok-switched ] \
  || fail "a switched account did not reach the machine on the next placement"
w_env "$ROOT/bin/fm-teardown.sh" ship1 > "$TMP_ROOT/ship-td.out" 2>&1 \
  || fail "cleaning up the placed ship failed: $(cat "$TMP_ROOT/ship-td.out")"
assert_absent "$PARENT/state/ship1.meta" "ship cleanup left this home's record"
pass "a direct-PR ship places, follows the account switch, relays a machine deferral, and cleans up"
