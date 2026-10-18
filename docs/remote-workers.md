# Remote workers

This page covers placing one ship or scout worker on another machine while the home that spawned it keeps supervising it.
It is for operators who run worker machines and for anyone checking how a placed worker is supervised, steered, and cleaned up.

A placed worker runs on a registered worker machine, inside that machine's worker-host home, with its own isolated worktree, build daemons, and memory on that machine.
The spawning home keeps the task: its backlog item, its brief, its mirrored status stream, and a thin task record that routes every lifecycle action to the machine.
No firstmate agent runs on the worker machine, and it makes no decisions.

Whole-home placement is a different feature: [remote secondmates](remote-secondmates.md) place an entire persistent home on another host.

## Scope of this release

- Placement is explicit: firstmate chooses a machine at intake and passes `--machine`; nothing picks a machine automatically.
- Only the main home places workers; a secondmate home refuses.
- Scouts and `direct-PR` ships only; `no-mistakes` and `local-only` ships refuse, because their validation and landing run on the spawning machine.
- The `claude` harness only, because the worker machine signs in with the spawning machine's Claude login (see [the account](#the-claude-account-follows-the-spawning-machine)).
- Worker machines are Linux hosts reached over SSH; macOS-to-macOS placement is not covered.
- A remote placement never fails over to a local replacement.

## Prepare a worker machine

A worker machine meets the same host requirements as a remote secondmate host:

- An SSH alias on the spawning machine with public-key authentication and strict host-key checking ([prerequisites](remote-secondmates.md#prerequisites)).
- A Firstmate clone on the machine as its code root, with the fixed entrypoint on the account's non-interactive SSH `PATH`.
  That code root must already contain this release, because the scripts below run from it.
- The [non-interactive tool contract](remote-secondmates.md#non-interactive-tool-contract), including `herdr`, `jq`, `tasks-axi`, `treehouse`, `git`, `gh`, and `claude`.
- Git access to each project's origin from that account, because the machine clones its own copies of the projects.
- The parent directory of the worker-host home must exist; the home itself is created on first use.

`bin/fm-remote-doctor.sh` remains the single readiness owner.
Every placement runs it through the machine route (read-only, then `--fix`, then a read-only verdict), so the machine's job worker and its `fm-remote` Herdr server are started on the worker machine when they are missing.

```sh
bin/fm-on.sh --machine <machine-id> fm-remote-doctor.sh
```

## Register a machine

Declare each worker machine in `config/worker-machines` in the spawning home.
[`bin/fm-worker-machine-lib.sh`](../bin/fm-worker-machine-lib.sh) owns the format, and [configuration](configuration.md#worker-machines-configworker-machines) summarizes it:

```text
pc host=fm-pc root=/home/me/fm/firstmate home=/home/me/fm/homes/main prefer=android,jvm
```

`prefer=` records the kinds of work the captain prefers to run on that machine; firstmate reads it at intake and nothing acts on it automatically.

## Place a task

Scaffold and fill the brief exactly as for a local task, then add `--machine` to the spawn:

```sh
bin/fm-spawn.sh <task-id> projects/<project> --scout --harness claude --machine pc
bin/fm-spawn.sh <task-id> projects/<project> --mode direct-PR --yolo off --harness claude --machine pc
```

The spawn checks the usual fresh-spawn gates and the backlog item first, then on the machine:

1. Readiness through the doctor.
2. The machine's code root follows this home's default-branch commit when that fast-forward is safe; otherwise it warns and continues.
3. This machine's current Claude login is installed for the launch.
4. The project is cloned from its validated origin into the worker-host home.
   A first clone runs detached; until it finishes, the spawn prints one `deferred:` line and exits 75 so the task stays queued, exactly like a [capacity deferral](configuration.md#project-capacity-configproject-capacity).
5. The brief is re-rendered there, so every path the worker reads is a path on that machine, and the filled `# Task` and `# Home brief additions` sections are spliced in, with a short placement note.
6. The ordinary `fm-spawn.sh` runs there on the Herdr backend in the `fm-remote` session; its isolation assertion, slot claim, capacity, and headroom checks are the machine's own.

The spawning home then records `window=remote:<task-id>` with `remote_kind=worker`, `remote_machine=`, `remote_host=`, `remote_root=`, `remote_home=`, `remote_target=`, and the machine's worktree path, moves the backlog item to In flight, and arms the status mirror.
[`bin/fm-remote-worker-spawn.sh`](../bin/fm-remote-worker-spawn.sh) owns that sequence, and [`bin/fm-remote-worker-control.sh`](../bin/fm-remote-worker-control.sh) owns the machine-side verbs.

## The Claude account follows the spawning machine

At every placement the worker machine signs in with the Claude account this machine is using at that moment, so switching accounts here takes effect on the next placement there.

- When this home pins an account in `config/claude-account`, that account is used; otherwise the account Claude would launch with here, which is `CLAUDE_CONFIG_DIR` when it is set and Claude's default login otherwise.
- The credentials come from that account's `.credentials.json`, or on macOS from the login keychain entry Claude Code keeps for it.
- Only the Claude OAuth credential object and the account profile travel, over the same SSH transport, on standard input; they never appear in a command line, a status line, or a log.
- On the worker machine they are written into an owner-only Claude config root under the worker-host home (directory mode 0700, files 0600), which that home's `config/claude-account` pins for every launch there.

### Security boundary

- Anyone who can read the worker machine's account can use the copied login, with the same reach as on this machine; place workers only on machines whose account you trust with this login.
- The copy is refreshed at each placement and never copied back.
- Both machines then hold the same refresh credential, and if the provider rotates refresh credentials on use, one machine's renewal can sign the other out.
  Signing in again with `/login` here and placing the next worker restores both.
- No other environment or keychain content is copied; the transport still disables agent forwarding and `SendEnv`.

## Supervising a placed worker

Every ordinary command keeps working on a placed worker's task id, and each one routes to the machine:

| Need | What happens |
| --- | --- |
| Status | The worker appends to its status file on the machine, and a cursor-anchored mirror copies each line into this home's `state/<id>.status`, so wakes, open decisions, and crew-state read it unchanged. A scout's report is offered with a structured `report=data/<id>/report.md` pointer and copied to the same path here. |
| Steering | `fm-send.sh` writes the durable steering-inbox record on the machine and rings the doorbell there; an unconfirmed transport keeps the same idempotent resend contract as a remote secondmate steer. |
| Watching | The watcher reads one bounded `observe` snapshot per poll (agent state, busy verdict, last lines) and the machine takes one step of the ordinary re-ring ladder for unread instructions. |
| Current state and peek | `fm-crew-state.sh` runs on the machine against the worker's own record and relays its line; `fm-peek.sh` captures the remote pane. |
| Lifecycle | `fm-control.sh <id>` with `interrupt`, `exit`, or `relaunch` runs the ordinary control plane on the machine; a relaunch republishes this home's record from the route the machine confirmed. |
| Capacity | A placed worker holds a place only in the machine's own project-capacity count, never in this machine's. |
| Session start | The digest asks the machine for the endpoint's state, bounded, and prints an unreachable machine as unknown. |
| Fleet view | The fleet snapshot carries the machine name and the machine's current-state line. |
| Cleanup | `fm-teardown.sh <id>` runs the ordinary teardown on the machine, so the landed-work test reads that machine's worktree, branch refs, and forge login; only then does this home close the backlog item and remove its record. A scout's report is copied here first. |

## Failure behavior

- An unreachable machine is unknown, never dead: crew-state reports `unknown-remote`, the watcher reports the machine once per unreachable episode instead of a wedge per worker, and nothing is relaunched locally.
- SSH exit 255 means completion is unknown; every record here is kept.
  Rerunning the same spawn adopts a worker that did launch instead of launching a second one.
- A worker keeps running through a dropped link, because it needs the forge and the model API, not this machine; its status lines mirror without loss on reconnect.
- After a machine reboot the panes are gone and the worktrees remain; `fm-control.sh <id> relaunch` re-creates the endpoint in the recorded worktree on the machine.

## Verification

The portable tests use a deterministic SSH boundary over the real entrypoint and job worker, real git repositories, and the stateful Herdr fixture:

```sh
bin/fm-test-run.sh tests/fm-worker-machine-lib.test.sh
bin/fm-test-run.sh tests/fm-remote-worker-lifecycle-e2e.test.sh
```

They cannot prove a real worker machine, a real Herdr server, or a real Claude login.
A real-host smoke test places a trivial scout with `--machine`, steers it once, confirms the mirrored status and copied report, and cleans it up.
