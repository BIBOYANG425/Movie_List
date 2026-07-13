/**
 * Spool Adaptive Ranking Algorithm
 *
 * Extracted from inline modal state for reusability and testability.
 * Implements the four-stage ranking flow:
 *  1. Auto-bracketing (genre classification) — see classifyBracket
 *  2. Tier placement — user-driven, not algorithmic
 *  3. Adaptive in-tier comparison — anchor poles (best/worst) + adaptiveNarrow
 *  4. Score assignment — computeTierScore
 */

import { Tier, Bracket } from '../types';
import { TIER_SCORE_RANGES, TIERS } from '../constants';

// ── Bracket Classification ──────────────────────────────────────────────────

const ANIMATION_GENRE = 'Animation';
const DOCUMENTARY_GENRE = 'Documentary';

/**
 * Genres that strongly signal mainstream/commercial films.
 * If a film has NONE of these and only has arthouse-leaning genres,
 * it's classified as Artisan.
 */
const COMMERCIAL_SIGNAL_GENRES = new Set([
    'Action', 'Adventure', 'Sci-Fi', 'Fantasy', 'Horror',
    'Thriller', 'Comedy', 'Family', 'Animation', 'TV Movie',
]);

/**
 * Derive a bracket from TMDb genre labels.
 *
 * - Animation genre → Animation bracket
 * - Documentary genre → Documentary bracket
 * - No commercial-signal genres (pure Drama, Romance, History, etc.) → Artisan
 * - Everything else → Commercial
 */
export function classifyBracket(genres: string[]): Bracket {
    if (genres.includes(ANIMATION_GENRE)) return Bracket.Animation;
    if (genres.includes(DOCUMENTARY_GENRE)) return Bracket.Documentary;
    if (genres.length > 0 && !genres.some(g => COMMERCIAL_SIGNAL_GENRES.has(g))) {
        return Bracket.Artisan;
    }
    return Bracket.Commercial;
}

// ── Anchor-First Comparison (owner redesign, 2026-07-13) ────────────────────
//
// The 6–20 tier ceremony opens by bracketing the tier's POLES, then narrows
// by quartiles:
//
//   round 1 — the tier's VERY BEST.  Beat it → rank 0, done.
//   round 2 — the tier's VERY WORST. Lose to it → bottom, done.
//   round 3+ — quartile narrowing over the remaining range, first pivot at
//              the 25% boundary: win → narrow into the top quarter; lose →
//              drop to the 75% point of the remainder (adaptiveNarrow's
//              25%/75% rule).
//
// This replaced the globalScore-seeded pivot (computeSeedIndex): opening with
// a crowd-score-chosen film read as "two random movies then done" in the
// iMessage card, and the crowd's opinion has no place in a personal ranking.
// The poles make the ceremony legible ("better than your best? worse than
// your worst?") and every placement is anchored against the full tier span.

// ── Quartile-Based Narrowing ────────────────────────────────────────────────

/**
 * Perform one step of quartile-based binary search narrowing.
 *
 * Instead of standard halving, uses the top/bottom 25% of the
 * remaining range for faster convergence in 3–4 rounds.
 *
 * "new" (BETTER) → next comparison from top 25% above current point
 * "existing" (WORSE) → next comparison from bottom 25% below current point
 *
 * Returns null if converged (newLow >= newHigh).
 */
export function adaptiveNarrow(
    low: number,
    high: number,
    mid: number,
    choice: 'new' | 'existing',
): { newLow: number; newHigh: number } | null {
    let newLow = low;
    let newHigh = high;

    if (choice === 'new') {
        // User prefers the new movie → it ranks higher (lower index)
        newHigh = mid;
    } else {
        // User prefers existing → new movie ranks lower (higher index)
        newLow = mid + 1;
    }

    if (newLow >= newHigh) {
        return null; // Converged
    }

    return { newLow, newHigh };
}

// ── Tier-Aware Score Assignment ──────────────────────────────────────────────

/**
 * Calculate a movie's numerical score using linear interpolation
 * within its tier's score range.
 *
 * Formula from Spool spec:
 *   score = tier_min + (tier_max − tier_min) × (position / total_in_tier)
 *
 * Where position is 0-indexed from the bottom of the tier, so the
 * highest-ranked item gets the maximum score.
 *
 * @param position     0-indexed rank within the tier (0 = top/best)
 * @param totalInTier  Total number of movies in this tier
 * @param tierMin      Minimum score for this tier
 * @param tierMax      Maximum score for this tier
 * @returns            Score rounded to 1 decimal place
 */
export function computeTierScore(
    position: number,
    totalInTier: number,
    tierMin: number,
    tierMax: number,
): number {
    if (totalInTier <= 1) {
        // Single item gets midpoint of tier range
        return Math.round(((tierMin + tierMax) / 2) * 10) / 10;
    }

    // position=0 is the best → gets tierMax
    // position=totalInTier-1 is the worst → gets tierMin
    const ratio = (totalInTier - 1 - position) / (totalInTier - 1);
    const score = tierMin + (tierMax - tierMin) * ratio;
    return Math.round(score * 10) / 10;
}

// ── Full List Scoring ───────────────────────────────────────────────────────

/**
 * Compute scores for all items using tier-aware interpolation.
 * Each tier independently distributes scores across its range.
 */
export function computeAllScores(
    items: { id: string; tier: Tier; rank: number }[],
): Map<string, number> {
    const scoreMap = new Map<string, number>();

    for (const tier of TIERS) {
        const range = TIER_SCORE_RANGES[tier];
        const tierItems = items
            .filter((i) => i.tier === tier)
            .sort((a, b) => a.rank - b.rank);

        for (let i = 0; i < tierItems.length; i++) {
            const score = computeTierScore(i, tierItems.length, range.min, range.max);
            scoreMap.set(tierItems[i].id, score);
        }
    }

    return scoreMap;
}

// ── Determine Natural Tier ──────────────────────────────────────────────────

/** Determine the "natural" tier for a given score based on tier ranges. */
export function getNaturalTier(score: number): Tier {
    for (const tier of TIERS) {
        const range = TIER_SCORE_RANGES[tier];
        if (score >= range.min) return tier;
    }
    return Tier.D;
}

// ── Small-Tier State Machine ────────────────────────────────────────────────
// Direct port of ios/Spool RankingAlgorithm.advanceSmallTier — the pure
// formalization of the inline smallTierRef logic previously copy-pasted
// across RankingFlowModal / AddMediaModal / AddTVSeasonModal /
// MovieOnboardingPage. tierCount is the size of the target tier (the new
// item is NOT counted).

export type SmallTierMode = 'compare_all' | 'anchor_best' | 'anchor_worst' | 'quartile';

export interface SmallTierState {
  mode: SmallTierMode;
  tierCount: number;
  low: number;
  high: number;
  mid: number;
  round: number;
  seedIdx: number;
}

export type SmallTierStep =
  | { type: 'done'; rank: number }
  | { type: 'next'; state: SmallTierState };

export function advanceSmallTier(
  state: SmallTierState,
  pick: 'new' | 'existing',
): SmallTierStep {
  const nextRound = state.round + 1;

  switch (state.mode) {
    case 'compare_all': {
      if (pick === 'new') return { type: 'done', rank: state.mid };
      if (state.mid + 1 >= state.tierCount) {
        return { type: 'done', rank: state.tierCount };
      }
      return { type: 'next', state: { ...state, mid: state.mid + 1, round: nextRound } };
    }

    case 'anchor_best': {
      // Round 1 — the tier's very best (index 0).
      if (pick === 'new') return { type: 'done', rank: 0 };
      // Below the best → probe the floor next.
      return {
        type: 'next',
        state: {
          ...state,
          mode: 'anchor_worst',
          low: 1,
          high: state.tierCount,
          mid: state.tierCount - 1,
          round: nextRound,
        },
      };
    }

    case 'anchor_worst': {
      // Round 2 — the tier's very worst (index tierCount-1).
      if (pick === 'existing') return { type: 'done', rank: state.tierCount };
      // Above the worst → insertion is somewhere in [1, tierCount-1].
      const low = 1;
      const high = state.tierCount - 1;
      if (low >= high) return { type: 'done', rank: low };
      // First quartile pivot: the 25% boundary of the remaining range.
      const mid = Math.max(low, Math.min(low + Math.floor((high - low) * 0.25), high - 1));
      return {
        type: 'next',
        state: { ...state, mode: 'quartile', low, high, mid, round: nextRound },
      };
    }

    case 'quartile': {
      const newLow = pick === 'new' ? state.low : state.mid + 1;
      const newHigh = pick === 'new' ? state.mid : state.high;
      if (newLow >= newHigh) return { type: 'done', rank: newLow };
      const ratio = pick === 'new' ? 0.25 : 0.75;
      const nextMid = Math.max(
        newLow,
        Math.min(newLow + Math.floor((newHigh - newLow) * ratio), newHigh - 1),
      );
      return {
        type: 'next',
        state: { ...state, low: newLow, high: newHigh, mid: nextMid, round: nextRound },
      };
    }
  }
}
