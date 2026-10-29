# Fleet pane

Audience: operator-current.

The fleet pane is a terminal view that sits beside the firstmate session and lists every open pull request and every decision waiting for you, so chat messages only need to cover what is new.
It is a plain program, [`bin/fm-fleet-pane.py`](../bin/fm-fleet-pane.py), so it works the same whatever agent runs the firstmate session.
Its header owns the row rules, the read cadence, and the key map; [`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh) owns the records it reads.

## What it shows

- **Open pull requests:** each one recorded in this home's tasks or backlog, with its project, title, check summary, and what keeps it from merging, or that it is ready and waits for your word.
- **Decisions waiting for you:** each open decision in this home's task records and registered second mate summaries, plus each backlog item held for you that is due now.

A decision is one line.
Expanding it shows its full title, its decision text (the question, the recommendation, and the alternatives, as recorded), and the path of its report or plan as plain text you can copy, all wrapped to the pane width.

## Opening it

Inside Herdr, from a shell in the firstmate session's pane (or by asking firstmate to run it there):

```sh
bin/fm-fleet-pane.py open
```

It opens the view in a new pane to the right without taking the keyboard, and reuses that pane rather than opening a second one.
`--session <name>` and `--pane <pane-id>` name another Herdr session and pane than the calling one.
Outside Herdr, run `bin/fm-fleet-pane.py` in any terminal.
It runs only for a main home; a second mate's home refuses it.

Session start does not open it.
Session start runs for every home and harness, inside and outside Herdr, under the session lock with a fixed digest; a pane opened there would appear in second mate and lab sessions and on every restart.
Open it once per Herdr tab; it keeps running across firstmate restarts.

## Keys

Move Herdr's focus to the pane so it takes the keyboard.

- Up and Down, or `k` and `j`: move between items.
- Enter or Space: expand or collapse the selected decision; Right expands and Left collapses.
- `o`: open the decision's report or plan, or the selected pull request, with the system opener.
- `y`: resolve the expanded decision with its recommendation.
- `a`: type a short answer, then Enter to review it.
- `d`: drop the expanded decision.
- `r`: read again now.
- `q`: quit.

Resolve and drop ask `y` or `n` before anything is recorded, and the pane shows the outcome.
They are offered only for a decision held in this home's backlog; for any other the pane says to answer it in chat.

Opening uses `open` (or `xdg-open`) rather than a terminal link, because macOS Terminal draws no clickable links.

## Resolving and dropping from a terminal

The pane runs [`bin/fm-decision.sh`](../bin/fm-decision.sh), and you or any agent can run the same command:

```sh
bin/fm-decision.sh resolve <task-id> <your answer>
bin/fm-decision.sh drop <task-id>
```

It records your words through `bin/fm-captain-hold.sh answer`, which closes a question or lifts the hold on held work, then leaves one captain inbox note that wakes firstmate to act on the answer.
It refuses a task this home's backlog does not hold for you, and records nothing then.
Its header owns the exact outcomes and exit codes.

## Reading and writing

Each read runs the snapshot for this home with its forge fallback off and its remote-summary cache pointed at a path that can never be created, so a read writes nothing.
It reads once a minute and on `r`, and asks GitHub in two batched queries at most about once a minute.
A failed read keeps the last rows on screen and says what could not be read.
Resolve and drop are the pane's only writes, and only through `bin/fm-decision.sh`.

[`docs/verification/fleet-pane.md`](verification/fleet-pane.md) records the live check in a Herdr session.

## Replacing the Claude Code mod

This view replaces the `fleet-pane` Claude Code mod.
A home that installed the mod removes it with:

```sh
claude plugin uninstall fleet-pane@firstmate-mods
```
