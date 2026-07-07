import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { RankingSession, SessionChoice } from '../rankingSession';
import { Tier, RankedItem } from '../../types';
import { TIER_SCORE_RANGES, NEW_USER_THRESHOLD } from '../../constants';

// Replays fixtures/engine-parity.json against the live TS implementation.
// If this fails, either the change to ranking semantics is unintentional
// (fix the code) or intentional (run `npm run fixtures:engine`, commit the
// diff, and expect the Swift parity test to fail until iOS is updated).

const corpus = JSON.parse(readFileSync('fixtures/engine-parity.json', 'utf8'));

describe('engine parity corpus — constants', () => {
  it('constants match the fixture', () => {
    expect(corpus.constants.tierScoreRanges).toEqual(TIER_SCORE_RANGES);
    expect(corpus.constants.newUserThreshold).toBe(NEW_USER_THRESHOLD);
  });
});

describe('engine parity corpus — replay', () => {
  for (const c of corpus.cases) {
    it(c.name, () => {
      const allItems = c.allItems.map((it: any) => ({ ...it, globalScore: it.globalScore ?? undefined }) as RankedItem);
      const item = { ...c.newItem, tier: c.tier as Tier, rank: 0, globalScore: c.newItem.globalScore ?? undefined } as RankedItem;
      const session = new RankingSession(item, c.tier as Tier, allItems);

      let result = session.start();
      let i = 0;
      const steps: any[] = [];
      while (result.type === 'comparison') {
        steps.push({ round: result.comparison.round, phase: result.comparison.phase, movieBId: result.comparison.movieB.id });
        result = session.submit(c.choices[i++] as SessionChoice);
      }

      expect(steps).toEqual(c.expectedSteps);
      expect(result.finalRank).toBe(c.expectedFinalRank);
      if (c.expectedFinalScore !== null) {
        expect(result.finalScore).toBeCloseTo(c.expectedFinalScore, 4);
      }
    });
  }
});
