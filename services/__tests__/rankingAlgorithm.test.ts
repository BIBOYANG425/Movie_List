import { describe, it, expect } from 'vitest';
import {
  advanceSmallTier,
  computeSeedIndex,
  computeTierScore,
  SmallTierState,
} from '../rankingAlgorithm';

// Ported 1:1 from ios/Spool/Tests/SpoolTests/SmallTierAlgorithmTests.swift
// so both platforms pin identical small-tier semantics.

const state = (overrides: Partial<SmallTierState>): SmallTierState => ({
  mode: 'seed',
  tierCount: 8,
  low: 0,
  high: 8,
  mid: 0,
  round: 1,
  seedIdx: 0,
  ...overrides,
});

describe('advanceSmallTier — seed mode', () => {
  it('user always picks new → inserts at rank 0 (8-item tier, median seed)', () => {
    const tierCount = 8;
    const tierScores = Array.from({ length: tierCount }, (_, idx) =>
      computeTierScore(idx, tierCount, 7.0, 8.9),
    );
    const seedIdx = computeSeedIndex(tierScores, 7.0, 8.9, undefined);
    expect(seedIdx).toBe(4); // median of 8 items

    let s = state({ mode: 'seed', mid: seedIdx, seedIdx });

    // Round 1: "new" at mid=4 → quartile with [0, 4), mid=0
    const r1 = advanceSmallTier(s, 'new');
    if (r1.type !== 'next') throw new Error('round 1: expected next');
    expect(r1.state.mode).toBe('quartile');
    expect(r1.state.low).toBe(0);
    expect(r1.state.high).toBe(4);
    expect(r1.state.mid).toBe(0);
    expect(r1.state.round).toBe(2);

    // Round 2: "new" at mid=0 → newLow=0 >= newHigh=0 → done at 0
    const r2 = advanceSmallTier(r1.state, 'new');
    expect(r2).toEqual({ type: 'done', rank: 0 });
  });

  it('new wins immediately at seed 0 → inserts at 0', () => {
    const s = state({ mode: 'seed', mid: 0, seedIdx: 0 });
    expect(advanceSmallTier(s, 'new')).toEqual({ type: 'done', rank: 0 });
  });

  it('user always picks existing → inserts at end (rank 8)', () => {
    let s = state({ mode: 'seed', mid: 4, seedIdx: 4 });
    const r1 = advanceSmallTier(s, 'existing');
    if (r1.type !== 'next') throw new Error('round 1: expected next');
    expect(r1.state.mode).toBe('quartile');
    expect(r1.state.low).toBe(5);
    expect(r1.state.high).toBe(8);
    expect(r1.state.mid).toBe(7); // 5 + floor(3 * 0.75) = 7

    const r2 = advanceSmallTier(r1.state, 'existing');
    expect(r2).toEqual({ type: 'done', rank: 8 });
  });
});

describe('advanceSmallTier — quartile mode', () => {
  it('existing jumps 75%: [0,8) mid=4 → [5,8) mid=7', () => {
    const s = state({ mode: 'quartile', low: 0, high: 8, mid: 4 });
    const r = advanceSmallTier(s, 'existing');
    if (r.type !== 'next') throw new Error('expected next');
    expect(r.state.low).toBe(5);
    expect(r.state.high).toBe(8);
    expect(r.state.mid).toBe(7);
  });

  it('new jumps 25%: [0,8) mid=4 → [0,4) mid=1', () => {
    const s = state({ mode: 'quartile', low: 0, high: 8, mid: 4 });
    const r = advanceSmallTier(s, 'new');
    if (r.type !== 'next') throw new Error('expected next');
    expect(r.state.low).toBe(0);
    expect(r.state.high).toBe(4);
    expect(r.state.mid).toBe(1);
  });
});

describe('advanceSmallTier — compare_all mode', () => {
  it('new wins → inserts at current cursor', () => {
    const s = state({ mode: 'compare_all', tierCount: 5, high: 5, mid: 2 });
    expect(advanceSmallTier(s, 'new')).toEqual({ type: 'done', rank: 2 });
  });

  it('losing every comparison walks to the end (rank == tierCount)', () => {
    let s = state({ mode: 'compare_all', tierCount: 3, high: 3, mid: 0 });
    for (const expectedMid of [1, 2]) {
      const r = advanceSmallTier(s, 'existing');
      if (r.type !== 'next') throw new Error(`expected next at mid ${s.mid}`);
      expect(r.state.mid).toBe(expectedMid);
      s = r.state;
    }
    expect(advanceSmallTier(s, 'existing')).toEqual({ type: 'done', rank: 3 });
  });
});
