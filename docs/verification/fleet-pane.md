# Fleet pane verification

Audience: maintainer verification.

This record supports the current guarantees of the [fleet pane](../fleet-pane.md): it opens once beside a Herdr pane, expands and collapses decisions from the keyboard, and resolves and drops them through `bin/fm-decision.sh` with a confirm step.

## Live Herdr lab check

On 2026-10-29, with Herdr 0.9.1 on macOS 27.0, the view ran in an isolated lab session provisioned through `bin/fm-herdr-lab.sh`, against a fixture home whose backlog held two captain questions and one held ship task.
Every Herdr call went through the lab helper's `run`, including the view's own `open`, whose `FM_HERDR_BIN` pointed at a stand-in that forwards to `fm-herdr-lab.sh run <session>` after dropping the trailing `--session` pair the view adds.

The sequence was:

```sh
FM_HOME=<fixture> FM_HERDR_BIN=<lab forwarder> bin/fm-fleet-pane.py open --session <lab> --pane w1:p1
FM_HOME=<fixture> FM_HERDR_BIN=<lab forwarder> bin/fm-fleet-pane.py open --session <lab> --pane w1:p1
fm-herdr-lab.sh run <lab> pane send-keys w1:p2 enter      # expand, then again to collapse
fm-herdr-lab.sh run <lab> pane send-text w1:p2 y          # recommendation, then y to confirm
fm-herdr-lab.sh run <lab> pane send-text w1:p2 d          # drop, n to cancel, d and y to drop
fm-herdr-lab.sh run <lab> pane send-text w1:p2 a          # typed answer, Enter, y to confirm
fm-herdr-lab.sh run <lab> pane read w1:p2 --source visible
```

The first `open` printed `opened: pane w1:p2` and the second `already open: pane w1:p2`.
The pane listed `Decisions waiting for you (3)` as three one-line rows, expanded the first to its full title, its reason, `Document:` with the absolute report path, and the key line, and collapsed it again.
`y` then `y` printed `q-one: resolved: q-one (recorded; the call is closed); Firstmate is told` and the count fell to 2.
`d` then `n` returned to the key line with nothing recorded; `d` then `y` dropped `q-two` and the count fell to 1.
`a`, the typed answer `not yet, after the model`, Enter, and `y` recorded it on the ship task with `Resolution mode: released`, leaving it queued, and the count fell to 0.
The fixture backlog recorded each answer under `Captain decision:`, and `state/inbox/` held three notes with request ids `fm-decision:<task>:<digest>`, each raising a `check` wake.
Lab teardown passed its fleet-state tripwire.

## Why decision rows did not open in macOS Terminal

The retired Claude Code mod drew each row as a terminal hyperlink.
Claude Code 2.1.312 emits a terminal hyperlink only when it detects support: its detection accepts `ghostty`, `Hyper`, `kitty`, `alacritty`, `iTerm.app`, `iTerm2`, `WarpTerminal`, JetBrains, Windows Terminal, a recent tmux, and `FORCE_HYPERLINK`, and has no case for `TERM_PROGRAM=Apple_Terminal`.
In macOS Terminal the row was therefore plain text with nothing to click, which is why the view opens documents with the system opener and shows their paths as plain text.

## Repeatable regression checks

```sh
bash tests/fm-fleet-pane.test.sh
bash tests/fm-decision.test.sh
```

The first pins the pull request rows (inventory, deduplication, required-check blockers, and the two-query GitHub budget), collapsed and expanded decision rendering within the width, decoded stored reasons through the real snapshot with nothing written, and the Herdr `open` calls through a stand-in.
The second pins resolve, multi-line answers, release of held work, drop, and the refusals of an unknown, unheld, already answered, or malformed request without a record or a wake.
Re-run the lab sequence after a Herdr upgrade before relying on the pane's key handling for a newer build.
