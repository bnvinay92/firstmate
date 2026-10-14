# stow-review

A Claude Code mod that shows the captain what Firstmate's `/stow` would save before anything is written, and offers to stow any Firstmate home whose context has grown large.
The internal [`stow` skill](../../.agents/skills/stow/SKILL.md) owns the stow procedure, and [`bin/fm-stow-plan.sh`](../../bin/fm-stow-plan.sh) owns the plan, review, and approval file formats this mod reads and writes.

## What it does

In the main Firstmate session, a band above the prompt appears whenever any current home holds at least the threshold (200,000 tokens by default): the main session itself, or a live local secondmate.
It names each home over the threshold with its context size.

- **Stow** asks exactly the homes over the threshold to draft a plan: the main session drafts its own, and each listed secondmate drafts in its own home and replies with a pointer, or says its plan is empty.
- The review pane then shows every drafted plan together, grouped by home, then stow section, then target file.
  Every item starts ticked; untick what should not be saved, and edit an entry's line to change its wording.
  **Save** hands the approved plan back, and each home writes only its own approved items.
  **Cancel** writes nothing.
- **Auto** (off by default, remembered across sessions) stows a home on its own once it crosses the threshold, and saves everything the plans suggest with no review.
  **Turning Auto on is the captain's standing approval to save stow plans without reviewing them.**
  Auto fires once per crossing: a home is not stowed again until its context drops back under the threshold and crosses it again, and turning Auto on while a home is already over stows that home at once.
  After an automatic stow a short notice names the homes and how many items each saved, and the pane keeps the last automatic run's items viewable (`/stow-review` opens it).
- After a home's round ends, whether its approved items were saved or its plan was empty, the mod clears that home's session once.
  The main session runs the built-in `/clear` itself; a secondmate's own copy of the mod clears that secondmate's session.
  A hand-typed `/stow` never clears, and a cancelled review clears nothing.

The same safety boundaries hold on every path: a secondmate never writes `data/captain-shared.md`, and a shared-preference item it drafts goes to the main home's plan.
The mod writes only its own context reading and the approved-plan hand-off; every other write is the stow skill's.

## How homes are measured

Each Firstmate session that loads the mod publishes its own context fill to `state/stow-context.json` in its home, on context changes and at least once a minute:

```json
{"version":1,"tokens":212000,"window":1000000,"at":1791984220000}
```

The main session reads its own fill directly and each local secondmate's file through the homes named in `data/secondmates.md`.
A reading older than five minutes is stale and never triggers a stow, so a secondmate whose session stopped or does not run the mod is simply not offered.
Remote secondmates are not shown, because their homes are not readable from the main session; a hand-typed `/stow` still reaches them through the skill's cascade.

## Install

The mod must load in the main session and in every secondmate session that should be measured, so install it at user scope from this repository's local marketplace.
In a terminal Claude Code session:

```
/plugin marketplace add <firstmate-checkout>/mods
/plugin install stow-review@firstmate-mods
```

From a shell:

```
claude plugin marketplace add <firstmate-checkout>/mods
claude plugin install stow-review@firstmate-mods
```

A plugin installed from a local folder marketplace is read from that folder itself, so pulling Firstmate updates and running `/reload-plugins` picks up a new version of the mod.
To try it in one session without installing, start Claude Code with `claude --plugin-dir <firstmate-checkout>/mods/stow-review`, or name that folder in `CLAUDE_CODE_PLUGIN_DIRS` in the `env` block of `~/.claude/settings.json`.

Set the threshold in `/config` under the mod's "Stow threshold (tokens)" row.
Without the mod, or on another harness, `/stow` shows the same plan as a numbered list in chat and applies what the captain approves by number.

## Development

`claude plugin validate mods/stow-review` checks the manifest and the hooks module, and `claude plugin test mods/stow-review` runs the tests in `tests/`.
[`docs/verification/stow-review-mod.md`](../../docs/verification/stow-review-mod.md) records the live check that a mod can run the built-in `/clear`.
