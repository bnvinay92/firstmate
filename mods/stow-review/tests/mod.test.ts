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

// The plugin store, kept by the test when several sessions must share it.
type Store = Map<string, unknown>

function world(
  on: On,
  files: Record<string, string>,
  store: Record<string, unknown> | Store = {},
  { root = HOME, now = 1_000_000 }: { root?: string; now?: number } = {},
): World {
  const w: World = {
    files: new Map(Object.entries(files)),
    mtimes: new Map(),
    commands: [],
    toasts: [],
    opened: [],
    tokens: 10_000,
    clock: mock.clock(on, { now }),
  }
  if (store instanceof Map) {
    on('store.get', ($, e) => ({ value: store.get(e.key) }))
    on('store.set', ($, e) => {
      store.set(e.key, e.value)
      return { value: undefined }
    })
  } else mock.store(on, store)
  mock.env(on, {})
  on('fs.exists', ($, e) => ({ value: w.files.has(e.path) }))
  on('fs.read', ($, e) => ({ value: w.files.get(e.path) ?? '' }))
  on('fs.write', ($, e) => {
    w.files.set(e.path, e.text)
    w.mtimes.set(e.path, w.clock.now())
    return { value: undefined }
  })
  on('fs.stat', ($, e) => ({ value: { kind: 'file', size: 0, mtimeMs: w.mtimes.get(e.path) ?? 0, isLink: false } }))
  on('session.root', () => ({ value: root }))
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

const firstmateHome = (extra: Record<string, string> = {}, root = HOME): Record<string, string> => ({
  [`${root}/state`]: '',
  [`${root}/bin/fm-stow-plan.sh`]: '',
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
      expect((await band.find({ key: 'stow:mate-a' }))?.text).toContain('Stow mate-a (230k)')
      expect(await band.find({ key: 'stow:mate-b' })).toBeUndefined()
      expect(await band.find({ key: 'stow:main' })).toBeUndefined()
      await band.unmount()
    }
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await band.press({ key: 'stow:mate-a' })
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
    expect(await band.find({ key: 'stow:mate-a' })).toBeUndefined()
  })

  test('offers one button per home over the threshold, and stows only the home pressed', async ($, on) => {
    const w = world(
      on,
      firstmateHome({
        [`${HOME}/data/secondmates.md`]: `- mate-a - rides (home: ${MATE}; scope: rides; projects: a; added 2026-08-07)\n`,
        [`${MATE}/state/stow-context.json`]: reading(230_000, 1_000_000),
      }),
    )
    w.tokens = 250_000
    await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
    await turnEnds($, w)
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect((await band.find({ key: 'stow:main' }))?.text).toContain('Stow main (250k)')
    expect((await band.find({ key: 'stow:mate-a' }))?.text).toContain('Stow mate-a (230k)')
    await band.press({ key: 'stow:main' })
    await w.clock.advance(20)
    expect(w.commands).toEqual(['stow draft --mod --homes main'])
    // While that round runs, no other home can be started beside it.
    expect(await band.find({ key: 'stow:mate-a' })).toBeUndefined()
    expect((await band.find({ type: 'Text', text: /under way for main$/ })) !== undefined).toBe(true)
  })
})

describe('the review pane', () => {
  test('draws every item ticked and hands back only approved items in edited wording', async ($, on) => {
    const w = world(on, firstmateHome())
    w.tokens = 250_000
    await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
    await turnEnds($, w)
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await band.press({ key: 'stow:main' })
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
    await pane.press({ key: 'edit:main/m1' })
    await pane.input({ key: 'entry:main/m1', text: '- fact, reworded <!--a:2026-10-14-->', kind: 'change' })
    await pane.press({ key: 'save' })
    await w.clock.advance(20)

    const approved = JSON.parse(w.files.get(`${HOME}/state/stow-review.approved.json`) ?? '{}')
    expect(approved.homes.map((plan: { home: string }) => plan.home)).toEqual(['main', 'mate-a'])
    expect(approved.homes[0].items).toHaveLength(1)
    expect(approved.homes[0].items[0].entry).toBe('- fact, reworded <!--a:2026-10-14-->')
    expect(w.commands).toEqual(['stow draft --mod --homes main', 'stow apply --mod --homes main'])
  })

  test('cancel saves nothing', async ($, on) => {
    const w = world(on, firstmateHome())
    w.tokens = 250_000
    await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
    await turnEnds($, w)
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    await band.press({ key: 'stow:main' })
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

// The colours a pane run may name: theme keys that follow the theme in force,
// as the pane's own background does, and never the theme's dim grey.
const THEME_TEXT = new Set(['text', 'suggestion'])
const LONG_ENTRY = `- ${'the captain approves each stow entry only after reading it whole, '.repeat(6)}end`

async function openReview($: Engine, w: World, review: unknown): Promise<void> {
  w.tokens = 250_000
  await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
  await turnEnds($, w)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'stow:main' })
  await w.clock.advance(20)
  w.files.set(`${HOME}/state/stow-review.json`, JSON.stringify(review))
  w.mtimes.set(`${HOME}/state/stow-review.json`, w.clock.now())
  await turnEnds($, w)
}

describe('the review pane under any theme', () => {
  test('every run names a theme colour over a theme background, and no Button keeps default brackets', async ($, on) => {
    const w = world(on, firstmateHome())
    await openReview($, w, { ...REVIEW, exceptions: [{ home: 'mate-b', reason: 'no plan' }] })
    const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect(await pane.drawn()).toMatchObject({ type: 'Box', props: { backgroundColor: 'composerSidebarBackground' } })
    const texts = await pane.findAll({ type: 'Text' })
    expect(texts.length).toBeGreaterThan(10)
    for (const text of texts) {
      expect({ text: text.text, color: THEME_TEXT.has(String(text.props.color)) }).toEqual({ text: text.text, color: true })
      expect({ text: text.text, dimColor: text.props.dimColor }).toEqual({ text: text.text, dimColor: undefined })
    }
    const buttons = await pane.findAll({ type: 'Button' })
    expect(buttons.map(button => button.key)).toEqual(expect.arrayContaining(['all', 'none', 'auto', 'save', 'cancel']))
    for (const button of buttons) expect({ key: button.key, plain: button.props.plain }).toEqual({ key: button.key, plain: true })
    expect((await pane.find({ key: 'save' }))?.text).toContain('[ Save ]')
  })

  test('an entry is drawn once, whole, under its spelled-out action, and edits in place', async ($, on) => {
    const w = world(on, firstmateHome())
    const long = {
      version: 1,
      homes: [
        {
          home: 'main',
          items: [
            { id: 'l1', section: 'knowledge', action: 'add', target: 'data/captain.md', entry: LONG_ENTRY },
            { id: 'm1', section: 'memory', action: 'rewrite', target: 'data/learnings.md', entry: '- fact, new', replaces: '- fact, old' },
            { id: 'm2', section: 'memory', action: 'remove', target: 'data/learnings.md', entry: '- stale fact', replaces: '- stale fact' },
          ],
        },
      ],
    }
    await openReview($, w, long)
    const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
    const drawn = await pane.findAll({ type: 'Text', text: /reading it whole, end/ })
    expect(drawn).toHaveLength(1)
    expect(drawn[0]?.text.replace(/\s+/g, ' ').trim()).toBe(LONG_ENTRY)
    expect(drawn[0]?.props.wrap).toBe('wrap')
    for (const word of ['add', 'rewrite', 'remove']) {
      expect((await pane.find({ type: 'Text', text: new RegExp(`^\\s*${word}$`) })) !== undefined).toBe(true)
    }
    // A rewrite names what it replaces; a removal has nothing to edit.
    expect((await pane.findAll({ type: 'Text', text: /^replaces: / })).map(text => text.text)).toEqual(['replaces: - fact, old'])
    expect(await pane.find({ key: 'edit:main/m2' })).toBeUndefined()
    // No field is drawn until Edit is pressed, and then it stands in for the text.
    expect(await pane.find({ key: 'entry:main/l1' })).toBeUndefined()
    await pane.press({ key: 'tick:main/l1' })
    expect((await pane.find({ key: 'tick:main/l1' }))?.text).toContain('[ ]')
    await pane.press({ key: 'edit:main/l1' })
    expect((await pane.find({ key: 'entry:main/l1' })) !== undefined).toBe(true)
    expect(await pane.find({ type: 'Text', text: /reading it whole/ })).toBeUndefined()
    await pane.input({ key: 'entry:main/l1', text: '- short now', kind: 'submit' })
    expect(await pane.find({ key: 'entry:main/l1' })).toBeUndefined()
    expect((await pane.findAll({ type: 'Text', text: /^- short now$/ })).length).toBe(1)
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
    expect(await band.find({ key: 'stow:mate-a' })).toBeUndefined()

    w.files.set(`${HOME}/state/stow-applied.json`, JSON.stringify({ version: 1, at: Math.floor(w.clock.now() / 1000), clear: true, homes: [] }))
    await turnEnds($, w)
    await turnEnds($, w)
    expect(w.commands).toEqual(['clear'])
  })

  test('a cleared session publishes an empty reading at once, so main stops offering it', async ($, on) => {
    const w = world(on, {
      [`${HOME}/state`]: '',
      [`${HOME}/bin/fm-stow-plan.sh`]: '',
      [`${HOME}/.fm-secondmate-home`]: 'mate-a',
    })
    w.tokens = 434_000
    await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
    await turnEnds($, w)
    expect(JSON.parse(w.files.get(`${HOME}/state/stow-context.json`) ?? '{}').tokens).toBe(434_000)
    w.files.set(`${HOME}/state/stow-applied.json`, JSON.stringify({ version: 1, at: Math.floor(w.clock.now() / 1000), clear: true, homes: [] }))
    await turnEnds($, w)
    expect(w.commands).toEqual(['clear'])
    const published = JSON.parse(w.files.get(`${HOME}/state/stow-context.json`) ?? '{}')
    expect({ tokens: published.tokens, at: published.at }).toEqual({ tokens: 0, at: w.clock.now() - 500 })
  })

  test('the main band drops a cleared secondmate on its next tick', async ($, on) => {
    const w = world(
      on,
      firstmateHome({
        [`${HOME}/data/secondmates.md`]: `- mate-a - rides (home: ${MATE}; scope: rides; projects: a; added 2026-08-07)\n`,
        [`${MATE}/state/stow-context.json`]: reading(434_000, 1_000_000),
      }),
    )
    await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
    await turnEnds($, w)
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect((await band.find({ key: 'stow:mate-a' }))?.text).toContain('Stow mate-a (434k)')
    // The secondmate's session cleared and published its empty reading.
    w.files.set(`${MATE}/state/stow-context.json`, reading(0, w.clock.now()))
    await w.clock.advance(30_000)
    expect(await band.find({ key: 'stow:mate-a' })).toBeUndefined()
  })

  test('a round end older than a few minutes never clears', async ($, on) => {
    const w = world(on, firstmateHome())
    w.files.set(`${HOME}/state/stow-applied.json`, JSON.stringify({ version: 1, at: Math.floor(w.clock.now() / 1000) - 6 * 60, clear: true, homes: [] }))
    await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
    await turnEnds($, w)
    await w.clock.advance(60_000)
    expect(w.commands).toEqual([])
  })

  test('a round end that does not ask for a clear leaves the session alone', async ($, on) => {
    const w = world(on, firstmateHome({ [`${HOME}/state/stow-applied.json`]: JSON.stringify({ version: 1, at: 42, clear: false, homes: [] }) }))
    await $.session.start({ cwd: HOME, surface: 'terminal', isInteractive: true })
    await turnEnds($, w)
    expect(w.commands).toEqual([])
  })
})

// Every session that runs the mod shares one plugin store, in whichever home
// it runs. A test has one session, so the homes take turns in order: each
// session runs while the other home's session keeps writing everything it
// wrote to the store back over it on every tick, as a live session would.
describe('two homes sharing one store', () => {
  const store: Store = new Map()
  const wrote: Record<string, Store> = {}
  const MAIN_AT = 1792155314
  const MATE_AT = 1792154833

  async function runHome($: Engine, on: On, name: string, rival: string | undefined): Promise<string[]> {
    const root = name === 'main' ? HOME : MATE
    const at = name === 'main' ? MAIN_AT : MATE_AT
    const marker: Record<string, string> = name === 'main' ? {} : { [`${MATE}/.fm-secondmate-home`]: name }
    const own: Store = new Map()
    const w = world(on, firstmateHome(marker, root), store, { root, now: at * 1000 + 5_000 })
    w.files.set(`${root}/state/stow-applied.json`, JSON.stringify({ version: 1, at, clear: true, homes: [] }))
    const before = new Map(store)
    await $.session.start({ cwd: root, surface: 'terminal', isInteractive: true })
    for (let i = 0; i < 8; i++) {
      for (const [key, value] of wrote[rival ?? ''] ?? []) store.set(key, value)
      await turnEnds($, w)
      await w.clock.advance(30_000)
    }
    for (const [key, value] of store) if (before.get(key) !== value) own.set(key, value)
    wrote[name] = own
    return w.commands
  }

  test('the secondmate clears once', async ($, on) => {
    expect(await runHome($, on, 'mate-a', undefined)).toEqual(['clear'])
  })

  test('main clears once while the secondmate keeps writing its store values', async ($, on) => {
    expect(await runHome($, on, 'main', 'mate-a')).toEqual(['clear'])
  })

  test('the secondmate is not cleared again while main keeps writing its store values', async ($, on) => {
    expect(await runHome($, on, 'mate-a', 'main')).toEqual([])
  })
})
