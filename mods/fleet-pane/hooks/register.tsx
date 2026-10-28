import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderChildren } from 'claude-code'

import type { FleetView, PaneSite } from '../types'
import {
  REFRESH_MS,
  SECONDMATE_MARKER,
  SNAPSHOT_ENV,
  SNAPSHOT_SCRIPT,
  TURN_REFRESH_MS,
  clock,
  isGithubDue,
  parsePrStatuses,
  parseSnapshot,
  prQuery,
  prStateQuery,
  prRow,
  shortLine,
} from './lib'
import type { PrRef, PrStatus } from './lib'

type Engine = EngineInterface

const PANE = 'fleet-pane'
const TITLE = 'Pull requests and decisions'

// The pane's colours, every one a theme key so it follows the theme in force:
// a run left uncoloured takes the terminal's default foreground instead,
// which a dark theme in a light terminal draws dark on the pane's dark grey.
const TEXT = 'text'
const LINK = 'suggestion'
const WAIT = 'warning'
const READY = 'success'
const BACKGROUND = 'composerSidebarBackground'

// The pane's width when a surface hands none, as at its narrowest seat.
const FALLBACK_COLUMNS = 40

const EMPTY: FleetView = { prs: [], decisions: [], at: null, problem: null }

const view = atom({ plugin: 'fleet-pane', key: 'view' } as const, EMPTY)

async function exists($: Engine, path: string): Promise<boolean> {
  try {
    return await $.fs.exists(path)
  } catch {
    return false
  }
}

// The main Firstmate home: FM_HOME when set, else the session's root, holding
// state/ beside a code root with the snapshot script. A second mate's home
// or any other folder leaves the mod idle.
async function detectSite($: Engine): Promise<PaneSite | null> {
  const root = await $.session.root()
  const home = (await $.env.get('FM_HOME')) || root
  if (!(await exists($, `${home}/state`))) return null
  if (await exists($, `${home}/${SECONDMATE_MARKER}`)) return null
  for (const code of [root, home]) {
    if (await exists($, `${code}/${SNAPSHOT_SCRIPT}`)) return { home, root: code }
  }
  return null
}

// The home this process runs in, kept by the module rather than in $.state: a
// /clear goes on under a new session whose $.state starts empty and raises no
// session.start, while the module and its timers run on.
let site: PaneSite | null = null

// What GitHub last said, kept by the module so a render never asks it; a hot
// reload starts it over, which costs one early read.
let asked: { urls: string; at: number } | null = null
let statuses: Record<string, PrStatus> = {}
let isReading = false

async function askGithub($: Engine, refs: PrRef[], now: number): Promise<string | null> {
  if (!isGithubDue(refs, asked, now)) return null
  const states = await $.process.run(['gh', 'api', 'graphql', '-f', `query=${prStateQuery(refs)}`], { timeoutMs: 20_000 })
  const known = parsePrStatuses(states.stdout, refs)
  const open = refs.filter(ref => known[ref.url]?.state === 'OPEN')
  const closed = Object.fromEntries(Object.entries(known).filter(([, status]) => status.state !== 'OPEN'))
  let found: Record<string, PrStatus> = {}
  if (open.length > 0) {
    const ran = await $.process.run(['gh', 'api', 'graphql', '-f', `query=${prQuery(open)}`], { timeoutMs: 20_000 })
    found = parsePrStatuses(ran.stdout, open)
  }
  asked = { urls: refs.map(ref => ref.url).join(' '), at: now }
  statuses = { ...closed, ...found }
  return Object.keys(statuses).length < refs.length ? 'Some GitHub statuses could not be read just now.' : null
}

// Reread the snapshot and, when due, GitHub, then redraw. One read at a time;
// a failed read keeps the last good rows and says what failed.
async function refresh($: Engine): Promise<void> {
  const where = site
  if (isReading || where === null) return
  isReading = true
  try {
    const ran = await $.process.run([`${where.root}/${SNAPSHOT_SCRIPT}`, '--json'], {
      env: { FM_HOME: where.home, ...SNAPSHOT_ENV },
      timeoutMs: 90_000,
    })
    const snapshot = parseSnapshot(ran.stdout)
    const now = await $.clock.now()
    if (snapshot === null) {
      await update($, view, old => ({ ...old, problem: 'The task records could not be read just now.' }))
      return
    }
    let problem: string | null = null
    try {
      problem = await askGithub($, snapshot.prs, now)
    } catch {
      problem = 'GitHub could not be read just now.'
    }
    const prs = snapshot.prs.flatMap(ref => prRow(ref, statuses[ref.url]) ?? [])
    await update($, view, () => ({ prs, decisions: snapshot.decisions, at: now, problem }))
  } catch {
    await update($, view, old => ({ ...old, problem: 'The task records could not be read just now.' }))
  } finally {
    isReading = false
  }
}

// Opened unasked, the pane never takes the keyboard; /fleet-pane asks for it.
async function openPane($: Engine, isAsked: boolean): Promise<void> {
  await $.ui.open(isAsked ? { id: PANE, title: TITLE, focus: true } : { id: PANE, title: TITLE })
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    site = await detectSite($)
    if (site !== null) {
      await $.command.register({ name: 'fleet-pane', description: 'Show open pull requests and decisions waiting on you' })
      if ((await $.store.get('isHidden')) !== true) void openPane($, false)
      $.clock.every(REFRESH_MS, () => {
        void refresh($)
      })
      $.clock.after(10, () => {
        void refresh($)
      })
    }
    return next(e)
  })

  // A /clear leaves the new session's view empty: read again at once rather
  // than at the next minute.
  on('session.end', async ($, e, next) => {
    if (e.reason === 'clear' && site !== null) {
      $.clock.after(10, () => {
        void refresh($)
      })
    }
    return next(e)
  })

  // A finished turn is the cheap trigger: it rereads when the last read is
  // older than TURN_REFRESH_MS, and GitHub is still asked about once a minute.
  on('turn.complete', async ($, e, next) => {
    const ran = await next(e)
    if (e.agentId === undefined) {
      const { at } = await read($, view)
      if (at === null || (await $.clock.now()) - at >= TURN_REFRESH_MS) void refresh($)
    }
    return ran
  })

  on('command.run', { command: 'fleet-pane' }, async $ => {
    await $.store.set('isHidden', false)
    site = (await detectSite($)) ?? site
    await openPane($, true)
    $.clock.after(10, () => {
      void refresh($)
    })
    return { text: 'Pull requests and decisions pane opened.' }
  })

  // Closing the pane by hand keeps it closed in later sessions until
  // /fleet-pane opens it again.
  on('ui.close', { id: PANE }, async ($, e, next) => {
    if (e.origin.kind === 'person') await $.store.set('isHidden', true).catch(() => undefined)
    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Link } = $.ui.resolve(e)
    const shown = await read($, view)
    const pane = (...children: RenderChildren[]) => (
      <Box flexDirection="column" backgroundColor={BACKGROUND}>
        {children}
      </Box>
    )
    // One physical line per item. Link targets remain whole when the visible
    // label is ellipsized, including local report paths on the terminal.
    const width = e.props.bodyColumns > 0 ? e.props.bodyColumns : FALLBACK_COLUMNS
    const row = (key: string, label: string, href: string | null = null, color = TEXT, bold = false) => {
      const title = shortLine(label, Math.max(1, width - 2))
      const target = href?.startsWith('/') ? `file://${encodeURI(href)}` : href?.startsWith('data/') && site !== null ? `file://${encodeURI(`${site.home}/${href}`)}` : href
      return (
        <Text key={key} color={color} bold={bold} wrap="truncate-end">
          {'  '}{target === null ? title : <Link href={target}>{title}</Link>}
        </Text>
      )
    }

    if (shown.at === null) {
      return pane(row('wait', shown.problem ?? 'Reading pull requests and decisions...'))
    }
    return pane(
      row('prs', `Open pull requests (${shown.prs.length})`, null, TEXT, true),
      shown.prs.length === 0
        ? row('no-prs', 'None open.')
        : shown.prs.map(pr => row(`pr:${pr.url}`, `${pr.project}: ${pr.title} · ${pr.checks} · ${pr.blockers.join('; ')}`, pr.url,
            pr.blockers[0]?.startsWith('ready') === true ? READY : WAIT)),
      row('decisions', `Decisions waiting for you (${shown.decisions.length})`, null, TEXT, true),
      shown.decisions.length === 0
        ? row('no-decisions', 'None.')
        : shown.decisions.map((one, i) => row(`decision:${i}`, `${one.label}: ${one.summary}`, one.report, LINK)),
      row('updated', `Updated ${clock(shown.at)}, every minute and after each reply.`),
      shown.problem === null ? null : row('problem', shown.problem, null, WAIT),
    )
  })
}
