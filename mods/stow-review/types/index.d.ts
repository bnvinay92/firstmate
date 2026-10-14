// The stow-review mod's state contract: what its band and pane draw from.
// The file formats these values are read from are owned by
// bin/fm-stow-plan.sh (plans, reviews, round ends) and hooks/lib.ts
// (context readings).

export type StowSection = 'memory' | 'offload' | 'knowledge' | 'records'

export type StowItem = {
  id: string
  section: StowSection
  action: 'add' | 'rewrite' | 'remove' | 'archive' | 'record'
  target: string
  entry: string
  replaces?: string
  after?: string
  why?: string
}

export type StowHomePlan = { home: string; items: StowItem[] }

export type StowReview = {
  version: 1
  homes: StowHomePlan[]
  exceptions?: { home: string; reason: string }[]
}

export type StowApplied = {
  version: 1
  at: number
  clear: boolean
  homes: StowHomePlan[]
}

// Where this session runs: a Firstmate primary or secondmate home.
export type StowSite = { home: string; role: 'primary' | 'secondmate'; name: string }

// One home's latest published context fill, as the main session reads it.
export type StowReading = {
  home: string
  tokens: number
  window: number
  at: number
  isStale: boolean
}

// A stow round this mod started: which homes were asked, and whether Auto
// started it (Auto saves everything the plans suggest, with no review).
export type StowRound = { at: number; homes: string[]; isAuto: boolean; isReviewOpen: boolean }

declare module 'claude-code' {
  interface PluginState {
    'stow-review': {
      site: StowSite | null
      readings: StowReading[]
      review: StowReview | null
      ticks: Record<string, boolean>
      edits: Record<string, string>
      page: number
      round: StowRound | null
      isAuto: boolean
      lastAuto: StowApplied | null
    }
  }
}
