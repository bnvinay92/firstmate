import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { StowApplied, StowReading, StowReview, StowRound, StowSite } from '../types'
import {
  APPLIED_FILE,
  APPROVED_FILE,
  CONTEXT_FILE,
  REFRESH_MS,
  REGISTRY_FILE,
  REVIEW_FILE,
  ROUND_TIMEOUT_MS,
  SECONDMATE_MARKER,
  SECTION_LABELS,
  appliedSummary,
  approvedReview,
  countItems,
  crossings,
  draftArgs,
  formatTokens,
  isOver,
  keyOf,
  pageOf,
  parseApplied,
  parseReading,
  parseRegistry,
  parseReview,
  reviewRows,
} from './lib'

type Engine = EngineInterface

const PANE = 'stow-review'
const TICK_MS = 30 * 1000
const PUBLISH_MIN_MS = 30 * 1000

const site = atom({ plugin: 'stow-review', key: 'site' } as const, null)
const readings = atom({ plugin: 'stow-review', key: 'readings' } as const, [])
const review = atom({ plugin: 'stow-review', key: 'review' } as const, null)
const ticks = atom({ plugin: 'stow-review', key: 'ticks' } as const, {})
const edits = atom({ plugin: 'stow-review', key: 'edits' } as const, {})
const page = atom({ plugin: 'stow-review', key: 'page' } as const, 0)
const round = atom({ plugin: 'stow-review', key: 'round' } as const, null)
const isAuto = atom({ plugin: 'stow-review', key: 'isAuto' } as const, false)
const lastAuto = atom({ plugin: 'stow-review', key: 'lastAuto' } as const, null)

async function readText($: Engine, path: string): Promise<string | null> {
  try {
    return (await $.fs.exists(path)) ? await $.fs.read(path) : null
  } catch {
    return null
  }
}

async function exists($: Engine, path: string): Promise<boolean> {
  try {
    return await $.fs.exists(path)
  } catch {
    return false
  }
}

// A Firstmate home: FM_HOME when set, else the session's root, holding state/
// beside a Firstmate code root. Anything else leaves the mod idle.
async function detectSite($: Engine): Promise<StowSite | null> {
  const root = await $.session.root()
  const home = (await $.env.get('FM_HOME')) || root
  const isFirstmate =
    (await exists($, `${home}/state`)) &&
    ((await exists($, `${root}/bin/fm-stow-plan.sh`)) || (await exists($, `${home}/bin/fm-stow-plan.sh`)))
  if (!isFirstmate) return null
  const marker = await readText($, `${home}/${SECONDMATE_MARKER}`)
  if (marker === null) return { home, role: 'primary', name: 'main' }
  return { home, role: 'secondmate', name: marker.trim() }
}

// The last reading this session published; a hot reload starts it over,
// which only costs one early write.
let published: { tokens: number; at: number } | null = null

async function publish($: Engine, where: StowSite, threshold: number, tokens: number | undefined, window: number): Promise<void> {
  if (tokens === undefined) return
  const now = await $.clock.now()
  const crossed = published !== null && published.tokens < threshold !== tokens < threshold
  const isDue = published === null || now - published.at >= REFRESH_MS
  const isWorthIt = published === null || (tokens !== published.tokens && now - published.at >= PUBLISH_MIN_MS)
  if (!crossed && !isDue && !isWorthIt) return
  published = { tokens, at: now }
  await $.fs.write(`${where.home}/${CONTEXT_FILE}`, JSON.stringify({ version: 1, tokens, window, at: now }) + '\n')
}

async function refreshReadings($: Engine, where: StowSite): Promise<StowReading[]> {
  const now = await $.clock.now()
  const found: StowReading[] = []
  const { context } = await $.session.usage()
  if (context.tokens !== undefined) {
    found.push({ home: 'main', tokens: context.tokens, window: context.window, at: now, isStale: false })
  }
  const registry = await readText($, `${where.home}/${REGISTRY_FILE}`)
  for (const mate of parseRegistry(registry ?? '')) {
    const text = await readText($, `${mate.home}/${CONTEXT_FILE}`)
    const reading = text === null ? null : parseReading(mate.id, text, now)
    if (reading !== null) found.push(reading)
  }
  await update($, readings, () => found)
  return found
}

async function startRound($: Engine, homes: string[], auto: boolean): Promise<void> {
  if (homes.length === 0 || (await read($, round)) !== null) return
  const now = await $.clock.now()
  await update($, round, () => ({ at: now, homes, isAuto: auto, isReviewOpen: false }))
  $.clock.after(10, () => {
    $.command.run({ command: 'stow', args: draftArgs(homes, auto) }).catch(() => {
      void update($, round, () => null)
      $.ui.toast('The stow could not start; nothing was asked or saved.')
    })
  })
}

// A round ends when this home records its end; a review opens when the
// round's plans are gathered. Each check reads files the stow skill wrote.
async function followRound($: Engine, where: StowSite): Promise<void> {
  const current = await read($, round)
  if (current === null) return
  const now = await $.clock.now()
  const applied = parseApplied((await readText($, `${where.home}/${APPLIED_FILE}`)) ?? '')
  if (applied !== null && applied.at * 1000 >= current.at - 1000) {
    await update($, round, () => null)
    await update($, review, () => null)
    if (current.isAuto) {
      await update($, lastAuto, () => applied)
      await $.store.set('lastAuto', applied)
      $.ui.toast(`Auto stow saved: ${appliedSummary(applied)}.`)
    }
    return
  }
  if (now - current.at > ROUND_TIMEOUT_MS) {
    await update($, round, () => null)
    return
  }
  if (current.isAuto || current.isReviewOpen) return
  const path = `${where.home}/${REVIEW_FILE}`
  if (!(await exists($, path)) || (await $.fs.stat(path)).mtimeMs < current.at) return
  const loaded = parseReview((await readText($, path)) ?? '')
  if (loaded === null) return
  await update($, review, () => loaded)
  await update($, ticks, () => ({}))
  await update($, edits, () => ({}))
  await update($, page, () => 0)
  await update($, round, r => (r === null ? r : { ...r, isReviewOpen: true }))
  await $.ui.open({ id: PANE, title: 'Stow review', focus: true })
}

// Clear this home's session once per recorded round end that asks for it:
// the record is written after every file write, and the command waits for
// the session to be idle, so the agent's turn finishes first.
async function clearIfAsked($: Engine, where: StowSite): Promise<void> {
  const applied = parseApplied((await readText($, `${where.home}/${APPLIED_FILE}`)) ?? '')
  if (applied === null || !applied.clear) return
  if ((await $.store.get('clearedAt')) === applied.at) return
  await $.store.set('clearedAt', applied.at)
  $.clock.after(1000, () => {
    $.command.run({ command: 'clear', args: '' }).catch(() => {
      $.ui.toast('The stow finished, but this session could not be cleared; run /clear.')
    })
  })
}

async function tick($: Engine, threshold: number): Promise<void> {
  const where = await read($, site)
  if (where === null) return
  const { context } = await $.session.usage()
  await publish($, where, threshold, context.tokens, context.window)
  if (where.role === 'primary') {
    const found = await refreshReadings($, where)
    const fired = ((await $.store.get('fired')) as string[] | undefined) ?? []
    const next = crossings(found, threshold, fired)
    await $.store.set('fired', next.fired)
    if ((await read($, isAuto)) && next.fire.length > 0) await startRound($, next.fire, true)
    await followRound($, where)
  }
  await clearIfAsked($, where)
}

async function toggleAuto($: Engine): Promise<void> {
  const value = !(await read($, isAuto))
  await update($, isAuto, () => value)
  await $.store.set('auto', value)
  if (value) await $.store.set('fired', [])
  $.ui.toast(value ? 'Auto stow is on: plans will be saved without review.' : 'Auto stow is off.')
}

async function openPane($: Engine): Promise<void> {
  await $.ui.open({ id: PANE, title: 'Stow review', focus: true })
}

async function closePane($: Engine): Promise<void> {
  await $.ui.close({ id: PANE })
}

async function toggleItem($: Engine, key: string): Promise<void> {
  await update($, ticks, map => ({ ...map, [key]: map[key] === false }))
}

async function editItem($: Engine, key: string, value: string): Promise<void> {
  await update($, edits, map => ({ ...map, [key]: value }))
}

async function tickAll($: Engine, review: StowReview, value: boolean): Promise<void> {
  const next: Record<string, boolean> = {}
  if (!value) for (const plan of review.homes) for (const item of plan.items) next[keyOf(plan.home, item.id)] = false
  await update($, ticks, () => next)
}

async function turnPage($: Engine, by: number, pages: number): Promise<void> {
  await update($, page, n => Math.min(Math.max(0, n + by), pages - 1))
}

async function save($: Engine): Promise<void> {
  const where = await read($, site)
  const loaded = await read($, review)
  if (where === null || loaded === null) return
  const approved = approvedReview(loaded, await read($, ticks), await read($, edits))
  await $.fs.write(`${where.home}/${APPROVED_FILE}`, JSON.stringify(approved, null, 2) + '\n')
  await update($, review, () => null)
  await update($, round, r => (r === null ? r : { ...r, isReviewOpen: false }))
  await $.ui.close({ id: PANE })
  $.clock.after(10, () => {
    $.command.run({ command: 'stow', args: 'apply --mod' }).catch(() => {
      $.ui.toast('The approved plan is saved, but the stow could not apply it; run /stow apply --mod.')
    })
  })
}

async function cancel($: Engine): Promise<void> {
  await update($, review, () => null)
  await update($, round, () => null)
  await $.ui.close({ id: PANE })
  $.ui.toast('Stow cancelled; nothing was saved.')
}

export const register: Register = (on, options) => {
  const threshold = typeof options.thresholdTokens === 'number' ? options.thresholdTokens : 200_000

  on('session.start', async ($, e, next) => {
    const where = await detectSite($)
    await update($, site, () => where)
    if (where !== null) {
      if (where.role === 'primary') {
        await $.command.register({ name: 'stow-review', description: 'Open the stow review pane' })
        const auto = await $.store.get('auto')
        await update($, isAuto, () => auto === true)
        const kept = (await $.store.get('lastAuto')) as StowApplied | undefined
        await update($, lastAuto, () => kept ?? null)
      }
      $.clock.every(TICK_MS, () => {
        void tick($, threshold)
      })
    }
    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    const where = await read($, site)
    if (where !== null && e.changed.includes('context')) {
      await publish($, where, threshold, e.context.tokens, e.context.window)
      if (where.role === 'primary' && e.context.tokens !== undefined) {
        const now = await $.clock.now()
        const own: StowReading = { home: 'main', tokens: e.context.tokens, window: e.context.window, at: now, isStale: false }
        await update($, readings, list => [own, ...list.filter(one => one.home !== 'main')])
      }
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const ran = await next(e)
    if (e.agentId === undefined) await tick($, threshold)
    return ran
  })

  on('command.run', { command: 'stow-review' }, async $ => {
    await openPane($)
    return { text: 'Stow review pane opened.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const where = await read($, site)
    if (where === null || where.role !== 'primary' || e.props.hasSurvey) return next(e)
    const current = await read($, round)
    const over = (await read($, readings)).filter(one => isOver(one, threshold))
    if (over.length === 0 && current === null) return next(e)
    const auto = await read($, isAuto)
    const { Box, Button, Text } = $.ui.resolve(e)
    const homes = over.map(one => one.home)
    const names = over.map(one => `${one.home} ${formatTokens(one.tokens)}`).join(', ')
    return (
      <Box flexDirection="row" gap={1}>
        {current === null ? (
          <Text key="what">Context over {formatTokens(threshold)}: {names}</Text>
        ) : (
          <Text key="what">
            Stow {current.isAuto ? '(auto) ' : ''}under way for {current.homes.join(', ')}
          </Text>
        )}
        {current === null && (
          <Button key="stow" variant="primary" onPress={() => startRound($, homes, false)}>
            Stow
          </Button>
        )}
        {current?.isReviewOpen === true && (
          <Button key="review" onPress={() => openPane($)}>
            Review
          </Button>
        )}
        <Button key="auto" onPress={() => toggleAuto($)}>
          {auto ? 'Auto: on' : 'Auto: off'}
        </Button>
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    if (e.surface === 'mobile') {
      const { Text } = $.ui.resolve(e)
      return <Text key="elsewhere">Review the stow plan in a terminal or desktop session.</Text>
    }
    const { Box, Button, Input, Text } = $.ui.resolve(e)
    const loaded = await read($, review)
    const auto = await read($, isAuto)
    const room = (e.viewport?.rows ?? 30) - 8
    const footer = [
      <Button key="auto" onPress={() => toggleAuto($)}>
        {auto ? 'Auto: on' : 'Auto: off'}
      </Button>,
    ]

    if (loaded === null) {
      const last = await read($, lastAuto)
      if (last === null) {
        return (
          <Box flexDirection="column">
            <Text key="empty" dimColor>No stow plan to review.</Text>
            <Box flexDirection="row" gap={1}>
              {footer}
              <Button key="close" role="dismiss" onPress={() => closePane($)}>
                Close
              </Button>
            </Box>
          </Box>
        )
      }
      const shown = pageOf(reviewRows({ version: 1, homes: last.homes }), room, 0)
      return (
        <Box flexDirection="column">
          <Text key="last" bold>Last automatic stow: {appliedSummary(last)}</Text>
          {shown.rows.map(row =>
            row.kind === 'home' ? (
              <Text bold>Home: {row.home}</Text>
            ) : row.kind === 'section' ? (
              <Text>  {SECTION_LABELS[row.section]}</Text>
            ) : row.kind === 'target' ? (
              <Text dimColor>    {row.target}</Text>
            ) : (
              <Text>      [{row.item.action}] {row.item.entry}</Text>
            ),
          )}
          <Box flexDirection="row" gap={1}>
            {footer}
            <Button key="close" role="dismiss" onPress={() => closePane($)}>
              Close
            </Button>
          </Box>
        </Box>
      )
    }

    const tickMap = await read($, ticks)
    const editMap = await read($, edits)
    const shown = pageOf(reviewRows(loaded), room, await read($, page))
    const at = Math.min(await read($, page), shown.pages - 1)
    const total = countItems(loaded)
    const kept = total - Object.values(tickMap).filter(value => value === false).length

    return (
      <Box flexDirection="column">
        <Text key="hint" dimColor>
          {kept} of {total} items ticked. Untick what should not be saved; edit a line to change its wording.
        </Text>
        {shown.rows.map(row => {
          if (row.kind === 'home') return <Text bold>Home: {row.home}</Text>
          if (row.kind === 'section') return <Text>  {SECTION_LABELS[row.section]}</Text>
          if (row.kind === 'target') return <Text dimColor>    {row.target}</Text>
          const key = keyOf(row.home, row.item.id)
          return (
            <Box key={`row:${key}`} flexDirection="row" gap={1}>
              <Text>     </Text>
              <Button key={`tick:${key}`} plain onPress={() => toggleItem($, key)}>
                {tickMap[key] === false ? '[ ]' : '[x]'}
              </Button>
              <Text dimColor>{row.item.action}</Text>
              {row.item.action === 'remove' ? (
                <Text>{row.item.entry}</Text>
              ) : (
                <Input
                  key={`entry:${key}`}
                  value={editMap[key] ?? row.item.entry}
                  submitLabel="keep"
                  onInput={(value: string) => {
                    void editItem($, key, value)
                  }}
                  onSubmit={(value: string) => {
                    void editItem($, key, value)
                  }}
                />
              )}
            </Box>
          )
        })}
        {(loaded.exceptions ?? []).map(one => (
          <Text dimColor>
            Not reviewable: {one.home} - {one.reason}
          </Text>
        ))}
        <Box flexDirection="row" gap={1}>
          {shown.pages > 1 && (
            <Button key="prev" onPress={() => turnPage($, -1, shown.pages)}>
              Prev
            </Button>
          )}
          {shown.pages > 1 && (
            <Text dimColor>
              page {at + 1}/{shown.pages}
            </Text>
          )}
          {shown.pages > 1 && (
            <Button key="next" onPress={() => turnPage($, 1, shown.pages)}>
              Next
            </Button>
          )}
          <Button key="all" onPress={() => tickAll($, loaded, true)}>
            All
          </Button>
          <Button key="none" onPress={() => tickAll($, loaded, false)}>
            None
          </Button>
          {footer}
          <Button key="save" variant="primary" onPress={() => save($)}>
            Save
          </Button>
          <Button key="cancel" onPress={() => cancel($)}>
            Cancel
          </Button>
        </Box>
      </Box>
    )
  })
}
