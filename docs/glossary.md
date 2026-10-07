# Glossary

This is the vocabulary Firstmate uses for its own records, rules, briefs, and charters.
Each entry is a one-line definition plus the owner that states the full contract; the owner wins if they ever disagree.
Captain-facing chat translates several of these terms into plain words; `AGENTS.md` section 9 owns that translation.

## People and agents

- **Captain** - the user; the only human Firstmate answers to (`AGENTS.md` intro).
- **Firstmate** - the supervisor agent and the captain's only point of contact; it delegates project work rather than doing it (`AGENTS.md` section 1).
- **Crewmate** - an agent Firstmate spawns to run one task in an isolated worktree; called a "worker" in captain chat (`AGENTS.md` section 1).
- **Secondmate** - a persistent crewmate with its own home and charter, which takes the requests that fit its scope (`AGENTS.md` sections 1 and 6, `secondmate-provisioning`).
- **Direct report** - a crewmate or secondmate that a home spawned and supervises; each home reconciles only its own direct reports (`AGENTS.md` section 5).

## Places

- **Home** - one instance's private `data/`, `state/`, `config/`, and `projects/`, selected by `FM_HOME`; the **main home**, also called the primary home, is the one whose firstmate the captain talks to (`docs/configuration.md`).
- **Project** - a registered repository cloned under a home's `projects/`; read-only to Firstmate outside hard rule 1's exceptions (`AGENTS.md` sections 1 and 6, `project-management`).
- **Worktree** - the isolated copy of a project where one crewmate works; never the primary clone (`AGENTS.md` section 7).
- **Endpoint** - the runtime backend pane, tab, or window an agent runs in, as named in its task record (`docs/agent-control.md`).
- **Charter** - a secondmate home's `data/charter.md`, stating its scope and how it reports back (`secondmate-provisioning`).

## Work

- **Request** - anything the captain asks; intake resolves its project and classifies it as a question or a task (`AGENTS.md` section 7).
- **Question** - a request that established evidence already answers, relayed without creating a task (`AGENTS.md` section 7).
- **Task** - a request that needs a deliverable, tracked as a backlog item; every task is a ship or a scout (`AGENTS.md` sections 7 and 10).
- **Ship** - a task that produces a project change through its delivery mode (`AGENTS.md` section 7).
- **Scout** - a task that produces knowledge in a report, never a PR; used when the captain asks for an investigation or design, or when uncertainty could change whether or what to build (`AGENTS.md` section 7).
- **Report** - a scout's findings in `data/<task-id>/report.md` (`scout-completion`).
- **Backlog** - the durable queue of tasks; it never tracks agents (`AGENTS.md` section 10).
- **Hold** - a task held for the captain's decision, which `AGENTS.md` also calls a decision (`AGENTS.md` section 10, `captain-hold-lifecycle`).
- **Promotion** - converting a scout into a ship in place, with an explicit delivery mode (`scout-completion`, `bin/fm-promote.sh`).

## Communication

- **Brief** - a task's written instructions, created before spawn; `## Captain's intent` carries the captain's own words (`AGENTS.md` section 11, `bin/fm-brief.sh`).
- **Steer** - text sent to a running crewmate or secondmate through `bin/fm-send.sh` (`AGENTS.md` section 7).
- **Routed reply** - what a secondmate sends back to its parent: an answer, a report pointer, or a task outcome, via status or a document pointer (`AGENTS.md` section 7).
- **Goal record** - a crewmate's `goals.md` beside its brief, listing each goal (an outcome the brief asks for) with its result and `origin:` chain for retrospectives; a home-local brief addition, not upstream Firstmate (`config/brief-include.md`).
- **Status line** - a line a crewmate or secondmate appends to its `state/<task-id>.status` log; a wake event, not current-state truth (`AGENTS.md` sections 2 and 8, `bin/fm-classify-lib.sh`).
- **Keyed decision** - a `needs-decision:` or `blocked:` status line carrying a key, which stays open until a `resolved` line with that key lands (`bin/fm-classify-lib.sh`, `bin/fm-send.sh`).

## Delivery

- **Delivery mode** - how a ship lands: `no-mistakes`, `direct-PR`, or `local-only` (`AGENTS.md` section 7).
- **Yolo** - a project's standing merge posture; on lets Firstmate merge green in-scope work itself (`AGENTS.md` section 7).
- **Ask-user finding** - a no-mistakes validation finding that needs a decision above the implementation worker; Firstmate decides it or escalates it to the captain (`ask-user-authority`).
- **Landing** - getting a ready ship onto its target branch by merging its PR or fast-forwarding its local-only branch (`ship-landing`, `bin/fm-pr-merge.sh`, `bin/fm-merge-local.sh`).
- **Teardown** - task cleanup that removes the worktree and endpoint only after the landed-work test passes; "cleanup" in captain chat (`bin/fm-teardown.sh`).

## Runtime and supervision

- **Harness** - the agent CLI an agent runs on, such as `claude` or `codex`; only verified harnesses are dispatched (`AGENTS.md` section 4, `harness-adapters`).
- **Runtime backend** - the terminal multiplexer or app that hosts endpoints, such as tmux or Herdr (`docs/configuration.md` "Runtime backend").
- **Dispatch profile** - a concrete harness, model, and effort choice that a configured routing rule selects for a crewmate or scout (`docs/configuration.md` "Crew dispatch profiles", `quota-array-dispatch`).
- **Session lock** - the per-home lock that lets one primary session mutate a home; a lock-refused session stays read-only (`AGENTS.md` section 3, `bin/fm-session-lock-lib.sh`).
- **Wake** - a durable queued event that asks the primary to act, typed as a signal, stale, check, or heartbeat (`AGENTS.md` section 8, `docs/architecture.md`).
- **Watcher** - the zero-token bash poller `bin/fm-watch.sh` that classifies fleet events into wakes (`docs/architecture.md`).
- **Heartbeat** - the periodic backstop wake that triggers a whole-fleet review (`AGENTS.md` section 8, `bin/fm-watch.sh`).
- **Supervision cycle** - the one live watcher wait the primary keeps whenever work is under way, shaped by its harness's emitted protocol (`AGENTS.md` section 8, `docs/supervision-protocols/`).
- **Supervision host** - the headless process that runs the supervision branch's contract beside a primary that is not Pi (`docs/supervision-host.md`).
- **Away mode** - the `/afk` posture in which the captain's away words are the whole mandate while supervision continues without them (`afk`, `away-quiet-supervision`).
- **Quiet mode** - the `/quiet` posture that keeps routine wakes out of the conversation while the captain stays present, until `/quiet off` (`quiet`, `away-quiet-supervision`).
