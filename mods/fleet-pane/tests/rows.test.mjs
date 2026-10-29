// Portable row regressions run in CI without the interactive mod host.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { parseSnapshot, prQuery, prStateQuery, prRow, shortLine, decisionText } from '../hooks/lib.ts'

const url = n => `https://github.com/example/app/pull/${n}`
const read = over => parseSnapshot(JSON.stringify({ schema: 'fm-fleet-snapshot.v1', ...over }))

describe('fleet pane inventory', () => {
  it('keeps every task PR, backlog-only PR and body link once', () => {
    const result = read({
      tasks: [{ id: 'stack', pr: { url: url(1), urls: [url(1), url(2), url(3)] }, backlog: { unresolved_blocker_ids: ['base'] } }],
      backlog: { records: [{ id: 'old-task', state: 'done', pr_url: url(3), links: [url(3), url(4), 'https://example.org/report'] }] },
    })
    assert.deepEqual(result.prs.map(pr => pr.url), [url(1), url(2), url(3), url(4)])
    assert.deepEqual(result.prs[1].waitsOn, ['base'])
    assert.equal(result.prs[3].task, 'old-task')
    assert.equal((prQuery(result.prs).match(/pullRequest\(number:/g) ?? []).length, 4)
    assert.equal((prStateQuery(result.prs).match(/title state/g) ?? []).length, 4)
    assert.equal(prStateQuery(result.prs).includes('statusCheckRollup'), false)
    assert.equal(prRow(result.prs[0], { state: 'CLOSED' }), null)
    assert.equal(prRow(result.prs[1], undefined).url, url(2))
  })

  it('accepts legacy snapshots and normalizes URL duplicates', () => {
    assert.equal(read({ tasks: [{ id: 'legacy', pr: { url: url(1) + '/' } }, { id: 'other', pr: { url: url(1) } }] }).prs.length, 1)
    assert.equal(parseSnapshot('bad'), null)
    assert.equal(read({ tasks: [{ id: 'invalid', pr: { urls: [null, 3, 'https://github.com/o/r/issues/1'] } }] }).prs.length, 0)
  })

  it('merges structured secondmate holds with relays, keeping title and detail', () => {
    const result = read({
      secondmate_current: { records: [{
        id: 'mate', home: '/mate', provenance: { selected: 'structured-home', trust: 'partial-structured' },
        decisions_open: [
          { id: 'foot-points', key: 'foot-points', verb: 'captain-hold', source: 'backlog', summary: 'Choose the foot point model', reason: 'Long reason without a report' },
          { id: 'new-hold', verb: 'captain-hold', source: 'backlog', summary: 'A hold never relayed', reason: 'See data/new/plan.md' },
          { id: 'worker', key: 'default', verb: 'needs-decision', source: 'status', summary: 'Long prose '.repeat(80) },
          { id: 'blocked', verb: 'blocked', summary: 'Worker problem' },
        ],
      }] },
      tasks: [{ id: 'mate', kind: 'secondmate', hints: { open_decisions: [
        { key: 'captain-hold-foot-points-1', verb: 'needs-decision', summary: 'captain hold foot-points: ' + 'Long explanation '.repeat(100) + ' data/foot/report.md' },
        { key: 'modal-timing', verb: 'needs-decision', summary: 'Long timing explanation '.repeat(100) + ' http://localhost:8000/timing' },
      ] } }],
      backlog: { records: [
        { id: 'due', title: 'Approve the next step', captain_actionable: true, hold_reason: 'reason '.repeat(100) },
        { id: 'later', title: 'Future hold', captain_actionable: false },
      ] },
    })
    assert.equal(result.decisions.length, 5)
    assert.equal(result.decisions[0].summary, 'Choose the foot point model')
    assert.equal(result.decisions[0].report, '/mate/data/foot/report.md')
    assert.equal(result.decisions[2].report, '/mate/state/worker.status')
    assert.equal(result.decisions[1].report, '/mate/data/new/plan.md')
    assert.equal(result.decisions[2].summary, 'worker')
    assert.equal(result.decisions[3].summary, 'modal timing')
    assert.equal(result.decisions[3].report, 'http://localhost:8000/timing')
    assert.equal(result.decisions[4].summary, 'Approve the next step')
    assert.ok(result.decisions.every(row => row.summary.length <= 100 && !row.summary.includes('Long')))
  })

  it('uses parent relays when a secondmate summary is unavailable', () => {
    const result = read({ secondmate_current: { records: [{ id: 'mate', provenance: { selected: 'parent-event-fallback' }, decisions_open: [] }] }, tasks: [{
      id: 'mate', kind: 'secondmate', paths: { home: { path: '/mate' }, status_log: { path: '/fm/state/mate.status' } },
      hints: { open_decisions: [{ key: 'captain-hold-call-1', verb: 'needs-decision', summary: 'captain hold call: a long reason' }] },
    }] })
    assert.deepEqual(result.decisions, [{ label: 'mate · call', summary: 'call', report: '/fm/state/mate.status' }])
    const relative = read({ tasks: [{ id: 'mate', kind: 'secondmate', paths: { home: { path: '/mate' } }, hints: { open_decisions: [{ key: 'captain-hold-call-1', verb: 'needs-decision', summary: 'captain hold call: see data/call/report.md' }] } }] })
    assert.equal(relative.decisions[0].report, '/mate/data/call/report.md')
  })
})

describe('fleet pane labels', () => {
  it('uses decision titles or keys rather than reason prose', () => {
    assert.deepEqual(decisionText('mate', 'captain hold modal-timing: ' + 'reason '.repeat(100)), { label: 'mate · modal-timing', summary: 'modal timing' })
    assert.equal(decisionText('task', 'private reason', 'Choose the device').summary, 'Choose the device')
    assert.equal(decisionText('task', 'private reason', undefined, 'pick-device').summary, 'pick device')
  })

  it('flattens controls and ellipsizes at a clean boundary without splitting surrogate pairs', () => {
    assert.equal(shortLine(' A\n title\twith details ', 14), 'A title with…')
    assert.equal(shortLine('short'), 'short')
    assert.equal(shortLine('long', 1), '…')
    assert.equal(shortLine('long', 0), '')
    assert.equal(shortLine('😀😀😀', 2), '😀…')
    assert.equal(shortLine('one\u0000two\u009bthree'), 'one two three')
    assert.ok(Array.from(shortLine('word '.repeat(200))).length <= 100)
  })
})
