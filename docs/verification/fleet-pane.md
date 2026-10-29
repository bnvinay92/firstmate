# Fleet pane verification

Audience: maintainer verification.

This record supports the current guarantees of the [fleet pane](../fleet-pane.md): it opens once beside a Herdr pane, expands decisions and pull requests from the keyboard, stages answers and pull request actions and submits them together through `bin/fm-decision.sh batch` as one note, and keeps every key the captain presses.

## Live Herdr lab check

On 2026-10-29, with Herdr 0.9.1 on macOS 27.0, the view ran in an isolated lab session provisioned through `bin/fm-herdr-lab.sh`, against a fixture home whose backlog held three captain questions, one held ship task, and two ship tasks recording pull requests.
A stand-in `gh` on the view's `PATH` answered the pull request reads: one pull request ready, the other with its `lint` check failing and a log link.
A stand-in `open` logged what it was asked to open.
Every Herdr call went through the lab helper's `run`, including the view's own `open`, whose `FM_HERDR_BIN` pointed at a stand-in that forwards to `fm-herdr-lab.sh run <session>` after dropping the trailing `--session` pair the view adds.

The sequence was:

```sh
FM_HOME=<fixture> FM_HERDR_BIN=<lab forwarder> bin/fm-fleet-pane.py open --session <lab> --pane w1:p1
FM_HOME=<fixture> FM_HERDR_BIN=<lab forwarder> bin/fm-fleet-pane.py open --session <lab> --pane w1:p1
fm-herdr-lab.sh run <lab> pane run w1:p1 <fixture>/view.sh      # a second lab: the view, stand-ins on PATH
fm-herdr-lab.sh run <lab> pane send-keys w1:p1 enter            # expand each pull request
fm-herdr-lab.sh run <lab> pane send-text w1:p1 o                # then g, f with a typed note, m on the ready one
fm-herdr-lab.sh run <lab> pane send-text w1:p1 y                # then d, a with a typed answer, u, d again, q
fm-herdr-lab.sh run <lab> pane send-text w1:p1 s                # then y, then Down and d while it is passed on
fm-herdr-lab.sh run <lab> pane read w1:p1 --source visible
```

The first `open` printed `opened: pane w1:p2` and the second `already open: pane w1:p2`, leaving one pane labelled `fleet-pane`.
Enter expanded the ready pull request to `Ready - waiting for your word to merge.` with `o open it in the browser · m merge · c close`, and the failing one to `Keeps it from merging: a failing check.`, `Failing: lint`, its log link, and `o open it in the browser · g open the failing check's log · f ask for a fix · c close`, with no merge offered.
`o` and `g` opened the pull request and the check log at once.
`f`, `m`, `y`, `d`, and `a` tagged their rows `[fix]`, `[merge]`, `[answer]`, `[drop]`, and `[answer]`, the footer read `s submits 5 staged`, and nothing was recorded.
`u` let go of the drop and `d` staged it again; `q` printed `Quitting lets go of 5 staged answers, which Firstmate never sees. q again quits; s submits them.` and kept the view open.
`s` printed `Submit 5 staged answers to Firstmate in one note?  y yes · n no` at the bottom of the pane, and `y` tagged all five `[sending]` while Down still moved the selection.
About 8 seconds later the pane printed `Passed 5 answers on in one note; Firstmate is told.`, the three answered decisions had left the list with the selection on the remaining one, and the pull requests read `[merge sent]` and `[fix sent]`; the next read, 65 seconds later, showed the same list.
With one more answer staged, two `q` presses quit the view.
The fixture recorded each decision answer under `Captain decision:`, and `state/inbox/` held exactly one note, request id `fm-decision:batch:<digest>`, listing the fix with its note, the merge through the guarded merge path, and the three decision answers, raising one `check` wake.
Lab teardown passed its fleet-state tripwire.

The view's commands must not share its terminal input: in the same lab, before every command the view runs was given its own input, one of two Down presses sent while a read ran never reached the view, and with it both arrived.
`tests/fm-fleet-pane.test.sh` pins that a read takes none of the view's keys.

## Why decision rows did not open in macOS Terminal

The retired Claude Code mod drew each row as a terminal hyperlink.
Claude Code 2.1.312 emits a terminal hyperlink only when it detects support: its detection accepts `ghostty`, `Hyper`, `kitty`, `alacritty`, `iTerm.app`, `iTerm2`, `WarpTerminal`, JetBrains, Windows Terminal, a recent tmux, and `FORCE_HYPERLINK`, and has no case for `TERM_PROGRAM=Apple_Terminal`.
In macOS Terminal the row was therefore plain text with nothing to click, which is why the view opens documents with the system opener and shows their paths as plain text.

## Repeatable regression checks

```sh
bash tests/fm-fleet-pane.test.sh
bash tests/fm-decision.test.sh
```

The first pins the pull request rows (inventory, deduplication, required-check blockers, and the two-query GitHub budget), that a read never takes the view's keys, collapsed and expanded decision and pull request rendering within the width, Enter expanding a pull request with merge offered only when it is ready, `o` and `g` opening at once, staging, changing, letting go, and submitting answers and pull request actions through the view's own key handling as one note that leaves the list at once and keeps the selection, a refused line keeping everything staged, decoded stored reasons through the real snapshot with nothing written, and the Herdr `open` calls through a stand-in.
The second pins resolve, multi-line answers, release of held work, drop, a batch of decision answers and pull request actions recorded with one note and one wake, a batch refused whole with each line named, and the refusals of an unknown, unheld, already answered, or malformed request without a record or a wake.
Re-run the lab sequence after a Herdr upgrade before relying on the pane's key handling for a newer build.
