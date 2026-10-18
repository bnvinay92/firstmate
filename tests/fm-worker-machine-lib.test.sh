#!/usr/bin/env bash
# Worker-machine registry, the fm-on.sh machine route, the spawning home's view
# of a placed worker, and the fm-spawn.sh --machine refusals that run before any
# transport (docs/remote-workers.md).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-worker-machine)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
mkdir -p "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/projects"

# --- registry parsing -------------------------------------------------------

registry() { cat > "$HOME_DIR/config/worker-machines"; }
resolve() { # <machine> -> prints host root home prefer, or the error
  bash -c '. "$1/bin/fm-worker-machine-lib.sh"
    if fm_worker_machine_resolve "$2" "$3"; then
      printf "%s|%s|%s|%s\n" "$FM_WORKER_MACHINE_HOST" "$FM_WORKER_MACHINE_ROOT" "$FM_WORKER_MACHINE_HOME" "$FM_WORKER_MACHINE_PREFER"
    else
      printf "error: %s\n" "$FM_WORKER_MACHINE_ERROR"; exit 1
    fi' _ "$ROOT" "$HOME_DIR/config" "$1"
}

out=$(resolve pc) && fail "an absent registry resolved a machine"
assert_contains "$out" "no worker machine is registered" "absent registry was not named"

registry <<'EOF'
# worker machines
pc host=fm-pc root=/srv/fm/firstmate home=/srv/fm/homes/main prefer=android,jvm

mini host=mini-alias root=/opt/fm home=/opt/homes/w
EOF
out=$(resolve pc) || fail "a registered machine did not resolve: $out"
assert_equals "fm-pc|/srv/fm/firstmate|/srv/fm/homes/main|android,jvm" "$out" "machine fields were not parsed"
out=$(resolve mini) || fail "a second machine did not resolve: $out"
assert_equals "mini-alias|/opt/fm|/opt/homes/w|" "$out" "prefer= is optional"
out=$(resolve laptop) && fail "an unregistered machine resolved"
assert_contains "$out" "registered: pc mini" "the refusal did not list registered machines"
pass "the registry resolves declared machines and names unregistered ones"

bad() { # <description> <line>
  printf '%s\n' "$2" | registry
  out=$(resolve pc) && fail "$1 was accepted"
}
bad "a missing home" 'pc host=fm-pc root=/srv/fm'
bad "a relative root" 'pc host=fm-pc root=srv/fm home=/srv/h'
bad "an unknown key" 'pc host=fm-pc root=/srv/fm home=/srv/h user=me'
bad "overlapping root and home" 'pc host=fm-pc root=/srv/fm home=/srv/fm/homes'
bad "an unsafe alias" 'pc host=-oProxyCommand=x root=/srv/fm home=/srv/h'
bad "traversal" 'pc host=fm-pc root=/srv/../fm home=/srv/h'
printf 'pc host=a root=/a home=/h\npc host=b root=/b home=/i\n' | registry
out=$(resolve pc) && fail "a duplicate machine id was accepted"
assert_contains "$out" "declared twice" "duplicate id refusal was not named"
printf 'pc host=a root=/a home=/h\nbroken line\n' | registry
out=$(resolve pc) && fail "a malformed line elsewhere did not refuse the whole declaration"
pass "malformed, unsafe, overlapping, and duplicate declarations refuse the whole registry"

# --- fm-on.sh machine route -------------------------------------------------

registry <<'EOF'
pc host=fm-pc root=/srv/fm/firstmate home=/srv/fm/homes/main
EOF
cat > "$FAKEBIN/fake-ssh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP_ROOT/ssh.argv"
exit 0
SH
chmod +x "$FAKEBIN/fake-ssh"
FM_HOME="$HOME_DIR" FM_SSH_BIN="$FAKEBIN/fake-ssh" "$ROOT/bin/fm-on.sh" --machine pc \
  fm-remote-worker-control.sh state task-a || fail "fm-on.sh --machine did not route a registered machine"
assert_grep 'fm-pc' "$TMP_ROOT/ssh.argv" "the machine route did not use its SSH alias"
assert_grep 'ForwardAgent=no' "$TMP_ROOT/ssh.argv" "the machine route dropped the transport protections"
root_b64=$(printf '%s' /srv/fm/firstmate | base64 | tr -d '\n')
home_b64=$(printf '%s' /srv/fm/homes/main | base64 | tr -d '\n')
assert_grep "$root_b64" "$TMP_ROOT/ssh.argv" "the machine route did not carry its code root"
assert_grep "$home_b64" "$TMP_ROOT/ssh.argv" "the machine route did not carry its worker-host home"
if FM_HOME="$HOME_DIR" FM_SSH_BIN="$FAKEBIN/fake-ssh" "$ROOT/bin/fm-on.sh" --machine laptop \
  fm-remote-worker-control.sh state task-a 2>"$TMP_ROOT/on.err"; then
  fail "fm-on.sh --machine routed an unregistered machine"
fi
assert_grep "not registered" "$TMP_ROOT/on.err" "an unregistered machine route was not refused by name"
pass "fm-on.sh --machine resolves the registry and keeps the transport protections"

# --- the spawning home's view of a placed worker ----------------------------

cat > "$HOME_DIR/state/w1.meta" <<'EOF'
window=remote:w1
endpoint_task_id=w1
kind=scout
remote_kind=worker
remote_machine=pc
remote_host=fm-pc
EOF
cat > "$HOME_DIR/state/sm.meta" <<'EOF'
window=remote:sm
kind=secondmate
remote_host=mac-two
EOF
route=$(bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-remote-worker-lib.sh"
  fm_remote_route_for_meta "$2/state/w1.meta" w1; printf "%s " "${FM_REMOTE_ROUTE[@]}"; printf "| "
  fm_remote_route_for_meta "$2/state/sm.meta" sm; printf "%s " "${FM_REMOTE_ROUTE[@]}"' _ "$ROOT" "$HOME_DIR")
assert_equals "--machine pc fm-remote-worker-control.sh | sm fm-remote-secondmate-control.sh " "$route" \
  "placed workers and remote secondmates did not route to their own control scripts"
pass "a placed worker routes through its machine and a remote secondmate through its own route"

# The Claude login a placement carries: the pinned root's credentials and
# account profile, and nothing else from either file.
ACCOUNT="$TMP_ROOT/claude-root"
mkdir -p "$ACCOUNT"
printf '{"claudeAiOauth":{"accessToken":"tok-1","refreshToken":"ref-1"},"mcpOAuth":{"secret":"keep-me-here"}}\n' \
  > "$ACCOUNT/.credentials.json"
printf '{"oauthAccount":{"emailAddress":"a@example.com"},"projects":{"/x":{"trust":true}}}\n' > "$ACCOUNT/.claude.json"
printf '%s\n' "$ACCOUNT" > "$HOME_DIR/config/claude-account"
cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/claude"
payload=$(PATH="$FAKEBIN:$PATH" bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-worker-account-lib.sh"; . "$1/bin/fm-remote-worker-lib.sh"
  fm_remote_worker_claude_payload "$2/config"' _ "$ROOT" "$HOME_DIR") || fail "a pinned Claude login produced no payload"
assert_equals "tok-1" "$(printf '%s' "$payload" | jq -r '.claudeAiOauth.accessToken')" "the payload did not carry the pinned credentials"
assert_equals "a@example.com" "$(printf '%s' "$payload" | jq -r '.oauthAccount.emailAddress')" "the payload did not carry the account profile"
assert_not_contains "$payload" "keep-me-here" "the payload carried credentials other than the Claude login"
assert_not_contains "$payload" "trust" "the payload carried unrelated account config"
rm -f "$ACCOUNT/.credentials.json"
if PATH="$FAKEBIN:$PATH" HOME="$TMP_ROOT/empty-home" bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-worker-account-lib.sh"; . "$1/bin/fm-remote-worker-lib.sh"
  fm_remote_worker_claude_payload "$2/config" >/dev/null || { printf "%s\n" "$FM_REMOTE_ACCOUNT_ERROR" >&2; exit 1; }' \
  _ "$ROOT" "$HOME_DIR" 2>"$TMP_ROOT/payload.err"; then
  [ "$(uname -s)" = Darwin ] || fail "a root with no login produced a payload"
else
  assert_grep "no Claude login" "$TMP_ROOT/payload.err" "a missing login was not named"
fi
pass "a placement carries only the selected account's Claude login and profile"

# A placed worker never holds a place in this machine's project capacity.
git -C "$HOME_DIR/projects" init -q alpha
cat > "$HOME_DIR/state/w1.meta" <<EOF
window=remote:w1
kind=scout
project=$HOME_DIR/projects/alpha
remote_kind=worker
remote_machine=pc
remote_host=fm-pc
EOF
cat > "$HOME_DIR/state/l1.meta" <<EOF
window=firstmate:fm-l1
kind=scout
project=$HOME_DIR/projects/alpha
EOF
occupants=$(FM_HOME="$HOME_DIR" bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-secondmate-registry-lib.sh"; . "$1/bin/fm-backend.sh"; . "$1/bin/fm-project-capacity-lib.sh"
  lock=$(fm_treehouse_project_lock_path "$2/projects/alpha") || exit 1
  fm_project_capacity_occupants "$lock" "$2/projects/alpha" "$2/state" new-task || exit 1
  printf "%s %s\n" "$FM_PROJECT_CAPACITY_OCCUPANTS" "$FM_PROJECT_CAPACITY_OCCUPANT_IDS"' _ "$ROOT" "$HOME_DIR") \
  || fail "capacity occupancy could not be counted"
assert_equals "1 l1" "$occupants" "a placed worker held a place in this machine's capacity"
pass "project capacity counts only workers on this machine"

# --- fm-spawn.sh --machine refusals before any transport ---------------------

spawn_refusal() { # <description> <expected-text> <args...>
  local description=$1 expected=$2
  shift 2
  if FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    "$ROOT/bin/fm-spawn.sh" "$@" > "$TMP_ROOT/spawn.out" 2>&1; then
    fail "$description was not refused"
  fi
  assert_grep "$expected" "$TMP_ROOT/spawn.out" "$description was refused for the wrong reason"
}
rm -f "$TMP_ROOT/ssh.argv"
spawn_refusal "a no-mistakes ship" "only direct-PR" t1 "$HOME_DIR/projects/alpha" --mode no-mistakes --yolo off --harness claude --machine pc
spawn_refusal "a local-only ship" "only direct-PR" t1 "$HOME_DIR/projects/alpha" --mode local-only --yolo off --harness claude --machine pc
spawn_refusal "a secondmate" "ship and scout workers only" t1 --secondmate --machine pc
spawn_refusal "an explicit backend" "cannot be combined" t1 "$HOME_DIR/projects/alpha" --scout --backend tmux --harness claude --machine pc
spawn_refusal "a relaunch" "fresh spawn" t1 --relaunch --machine pc
spawn_refusal "another harness" "only on the claude harness" t1 "$HOME_DIR/projects/alpha" --scout --harness codex --machine pc
spawn_refusal "an unregistered machine" "not registered" t1 "$HOME_DIR/projects/alpha" --scout --harness claude --machine laptop
printf 'sm\n' > "$HOME_DIR/.fm-secondmate-home"
spawn_refusal "a secondmate home" "only the main home" t1 "$HOME_DIR/projects/alpha" --scout --harness claude --machine pc
rm -f "$HOME_DIR/.fm-secondmate-home"
assert_absent "$TMP_ROOT/ssh.argv" "a refused placement still reached the transport"
assert_absent "$HOME_DIR/state/t1.meta" "a refused placement published a task record"
pass "fm-spawn.sh --machine refuses unsupported placements before any transport or record"
