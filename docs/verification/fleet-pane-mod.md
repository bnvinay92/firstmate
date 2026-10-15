# fleet-pane mod verification

Audience: maintainer verification.

This record supports the active guarantee that the [fleet-pane mod](../../mods/fleet-pane/README.md) draws a real Firstmate home's open pull requests and open decisions in a Claude Code pane without writing anything.
[`bin/fm-fleet-snapshot.sh`](../../bin/fm-fleet-snapshot.sh) owns the records the pane reads.

## The pane against a live home

This check ran on 2026-10-16 with Claude Code 2.1.301, loading this repository's `mods/fleet-pane` with `--plugin-dir` into an interactive session on a private tmux socket, 200 columns wide.
The session ran in an empty scratch folder with `FM_HOME` naming a live main Firstmate home, so the mod found the home through `FM_HOME` and the snapshot script through the home's own code root:

```sh
tmux -L <socket> new-session -d -s live -x 200 -y 60 \
  "cd <scratch> && FM_HOME=<home> claude --plugin-dir <checkout>/mods/fleet-pane"
```

After the folder-trust prompt, and with no prompt typed, the pane opened by itself beside the transcript and filled within about 25 seconds.
Observed in the terminal, with rows for private repositories and decision summaries elided:

```text
Open pull requests (8)
  ...
  firstmate: feat(stow-review): one stow button per home and a readable review pane
    https://github.com/bnvinay92/firstmate/pull/11
    checks 16 running - checks still running
  ...

Decisions waiting for you (12)
  <second mate> · <hold name>: <one-line summary, cut at the pane's width>…
    report data/<report folder>/report.md
  ...

Updated 00:50, every minute and after each reply.
```

The eight pull requests matched the home's task records with an open pull request, each with its full URL and a blocker: two ready and waiting for the merge word, one still a draft, one behind its base branch, the rest needing an approving review or with checks still running.
The twelve decisions matched the home's open decisions: nine captain holds relayed by a second mate, one worker's open question, and two backlog items held for the captain.
The home's `state/secondmate-summary-cache` folder was still empty after the session, as before it, confirming the snapshot run wrote no cache copy.

Dark and light theme readability, the pane's colours, closing and reopening, merged pull requests dropping off, and the GitHub call budget are covered by `claude plugin test mods/fleet-pane`, which drives the pane through the engine's test kit on the terminal and desktop surfaces.
Re-run this check after a Claude Code upgrade before relying on this record for a newer build.
