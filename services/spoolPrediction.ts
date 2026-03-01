import { Tier, Bracket, RankedItem, PredictionSignals } from '../types';
import { TIER_SCORE_RANGES, NEW_USER_THRESHOLD } from '../constants';
import { computeTierScore } from './rankingAlgorithm';

const WEIGHTS = {
  genreAffinity: 0.45,
  globalScore: 0.35,
  bracketAffinity: 0.20,
} as const;

export function computePredictionSignals(
  allItems: RankedItem[],
  primaryGenre: string,
  bracket: Bracket,
  globalScore: number | undefined,
  tier: Tier,
): PredictionSignals {
  const range = TIER_SCORE_RANGES[tier];

  // Genre affinity: average score of user's movies with same primary genre
  const genreItems = allItems.filter(
    (item) => item.genres.length > 0 && item.genres[0] === primaryGenre
  );
  let genreAffinity: number | null = null;
  if (genreItems.length > 0) {
    const scores = genreItems.map((item) => {
      const tierRange = TIER_SCORE_RANGES[item.tier];
      const tierPeers = allItems
        .filter((i) => i.tier === item.tier)
        .sort((a, b) => a.rank - b.rank);
      return computeTierScore(item.rank, tierPeers.length, tierRange.min, tierRange.max);
    });
    genreAffinity = scores.reduce((a, b) => a + b, 0) / scores.length;
  }

  // Global score: clamp to tier range
  let mappedGlobal: number | null = null;
  if (globalScore !== undefined) {
    mappedGlobal = Math.max(range.min, Math.min(range.max, globalScore));
  }

  // Bracket affinity: average score of user's movies with same bracket
  const bracketItems = allItems.filter((item) => item.bracket === bracket);
  let bracketAffinity: number | null = null;
  if (bracketItems.length > 0) {
    const scores = bracketItems.map((item) => {
      const tierRange = TIER_SCORE_RANGES[item.tier];
      const tierPeers = allItems
        .filter((i) => i.tier === item.tier)
        .sort((a, b) => a.rank - b.rank);
      return computeTierScore(item.rank, tierPeers.length, tierRange.min, tierRange.max);
    });
    bracketAffinity = scores.reduce((a, b) => a + b, 0) / scores.length;
  }

  return {
    genreAffinity,
    globalScore: mappedGlobal,
    bracketAffinity,
    totalRanked: allItems.length,
  };
}

export function predictScore(signals: PredictionSignals, tier: Tier): number {
  const range = TIER_SCORE_RANGES[tier];
  const midpoint = (range.min + range.max) / 2;

  // New user fallback: use globalScore only
  if (signals.totalRanked < NEW_USER_THRESHOLD) {
    return signals.globalScore ?? midpoint;
  }

  // Build weighted average from available signals
  const entries: { value: number; weight: number }[] = [];

  if (signals.genreAffinity !== null) {
    entries.push({ value: signals.genreAffinity, weight: WEIGHTS.genreAffinity });
  }
  if (signals.globalScore !== null) {
    entries.push({ value: signals.globalScore, weight: WEIGHTS.globalScore });
  }
  if (signals.bracketAffinity !== null) {
    entries.push({ value: signals.bracketAffinity, weight: WEIGHTS.bracketAffinity });
  }

  if (entries.length === 0) return midpoint;

  // Redistribute weights proportionally
  const totalWeight = entries.reduce((sum, e) => sum + e.weight, 0);
  const raw = entries.reduce((sum, e) => sum + e.value * (e.weight / totalWeight), 0);

  // Clamp to tier bounds
  return Math.max(range.min, Math.min(range.max, Math.round(raw * 100) / 100));
}
