/**
 * Generates fixtures/engine-parity.json from the TypeScript ranking
 * implementation (the semantic reference). Both vitest
 * (services/__tests__/engineParity.test.ts) and XCTest
 * (ios/Spool/Tests/SpoolTests/EngineParityTests.swift) replay this file.
 *
 * Fully deterministic — no Date, no Math.random. Regenerate with:
 *   npm run fixtures:engine
 * Only regenerate when TS ranking semantics change INTENTIONALLY; the
 * diff is the review artifact.
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { RankingSession, SessionChoice } from '../services/rankingSession';
import { WEIGHTS } from '../services/spoolPrediction';
import { Tier, RankedItem } from '../types';
import { TIER_SCORE_RANGES, NEW_USER_THRESHOLD } from '../constants';

const GENRES = ['Drama', 'Action', 'Comedy', 'Horror', 'Sci-Fi'];

function mkItem(i: number, tier: Tier, rank: number): RankedItem {
  return {
    id: `m${i}`,
    title: `Movie ${i}`,
    genres: [GENRES[i % GENRES.length]],
    tier,
    rank,
    globalScore: 5 + (i % 5),
  } as RankedItem;
}

function mkTier(tier: Tier, count: number): RankedItem[] {
  return Array.from({ length: count }, (_, i) => mkItem(i, tier, i));
}

const newItem = (genre = 'Drama', globalScore = 7.5): RankedItem =>
  ({ id: 'new1', title: 'New Movie', genres: [genre], tier: Tier.A, rank: 0, globalScore } as RankedItem);

interface CaseSpec {
  name: string;
  tier: Tier;
  item: RankedItem;
  allItems: RankedItem[];
  choices: SessionChoice[];
}

// Choice sequences are longer than any flow needs; replay stops at done.
const always = (c: SessionChoice) => Array.from({ length: 30 }, () => c);
const alternating = (): SessionChoice[] =>
  Array.from({ length: 30 }, (_, i) => (i % 2 === 0 ? 'new' : 'existing') as SessionChoice);

const specs: CaseSpec[] = [
  { name: 'small-3-compare-all-always-new', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 3), choices: always('new') },
  { name: 'small-3-compare-all-always-existing', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 3), choices: always('existing') },
  { name: 'small-3-skip-after-one', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 3), choices: ['existing', 'skip'] },
  { name: 'small-8-seed-always-new', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 8), choices: always('new') },
  { name: 'small-8-seed-always-existing', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 8), choices: always('existing') },
  { name: 'small-8-seed-alternating', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 8), choices: alternating() },
  { name: 'small-20-seed-alternating', tier: Tier.B, item: newItem('Action', 6.0), allItems: mkTier(Tier.B, 20), choices: alternating() },
  { name: 'engine-25-always-new', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 25), choices: always('new') },
  { name: 'engine-25-always-existing', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 25), choices: always('existing') },
  { name: 'engine-25-alternating', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 25), choices: alternating() },
  { name: 'engine-25-skip-after-two', tier: Tier.A, item: newItem(), allItems: mkTier(Tier.A, 25), choices: ['new', 'existing', 'skip'] },
  { name: 'engine-25-offgenre-item', tier: Tier.A, item: newItem('Horror', 8.2), allItems: mkTier(Tier.A, 25), choices: alternating() },
  { name: 'engine-40-cross-tiers', tier: Tier.A, item: newItem(), allItems: [...mkTier(Tier.A, 25), ...mkTier(Tier.B, 15).map((it, i) => ({ ...it, id: `b${i}` }))], choices: alternating() },
];

function runCase(spec: CaseSpec) {
  const session = new RankingSession(spec.item, spec.tier, spec.allItems);
  const steps: { round: number; phase: string; movieBId: string }[] = [];
  const usedChoices: SessionChoice[] = [];

  let result = session.start();
  let i = 0;
  while (result.type === 'comparison') {
    steps.push({
      round: result.comparison.round,
      phase: result.comparison.phase,
      movieBId: result.comparison.movieB.id,
    });
    if (i >= spec.choices.length) throw new Error(`${spec.name}: ran out of choices`);
    const choice = spec.choices[i++];
    usedChoices.push(choice);
    result = session.submit(choice);
  }

  return {
    name: spec.name,
    tier: spec.tier,
    newItem: { id: spec.item.id, title: spec.item.title, genres: spec.item.genres, globalScore: spec.item.globalScore ?? null },
    allItems: spec.allItems.map((it) => ({
      id: it.id, title: it.title, genres: it.genres,
      tier: it.tier, rank: it.rank, globalScore: it.globalScore ?? null,
    })),
    choices: usedChoices,
    expectedSteps: steps,
    expectedFinalRank: result.finalRank,
    expectedFinalScore: result.finalScore, // null on small-tier paths
  };
}

const out = {
  constants: {
    tierScoreRanges: TIER_SCORE_RANGES,
    newUserThreshold: NEW_USER_THRESHOLD,
    // Sourced from the implementation (key order genreAffinity, globalScore,
    // bracketAffinity keeps regeneration byte-identical).
    predictionWeights: WEIGHTS,
  },
  cases: specs.map(runCase),
};

mkdirSync('fixtures', { recursive: true });
writeFileSync('fixtures/engine-parity.json', JSON.stringify(out, null, 2) + '\n');
console.log(`wrote fixtures/engine-parity.json with ${out.cases.length} cases`);
