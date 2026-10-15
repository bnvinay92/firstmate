import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine, MockClock } from 'claude-code/testing'
import type { On, RenderElement } from 'claude-code'

// An in-memory Firstmate home beneath the mod: its files, the commands it
// runs and what they answer, the panes it opens, and the session's $.state.
type World = {
  files: Set<string>
  state: Map<string, { value: unknown; version: number }>
  runs: { argv: readonly string[]; env: Record<string, string> | undefined }[]
  writes: string[]
  opened: { id: string; focus: boolean | undefined }[]
  snapshot: unknown
  github: unknown
  clock: MockClock
}

const HOME = '/fm'
const PANE = {
  plugin: 'fleet-pane',
  component: 'Pane',
  requestId: 'fleet-pane',
  viewport: { columns: 160, rows: 40 },
  props: { title: 'Pull requests and decisions', isFocused: false, bodyColumns: 120, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} },
} as const

const AXI = 'https://github.com/careem/axi/pull/7'
const KSM = 'https://github.com/careem/kotlin-state-machine/pull/376'

const SNAPSHOT = {
  schema: 'fm-fleet-snapshot.v1',
  tasks: [
    { id: 'axi-packaging', pr: { url: AXI }, backlog: { unresolved_blocker_ids: [] }, hints: { open_decisions: [] } },
    { id: 'ksm-debug', pr: { url: KSM }, backlog: { unresolved_blocker_ids: [] }, hints: { open_decisions: [] } },
    {
      id: 'booking-explore',
      pr: { url: null },
      hints: {
        open_decisions: [
          { key: 'captain-hold-s6-cli-q-1', verb: 'needs-decision', summary: 'captain hold s6-cli-q: Should the CLI build alone? Report data/s6-codex-cp1/report.md.' },
        ],
      },
    },
  ],
  backlog: { records: [{ id: 'inspector-lavish-ship', title: 'Ship the Lavish review page?', captain_actionable: true }] },
}

const pr = (title: string, state: string, conclusion: string, reviewDecision: string | null) => ({
  pullRequest: {
    title,
    state,
    isDraft: false,
    mergeable: 'MERGEABLE',
    mergeStateStatus: 'CLEAN',
    reviewDecision,
    commits: { nodes: [{ commit: { statusCheckRollup: { contexts: { nodes: [{ __typename: 'CheckRun', status: 'COMPLETED', conclusion, isRequired: false }] } } } }] },
  },
})

const GITHUB = { data: { p0: pr('Package axi for brew', 'OPEN', 'SUCCESS', null), p1: pr('Cut the frame cost', 'OPEN', 'FAILURE', 'REVIEW_REQUIRED') } }

function world(on: On, store: Record<string, unknown> = {}, files: string[] = [`${HOME}/state`, `${HOME}/bin/fm-fleet-snapshot.sh`]): World {
  const w: World = {
    files: new Set(files),
    state: new Map(),
    runs: [],
    writes: [],
    opened: [],
    snapshot: SNAPSHOT,
    github: GITHUB,
    clock: mock.clock(on, { now: 1_000_000 }),
  }
  mock.store(on, store)
  mock.env(on, {})
  on('fs.exists', ($, e) => ({ value: w.files.has(e.path) }))
  on('fs.write', ($, e) => {
    w.writes.push(e.path)
    return { value: undefined }
  })
  // The session's named values, held here so a /clear can start them over.
  on('state.get', ($, e) => ({ value: w.state.get(`${e.plugin}/${e.key}`) ?? { value: undefined, version: 0 } }))
  on('state.set', ($, e) => {
    const name = `${e.plugin}/${e.key}`
    const version = w.state.get(name)?.version ?? 0
    if (e.ifVersion !== undefined && e.ifVersion !== version) return { value: { isSet: false, version } }
    w.state.set(name, { value: e.value, version: version + 1 })
    return { value: { isSet: true, version: version + 1 } }
  })
  on('session.root', () => ({ value: HOME }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('turn.complete', () => ({ text: '' }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('process.run', ($, e) => {
    w.runs.push({ argv: e.argv, env: e.init?.env })
    const answer = e.argv[0] === 'gh' ? w.github : w.snapshot
    return { value: { exitCode: 0, stdout: JSON.stringify(answer), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('ui.open', ($, e) => {
    w.opened.push({ id: e.id, focus: e.focus })
    return { value: { isPlaced: true } }
  })
  on('ui.close', () => ({ value: undefined }))
  // The engine's own drawing, standing where the mod hands a site on.
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return h(Text, { key: 'engine' }, 'engine') as RenderElement
  })
  return w
}

async function start($: Engine, w: World): Promise<void> {
  await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
  await w.clock.advance(20)
}

// A /clear: the session ends and the process goes on under a new one, whose
// $.state starts empty and which raises no session.start.
async function clear($: Engine, w: World): Promise<void> {
  await $.session.end({ reason: 'clear', sessionId: 'before-clear', resume: { id: 'before-clear' } })
  w.state = new Map()
}

const snapshotRuns = (w: World) => w.runs.filter(run => run.argv[0] !== 'gh').length
const ghRuns = (w: World) => w.runs.filter(run => run.argv[0] === 'gh').length

describe('the pane', () => {
  test('opens unasked and lists each open pull request and each decision waiting', async ($, on) => {
    const w = world(on)
    await start($, w)
    expect(w.opened).toEqual([{ id: 'fleet-pane', focus: undefined }])
    for (const surface of ['terminal', 'desktop'] as const) {
      const pane = await $.ui.mount({ ...PANE, surface })
      expect((await pane.find({ type: 'Text', text: /Open pull requests \(2\)/ })) !== undefined).toBe(true)
      expect((await pane.find({ type: 'Text', text: /axi: Package axi for brew/ })) !== undefined).toBe(true)
      expect((await pane.find({ type: 'Text', text: new RegExp(AXI) })) !== undefined).toBe(true)
      expect((await pane.find({ type: 'Text', text: /checks passing - ready - waiting for your word to merge/ })) !== undefined).toBe(true)
      expect((await pane.find({ type: 'Text', text: /checks 1 failing - a failing check; needs an approving review/ })) !== undefined).toBe(true)
      expect((await pane.find({ type: 'Text', text: /Decisions waiting for you \(2\)/ })) !== undefined).toBe(true)
      expect((await pane.find({ type: 'Text', text: /booking-explore · s6-cli-q: Should the CLI build alone/ })) !== undefined).toBe(true)
      expect((await pane.find({ type: 'Text', text: /report data\/s6-codex-cp1\/report\.md/ })) !== undefined).toBe(true)
      expect((await pane.find({ type: 'Text', text: /inspector-lavish-ship: Ship the Lavish review page\?/ })) !== undefined).toBe(true)
      await pane.unmount()
    }
  })

  test('reads the snapshot for this home with nothing written, and asks GitHub once for every pull request', async ($, on) => {
    const w = world(on)
    await start($, w)
    expect(w.runs[0]?.argv).toEqual([`${HOME}/bin/fm-fleet-snapshot.sh`, '--json'])
    expect(w.runs[0]?.env).toEqual({ FM_HOME: HOME, FM_CREW_STATE_NO_FORGE: '1', FM_SNAPSHOT_CACHE_DIR: '/dev/null/fleet-pane' })
    expect(w.runs[1]?.argv.slice(0, 3)).toEqual(['gh', 'api', 'graphql'])
    expect(ghRuns(w)).toBe(1)
    expect(w.writes).toEqual([])
  })

  test('rereads after a reply, asks GitHub at most once a minute, and drops a merged pull request', async ($, on) => {
    const w = world(on)
    await start($, w)
    await w.clock.advance(25_000)
    await $.turn.complete({ answer: '', durationMs: 1, isAborted: false, turnId: 't', reason: 'answer' })
    await w.clock.advance(10)
    expect(w.runs.filter(run => run.argv[0] !== 'gh')).toHaveLength(2)
    expect(ghRuns(w)).toBe(1)

    w.github = { data: { ...GITHUB.data, p1: pr('Cut the frame cost', 'MERGED', 'SUCCESS', null) } }
    await w.clock.advance(60_000)
    expect(ghRuns(w)).toBe(2)
    const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect((await pane.find({ type: 'Text', text: /Open pull requests \(1\)/ })) !== undefined).toBe(true)
    expect(await pane.find({ type: 'Text', text: /Cut the frame cost/ })).toBeUndefined()
  })

  test('a failed read keeps the last rows and says so', async ($, on) => {
    const w = world(on)
    await start($, w)
    w.snapshot = 'broken'
    await w.clock.advance(60_000)
    const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect((await pane.find({ type: 'Text', text: /axi: Package axi for brew/ })) !== undefined).toBe(true)
    expect((await pane.find({ type: 'Text', text: /could not be read just now/ })) !== undefined).toBe(true)
  })

  test('fills in again on its own after /clear', async ($, on) => {
    const w = world(on)
    await start($, w)
    await clear($, w)
    await w.clock.advance(20)
    expect(snapshotRuns(w)).toBe(2)
    const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect((await pane.find({ type: 'Text', text: /Open pull requests \(2\)/ })) !== undefined).toBe(true)
    expect((await pane.find({ type: 'Text', text: /Decisions waiting for you \(2\)/ })) !== undefined).toBe(true)
    await pane.unmount()

    await w.clock.advance(60_000)
    expect(snapshotRuns(w)).toBe(3)
  })

  test('/fleet-pane reads again at once after /clear', async ($, on) => {
    const w = world(on)
    await start($, w)
    await clear($, w)
    await w.clock.advance(20)
    w.snapshot = { ...SNAPSHOT, backlog: { records: [] } }
    await $.command.run({ command: 'fleet-pane', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 160 } })
    await w.clock.advance(20)
    expect(snapshotRuns(w)).toBe(3)
    const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect((await pane.find({ type: 'Text', text: /Decisions waiting for you \(1\)/ })) !== undefined).toBe(true)
  })

  test('closed by hand stays closed until /fleet-pane', async ($, on) => {
    const w = world(on, { isHidden: true })
    await start($, w)
    expect(w.opened).toEqual([])
    await $.command.run({ command: 'fleet-pane', args: '', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 160 } })
    expect(w.opened).toEqual([{ id: 'fleet-pane', focus: true }])
  })

  test('stays idle outside a main Firstmate home', async ($, on) => {
    const w = world(on, {}, [`${HOME}/state`, `${HOME}/bin/fm-fleet-snapshot.sh`, `${HOME}/.fm-secondmate-home`])
    await start($, w)
    await w.clock.advance(60_000)
    expect(w.opened).toEqual([])
    expect(w.runs).toEqual([])
  })
})

// The colours a pane run may name: theme keys that follow the theme in force,
// as the pane's own background does.
const THEME = new Set(['text', 'suggestion', 'warning', 'success'])

describe('the pane under any theme', () => {
  test('every run names a theme colour over a theme background, none dimmed', async ($, on) => {
    const w = world(on)
    await start($, w)
    const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect(await pane.drawn()).toMatchObject({ type: 'Box', props: { backgroundColor: 'composerSidebarBackground' } })
    const texts = await pane.findAll({ type: 'Text' })
    expect(texts.length).toBeGreaterThan(10)
    for (const text of texts) {
      expect({ text: text.text, color: THEME.has(String(text.props.color)) }).toEqual({ text: text.text, color: true })
      expect({ text: text.text, dimColor: text.props.dimColor }).toEqual({ text: text.text, dimColor: undefined })
    }
  })
})
