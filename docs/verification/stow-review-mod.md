# stow-review mod verification

Audience: maintainer verification.

This record supports the active guarantee that the [stow-review mod](../../mods/stow-review/README.md) can clear a Claude Code session after a stow round by running the built-in `/clear` itself.
The internal [`stow` skill](../../.agents/skills/stow/SKILL.md) owns when a round asks for a clear, and [`bin/fm-stow-plan.sh`](../../bin/fm-stow-plan.sh) owns the round-end record the mod reads.

## A mod can run the built-in /clear

This check ran on 2026-10-14 with Claude Code 2.1.299 in an interactive session on a private tmux socket, loading a throwaway probe mod with `--plugin-dir` from a scratch folder.
The probe registered a `/probeclear` command, logged whether `clear` was listed by `$.command.list()`, called `$.command.run({ command: 'clear' })`, and logged the session's `session.end` reason.

The probe's hooks module, first form, called the command directly inside its own `command.run` hook:

```ts
on('command.run', { command: 'probeclear' }, async $ => {
  try {
    const r = await $.command.run({ command: 'clear' })
    await note($, 'run clear resolved ' + JSON.stringify(r))
  } catch (err) {
    await note($, 'run clear rejected ' + String(err))
  }
  return { text: 'probed' }
})
```

Typing `/probeclear` logged:

```text
clear listed=true
run clear rejected HooksError: clearprobe: command.run: called from a command.run hook, it would wait on the turn this hook is holding; answer { text } instead, or run it from a later event (turn.complete) (host check)
```

The second form scheduled the same call on a timer, as the mod does:

```ts
on('command.run', { command: 'probeclear' }, async $ => {
  $.clock.after(300, async () => {
    try {
      const r = await $.command.run({ command: 'clear' })
      await note($, 'timer run clear resolved ' + JSON.stringify(r))
    } catch (err) {
      await note($, 'timer run clear rejected ' + String(err))
    }
  })
  return { text: 'probed' }
})
```

Typing `/probeclear` again cleared the transcript, the pane showed `❯ /clear` as the session's only row, and the probe logged:

```text
end reason=clear
timer run clear resolved {"text":""}
```

So on this build a mod runs `/clear` through `$.command.run` from a timer or another later event, never from inside a hook the turn waits on.
The mod schedules the call with `$.clock.after`, and the engine queues it until the session is idle, so the agent's turn finishes before the session is cleared.
Re-run the probe after a Claude Code upgrade before relying on this record for a newer build.

## The band, Auto, the clear, and the pane in a live session

This check ran on 2026-10-14 with Claude Code 2.1.299, loading this repository's `mods/stow-review` with `--plugin-dir` into an interactive session on a private tmux socket.
The session ran in a scratch Firstmate-shaped home whose `data/secondmates.md` named one local secondmate, `mate-a`, with a fresh `state/stow-context.json` reading of 250,000 tokens, and a stand-in `/stow` command that only replied `OK`.

Observed in the terminal:

```text
Context over 200k: mate-a 250k [ Stow ] [ Auto: off ]
❯ /stow draft --mod --auto --homes mate-a
Stow (auto) under way for mate-a [ Auto: on ]
Auto stow saved: mate-a 1 item.
❯ /clear
```

The band named only the home over the threshold, Auto started a round for exactly that home, writing a round-end record with `"clear":true` produced the notice and then the clear, and the band came back on the next poll after the clear without a reload.
`/stow-review` then showed the kept `Last automatic stow: mate-a 1 item` with its items grouped by home, section, and target.
A reviewed round opened the pane once the review file appeared, drawn as:

```text
3 of 3 items ticked. Untick what should not be saved; edit a line to change its wording.
Home: main
  Startup-memory tiers
    data/learnings.md
      [x] rewrite - fact <!--a:2026-10-14-->
  Knowledge routing
    data/captain.md
      [x] add - likes short PRs
Home: mate-a
  Open-record persistence
    backlog
      [x] record file: flaky test follow-up
[ All ] [ None ] [ Auto: off ] [ Save ] [ Cancel ]
```

Toggling, editing, Save, and Cancel are covered by `claude plugin test mods/stow-review`, which drives the same pane through the engine's test kit on the terminal and desktop surfaces.
A `--plugin-dir` load keeps its own store, separate from an installed copy's, so a test session's Auto setting never reaches an installed mod.
