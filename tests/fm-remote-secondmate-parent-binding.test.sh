#!/usr/bin/env bash
# tests/fm-remote-secondmate-parent-binding.test.sh - regression coverage for a
# REMOTE second-mate home's durable .fm-secondmate-parent record: remote
# provisioning publishes it before the .fm-secondmate-home completion marker
# and records the route as "remote", a finished child worker inside that home
# still cleans up, and the parent-side task record refuses a publication target
# that resolves outside its home.
#
# This drives the REAL remote route (fm-remote-home-seed.sh -> fm-on.sh ->
# fm-remote-entrypoint.sh -> the host-local fm-remote-secondmate-control.sh ->
# the real bin/fm-spawn.sh --secondmate) across the repo's own deterministic SSH
# boundary and Herdr fixture, then runs the real bin/fm-teardown.sh for a
# finished child worker inside the produced remote home - never source-text
# matching.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-parent-binding)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
SSH_COUNT="$TMP_ROOT/ssh.count"
DOCTOR_LOG="$TMP_ROOT/doctor.log"
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
CLAIMS="$TMP_ROOT/claims"
PUBLISH_PID=
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"

cleanup() {
  local worker_pid=''
  if [ -n "$PUBLISH_PID" ]; then
    touch "$PUBLISH_RELEASE" 2>/dev/null || true
    kill "$PUBLISH_PID" 2>/dev/null || true
    wait "$PUBLISH_PID" 2>/dev/null || true
  fi
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    kill "$worker_pid" 2>/dev/null || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

PUBLISH_HOME="$TMP_ROOT/publication-home"
PUBLISH_FAKEBIN=$(fm_fakebin "$TMP_ROOT/publication-fake")
PUBLISH_ENTERED="$TMP_ROOT/publication-marker-entered"
PUBLISH_RELEASE="$TMP_ROOT/publication-marker-release"
PUBLISH_MANIFEST="$TMP_ROOT/publication.manifest"
REAL_MV=$(command -v mv)
cat > "$PUBLISH_FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
case "$destination" in
  */.fm-secondmate-home)
    touch "$FM_TEST_PUBLISH_ENTERED"
    while [ ! -f "$FM_TEST_PUBLISH_RELEASE" ]; do sleep 0.02; done
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
chmod +x "$PUBLISH_FAKEBIN/mv"
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nparent_host_b64=%s\nproject_count=0\n' \
  "$(printf publication | base64 | tr -d '\n')" \
  "$(printf 'Publication-order regression charter.\n' | base64 | tr -d '\n')" \
  "$(printf publish-host | base64 | tr -d '\n')" > "$PUBLISH_MANIFEST"
PATH="$PUBLISH_FAKEBIN:$PATH" FM_HOME="$PUBLISH_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  FM_TEST_REAL_MV="$REAL_MV" FM_TEST_PUBLISH_ENTERED="$PUBLISH_ENTERED" \
  FM_TEST_PUBLISH_RELEASE="$PUBLISH_RELEASE" \
  "$ROOT/bin/fm-remote-home-provision.sh" < "$PUBLISH_MANIFEST" >/dev/null 2>&1 &
PUBLISH_PID=$!
publish_wait=0
while [ ! -f "$PUBLISH_ENTERED" ]; do
  kill -0 "$PUBLISH_PID" 2>/dev/null || fail "remote provisioning exited before its completion marker"
  publish_wait=$((publish_wait + 1))
  [ "$publish_wait" -le 250 ] || fail "remote provisioning never reached its completion marker"
  sleep 0.02
done
cmp -s "$PUBLISH_HOME/.fm-secondmate-parent" <(
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=publish-host\n'
) || fail "remote provisioning exposed completion before publishing the durable parent record"
assert_absent "$PUBLISH_HOME/.fm-secondmate-home" \
  "the remote identity marker must remain absent until durable parent publication completes"
touch "$PUBLISH_RELEASE"
wait "$PUBLISH_PID" || fail "remote provisioning failed after publishing durable state"
PUBLISH_PID=
assert_present "$PUBLISH_HOME/.fm-secondmate-home" \
  "remote provisioning must publish its identity marker as the completion point"
pass "remote provisioning publishes durable parent state before its completion marker"

# --- the remote host's tracked code root, real git repos, one project --------
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'
REMOTE_ORIGIN="$TMP_ROOT/firstmate-origin.git"
git init -q --bare "$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" remote add origin "file://$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" push -q -u origin main
git --git-dir="$REMOTE_ORIGIN" symbolic-ref HEAD refs/heads/main

git init -q --bare "$TMP_ROOT/alpha.git"
git -C "$PARENT/projects" init -q -b main alpha
git -C "$PARENT/projects/alpha" config user.email test@example.com
git -C "$PARENT/projects/alpha" config user.name Test
printf 'alpha\n' > "$PARENT/projects/alpha/README.md"
git -C "$PARENT/projects/alpha" add README.md
git -C "$PARENT/projects/alpha" commit -qm init
git -C "$PARENT/projects/alpha" remote add origin "file://$TMP_ROOT/alpha.git"
git -C "$PARENT/projects/alpha" push -q -u origin main
git --git-dir="$TMP_ROOT/alpha.git" symbolic-ref HEAD refs/heads/main
printf -- '- alpha [direct-PR] - alpha project (added 2026-08-04)\n' > "$PARENT/data/projects.md"
printf 'codex\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"

# --- deterministic SSH boundary, identical shape to the lifecycle e2e suite --
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ ? $_ : "" } @args[0..2]);
' "$argv_b64")
IFS=$'\t' read -r command_name _command_action command_rel <<EOF
$command_fields
EOF
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf 'check herdr=ok: /usr/bin/herdr\n'
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
if [ "$command_name" = fm-remote-secondmate-control.sh ] \
   && [ "$_command_action" = launch ] \
   && [ -n "${FM_TEST_PUBLICATION_TARGET:-}" ]; then
  out=$("$FM_FAKE_REMOTE_ENTRYPOINT" "$@")
  rc=$?
  rm -f "$FM_TEST_PUBLICATION_TARGET"
  ln -s "$FM_TEST_PUBLICATION_FOREIGN" "$FM_TEST_PUBLICATION_TARGET" || exit 94
  printf '%s\n' "$out"
  exit "$rc"
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_FAKE_DOCTOR_LOG="$DOCTOR_LOG" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$@"
}

FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" alpha \
  >/dev/null || fail "real remote secondmate seeding failed"

# --- the durable record itself: the fundamental part of the fix -------------
assert_present "$REMOTE_HOME/.fm-secondmate-parent" \
  "real remote provisioning must write a durable parent record"
cmp -s "$REMOTE_HOME/.fm-secondmate-parent" <(
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=remote-mac\n'
) || fail "real remote provisioning must write the exact durable remote parent record"

remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate >/dev/null \
  || fail "real remote secondmate launch failed"

# --- a finished child worker inside the remote secondmate home --------------
CHILD_WT="$REMOTE_HOME/projects/alpha"
mkdir -p "$REMOTE_HOME/state"
# This regression exercises remote-parent binding, not backlog mutation. Keep
# its synthetic child home on the supported hand-edited backend so teardown's
# fused automatic close is correctly exempt without requiring a tasks-axi mock.
printf '%s\n' manual > "$REMOTE_HOME/config/backlog-backend"
write_child_meta() {
  fm_write_meta "$REMOTE_HOME/state/work-child.meta" \
    "window=firstmate:fm-work-child" "endpoint_task_id=work-child" \
    "worktree=$CHILD_WT" "project=$CHILD_WT" "harness=codex" "kind=ship" \
    "mode=local-only" "yolo=off"
}
mkdir -p "$TMP_ROOT/childfake"
for t in tmux treehouse no-mistakes gh gh-axi tasks-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/childfake/$t"
  chmod +x "$TMP_ROOT/childfake/$t"
done

run_child_teardown() { # <extra env assignments...>
  local out rc=0
  write_child_meta
  out=$(env "$@" PATH="$TMP_ROOT/childfake:$PATH" \
    FM_HOME="$REMOTE_HOME" FM_STATE_OVERRIDE="$REMOTE_HOME/state" \
    FM_DATA_OVERRIDE="$REMOTE_HOME/data" FM_CONFIG_OVERRIDE="$REMOTE_HOME/config" \
    "$REMOTE_ROOT/bin/fm-teardown.sh" work-child 2>&1) || rc=$?
  CHILD_TEARDOWN_OUT=$out
  CHILD_TEARDOWN_RC=$rc
}

run_child_teardown
[ "$CHILD_TEARDOWN_RC" -eq 0 ] \
  || fail "a remote-routed child must allow cleanup (rc=$CHILD_TEARDOWN_RC): $CHILD_TEARDOWN_OUT"
pass "a remote secondmate's finished worker cleans up"

FOREIGN_META="$TMP_ROOT/foreign-ios.meta"
LOCAL_META="$PARENT/state/ios.meta"
printf 'foreign sentinel\n' > "$FOREIGN_META"
rm -f "$LOCAL_META"
PUBLICATION_RC=0
PUBLICATION_OUT=$(FM_TEST_PUBLICATION_TARGET="$LOCAL_META" \
  FM_TEST_PUBLICATION_FOREIGN="$FOREIGN_META" \
  remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1) || PUBLICATION_RC=$?
[ "$PUBLICATION_RC" -ne 0 ] \
  || fail "remote secondmate publication accepted a target resolving outside its home"
assert_contains "$PUBLICATION_OUT" "task record could not be published" \
  "remote secondmate publication did not report its record-boundary refusal"
cmp -s "$FOREIGN_META" <(printf 'foreign sentinel\n') \
  || fail "remote secondmate publication wrote through the foreign target"
[ -L "$LOCAL_META" ] \
  || fail "remote secondmate publication replaced the refused target boundary"
pass "remote secondmate publication refuses targets outside its home"

echo "ALL TESTS PASSED"
