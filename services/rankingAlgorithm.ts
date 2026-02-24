/**
 * Spool Adaptive Ranking Algorithm
 *
 * Extracted from inline modal state for reusability and testability.
 * Implements the four-stage ranking flow:
 *  1. Auto-bracketing (genre classification) — see classifyBracket
 *  2. Tier placement — user-driven, not algorithmic
 *  3. Adaptive in-tier comparison — computeSeedIndex + adaptiveNarrow
 *  4. Score assignment — computeTierScore
 */

import { Tier, Bracket } from '../types';
import { TIER_SCORE_RANGES, TIERS } from '../constants';

// ── Bracket Classification ──────────────────────────────────────────────────

const ANIMATION_GENRE = 'Animation';
const DOCUMENTARY_GENRE = 'Documentary';

/**
 * Derive a bracket from TMDb genre labels.
 * Animation and Documentary map directly; everything else defaults
 * to Commercial. Artisan classification requires distribution/festival
 * data not available from TMDb—deferred to V2.
 */
export function classifyBracket(genres: string[]): Bracket {
    if (genres.includes(ANIMATION_GENRE)) return Bracket.Animation;
    if (genres.includes(DOCUMENTARY_GENRE)) return Bracket.Documentary;
    return Bracket.Commercial;
}

// ── Adaptive Comparison Seeding ─────────────────────────────────────────────

/**
 * Determine the initial comparison pivot index within a tier.
 *
 * If the movie's global average falls within the tier's score range,
 * find the existing movie closest to that global avg and use it
 * as the first comparison. This is the "aligned" case.
 *
 * If the global average falls outside the tier (the user's judgment
 * diverges from the crowd), ignore it and start at the median.
 * This respects the user's tier choice as sacred.
 *
 * @param tierItemScores  Ordered array of scores for items in the tier (high→low)
 * @param tierMin         Minimum score of the tier range
 * @param tierMax         Maximum score of the tier range
 * @param globalAvg       The movie's global average score (TMDb vote_average)
 * @returns               0-based index to use as the first comparison pivot
 */
export function computeSeedIndex(
    tierItemScores: number[],
    tierMin: number,
    tierMax: number,
    globalAvg: number | undefined,
): number {
    const n = tierItemScores.length;
    if (n === 0) return 0;

    // Median fallback
    const median = Math.floor(n / 2);

    if (globalAvg === undefined || globalAvg < tierMin || globalAvg > tierMax) {
        // Divergent: global avg is outside the user's chosen tier → use median
        return median;
    }

    // Aligned: find the item closest to the global average score
    let closestIdx = 0;
    let closestDist = Math.abs(tierItemScores[0] - globalAvg);

    for (let i = 1; i < n; i++) {
        const dist = Math.abs(tierItemScores[i] - globalAvg);
        if (dist < closestDist) {
            closestDist = dist;
            closestIdx = i;
        }
    }

    return closestIdx;
}

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
