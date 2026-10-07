# Glossary

This is the vocabulary Firstmate uses for its own records, rules, briefs, and charters.
Each entry is a one-line definition plus the owner that states the full contract; the owner wins if they ever disagree.
Captain-facing chat translates several of these terms into plain words; `AGENTS.md` section 9 owns that translation.

## People and agents

- **Captain** - the user; the only human Firstmate answers to (`AGENTS.md` intro).
- **Firstmate** - the supervisor agent and the captain's only point of contact; it delegates project work rather than doing it (`AGENTS.md` section 1).
- **Crewmate** - an agent Firstmate spawns to run one task in an isolated worktree; called a "worker" in captain chat (`AGENTS.md` section 1).
- **Secondmate** - a persistent crewmate with its own home and charter, which takes the requests that fit its scope (`AGENTS.md` sections 1 and 6, `secondmate-provisioning`).

## Places

- **Home** - one instance's private `data/`, `state/`, `config/`, and `projects/`, selected by `FM_HOME`; the **main home** is the primary one (`docs/configuration.md`).
- **Project** - a registered repository cloned under a home's `projects/`; read-only to Firstmate (`AGENTS.md` section 6, `project-management`).
- **Worktree** - the isolated copy of a project where one crewmate works; never the primary clone (`AGENTS.md` section 7).
- **Charter** - a secondmate home's `data/charter.md`, stating its scope and how it reports back (`secondmate-provisioning`).

## Work

- **Request** - anything the captain asks; intake resolves its project and classifies it as a question or a task (`AGENTS.md` section 7).
- **Question** - a request that established evidence already answers, relayed without creating a task (`AGENTS.md` section 7).
- **Task** - a request that needs a deliverable, tracked as a backlog item; every task is a ship or a scout (`AGENTS.md` sections 7 and 10).
- **Ship** - a task that produces a project change through its delivery mode (`AGENTS.md` section 7).
- **Scout** - a task that produces knowledge in a report, never a PR; used when the captain asks for an investigation or design, or when uncertainty could change whether or what to build (`AGENTS.md` section 7).
- **Report** - a scout's findings in `data/<task-id>/report.md` (`scout-completion`).
- **Backlog** - the durable queue of tasks; it never tracks agents (`AGENTS.md` section 10).
- **Hold** - a task held for the captain's decision (`AGENTS.md` section 10, `captain-hold-lifecycle`).

## Communication

- **Brief** - a task's written instructions, created before spawn; `## Captain's intent` carries the captain's own words (`AGENTS.md` section 11, `bin/fm-brief.sh`).
- **Steer** - text sent to a running crewmate or secondmate through `bin/fm-send.sh` (`AGENTS.md` section 7).
- **Routed reply** - what a secondmate sends back to its parent: an answer, a report pointer, or a task outcome, via status or a document pointer (`AGENTS.md` section 7).

## Delivery

- **Delivery mode** - how a ship lands: `no-mistakes`, `direct-PR`, or `local-only` (`AGENTS.md` section 7).
- **Yolo** - a project's standing merge posture; on lets Firstmate merge green in-scope work itself (`AGENTS.md` section 7).
