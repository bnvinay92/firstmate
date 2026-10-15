// The fleet-pane mod's state contract: what its pane draws from.
// bin/fm-fleet-snapshot.sh owns the task records these rows are read from;
// hooks/lib.ts owns how they and GitHub's answer become rows.

// The main Firstmate home this session runs in, and the code root its
// scripts run from.
export type PaneSite = { home: string; root: string }

// One open pull request, as the pane draws it.
export type PrRow = {
  url: string
  project: string
  title: string
  // The check summary: passing, N failing, running, or none reported.
  checks: string
  // What keeps it from merging, in plain words; never empty.
  blockers: string[]
}

// One decision waiting on the captain.
export type DecisionRow = {
  label: string
  summary: string
  report: string | null
}

export type FleetView = {
  prs: PrRow[]
  decisions: DecisionRow[]
  // When the rows were last read, or null before the first read.
  at: number | null
  // A read that failed, in plain words; the last good rows stay shown.
  problem: string | null
}

declare module 'claude-code' {
  interface PluginState {
    'fleet-pane': {
      site: PaneSite | null
      view: FleetView
    }
  }
}
