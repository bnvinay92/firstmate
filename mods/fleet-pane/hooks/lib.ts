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
  title?: string
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
  checks: {
    passing: number
    failing: number
    running: number
    failingRequired: number
    runningRequired: number
    // Required checks the repository names that have not reported on the
    // pull request at all yet, such as one a later CI job creates.
    missingRequired: number
    // Whether the base branch's rules were read and named required checks:
    // 'some' when they did, 'none' when they named none, and 'unknown' when
    // GitHub did not answer for them.
    required: 'some' | 'none' | 'unknown'
  }
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

// Labels are bounded and never carry prose, newlines or terminal controls.
export function shortLine(text: string, limit = 100): string {
  const flat = text.replace(/[\s\u0000-\u001f\u007f-\u009f]+/g, ' ').trim()
  const chars = Array.from(flat)
  if (chars.length <= limit) return flat
  if (limit < 2) return limit > 0 ? '…' : ''
  const head = chars.slice(0, limit - 1).join('')
  const space = head.lastIndexOf(' ')
  return `${(space > head.length / 2 ? head.slice(0, space) : head).trimEnd()}…`
}

const humanTitle = (key: string) => key.replace(/[-_]+/g, ' ')

// A hold's name or explicit title identifies the call; its reason is detail.
export function decisionText(task: string, summary: string, title?: string, key?: string): { label: string; summary: string } {
  const held = /^captain hold ([A-Za-z0-9._-]+):/.exec(summary.trim())
  const name = held?.[1]
  return {
    label: shortLine(name === undefined ? task : `${task} · ${name}`),
    summary: shortLine(title || humanTitle(name ?? (key === 'default' ? task : key) ?? task)),
  }
}

// A report or plan named by a decision, before its first web detail link.
export function reportIn(text: string): string | null {
  return /(?:^|[\s(])((?:\/[^\s,;()]+\/)?data\/[^\s,;()]+\.md)/.exec(text)?.[1] ?? null
}

function detailIn(text: string): string | null {
  return reportIn(text) ?? /https?:\/\/[^\s<>]+/.exec(text)?.[0]?.replace(/[.,;)]+$/, '') ?? null
}

// Structured secondmate decisions supply short titles; keyed parent relays
// fill any gaps. Keep legacy snapshots readable, and never invent a PR from
// a bare number or a decision from reason prose.
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
  const seenPrs = new Map<string, PrRef>()
  const seenDecisions = new Map<string, DecisionRow>()
  const mates = new Map<string, Record<string, unknown>>()
  const addPr = (task: string, candidate: unknown, waits: unknown, title?: unknown) => {
    const parsed = typeof candidate === 'string' ? parsePrUrl(candidate) : null
    if (parsed === null) return
    const url = `https://github.com/${parsed.owner}/${parsed.repo}/pull/${parsed.number}`
    const waitsOn = asArray(waits).filter((one): one is string => typeof one === 'string')
    const existing = seenPrs.get(url.toLowerCase())
    if (existing !== undefined) {
      existing.waitsOn = [...new Set([...existing.waitsOn, ...waitsOn])]
      return
    }
    const name = asString(title)
    const ref = { task, url, ...parsed, waitsOn, ...(name === null ? {} : { title: shortLine(name) }) }
    seenPrs.set(url.toLowerCase(), ref)
    prs.push(ref)
  }
  const addDecision = (scope: string, id: string, key: string, title: string, report: string | null) => {
    const identity = `${scope}/${id}/${key}`
    const existing = seenDecisions.get(identity)
    if (existing !== undefined) {
      if (report !== null && (existing.report === null || existing.report.endsWith('/data/backlog.md'))) existing.report = report
      return
    }
    const row = { label: shortLine(scope ? `${scope} · ${id}` : id), summary: shortLine(title), report }
    seenDecisions.set(identity, row)
    decisions.push(row)
  }
  for (const entry of asArray(asRecord(snapshot.secondmate_current).records)) {
    const mate = asRecord(entry)
    const scope = asString(mate.id)
    if (scope === null || asRecord(mate.provenance).selected !== 'structured-home') continue
    mates.set(scope, mate)
    for (const entry of asArray(mate.decisions_open)) {
      const decision = asRecord(entry)
      if (decision.verb !== 'needs-decision' && decision.verb !== 'captain-hold') continue
      const id = asString(decision.id) ?? scope
      const key = asString(decision.key) ?? id
      const title = asString(decision.title) ?? (decision.source === 'backlog' ? asString(decision.summary) : null) ?? humanTitle(id)
      const detail = asString(decision.report_path) ?? detailIn(asString(decision.reason) ?? '') ?? detailIn(asString(decision.summary) ?? '')
      const home = asString(mate.home)
      for (const url of (asString(decision.summary) ?? '').match(/https:\/\/github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\/pull\/\d+/g) ?? []) addPr(id, url, [])
      addDecision(scope, id, decision.verb === 'captain-hold' ? 'hold' : key, title,
        detail !== null && detail.startsWith('data/') && home !== null ? `${home}/${detail}` : detail ?? (home === null ? null : (decision.source === 'status' ? `${home}/state/${id}.status` : `${home}/data/backlog.md`)))
    }
  }
  for (const entry of asArray(snapshot.tasks)) {
    const task = asRecord(entry)
    const id = asString(task.id)
    if (id === null) continue
    const backlog = asRecord(task.backlog)
    const pr = asRecord(task.pr)
    for (const url of [pr.url, ...asArray(pr.urls)]) addPr(id, url, backlog.unresolved_blocker_ids, backlog.title)
    const report = asRecord(asRecord(task.paths).report)
    const ownReport = report.present === true ? asString(report.path) : null
    for (const open of asArray(asRecord(task.hints).open_decisions)) {
      const decision = asRecord(open)
      if (decision.verb !== 'needs-decision') continue
      const summary = asString(decision.summary) ?? ''
      const held = /^captain hold ([A-Za-z0-9._-]+):/.exec(summary.trim())?.[1]
      const key = asString(decision.key) ?? 'default'
      const detail = detailIn(summary) ?? ownReport ?? asString(asRecord(asRecord(task.paths).status_log).path)
      const home = asString(mates.get(id)?.home) ?? (task.kind === 'secondmate' ? asString(asRecord(asRecord(task.paths).home).path) : null)
      const resolvedDetail = detail !== null && detail.startsWith('data/') && home !== null ? `${home}/${detail}` : detail
      if (held !== undefined) {
        addDecision(id, held, 'hold', humanTitle(held), resolvedDetail)
      } else {
        const title = asString(decision.title) ?? (key === 'default' ? asString(backlog.title) ?? id : humanTitle(key))
        addDecision('', id, key, title, resolvedDetail)
      }
    }
  }
  for (const entry of asArray(asRecord(snapshot.backlog).records)) {
    const record = asRecord(entry)
    const id = asString(record.id) ?? 'backlog'
    for (const url of [record.pr_url, ...asArray(record.links)]) addPr(id, url, record.unresolved_blocker_ids, record.title)
    if (record.captain_actionable !== true) continue
    addDecision('', id, 'hold', asString(record.title) ?? humanTitle(id), asString(record.report_path) ?? detailIn(asString(record.hold_reason) ?? '') ?? asString(asRecord(snapshot.backlog).path))
  }
  return { prs, decisions }
}

// Historical task logs retain merged PRs. Discover state cheaply before asking
// for expensive check contexts and branch rules on the open subset only.
export function prStateQuery(refs: readonly PrRef[]): string {
  return `query { ${refs.map((ref, i) => `p${i}: repository(owner:${JSON.stringify(ref.owner)}, name:${JSON.stringify(ref.repo)}) { pullRequest(number:${ref.number}) { title state } }`).join(' ')} }`
}

// One GraphQL query for every pull request: each is aliased p<index>, so a
// single call answers the whole list however long it is. The base branch's
// rulesets and protection name the required checks, including ones that have
// not reported on the pull request yet.
export function prQuery(refs: readonly PrRef[]): string {
  const fields = (n: number) =>
    `title state isDraft mergeable mergeStateStatus reviewDecision baseRef{branchProtectionRule{requiredStatusCheckContexts} rules(first:100){nodes{type parameters{... on RequiredStatusChecksParameters{requiredStatusChecks{context}}}}}} commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{__typename ... on CheckRun{name status conclusion isRequired(pullRequestNumber:${n})} ... on StatusContext{context state isRequired(pullRequestNumber:${n})}}}}}}}`
  const parts = refs.map(
    (ref, i) =>
      `p${i}: repository(owner:${JSON.stringify(ref.owner)}, name:${JSON.stringify(ref.repo)}) { pullRequest(number:${ref.number}) { ${fields(ref.number)} } }`,
  )
  return `query { ${parts.join(' ')} }`
}

const FAILED = new Set(['FAILURE', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE', 'ERROR'])
const RUNNING = new Set(['QUEUED', 'IN_PROGRESS', 'WAITING', 'PENDING', 'REQUESTED', 'EXPECTED'])

// The check names a base branch requires, from its rulesets and protection,
// or null when GitHub did not answer for them (the branch is gone, or reading
// its rules failed).
function requiredContexts(baseRef: unknown, failed: boolean): Set<string> | null {
  if (failed || typeof baseRef !== 'object' || baseRef === null) return null
  const base = asRecord(baseRef)
  const rules = asRecord(base.rules).nodes
  if (!Array.isArray(rules)) return null
  const names = new Set<string>()
  for (const node of rules) {
    const rule = asRecord(node)
    if (rule.type !== 'REQUIRED_STATUS_CHECKS') continue
    for (const one of asArray(asRecord(rule.parameters).requiredStatusChecks)) {
      const context = asString(asRecord(one).context)
      if (context !== null) names.add(context)
    }
  }
  for (const one of asArray(asRecord(base.branchProtectionRule).requiredStatusCheckContexts)) {
    if (typeof one === 'string' && one !== '') names.add(one)
  }
  return names
}

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
  // Aliases whose base-branch rules GitHub reported an error for.
  const rulesFailed = new Set<unknown>()
  for (const error of asArray(asRecord(raw).errors)) {
    const path = asArray(asRecord(error).path)
    if (path.includes('baseRef')) rulesFailed.add(path[0])
  }
  const found: Record<string, PrStatus> = {}
  refs.forEach((ref, i) => {
    const pr = asRecord(asRecord(data[`p${i}`]).pullRequest)
    const state = asString(pr.state)
    if (state === null) return
    const named = requiredContexts(pr.baseRef, rulesFailed.has(`p${i}`))
    const unreported = new Set(named ?? [])
    const checks: PrStatus['checks'] = { passing: 0, failing: 0, running: 0, failingRequired: 0, runningRequired: 0, missingRequired: 0, required: 'none' }
    const commit = asRecord(asRecord(asArray(asRecord(pr.commits).nodes)[0]).commit)
    for (const node of asArray(asRecord(asRecord(commit.statusCheckRollup).contexts).nodes)) {
      const check = asRecord(node)
      const name = asString(check.__typename === 'StatusContext' ? check.context : check.name)
      if (name !== null) unreported.delete(name)
      const isRequired = check.isRequired === true || (name !== null && named?.has(name) === true)
      if (isRequired) checks.required = 'some'
      const word = asString(check.__typename === 'StatusContext' ? check.state : check.status === 'COMPLETED' ? check.conclusion : check.status) ?? ''
      if (FAILED.has(word)) {
        checks.failing += 1
        if (isRequired) checks.failingRequired += 1
      } else if (RUNNING.has(word)) {
        checks.running += 1
        if (isRequired) checks.runningRequired += 1
      } else checks.passing += 1
    }
    if (named === null) checks.required = 'unknown'
    else if (named.size > 0) checks.required = 'some'
    checks.missingRequired = unreported.size
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

// What keeps a pull request from merging, most basic first. Only required
// checks block when the base branch names some; a repository that marks no
// check required, or whose rules GitHub did not answer for, has every check
// counted, so a failing or running check there still reads as a blocker
// rather than vanishing. A required check that has not reported yet blocks,
// and a pull request GitHub itself reports blocked is never called ready.
export function blockersOf(status: PrStatus, waitsOn: readonly string[] = []): string[] {
  const found: string[] = []
  const { checks } = status
  const onlyRequired = checks.required === 'some'
  const failing = onlyRequired ? checks.failingRequired : checks.failing
  const running = onlyRequired ? checks.runningRequired : checks.running
  const missing = onlyRequired ? checks.missingRequired : 0
  if (status.isDraft) found.push('still a draft')
  if (status.mergeable === 'CONFLICTING') found.push('merge conflict')
  if (failing > 0) found.push(failing === 1 ? 'a failing check' : `${failing} failing checks`)
  if (running > 0) found.push('checks still running')
  if (missing > 0) found.push(missing === 1 ? 'a required check not reported yet' : `${missing} required checks not reported yet`)
  if (status.reviewDecision === 'CHANGES_REQUESTED') found.push('changes requested in review')
  if (status.reviewDecision === 'REVIEW_REQUIRED') found.push('needs an approving review')
  if (status.mergeState === 'BEHIND') found.push('behind its base branch')
  if (waitsOn.length > 0) found.push(`waits on ${waitsOn.join(', ')}`)
  if (found.length === 0 && status.mergeState === 'BLOCKED') found.push('GitHub reports it blocked')
  if (found.length === 0) found.push('ready - waiting for your word to merge')
  return found
}

// A pull request's row, or null once it merged or closed. Without an answer
// from GitHub it still shows, saying its status is unknown.
export function prRow(ref: PrRef, status: PrStatus | undefined): PrRow | null {
  if (status === undefined) {
    return { url: ref.url, project: ref.repo, title: shortLine(ref.title ?? ref.task), checks: 'status unknown', blockers: ['GitHub did not answer'] }
  }
  if (status.state !== 'OPEN') return null
  return {
    url: ref.url,
    project: ref.repo,
    title: shortLine(status.title || ref.title || ref.task),
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
