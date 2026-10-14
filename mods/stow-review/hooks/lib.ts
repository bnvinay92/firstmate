// Pure logic of the stow-review mod: everything here reads and returns plain
// values, so tests exercise it without an engine. register.tsx owns every
// effect (files, commands, panes, timers).

import type {
  StowApplied,
  StowHomePlan,
  StowItem,
  StowReading,
  StowReview,
  StowSection,
} from '../types'

// A home's published context fill: <home>/state/stow-context.json, written by
// the mod in that home's own session and read by the main session's mod.
//   {"version":1,"tokens":<n>,"window":<n>,"at":<ms>}
export const CONTEXT_FILE = 'state/stow-context.json'
export const REVIEW_FILE = 'state/stow-review.json'
export const APPROVED_FILE = 'state/stow-review.approved.json'
export const APPLIED_FILE = 'state/stow-applied.json'
export const SECONDMATE_MARKER = '.fm-secondmate-home'
export const REGISTRY_FILE = 'data/secondmates.md'

// A reading older than this is reported stale and never triggers a stow.
export const STALE_MS = 5 * 60 * 1000
// How often a session republishes an unchanged reading, so it stays fresh.
export const REFRESH_MS = 60 * 1000
// A round that never ends (no plan, no apply) stops holding the band after this.
export const ROUND_TIMEOUT_MS = 45 * 60 * 1000

export const SECTIONS: readonly StowSection[] = ['memory', 'offload', 'knowledge', 'records']

export const SECTION_LABELS: Record<StowSection, string> = {
  memory: 'Startup-memory tiers',
  offload: 'Over-budget offload',
  knowledge: 'Knowledge routing',
  records: 'Open-record persistence',
}

export const keyOf = (home: string, id: string): string => `${home}/${id}`

export function formatTokens(tokens: number): string {
  if (tokens >= 1_000_000) return `${(tokens / 1_000_000).toFixed(1)}M`
  if (tokens >= 1000) return `${Math.round(tokens / 1000)}k`
  return String(tokens)
}

// Local secondmate routes from data/secondmates.md; a remote route has no
// readable home here, so it is left out.
export function parseRegistry(text: string): { id: string; home: string }[] {
  const found: { id: string; home: string }[] = []
  for (const line of text.split('\n')) {
    const id = /^- ([A-Za-z0-9._-]+) - /.exec(line)?.[1]
    if (id === undefined || /\(host:/.test(line)) continue
    const home = /\(home:\s*([^;)]*?)\s*;/.exec(line)?.[1]
    if (home !== undefined && home.startsWith('/')) found.push({ id, home })
  }
  return found
}

export function parseReading(home: string, text: string, now: number): StowReading | null {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return null
  }
  if (typeof raw !== 'object' || raw === null) return null
  const { tokens, window, at } = raw as Record<string, unknown>
  if (typeof tokens !== 'number' || typeof window !== 'number' || typeof at !== 'number') return null
  return { home, tokens, window, at, isStale: now - at > STALE_MS }
}

export const isOver = (reading: StowReading, threshold: number): boolean =>
  !reading.isStale && reading.tokens >= threshold

// Auto fires for a home once as it crosses the threshold, and is armed for it
// again only once a fresh reading shows it back under (after a clear). A stale
// reading neither fires nor re-arms.
export function crossings(
  readings: readonly StowReading[],
  threshold: number,
  fired: readonly string[],
): { fire: string[]; fired: string[] } {
  const next = new Set(fired)
  const fire: string[] = []
  for (const reading of readings) {
    if (reading.isStale) continue
    if (reading.tokens < threshold) next.delete(reading.home)
    else if (!next.has(reading.home)) {
      fire.push(reading.home)
      next.add(reading.home)
    }
  }
  return { fire, fired: [...next] }
}

// The command the main session's agent runs to start a round: --mod marks a
// round this mod reviews and clears; --auto saves everything without review.
export function draftArgs(homes: readonly string[], isAuto: boolean): string {
  return `draft --mod${isAuto ? ' --auto' : ''} --homes ${homes.join(',')}`
}

export function parseReview(text: string): StowReview | null {
  try {
    const raw = JSON.parse(text) as StowReview
    return raw.version === 1 && Array.isArray(raw.homes) ? raw : null
  } catch {
    return null
  }
}

export function parseApplied(text: string): StowApplied | null {
  try {
    const raw = JSON.parse(text) as StowApplied
    return raw.version === 1 && typeof raw.at === 'number' && Array.isArray(raw.homes) ? raw : null
  } catch {
    return null
  }
}

// One drawn row of the review: home, then section, then target, then items,
// the same order bin/fm-stow-plan.sh show numbers.
export type ReviewRow =
  | { kind: 'home'; home: string }
  | { kind: 'section'; home: string; section: StowSection }
  | { kind: 'target'; home: string; target: string }
  | { kind: 'item'; home: string; item: StowItem }

export function reviewRows(review: StowReview): ReviewRow[] {
  const rows: ReviewRow[] = []
  for (const plan of review.homes) {
    rows.push({ kind: 'home', home: plan.home })
    for (const section of SECTIONS) {
      const inSection = plan.items.filter(item => item.section === section)
      if (inSection.length === 0) continue
      rows.push({ kind: 'section', home: plan.home, section })
      const targets = [...new Set(inSection.map(item => item.target))]
      for (const target of targets) {
        rows.push({ kind: 'target', home: plan.home, target })
        for (const item of inSection.filter(one => one.target === target)) {
          rows.push({ kind: 'item', home: plan.home, item })
        }
      }
    }
  }
  return rows
}

export function countItems(review: StowReview): number {
  return review.homes.reduce((sum, plan) => sum + plan.items.length, 0)
}

// Pages of at most `room` rows; a page never starts with a lone heading that
// has none of its items under it, because headings are repeated per page.
export function pageOf(rows: readonly ReviewRow[], room: number, page: number): { rows: ReviewRow[]; pages: number } {
  const size = Math.max(4, room)
  const pages: ReviewRow[][] = []
  let current: ReviewRow[] = []
  let heads: ReviewRow[] = []
  for (const row of rows) {
    if (row.kind !== 'item') {
      heads = row.kind === 'home' ? [row] : row.kind === 'section' ? [heads[0] ?? row, row] : [...heads.slice(0, 2), row]
      continue
    }
    if (current.length === 0 || current.length >= size) {
      if (current.length > 0) pages.push(current)
      current = [...heads]
    } else {
      for (const head of heads) if (!current.includes(head)) current.push(head)
    }
    current.push(row)
  }
  if (current.length > 0) pages.push(current)
  const total = Math.max(1, pages.length)
  const index = Math.min(Math.max(0, page), total - 1)
  return { rows: pages[index] ?? [], pages: total }
}

// The hand-off the agent applies: only the ticked items, each entry as edited
// (a blank edit keeps the drafted wording; a removal's text never changes).
export function approvedReview(
  review: StowReview,
  ticks: Readonly<Record<string, boolean>>,
  edits: Readonly<Record<string, string>>,
): StowReview {
  const homes: StowHomePlan[] = []
  for (const plan of review.homes) {
    const items: StowItem[] = []
    for (const item of plan.items) {
      const key = keyOf(plan.home, item.id)
      if (ticks[key] === false) continue
      const edited = (edits[key] ?? '').replace(/[\r\n]+/g, ' ').trim()
      items.push(item.action === 'remove' || edited === '' ? item : { ...item, entry: edited })
    }
    if (items.length > 0) homes.push({ home: plan.home, items })
  }
  return { version: 1, homes }
}

export function appliedSummary(applied: StowApplied): string {
  if (applied.homes.length === 0) return 'nothing to save'
  return applied.homes
    .map(plan => `${plan.home} ${plan.items.length} item${plan.items.length === 1 ? '' : 's'}`)
    .join(', ')
}
