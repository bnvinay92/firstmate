import { describe, expect, test } from 'claude-code/testing'

import type { StowItem, StowReview } from '../types'
import {
  approvedReview,
  crossings,
  draftArgs,
  isEntryCut,
  itemHeight,
  pageOf,
  parseReading,
  parseRegistry,
  reviewRows,
} from '../hooks/lib'

const REVIEW: StowReview = {
  version: 1,
  homes: [
    {
      home: 'main',
      items: [
        { id: 'k1', section: 'knowledge', action: 'add', target: 'data/captain.md', entry: '- likes short PRs' },
        { id: 'm1', section: 'memory', action: 'rewrite', target: 'data/learnings.md', entry: '- new', replaces: '- old' },
        { id: 'm2', section: 'memory', action: 'remove', target: 'data/learnings.md', entry: '- dup', replaces: '- dup' },
      ],
    },
    {
      home: 'mate-a',
      items: [{ id: 'r1', section: 'records', action: 'record', target: 'backlog', entry: 'file: flaky test' }],
    },
  ],
}

describe('the review layout', () => {
  test('groups by home, then stow section, then target file', async () => {
    const rows = reviewRows(REVIEW).map(row =>
      row.kind === 'item' ? `item ${row.item.id}` : row.kind === 'home' ? `home ${row.home}` : row.kind === 'section' ? `section ${row.section}` : `target ${row.target}`,
    )
    expect(rows).toEqual([
      'home main',
      'section memory',
      'target data/learnings.md',
      'item m1',
      'item m2',
      'section knowledge',
      'target data/captain.md',
      'item k1',
      'home mate-a',
      'section records',
      'target backlog',
      'item r1',
    ])
  })

  test('every page repeats the headings its items sit under', async () => {
    const second = pageOf(reviewRows(REVIEW), 4, 1).rows
    expect(second[0]).toMatchObject({ kind: 'home' })
    expect(second.some(row => row.kind === 'item')).toBe(true)
    expect(pageOf(reviewRows(REVIEW), 100, 0).pages).toBe(1)
  })

  test('a long entry counts every row its wrapped full text takes', async () => {
    const short: StowItem = { id: 's', section: 'memory', action: 'add', target: 't', entry: '- short' }
    const long: StowItem = { ...short, id: 'l', entry: `- ${'word '.repeat(60)}` }
    expect(isEntryCut(short.entry, short.action, 80)).toBe(false)
    expect(isEntryCut(long.entry, long.action, 80)).toBe(true)
    expect(isEntryCut('- one\n- two', 'add', 80)).toBe(true)
    expect(itemHeight(short, 80)).toBe(1)
    // Its row, then 302 characters wrapped at 74 columns.
    expect(itemHeight(long, 80)).toBe(1 + 5)
    const tall: StowReview = { version: 1, homes: [{ home: 'main', items: [long, short] }] }
    const heightOf = (row: ReturnType<typeof reviewRows>[number]) => (row.kind === 'item' ? itemHeight(row.item, 80) : 1)
    expect(pageOf(reviewRows(tall), 9, 0).pages).toBe(1)
    expect(pageOf(reviewRows(tall), 9, 0, heightOf).pages).toBe(2)
  })
})

describe('the approved hand-off', () => {
  test('keeps only ticked items, in their edited wording', async () => {
    const approved = approvedReview(
      REVIEW,
      { 'main/k1': false, 'mate-a/r1': false },
      { 'main/m1': '  - newer\n', 'main/m2': '- changed removal' },
    )
    expect(approved).toEqual({
      version: 1,
      homes: [
        {
          home: 'main',
          items: [
            { id: 'm1', section: 'memory', action: 'rewrite', target: 'data/learnings.md', entry: '- newer', replaces: '- old' },
            { id: 'm2', section: 'memory', action: 'remove', target: 'data/learnings.md', entry: '- dup', replaces: '- dup' },
          ],
        },
      ],
    })
  })

  test('a blank edit keeps the drafted wording', async () => {
    const approved = approvedReview(REVIEW, {}, { 'main/k1': '   ' })
    expect(approved.homes[0]?.items[0]?.entry).toBe('- likes short PRs')
  })
})

describe('thresholds and Auto', () => {
  test('a stale reading is marked and a fresh one is not', async () => {
    const text = JSON.stringify({ version: 1, tokens: 250_000, window: 1_000_000, at: 1000 })
    expect(parseReading('mate-a', text, 1000 + 60_000)?.isStale).toBe(false)
    expect(parseReading('mate-a', text, 1000 + 10 * 60_000)?.isStale).toBe(true)
    expect(parseReading('mate-a', 'not json', 0)).toBeNull()
  })

  test('Auto fires once per crossing and re-arms only below the threshold', async () => {
    const over = { home: 'main', tokens: 210_000, window: 1_000_000, at: 0, isStale: false }
    const under = { ...over, tokens: 20_000 }
    const first = crossings([over], 200_000, [])
    expect(first.fire).toEqual(['main'])
    const again = crossings([over], 200_000, first.fired)
    expect(again.fire).toEqual([])
    const stale = crossings([{ ...under, isStale: true }], 200_000, again.fired)
    expect(stale.fired).toEqual(['main'])
    const cleared = crossings([under], 200_000, again.fired)
    expect(cleared.fired).toEqual([])
    expect(crossings([over], 200_000, cleared.fired).fire).toEqual(['main'])
  })

  test('the draft command names exactly the homes asked', async () => {
    expect(draftArgs(['main', 'mate-a'], false)).toBe('draft --mod --homes main,mate-a')
    expect(draftArgs(['mate-a'], true)).toBe('draft --mod --auto --homes mate-a')
  })

  test('only local secondmate routes are read', async () => {
    const registry = [
      '# Secondmates',
      '- mate-a - rides work (home: /homes/mate-a; scope: rides; projects: alpha; added 2026-08-07)',
      '- mate-b - remote (host: box; root: /fm; home: /homes/mate-b; scope: x; projects: y; added 2026-08-07)',
    ].join('\n')
    expect(parseRegistry(registry)).toEqual([{ id: 'mate-a', home: '/homes/mate-a' }])
  })
})
