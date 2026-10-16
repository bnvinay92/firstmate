// Pure logic of the fleet-pane mod: everything here reads and returns plain
// values, so tests exercise it without an engine. register.tsx owns every
// effect (the snapshot and GitHub reads, the pane, timers).

import type { DecisionRow, PrRow } from '../types'

// The read-only fleet snapshot (bin/fm-fleet-snapshot.sh owns its contract),
// run with the forge fallback of its per-task state reads off, because this
// mod reads GitHub itself, and with its remote-summary cache pointed at a
// path that can never be created, so the run writes nothing.
export const SNAPSHOT_SCRIPT = 'bin/fm-fleet-snapshot.sh'
export const SNAPSHOT_ENV = {
  FM_CREW_STATE_NO_FORGE: '1',
  FM_SNAPSHOT_CACHE_DIR: '/dev/null/fleet-pane',
} as const
export const SECONDMATE_MARKER = '.fm-secondmate-home'

// How often the pane rereads on its own, and how soon after a read a finished
// turn may start another one.
export const REFRESH_MS = 60 * 1000
export const TURN_REFRESH_MS = 20 * 1000
// GitHub is asked at most this often, unless the set of pull requests changed;
// a little under REFRESH_MS, so each timed read asks it once.
export const GITHUB_MS = 50 * 1000

// A task's pull request, as the snapshot records it.
export type PrRef = {
  task: string
  url: string
  owner: string
  repo: string
  number: number
  // Other backlog items this task still waits on.
  waitsOn: string[]
}

export type PrStatus = {
  title: string
  state: string
  isDraft: boolean
  mergeable: string
  mergeState: string
  reviewDecision: string | null
  checks: { passing: number; failing: number; running: number; failingRequired: number; runningRequired: number; hasRequired: boolean }
}

const PR_URL = /^https:\/\/github\.com\/([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+)\/pull\/(\d+)\/?$/

export function parsePrUrl(url: string): { owner: string; repo: string; number: number } | null {
  const match = PR_URL.exec(url.trim())
  if (match === null) return null
  return { owner: match[1] ?? '', repo: match[2] ?? '', number: Number(match[3]) }
}

const asRecord = (value: unknown): Record<string, unknown> =>
  typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : {}
const asArray = (value: unknown): unknown[] => (Array.isArray(value) ? value : [])
const asString = (value: unknown): string | null => (typeof value === 'string' && value !== '' ? value : null)

// A decision's one-line form: a relayed captain hold leads with its own name,
// which becomes part of the label; whitespace collapses to single spaces.
export function decisionText(task: string, summary: string): { label: string; summary: string } {
  const flat = summary.replace(/\s+/g, ' ').trim()
  const held = /^captain hold ([A-Za-z0-9._-]+):\s*(.*)$/.exec(flat)
  if (held === null) return { label: task, summary: flat }
  return { label: `${task} · ${held[1]}`, summary: held[2] ?? '' }
}

// The first report a decision's text names, such as data/s6-convert/report.md.
export function reportIn(text: string): string | null {
  return /(?:^|[\s(])((?:\/[^\s,;()]+\/)?data\/[^\s,;()]+\/report\.md)/.exec(text)?.[1] ?? null
}

// Every open pull request and every decision waiting on the captain, read from
// one snapshot: a task's recorded pull request, the pull request linked from a
// backlog item that is not done (one whose worker was already cleaned up is
// still watched there), a still-open `needs-decision`
// in a task's status log (the fold the wake drain's OPEN DECISIONS uses, so a
// second mate's relayed captain holds are included), and every backlog item
// held for the captain that is due now. A worker's own blocker is the
// supervisor's to clear, so it is not listed.
export function parseSnapshot(text: string): { prs: PrRef[]; decisions: DecisionRow[] } | null {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return null
  }
  const snapshot = asRecord(raw)
  if (snapshot.schema !== 'fm-fleet-snapshot.v1') return null
  const prs: PrRef[] = []
  const decisions: DecisionRow[] = []
  const seen = new Set<string>()
  for (const entry of asArray(snapshot.tasks)) {
    const task = asRecord(entry)
    const id = asString(task.id)
    if (id === null) continue
    const url = asString(asRecord(task.pr).url)
    const parsed = url === null ? null : parsePrUrl(url)
    if (url !== null && parsed !== null && !seen.has(url)) {
      seen.add(url)
      const waitsOn = asArray(asRecord(task.backlog).unresolved_blocker_ids).filter(
        (one): one is string => typeof one === 'string',
      )
      prs.push({ task: id, url, ...parsed, waitsOn })
    }
    const report = asRecord(asRecord(task.paths).report)
    const ownReport = report.present === true ? asString(report.path) : null
    for (const open of asArray(asRecord(task.hints).open_decisions)) {
      const decision = asRecord(open)
      if (decision.verb !== 'needs-decision') continue
      const summary = asString(decision.summary) ?? ''
      decisions.push({ ...decisionText(id, summary), report: reportIn(summary) ?? ownReport })
    }
  }
  for (const entry of asArray(asRecord(snapshot.backlog).records)) {
    const record = asRecord(entry)
    const id = asString(record.id)
    const url = asString(record.pr_url)
    const parsed = url === null ? null : parsePrUrl(url)
    if (id !== null && record.state !== 'done' && url !== null && parsed !== null && !seen.has(url)) {
      seen.add(url)
      const waitsOn = asArray(record.unresolved_blocker_ids).filter((one): one is string => typeof one === 'string')
      prs.push({ task: id, url, ...parsed, waitsOn })
    }
  }
  for (const entry of asArray(asRecord(snapshot.backlog).records)) {
    const record = asRecord(entry)
    if (record.captain_actionable !== true) continue
    const id = asString(record.id) ?? 'backlog'
    const summary = asString(record.title) ?? asString(record.hold_reason) ?? ''
    decisions.push({ label: id, summary: summary.replace(/\s+/g, ' ').trim(), report: asString(record.report_path) })
  }
  return { prs, decisions }
}

// One GraphQL query for every pull request: each is aliased p<index>, so a
// single call answers the whole list however long it is.
export function prQuery(refs: readonly PrRef[]): string {
  const fields = (n: number) =>
    `title state isDraft mergeable mergeStateStatus reviewDecision commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{__typename ... on CheckRun{status conclusion isRequired(pullRequestNumber:${n})} ... on StatusContext{state isRequired(pullRequestNumber:${n})}}}}}}}`
  const parts = refs.map(
    (ref, i) =>
      `p${i}: repository(owner:${JSON.stringify(ref.owner)}, name:${JSON.stringify(ref.repo)}) { pullRequest(number:${ref.number}) { ${fields(ref.number)} } }`,
  )
  return `query { ${parts.join(' ')} }`
}

const FAILED = new Set(['FAILURE', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE', 'ERROR'])
const RUNNING = new Set(['QUEUED', 'IN_PROGRESS', 'WAITING', 'PENDING', 'REQUESTED', 'EXPECTED'])

// GitHub's answer to prQuery, by pull request URL. A pull request GitHub could
// not answer for (a renamed repository, no access) is left out; the answer
// still counts when only some aliases failed.
export function parsePrStatuses(text: string, refs: readonly PrRef[]): Record<string, PrStatus> {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return {}
  }
  const data = asRecord(asRecord(raw).data)
  const found: Record<string, PrStatus> = {}
  refs.forEach((ref, i) => {
    const pr = asRecord(asRecord(data[`p${i}`]).pullRequest)
    const state = asString(pr.state)
    if (state === null) return
    const checks = { passing: 0, failing: 0, running: 0, failingRequired: 0, runningRequired: 0, hasRequired: false }
    const commit = asRecord(asRecord(asArray(asRecord(pr.commits).nodes)[0]).commit)
    for (const node of asArray(asRecord(asRecord(commit.statusCheckRollup).contexts).nodes)) {
      const check = asRecord(node)
      const isRequired = check.isRequired === true
      if (isRequired) checks.hasRequired = true
      const word = asString(check.__typename === 'StatusContext' ? check.state : check.status === 'COMPLETED' ? check.conclusion : check.status) ?? ''
      if (FAILED.has(word)) {
        checks.failing += 1
        if (isRequired) checks.failingRequired += 1
      } else if (RUNNING.has(word)) {
        checks.running += 1
        if (isRequired) checks.runningRequired += 1
      } else checks.passing += 1
    }
    found[ref.url] = {
      title: asString(pr.title) ?? '',
      state,
      isDraft: pr.isDraft === true,
      mergeable: asString(pr.mergeable) ?? 'UNKNOWN',
      mergeState: asString(pr.mergeStateStatus) ?? 'UNKNOWN',
      reviewDecision: asString(pr.reviewDecision),
      checks,
    }
  })
  return found
}

export function checkSummary(status: PrStatus): string {
  const { passing, failing, running } = status.checks
  if (passing + failing + running === 0) return 'no checks reported'
  const parts: string[] = []
  if (failing > 0) parts.push(`${failing} failing`)
  if (running > 0) parts.push(`${running} running`)
  if (parts.length === 0) return 'passing'
  return parts.join(', ')
}

// What keeps a pull request from merging, most basic first. A repository that
// marks no check required has every check counted, so a failing check there
// still reads as a blocker rather than vanishing.
export function blockersOf(status: PrStatus, waitsOn: readonly string[] = []): string[] {
  const found: string[] = []
  const { checks } = status
  const failing = checks.hasRequired ? checks.failingRequired : checks.failing
  const running = checks.hasRequired ? checks.runningRequired : checks.running
  if (status.isDraft) found.push('still a draft')
  if (status.mergeable === 'CONFLICTING') found.push('merge conflict')
  if (failing > 0) found.push(failing === 1 ? 'a failing check' : `${failing} failing checks`)
  if (running > 0) found.push('checks still running')
  if (status.reviewDecision === 'CHANGES_REQUESTED') found.push('changes requested in review')
  if (status.reviewDecision === 'REVIEW_REQUIRED') found.push('needs an approving review')
  if (status.mergeState === 'BEHIND') found.push('behind its base branch')
  if (waitsOn.length > 0) found.push(`waits on ${waitsOn.join(', ')}`)
  if (found.length === 0) found.push('ready - waiting for your word to merge')
  return found
}

// A pull request's row, or null once it merged or closed. Without an answer
// from GitHub it still shows, saying its status is unknown.
export function prRow(ref: PrRef, status: PrStatus | undefined): PrRow | null {
  if (status === undefined) {
    return { url: ref.url, project: ref.repo, title: ref.task, checks: 'status unknown', blockers: ['GitHub did not answer'] }
  }
  if (status.state !== 'OPEN') return null
  return {
    url: ref.url,
    project: ref.repo,
    title: status.title || ref.task,
    checks: checkSummary(status),
    blockers: blockersOf(status, ref.waitsOn),
  }
}

// Whether GitHub must be asked again: the list of pull requests changed, or
// the last answer is older than GITHUB_MS.
export function isGithubDue(refs: readonly PrRef[], asked: { urls: string; at: number } | null, now: number): boolean {
  if (refs.length === 0) return false
  if (asked === null) return true
  return asked.urls !== refs.map(ref => ref.url).join(' ') || now - asked.at >= GITHUB_MS
}

export function clock(ms: number): string {
  const at = new Date(ms)
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${pad(at.getHours())}:${pad(at.getMinutes())}`
}

// Splits text into the spans of the lines it wraps to: the first fits `first`
// cells and each later one `rest`. Breaks fall at spaces, which the break
// drops; a word longer than a line, such as a URL, is split inside so no line
// runs past the pane's edge. Each span is [start, end) into text.
export function wrapSpans(text: string, first: number, rest: number = first): [number, number][] {
  const spans: [number, number][] = []
  let start = 0
  while (start < text.length) {
    const width = Math.max(1, spans.length === 0 ? first : rest)
    if (text.length - start <= width) {
      spans.push([start, text.length])
      break
    }
    const room = text.lastIndexOf(' ', start + width)
    const end = room > start ? room : start + width
    spans.push([start, end])
    start = end
    while (text[start] === ' ') start++
  }
  return spans.length === 0 ? [[0, 0]] : spans
}
