import { describe, it, expect } from 'vitest';
import { computeTierScore } from '../rankingAlgorithm';
import { TIER_SCORE_RANGES } from '../../constants';
import { Tier } from '../../types';

/**
 * Parity pin for the `get_feed_ranking_scores` RPC
 * (supabase/migrations/20260707_feed_ranking_scores_rpc.sql).
 *
 * `sqlTierScore` below is a pure TS transcription of the SQL score expression,
 * modelling Postgres `numeric` semantics faithfully:
 *   - all operands are exact decimals (lo/hi have 1 decimal place, counts and
 *     positions are integers), so score*10 is the exact rational
 *     (L*n + (H-L)*k) / n with L=10*lo, H=10*hi, n=total-1, k=n-position;
 *   - `round(x::numeric, 1)` rounds half-AWAY-FROM-ZERO, which for the strictly
 *     positive scores in these tier ranges is identical to half-up, i.e. to
 *     JS `Math.round(x*10)/10` at exact halves.
 * Integer arithmetic is used throughout so the transcription is exact, not a
 * float re-approximation: roundHalfUp(p/r) = floor((2p + r) / (2r)) for p,r > 0.
 *
 * The grid below (totals 1..25 x all 5 tiers x every position) contains 71
 * exact-half cases (e.g. A-tier total=5 position=2 -> 7.95 -> 8.0); the test
 * proves the SQL math and computeTierScore agree on every one of them, plus
 * every non-half point.
 */
export function sqlTierScore(
  position: number,
  total: number,
  tierMin: number,
  tierMax: number,
): number {
  const L = Math.round(tierMin * 10); // lo as an exact integer of tenths
  const H = Math.round(tierMax * 10); // hi as an exact integer of tenths

  // roundHalfUp(p/r) for positive integers p, r — matches PG round(numeric, 1)
  // (half-away-from-zero) on the positive rational score*10 = p/r.
  const roundHalfUp = (p: number, r: number): number =>
    Math.floor((2 * p + r) / (2 * r));

  if (total <= 1) {
    // SQL: round(((lo + hi) / 2)::numeric, 1) — midpoint, score*10 = (L+H)/2
    return roundHalfUp(L + H, 2) / 10;
  }

  // SQL: round((lo + (hi - lo) * (total - 1 - position) / (total - 1))::numeric, 1)
  // score*10 = L + (H-L)*k/n = (L*n + (H-L)*k) / n
  const n = total - 1;
  const k = n - position;
  return roundHalfUp(L * n + (H - L) * k, n) / 10;
}

const TIERS = Object.entries(TIER_SCORE_RANGES) as [
  Tier,
  { min: number; max: number },
][];

describe('get_feed_ranking_scores SQL math ≡ computeTierScore', () => {
  it('matches for every (tier, total 1..25, position 0..total-1)', () => {
    for (const [tier, range] of TIERS) {
      for (let total = 1; total <= 25; total++) {
        for (let position = 0; position < total; position++) {
          const expected = computeTierScore(position, total, range.min, range.max);
          const actual = sqlTierScore(position, total, range.min, range.max);
          expect(
            actual,
            `tier=${tier} total=${total} position=${position}`,
          ).toBe(expected);
        }
      }
    }
  });

  it('single-item tiers get the midpoint rounded to 1dp (incl. the .x5 halves)', () => {
    expect(sqlTierScore(0, 1, 9.0, 10.0)).toBe(9.5); // S
    expect(sqlTierScore(0, 1, 7.0, 8.9)).toBe(8.0); // A: 7.95 -> 8.0 (half rounds up)
    expect(sqlTierScore(0, 1, 5.0, 6.9)).toBe(6.0); // B: 5.95 -> 6.0
    expect(sqlTierScore(0, 1, 3.0, 4.9)).toBe(4.0); // C: 3.95 -> 4.0
    expect(sqlTierScore(0, 1, 0.1, 2.9)).toBe(1.5); // D
  });

  it('endpoints: position 0 gets tierMax, last position gets tierMin', () => {
    for (const [, range] of TIERS) {
      for (const total of [2, 3, 10, 25]) {
        expect(sqlTierScore(0, total, range.min, range.max)).toBe(range.max);
        expect(sqlTierScore(total - 1, total, range.min, range.max)).toBe(range.min);
      }
    }
  });
});
