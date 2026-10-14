import { describe, expect, mock, test } from 'claude-code/testing'
import type { Engine, MockClock } from 'claude-code/testing'
import type { On, RenderElement } from 'claude-code'

// An in-memory Firstmate home beneath the mod: its files, the commands and
// panes the mod asks for, and the context fill the session reports.
type World = {
  files: Map<string, string>
  mtimes: Map<string, number>
  commands: string[]
  toasts: string[]
  opened: string[]
  tokens: number
  clock: MockClock
}

const HOME = '/fm'
const MATE = '/homes/mate-a'
const BAND = {
  plugin: 'stow-review',
  component: 'AbovePrompt',
  props: { hasSurvey: false, isWorking: false, maxRows: 3, bodyColumns: 120, scroll: { offset: 0, bodyRows: 3 }, view: {} },
} as const
const PANE = {
  plugin: 'stow-review',
  component: 'Pane',
  requestId: 'stow-review',
  viewport: { columns: 140, rows: 40 },
  props: { title: 'Stow review', isFocused: true, bodyColumns: 120, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} },
} as const

function world(on: On, files: Record<string, string>, store: Record<string, unknown> = {}): World {
  const w: World = {
    files: new Map(Object.entries(files)),
    mtimes: new Map(),
    commands: [],
    toasts: [],
    opened: [],
    tokens: 10_000,
    clock: mock.clock(on, { now: 1_000_000 }),
  }
  mock.store(on, store)
  mock.env(on, {})
  on('fs.exists', ($, e) => ({ value: w.files.has(e.path) }))
  on('fs.read', ($, e) => ({ value: w.files.get(e.path) ?? '' }))
  on('fs.write', ($, e) => {
    w.files.set(e.path, e.text)
    w.mtimes.set(e.path, w.clock.now())
    return { value: undefined }
  })
  on('fs.stat', ($, e) => ({ value: { kind: 'file', size: 0, mtimeMs: w.mtimes.get(e.path) ?? 0, isLink: false } }))
  on('session.root', () => ({ value: HOME }))
  on('session.usage', () => ({
    value: { startedAt: 0, context: { tokens: w.tokens, window: 1_000_000 }, rateLimits: [] },
  }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('turn.complete', () => ({ text: '' }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('command.run', ($, e) => {
    w.commands.push(`${e.command} ${e.args}`.trim())
    return { text: '' }
  })
  on('ui.open', ($, e) => {
    w.opened.push(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.close', () => ({ value: undefined }))
  on('ui.toast', ($, e) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  // The engine's own drawing, standing where the mod hands a site on.
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return h(Text, { key: 'engine' }, 'engine') as RenderElement
  })
  return w
}

const firstmateHome = (extra: Record<string, string> = {}): Record<string, string> => ({
  [`${HOME}/state`]: '',
  [`${HOME}/bin/fm-stow-plan.sh`]: '',
  ...extra,
})

const reading = (tokens: number, at: number): string => JSON.stringify({ version: 1, tokens, window: 1_000_000, at })

async function turnEnds($: Engine, w: World): Promise<void> {
  await $.turn.complete({ answer: '', durationMs: 1, isAborted: false, turnId: 't', reason: 'answer' })
  await w.clock.advance(1500)
}

const REVIEW = {
  version: 1,
  homes: [
    {
      home: 'main',
      items: [
        { id: 'm1', section: 'memory', action: 'rewrite', target: 'data/learnings.md', entry: '- fact <!--a:2026-10-14-->', replaces: '- fact <!--a:2026-08-01-->' },
        { id: 'k1', section: 'knowledge', action: 'add', target: 'data/captain.md', entry: '- likes short PRs' },
      ],
    },
    { home: 'mate-a', items: [{ id: 'r1', section: 'records', action: 'record', target: 'backlog', entry: 'file: flaky test' }] },
  ],
  exceptions: [],
}

describe('the band', () => {
  test('appears when any home is over the threshold and asks exactly those homes', async ($, on) => {
    const w = world(
      on,
      firstmateHome({
        [`${HOME}/data/secondmates.md`]: `- mate-a - rides (home: ${MATE}; scope: rides; projects: a; added 2026-08-07)\n- mate-b - quiet (home: /homes/mate-b; scope: q; projects: a; added 2026-08-07)\n`,
        [`${MATE}/state/stow-context.json`]: reading(230_000, 1_000_000),
        ['/homes/mate-b/state/stow-context.json']: reading(20_000, 1_000_000),
      }),
    )
    await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
    await turnEnds($, w)
    for (const surface of ['terminal', 'desktop'] as const) {
      const band = await $.ui.mount({ ...BAND, surface })
      expect((await band.find({ type: 'Text', text: /mate-a 230k/ })) !== undefined).toBe(true)
      expect((await band.find({ type: 'Text', text: /mate-b/ })) === undefined).toBe(true)
      await band.unmount()
    }
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await band.press({ key: 'stow' })
    await w.clock.advance(20)
    expect(w.commands).toEqual(['stow draft --mod --homes mate-a'])
    // The main session's own fill is published for every home to read.
    expect(JSON.parse(w.files.get(`${HOME}/state/stow-context.json`) ?? '{}').tokens).toBe(10_000)
  })

  test('stays hidden while every home is under, or its reading is stale', async ($, on) => {
    const w = world(
      on,
      firstmateHome({
        [`${HOME}/data/secondmates.md`]: `- mate-a - rides (home: ${MATE}; scope: rides; projects: a; added 2026-08-07)\n`,
        [`${MATE}/state/stow-context.json`]: reading(400_000, 1_000_000 - 10 * 60_000),
      }),
    )
    await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
    await turnEnds($, w)
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect(await band.find({ key: 'stow' })).toBeUndefined()
  })
})

describe('the review pane', () => {
  test('draws every item ticked and hands back only approved items in edited wording', async ($, on) => {
    const w = world(on, firstmateHome())
    w.tokens = 250_000
    await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
    await turnEnds($, w)
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await band.press({ key: 'stow' })
    await w.clock.advance(20)
    expect(w.commands).toEqual(['stow draft --mod --homes main'])

    // The agent gathers the plans; the pane opens once the review exists.
    w.files.set(`${HOME}/state/stow-review.json`, JSON.stringify(REVIEW))
    w.mtimes.set(`${HOME}/state/stow-review.json`, w.clock.now())
    await turnEnds($, w)
    expect(w.opened).toContain('stow-review')

    const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect((await pane.find({ key: 'tick:main/m1' }))?.text).toContain('[x]')
    expect((await pane.find({ key: 'tick:mate-a/r1' }))?.text).toContain('[x]')
    expect((await pane.find({ type: 'Text', text: /Home: mate-a/ })) !== undefined).toBe(true)
    await pane.press({ key: 'tick:main/k1' })
    expect((await pane.find({ key: 'tick:main/k1' }))?.text).toContain('[ ]')
    await pane.input({ key: 'entry:main/m1', text: '- fact, reworded <!--a:2026-10-14-->', kind: 'change' })
    await pane.press({ key: 'save' })
    await w.clock.advance(20)

    const approved = JSON.parse(w.files.get(`${HOME}/state/stow-review.approved.json`) ?? '{}')
    expect(approved.homes.map((plan: { home: string }) => plan.home)).toEqual(['main', 'mate-a'])
    expect(approved.homes[0].items).toHaveLength(1)
    expect(approved.homes[0].items[0].entry).toBe('- fact, reworded <!--a:2026-10-14-->')
    expect(w.commands).toEqual(['stow draft --mod --homes main', 'stow apply --mod'])
  })

  test('cancel saves nothing', async ($, on) => {
    const w = world(on, firstmateHome())
    w.tokens = 250_000
    await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
    await turnEnds($, w)
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await band.press({ key: 'stow' })
    await w.clock.advance(20)
    w.files.set(`${HOME}/state/stow-review.json`, JSON.stringify(REVIEW))
    w.mtimes.set(`${HOME}/state/stow-review.json`, w.clock.now())
    await turnEnds($, w)
    const pane = await $.ui.mount({ ...PANE, surface: 'desktop' })
    await pane.press({ key: 'cancel' })
    await w.clock.advance(20)
    expect(w.files.has(`${HOME}/state/stow-review.approved.json`)).toBe(false)
    expect(w.commands).toEqual(['stow draft --mod --homes main'])
  })
})

describe('Auto and clearing', () => {
  test('Auto stows a crossing home once, shows what it saved, then clears', async ($, on) => {
    const w = world(on, firstmateHome(), { auto: true })
    await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
    w.tokens = 250_000
    await turnEnds($, w)
    await w.clock.advance(20)
    expect(w.commands).toEqual(['stow draft --mod --auto --homes main'])

    // The agent saved everything and recorded the round's end.
    const applied = { version: 1, at: Math.floor(w.clock.now() / 1000), clear: true, homes: REVIEW.homes }
    w.files.set(`${HOME}/state/stow-applied.json`, JSON.stringify(applied))
    await turnEnds($, w)
    expect(w.toasts.some(text => text.includes('Auto stow saved: main 2 items, mate-a 1 item'))).toBe(true)
    expect(w.commands).toEqual(['stow draft --mod --auto --homes main', 'clear'])

    // Still over: no second round and no second clear.
    await turnEnds($, w)
    expect(w.commands).toEqual(['stow draft --mod --auto --homes main', 'clear'])

    const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect((await pane.find({ type: 'Text', text: /Last automatic stow/ })) !== undefined).toBe(true)

    // Back under after the clear, then over again: Auto fires once more.
    w.tokens = 5_000
    await turnEnds($, w)
    w.tokens = 260_000
    await turnEnds($, w)
    await w.clock.advance(20)
    expect(w.commands.filter(one => one.startsWith('stow draft'))).toHaveLength(2)
  })

  test('a secondmate session only publishes its fill and clears itself once', async ($, on) => {
    const w = world(on, {
      [`${HOME}/state`]: '',
      [`${HOME}/bin/fm-stow-plan.sh`]: '',
      [`${HOME}/.fm-secondmate-home`]: 'mate-a',
    })
    w.tokens = 300_000
    await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
    await turnEnds($, w)
    expect(JSON.parse(w.files.get(`${HOME}/state/stow-context.json`) ?? '{}').tokens).toBe(300_000)
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect(await band.find({ key: 'stow' })).toBeUndefined()

    w.files.set(`${HOME}/state/stow-applied.json`, JSON.stringify({ version: 1, at: 42, clear: true, homes: [] }))
    await turnEnds($, w)
    await turnEnds($, w)
    expect(w.commands).toEqual(['clear'])
  })

  test('a round end that does not ask for a clear leaves the session alone', async ($, on) => {
    const w = world(on, firstmateHome({ [`${HOME}/state/stow-applied.json`]: JSON.stringify({ version: 1, at: 42, clear: false, homes: [] }) }))
    await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
    await turnEnds($, w)
    expect(w.commands).toEqual([])
  })
})
