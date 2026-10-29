# Fleet pane

Audience: operator-current.

The fleet pane is a terminal view that sits beside the firstmate session and lists every open pull request and every decision waiting for you, so chat messages only need to cover what is new.
It is a plain program, [`bin/fm-fleet-pane.py`](../bin/fm-fleet-pane.py), so it works the same whatever agent runs the firstmate session.
Its header owns the row rules, the read cadence, and the key map; [`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh) owns the records it reads.

## What it shows

- **Open pull requests:** each one recorded in this home's tasks or backlog, with its project, title, check summary, and what keeps it from merging, or that it is ready and waits for your word.
- **Decisions waiting for you:** each open decision in this home's task records and registered second mate summaries, plus each backlog item held for you that is due now.

Every row is one line, and Enter expands it, wrapped to the pane width.
An expanded decision shows its full title, its decision text (the question, the recommendation, and the alternatives, as recorded), and the path of its report or plan as plain text you can copy.
An expanded pull request leads with what keeps it from merging, or that it is ready, then names its failing and running checks with each failing check's log link, its own link, and the keys for what you usually do next.

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
- Enter or Space: expand or collapse the selected item; Right expands and Left collapses.
- `o`: open the selected pull request in the browser, or the decision's report or plan, with the system opener.
- `g`: open the pull request's first failing check log.
- `y`: stage the recommendation as the decision's answer.
- `a`: type a short answer, then Enter to stage it.
- `d`: stage dropping the decision.
- `m`: stage merging the pull request; offered only once nothing keeps it from merging.
- `f`: stage asking firstmate to have the worker fix what keeps the pull request from merging, with an optional typed note.
- `c`: stage closing the pull request without merging.
- `u`: let go of the selected item's staged answer.
- `s`: submit every staged answer at once, after one `y` to confirm.
- `r`: read again now.
- `q`: quit.

Opening a pull request, a check log, or a document happens at once, because it changes nothing.
Everything else is staged first, so you can go through every decision and pull request before anything is passed on.
A staged row is tagged with what it carries, such as `[drop]` or `[merge]`; staging another answer on the same row replaces it.
The footer shows `s` and the number staged.
Submitting passes everything staged to firstmate in one note, which wakes firstmate once for the whole batch.
It runs in the background, so you can keep moving and staging while it does; what was passed on leaves the list at once, without waiting for the next read.
A pull request passed on stays listed, tagged `[merge sent]`, `[fix sent]`, or `[close sent]`, until firstmate acts.
If any staged answer is refused, for example because the decision was answered elsewhere, nothing is passed on, the pane names the refused one, and everything stays staged to change or let go.

Staged answers live only in the pane until you submit them.
Quitting with answers staged asks for a second `q`, and then lets them go without telling firstmate.
A staged row that stops being listed is let go, and the pane says so.

Decision answers are offered only for a decision held in this home's backlog; for any other the pane says to answer it in chat.
Merge, fix, and close only ask firstmate: a merge still goes through firstmate's guarded merge path, which refuses a pull request that is not green.

Opening uses `open` (or `xdg-open`) rather than a terminal link, because macOS Terminal draws no clickable links.

## Answering from a terminal

The pane runs [`bin/fm-decision.sh`](../bin/fm-decision.sh), and you or any agent can run the same command:

```sh
bin/fm-decision.sh resolve <task-id> <your answer>
bin/fm-decision.sh drop <task-id>
printf 'drop <task-id>\nmerge <pull-request-url>\n' | bin/fm-decision.sh batch
```

It records your words through `bin/fm-captain-hold.sh answer`, which closes a question or lifts the hold on held work, then leaves one captain inbox note that wakes firstmate to act on the answers.
A batch carries decision answers and pull request merge, fix, and close requests, one per line, in one note.
It checks every line before recording anything, so one refused line records nothing and names each line.
It refuses a task this home's backlog does not hold for you, and records nothing then.
Its header owns the line format, the exact outcomes, and exit codes.

## Reading and writing

Each read runs the snapshot for this home with its forge fallback off and its remote-summary cache pointed at a path that can never be created, so a read writes nothing.
It reads once a minute and on `r`, and asks GitHub in two batched queries at most about once a minute.
A failed read keeps the last rows on screen and says what could not be read.
Submitting staged answers is the pane's only write, and only through `bin/fm-decision.sh`.

[`docs/verification/fleet-pane.md`](verification/fleet-pane.md) records the live check in a Herdr session.

## Replacing the Claude Code mod

This view replaces the `fleet-pane` Claude Code mod.
A home that installed the mod removes it with:

```sh
claude plugin uninstall fleet-pane@firstmate-mods
```
