# fleet-pane

A Claude Code mod that keeps a live pane in the main Firstmate session listing every open pull request and every decision waiting on the captain, so chat messages only need to cover what is new.
[`bin/fm-fleet-snapshot.sh`](../../bin/fm-fleet-snapshot.sh) owns the task records the pane reads, and [`hooks/lib.ts`](hooks/lib.ts) owns how those records and GitHub's answer become rows.

## What it shows

- **Open pull requests:** every task in this home whose record carries a GitHub pull request that is still open, one entry each with its project and title, its full URL, a check summary (passing, failing, running, or none reported), and what keeps it from merging: still a draft, a merge conflict, failing or running checks, changes requested, an approving review needed, behind its base branch, another task it waits on, or ready and waiting for the captain's word.
  When the repository marks some checks required, only those block; the check summary still counts every check.
  A merged or closed pull request drops off.
- **Decisions waiting for you:** every still-open decision in this home's task records, the same set the supervision drain lists, including the captain holds a second mate relays, plus every backlog item held for the captain that is due now.
  Each shows its task, a short summary, and the report it names when it has one.
  A worker's own blocker is Firstmate's to clear and is not listed.

Every line stays within the pane's width: a longer one wraps onto lines indented under its row, so no title, URL, blocker, or summary is cut off, and a resized pane rewraps on its next draw.

The pane is strictly read-only: it never writes to the home's records, the backlog, or GitHub, never sends anything to a worker, and has no buttons.

## How it stays current

The pane rereads on its own once a minute and after each reply in the session, at most once every 20 seconds.
Each read runs `bin/fm-fleet-snapshot.sh --json` for this home, with its forge fallback off and its remote-summary cache pointed at a path that can never be created, so the run writes nothing.
GitHub is asked through one `gh api graphql` query covering every open pull request at once, at most about once a minute unless the list of pull requests changed; drawing the pane never asks GitHub.
A failed read keeps the last rows on screen and says what could not be read.

## Install

The mod loads in the main Firstmate session: a session whose root, or `FM_HOME`, is a Firstmate home with `state/` beside the snapshot script.
A second mate's home, or any other folder, leaves it idle.
It needs `gh` signed in to GitHub.
In a terminal Claude Code session:

```
/plugin marketplace add <firstmate-checkout>/mods
/plugin install fleet-pane@firstmate-mods
```

From a shell:

```
claude plugin marketplace add <firstmate-checkout>/mods
claude plugin install fleet-pane@firstmate-mods
```

The pane opens by itself without taking the keyboard, on a terminal at least 144 columns wide.
Closing it keeps it closed in later sessions; `/fleet-pane` opens it again.
To try it in one session without installing, start Claude Code with `claude --plugin-dir <firstmate-checkout>/mods/fleet-pane`.

## Development

`claude plugin validate mods/fleet-pane` checks the manifest and the hooks module, and `claude plugin test mods/fleet-pane` runs the tests in `tests/`.
[`docs/verification/fleet-pane-mod.md`](../../docs/verification/fleet-pane-mod.md) records the live check against a real Firstmate home.
