# fleet-pane mod verification

Audience: maintainer verification.

This record supports the current inventory and compact-label guarantees of the [fleet-pane mod](../../mods/fleet-pane/README.md).
[`bin/fm-fleet-snapshot.sh`](../../bin/fm-fleet-snapshot.sh) owns the snapshot contract.

## Live inventory projection

On 2026-10-28, the read-only snapshot and exported row builder were exercised against a live main home, using Node 23.11.0 and fleet-pane 0.2.0 source.
The installed interactive host was version 2.1.312; this check did not launch an interactive session or establish a new rendering verdict for that version.
The commands were:

```sh
FM_HOME=<home> FM_CREW_STATE_NO_FORGE=1 \
  FM_SNAPSHOT_CACHE_DIR=/dev/null/fleet-pane \
  bash bin/fm-fleet-snapshot.sh --json > <scratch>/snapshot.json
node --experimental-strip-types --input-type=module -e '
  import { readFileSync } from "node:fs";
  import { parseSnapshot } from "./mods/fleet-pane/hooks/lib.ts";
  console.log(JSON.stringify(parseSnapshot(readFileSync(process.argv[1], "utf8"))));
' <scratch>/snapshot.json
```

The previous projection produced 11 PR candidates and 21 decision rows.
The expanded projection recovered eleven omitted open PRs, including ten from one task's status history, and two decisions present only in the structured secondmate summary.
The named approval PRs were already present in the previous snapshot, so their reported absence was not an inventory omission in that projection.
Eight previous decision summaries exceeded 200 characters; the longest was 977 characters.
The current projection uses the structured hold title or decision key instead of those paragraphs, and caps titles at 100 characters.
Exact private records, the full before/after inventories, and forge observations belong in the task's private report.

## Repeatable regression checks

CI runs the portable row checks with Node 22:

```sh
node --experimental-strip-types --test mods/fleet-pane/tests/rows.test.mjs
```

They cover multi-PR tasks, backlog-only PRs and body links, URL deduplication, legacy snapshots, structured secondmate holds and keyed relays, unavailable summaries, due-now holds, title selection, and ellipsis handling.
The existing `tests/fm-fleet-snapshot-view.test.sh` fixture also verifies that `pr.urls` contains every recorded metadata/status PR while `pr.url` retains the primary URL.
Its existing stock Bash CI lane remains applicable.

The interactive host's rendering and refresh checks remain available through:

```sh
claude plugin validate mods/fleet-pane
claude plugin test mods/fleet-pane
```

The rendering suite now asserts one line per item at 70 and 34 columns, whole hyperlink targets after resizing, and short decision titles.
It also covers read-only snapshot flags, the batched GitHub query budget, merged PR removal, theme colours, persisted closing, and refresh after `/clear`.
Local tests were not run for the 2026-10-28 change because the operating home's policy delegates test execution to CI.
The earlier 2026-10-16 interactive observation established automatic pane opening and refresh with version 2.1.301; its multiline layout is superseded by the current single-line contract and is not evidence for the new rendering.
Re-run the interactive commands after a host upgrade before relying on the rendering contract for a newer build.
