// hooks/useRankingCeremony.ts
//
// The single, shared head-to-head ceremony DRIVER. Owns the RankingSession
// lifecycle (start → binary-search comparison loop → placement) plus the
// comparison-log emission, so every surface that ranks a film runs the SAME
// placement engine through the SAME driver rather than a hand-copied clone.
//
// Before this hook, AddMediaModal (the main app's movie flow) and
// RankingFlowModal (the book flow AND the /agent-rank in-iMessage ceremony)
// each kept a byte-for-byte copy of the driver (sessionRef, isProcessingRef,
// currentComparison, sessionId, proceedFromNotes/handleCompareChoice/handleUndo).
// Two copies of the placement loop is a fork waiting to drift — the /agent-rank
// parity defect. This hook is the de-duplicated driver both consume.
//
// The engine stepping itself lives in a pure, React-free core (CeremonyDriver /
// createCeremonyDriver) so it is unit-testable in the node test env and so the
// finalRank a given (item, tier, allItems, choice-sequence) produces is
// provably identical across the main flow and the agent flow — same driver,
// same RankingSession. The hook only adds React state around that core.
//
// It is engine-only: it does NOT touch tier/notes UI state, search, or the
// write path. Callers own those and call:
//   • begin(item, tier, allItems)  → start the loop for a chosen tier
//   • choose(choice)               → resolve the shown comparison
//   • undo()                       → step back one comparison
//   • reset()                      → clear session state (modal open/close)
// Each returns a CeremonyStep the caller renders/persists:
//   { kind: 'compare', comparison }  — show the next head-to-head
//   { kind: 'placed', rank }         — insert the film at `rank`
//   { kind: 'idle' }                 — nothing to show (undo with no history)
//
// Header last reviewed: 2026-07-13

import { useCallback, useRef, useState } from 'react';
import { RankedItem, Tier, ComparisonRequest, ComparisonLogEntry } from '../types';
import { RankingSession, SessionChoice } from '../services/rankingSession';

export type CeremonyStep =
  | { kind: 'compare'; comparison: ComparisonRequest }
  | { kind: 'placed'; rank: number }
  | { kind: 'idle' };

export type CompareSink = (log: ComparisonLogEntry) => void;
export type LogContext = () => { item: RankedItem | null; tier: Tier | null };

export interface CeremonyDriverOptions {
  /** Factory for a fresh run id — tags every emitted ComparisonLogEntry. */
  newSessionId?: () => string;
  /** Optional sink for the per-choice ComparisonLogEntry (main flow persists). */
  onCompare?: CompareSink;
  /** The caller's currently-selected (item, tier) for the log entry. */
  getLogContext?: LogContext;
}

/**
 * Pure, React-free placement driver. Wraps one RankingSession run and turns
 * start/submit/undo into CeremonyStep results. Re-entrancy-guarded so a double
 * `choose` (rapid double-tap) resolves the comparison exactly once. This is the
 * single code path both modals run — unit tests drive it directly.
 */
export interface CeremonyDriver {
  readonly sessionId: string;
  /** The comparison awaiting a choice, or null outside the loop. */
  current(): ComparisonRequest | null;
  begin(item: RankedItem, tier: Tier, allItems: RankedItem[]): CeremonyStep;
  choose(choice: SessionChoice): CeremonyStep;
  undo(): CeremonyStep;
}

export function createCeremonyDriver(options?: CeremonyDriverOptions): CeremonyDriver {
  const sessionId = (options?.newSessionId ?? (() => crypto.randomUUID()))();
  let session: RankingSession | null = null;
  let currentComparison: ComparisonRequest | null = null;
  let processing = false;

  const emitLog = (comparison: ComparisonRequest, choice: SessionChoice) => {
    if (!options?.onCompare) return;
    const ctx = options.getLogContext?.() ?? { item: null, tier: null };
    if (!ctx.item || !ctx.tier) return;
    options.onCompare({
      sessionId,
      movieAId: comparison.movieA.id,
      movieBId: comparison.movieB.id,
      winner: choice === 'new' ? 'a' : choice === 'existing' ? 'b' : 'skip',
      round: comparison.round,
      phase: comparison.phase,
      questionText: comparison.question,
    });
  };

  return {
    sessionId,
    current: () => currentComparison,

    begin(item, tier, allItems) {
      session = new RankingSession(item, tier, allItems);
      const result = session.start();
      if (result.type === 'done') {
        session = null;
        currentComparison = null;
        return { kind: 'placed', rank: result.finalRank };
      }
      currentComparison = result.comparison;
      return { kind: 'compare', comparison: result.comparison };
    },

    choose(choice) {
      const active = session;
      const comparison = currentComparison;
      if (!active || !comparison) return { kind: 'idle' };
      if (processing) return { kind: 'idle' };
      processing = true;
      try {
        emitLog(comparison, choice);
        const result = active.submit(choice);
        if (result.type === 'done') {
          session = null;
          currentComparison = null;
          return { kind: 'placed', rank: result.finalRank };
        }
        currentComparison = result.comparison;
        return { kind: 'compare', comparison: result.comparison };
      } finally {
        processing = false;
      }
    },

    undo() {
      const result = session?.undo();
      if (result && result.type === 'comparison') {
        currentComparison = result.comparison;
        return { kind: 'compare', comparison: result.comparison };
      }
      return { kind: 'idle' };
    },
  };
}

export interface RankingCeremony {
  /** The comparison currently awaiting a choice, or null outside the loop. */
  currentComparison: ComparisonRequest | null;
  /** Stable id for the active ceremony run — tags every ComparisonLogEntry. */
  sessionId: string;
  begin: (item: RankedItem, tier: Tier, allItems: RankedItem[]) => CeremonyStep;
  choose: (choice: SessionChoice) => CeremonyStep;
  undo: () => CeremonyStep;
  /** Clear all session state (call on modal open/close). */
  reset: () => void;
}

/**
 * React binding over CeremonyDriver: adds `currentComparison` / `sessionId`
 * render state and a `reset` that spins up a fresh driver+run id. The driver
 * core does the engine work; this only mirrors it into component state so the
 * ComparisonStep re-renders.
 */
export function useRankingCeremony(options?: CeremonyDriverOptions): RankingCeremony {
  const driverRef = useRef<CeremonyDriver | null>(null);
  const [currentComparison, setCurrentComparison] = useState<ComparisonRequest | null>(null);
  const [sessionId, setSessionId] = useState<string>('');

  const ensure = useCallback((): CeremonyDriver => {
    if (!driverRef.current) {
      driverRef.current = createCeremonyDriver(options);
      setSessionId(driverRef.current.sessionId);
    }
    return driverRef.current;
    // options is captured per-call by createCeremonyDriver; a stable closure is
    // fine here (getLogContext reads live refs), so we intentionally omit deps.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const reset = useCallback(() => {
    driverRef.current = createCeremonyDriver(options);
    setSessionId(driverRef.current.sessionId);
    setCurrentComparison(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const begin = useCallback(
    (item: RankedItem, tier: Tier, allItems: RankedItem[]): CeremonyStep => {
      const step = ensure().begin(item, tier, allItems);
      setCurrentComparison(driverRef.current!.current());
      return step;
    },
    [ensure],
  );

  const choose = useCallback(
    (choice: SessionChoice): CeremonyStep => {
      const driver = driverRef.current;
      if (!driver) return { kind: 'idle' };
      const step = driver.choose(choice);
      setCurrentComparison(driver.current());
      return step;
    },
    [],
  );

  const undo = useCallback((): CeremonyStep => {
    const driver = driverRef.current;
    if (!driver) return { kind: 'idle' };
    const step = driver.undo();
    setCurrentComparison(driver.current());
    return step;
  }, []);

  return { currentComparison, sessionId, begin, choose, undo, reset };
}
