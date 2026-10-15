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
  prRow,
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
  const ran = await $.process.run(['gh', 'api', 'graphql', '-f', `query=${prQuery(refs)}`], { timeoutMs: 20_000 })
  const found = parsePrStatuses(ran.stdout, refs)
  asked = { urls: refs.map(ref => ref.url).join(' '), at: now }
  statuses = found
  return Object.keys(found).length === 0 && ran.exitCode !== 0 ? 'GitHub could not be read just now.' : null
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
    const { Box, Text } = $.ui.resolve(e)
    const shown = await read($, view)
    const pane = (...children: RenderChildren[]) => (
      <Box flexDirection="column" backgroundColor={BACKGROUND}>
        {children}
      </Box>
    )
    if (shown.at === null) {
      return pane(
        <Text key="wait" color={TEXT}>
          {shown.problem ?? 'Reading pull requests and decisions...'}
        </Text>,
      )
    }
    return pane(
      <Text key="prs" bold color={TEXT}>
        Open pull requests ({shown.prs.length})
      </Text>,
      shown.prs.length === 0 ? (
        <Text key="no-prs" color={TEXT}>
          {'  '}None open.
        </Text>
      ) : (
        shown.prs.map(pr => (
          <Box key={`pr:${pr.url}`} flexDirection="column">
            <Text color={TEXT} wrap="truncate-end">
              {'  '}
              {pr.project}: {pr.title}
            </Text>
            <Text color={LINK} wrap="truncate-end">
              {'    '}
              {pr.url}
            </Text>
            <Text color={TEXT} wrap="truncate-end">
              {'    '}checks {pr.checks} -{' '}
              <Text color={pr.blockers[0]?.startsWith('ready') === true ? READY : WAIT}>{pr.blockers.join('; ')}</Text>
            </Text>
          </Box>
        ))
      ),
      <Text key="gap" color={TEXT}>
        {' '}
      </Text>,
      <Text key="decisions" bold color={TEXT}>
        Decisions waiting for you ({shown.decisions.length})
      </Text>,
      shown.decisions.length === 0 ? (
        <Text key="no-decisions" color={TEXT}>
          {'  '}None.
        </Text>
      ) : (
        shown.decisions.map((one, i) => (
          <Box key={`decision:${i}:${one.label}`} flexDirection="column">
            <Text color={TEXT} wrap="truncate-end">
              {'  '}
              <Text bold color={TEXT}>
                {one.label}
              </Text>
              : {one.summary}
            </Text>
            {one.report !== null && (
              <Text color={LINK} wrap="truncate-end">
                {'    '}report {one.report}
              </Text>
            )}
          </Box>
        ))
      ),
      <Text key="gap2" color={TEXT}>
        {' '}
      </Text>,
      <Text key="at" color={TEXT}>
        Updated {clock(shown.at)}, every minute and after each reply.{shown.problem === null ? '' : ` ${shown.problem}`}
      </Text>,
    )
  })
}
