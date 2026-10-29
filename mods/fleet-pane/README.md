# fleet-pane

A Claude Code mod that keeps a live pane in the main Firstmate session listing every open pull request and every decision waiting on the captain, so chat messages only need to cover what is new.
[`bin/fm-fleet-snapshot.sh`](../../bin/fm-fleet-snapshot.sh) owns the task records the pane reads, and [`hooks/lib.ts`](hooks/lib.ts) owns how those records and GitHub's answer become rows.

## What it shows

- **Open pull requests:** every GitHub pull request recorded in task metadata, task status history, or backlog links (including indented notes) that is still open, deduplicated by URL.
  A task driving a stack contributes every PR, including when its primary `pr=` names only one.
  Each linked row carries its project, short title, check summary, and what keeps it from merging: still a draft, a merge conflict, failing or running checks, changes requested, an approving review needed, behind its base branch, another task it waits on, or ready and waiting for the captain's word.
  When the base branch's rulesets or protection mark some checks required, only those block, including a required check that has not reported on the pull request yet; the check summary still counts every check.
  When no check is required, or GitHub does not answer for the base branch's rules, every failing or running check blocks.
  A pull request GitHub itself reports blocked is never shown ready.
  A merged or closed pull request drops off.
- **Decisions waiting for you:** every still-open decision in this home's task records and registered secondmate summaries, including relayed holds, plus every backlog item held for the captain that is due now.
  Structured secondmate summaries supply the hold's own short title; keyed parent relays fill gaps and retain detail links.
  Each shows its task and short title, never the hold reason or full decision prose.
  When no title is recorded, the decision key or task title supplies the label.
  A worker's own blocker is Firstmate's to clear and is not listed.

Each item occupies one line, capped at the pane width with a clean ellipsis.
Titles are also bounded to 100 characters before rendering.
The row links to the full PR URL, named report or plan, web detail page, or source record; shortening its label never shortens the link target.
Terminal links include local files; desktop surfaces only activate supported web links.

The pane is strictly read-only: it never writes to the home's records, the backlog, or GitHub, never sends anything to a worker, and has no buttons.

## How it stays current

The pane rereads on its own once a minute and after each reply in the session, at most once every 20 seconds.
Each read runs `bin/fm-fleet-snapshot.sh --json` for this home, with its forge fallback off and its remote-summary cache pointed at a path that can never be created, so the run writes nothing.
GitHub is asked in two batched `gh api graphql` queries: a lightweight state read for every recorded PR, then full checks and branch rules for the open subset.
This keeps merged PR history out of the expensive check query.
The batch pair runs at most about once a minute unless the PR list changes; drawing never asks GitHub.
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

After updating the marketplace checkout to the merged commit, refresh the installed cached copy and restart the session:

```sh
claude plugin marketplace update firstmate-mods
claude plugin update fleet-pane@firstmate-mods
```

Version 0.2.0 identifies the single-line inventory update in `~/.claude/plugins/cache/firstmate-mods/fleet-pane/`.

## Development

`node --experimental-strip-types --test mods/fleet-pane/tests/rows.test.mjs` runs the portable inventory and label regressions in CI.
`claude plugin validate mods/fleet-pane` checks the manifest and the hooks module, and `claude plugin test mods/fleet-pane` runs the tests in `tests/`.
[`docs/verification/fleet-pane-mod.md`](../../docs/verification/fleet-pane-mod.md) records the live check against a real Firstmate home.
