import { describe, expect, test } from 'claude-code/testing'

import {
  blockersOf,
  checkSummary,
  decisionText,
  isGithubDue,
  parsePrStatuses,
  parsePrUrl,
  parseSnapshot,
  prQuery,
  prRow,
  reportIn,
  wrapSpans,
} from '../hooks/lib'
import type { PrRef, PrStatus } from '../hooks/lib'

const SNAPSHOT = {
  schema: 'fm-fleet-snapshot.v1',
  tasks: [
    {
      id: 'axi-packaging',
      pr: { url: 'https://github.com/careem/axi/pull/7', source: 'meta' },
      backlog: { unresolved_blocker_ids: [] },
      hints: { open_decisions: [] },
      paths: { report: { path: '/fm/data/axi-packaging/report.md', present: false } },
    },
    {
      id: 'booking-explore',
      kind: 'secondmate',
      pr: { url: null, source: 'absent' },
      hints: {
        open_decisions: [
          { key: 'captain-hold-s6-cli-q-1', verb: 'needs-decision', summary: 'captain hold s6-cli-q: Should the CLI\n build alone? Report data/s6-codex-cp1/report.md, Questions.' },
          { key: 'stuck', verb: 'blocked', summary: 'the worker cannot reach the device' },
        ],
      },
      paths: { report: { path: null, present: false } },
    },
    {
      id: 'ksm-debug',
      pr: { url: 'https://github.com/careem/kotlin-state-machine/pull/376', source: 'status' },
      backlog: { unresolved_blocker_ids: ['ksm-release'] },
      hints: { open_decisions: [{ key: 'device-locked', verb: 'needs-decision', summary: 'Unlock the phone, or close out on JVM evidence?' }] },
      paths: { report: { path: '/fm/data/ksm-debug/report.md', present: true } },
    },
    { id: 'gitlab-one', pr: { url: 'https://gitlab.com/a/b/-/merge_requests/3' }, hints: { open_decisions: [] } },
  ],
  backlog: {
    records: [
      { id: 'inspector-lavish-ship', title: 'Ship the Lavish review page?', captain_actionable: true, report_path: null },
      { id: 'later-call', title: 'Deferred call', captain_actionable: false },
    ],
  },
}

const refs = (): PrRef[] => parseSnapshot(JSON.stringify(SNAPSHOT))?.prs ?? []

const status = (over: Partial<PrStatus> = {}, checks: Partial<PrStatus['checks']> = {}): PrStatus => ({
  title: 'Package axi',
  state: 'OPEN',
  isDraft: false,
  mergeable: 'MERGEABLE',
  mergeState: 'CLEAN',
  reviewDecision: null,
  checks: { passing: 3, failing: 0, running: 0, failingRequired: 0, runningRequired: 0, hasRequired: false, ...checks },
  ...over,
})

describe('reading the snapshot', () => {
  test('lists every recorded GitHub pull request once, with what its task waits on', () => {
    expect(refs()).toEqual([
      { task: 'axi-packaging', url: 'https://github.com/careem/axi/pull/7', owner: 'careem', repo: 'axi', number: 7, waitsOn: [] },
      {
        task: 'ksm-debug',
        url: 'https://github.com/careem/kotlin-state-machine/pull/376',
        owner: 'careem',
        repo: 'kotlin-state-machine',
        number: 376,
        waitsOn: ['ksm-release'],
      },
    ])
  })

  test('lists open decisions and live captain holds, never a worker blocker', () => {
    expect(parseSnapshot(JSON.stringify(SNAPSHOT))?.decisions).toEqual([
      { label: 'booking-explore · s6-cli-q', summary: 'Should the CLI build alone? Report data/s6-codex-cp1/report.md, Questions.', report: 'data/s6-codex-cp1/report.md' },
      { label: 'ksm-debug', summary: 'Unlock the phone, or close out on JVM evidence?', report: '/fm/data/ksm-debug/report.md' },
      { label: 'inspector-lavish-ship', summary: 'Ship the Lavish review page?', report: null },
    ])
  })

  test('refuses anything that is not a fleet snapshot', () => {
    expect(parseSnapshot('not json')).toBeNull()
    expect(parseSnapshot(JSON.stringify({ schema: 'other' }))).toBeNull()
  })

  test('a decision without a hold name keeps the task as its label', () => {
    expect(decisionText('t1', '  Pick\n one ')).toEqual({ label: 't1', summary: 'Pick one' })
    expect(reportIn('see /abs/home/data/x-y/report.md for more')).toBe('/abs/home/data/x-y/report.md')
    expect(reportIn('no report here')).toBeNull()
  })

  test('only github.com pull-request URLs parse', () => {
    expect(parsePrUrl('https://github.com/o/r/pull/12')).toEqual({ owner: 'o', repo: 'r', number: 12 })
    expect(parsePrUrl('https://github.com/o/r/issues/12')).toBeNull()
  })
})

describe('asking GitHub', () => {
  test('one aliased query covers every pull request', () => {
    const query = prQuery(refs())
    expect(query).toContain('p0: repository(owner:"careem", name:"axi") { pullRequest(number:7)')
    expect(query).toContain('p1: repository(owner:"careem", name:"kotlin-state-machine") { pullRequest(number:376)')
  })

  test('counts checks and keeps the answers it got when one alias failed', () => {
    const answer = {
      data: {
        p0: {
          pullRequest: {
            title: 'Package axi',
            state: 'OPEN',
            isDraft: false,
            mergeable: 'MERGEABLE',
            mergeStateStatus: 'BLOCKED',
            reviewDecision: 'REVIEW_REQUIRED',
            commits: {
              nodes: [
                {
                  commit: {
                    statusCheckRollup: {
                      contexts: {
                        nodes: [
                          { __typename: 'CheckRun', status: 'COMPLETED', conclusion: 'SUCCESS', isRequired: true },
                          { __typename: 'CheckRun', status: 'COMPLETED', conclusion: 'FAILURE', isRequired: false },
                          { __typename: 'CheckRun', status: 'IN_PROGRESS', conclusion: null, isRequired: true },
                          { __typename: 'StatusContext', state: 'ERROR', isRequired: true },
                        ],
                      },
                    },
                  },
                },
              ],
            },
          },
        },
        p1: null,
      },
      errors: [{ message: 'Could not resolve to a Repository' }],
    }
    const found = parsePrStatuses(JSON.stringify(answer), refs())
    expect(Object.keys(found)).toEqual(['https://github.com/careem/axi/pull/7'])
    const axi = found['https://github.com/careem/axi/pull/7']
    expect(axi?.checks).toEqual({ passing: 1, failing: 2, running: 1, failingRequired: 1, runningRequired: 1, hasRequired: true })
    if (axi === undefined) return
    expect(checkSummary(axi)).toBe('2 failing, 1 running')
    expect(blockersOf(axi)).toEqual(['a failing check', 'checks still running', 'needs an approving review'])
  })

  test('asks again only when the list changed or nearly a minute passed', () => {
    const list = refs()
    const urls = list.map(ref => ref.url).join(' ')
    expect(isGithubDue(list, null, 0)).toBe(true)
    expect(isGithubDue(list, { urls, at: 0 }, 49_000)).toBe(false)
    expect(isGithubDue(list, { urls, at: 0 }, 50_000)).toBe(true)
    expect(isGithubDue(list.slice(1), { urls, at: 0 }, 1)).toBe(true)
    expect(isGithubDue([], null, 0)).toBe(false)
  })
})

describe('what blocks a pull request', () => {
  test('a clean one waits only for the merge word', () => {
    expect(blockersOf(status())).toEqual(['ready - waiting for your word to merge'])
    expect(checkSummary(status())).toBe('passing')
    expect(checkSummary(status({}, { passing: 0 }))).toBe('no checks reported')
  })

  test('draft, conflict, changes requested, behind, and a dependency each show', () => {
    expect(
      blockersOf(status({ isDraft: true, mergeable: 'CONFLICTING', reviewDecision: 'CHANGES_REQUESTED', mergeState: 'BEHIND' }), ['other-task']),
    ).toEqual(['still a draft', 'merge conflict', 'changes requested in review', 'behind its base branch', 'waits on other-task'])
  })

  test('with required checks, an advisory failure does not block', () => {
    expect(blockersOf(status({}, { failing: 1, hasRequired: true }))).toEqual(['ready - waiting for your word to merge'])
    expect(blockersOf(status({}, { failing: 2 }))).toEqual(['2 failing checks'])
  })

  test('merged or closed drops off; no answer still shows the pull request', () => {
    const [axi] = refs()
    if (axi === undefined) throw new Error('fixture')
    expect(prRow(axi, status({ state: 'MERGED' }))).toBeNull()
    expect(prRow(axi, status({ state: 'CLOSED' }))).toBeNull()
    expect(prRow(axi, undefined)).toEqual({
      url: axi.url,
      project: 'axi',
      title: 'axi-packaging',
      checks: 'status unknown',
      blockers: ['GitHub did not answer'],
    })
  })
})

describe('wrapping a line to the pane', () => {
  const lines = (text: string, first: number, rest: number) => wrapSpans(text, first, rest).map(([a, b]) => text.slice(a, b))

  test('breaks at spaces, each line within its width', () => {
    expect(lines('checks passing - needs an approving review', 20, 18)).toEqual(['checks passing -', 'needs an approving', 'review'])
  })

  test('splits a word longer than a line rather than cutting it off', () => {
    expect(lines('https://github.com/a/b/pull/7', 12, 10)).toEqual(['https://gith', 'ub.com/a/b', '/pull/7'])
  })

  test('a short or empty line stays one line', () => {
    expect(lines('None.', 40, 38)).toEqual(['None.'])
    expect(lines('', 40, 38)).toEqual([''])
  })
})
