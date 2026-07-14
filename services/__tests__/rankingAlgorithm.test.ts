import { describe, it, expect } from 'vitest';
import {
  advanceSmallTier,
  SmallTierState,
} from '../rankingAlgorithm';

// Ported 1:1 from ios/Spool/Tests/SpoolTests/SmallTierAlgorithmTests.swift
// so both platforms pin identical small-tier semantics.

const state = (overrides: Partial<SmallTierState>): SmallTierState => ({
  mode: 'anchor_best',
  tierCount: 8,
  low: 0,
  high: 8,
  mid: 0,
  round: 1,
  seedIdx: 0,
  ...overrides,
});

describe('advanceSmallTier — anchor mode (owner redesign 2026-07-13)', () => {
  it('round 1 is the tier BEST: beating it places at rank 0 in one comparison', () => {
    const s = state({ mode: 'anchor_best', mid: 0 });
    expect(advanceSmallTier(s, 'new')).toEqual({ type: 'done', rank: 0 });
  });

  it('losing to the best moves to the WORST anchor (mid = tierCount-1)', () => {
    const s = state({ mode: 'anchor_best', mid: 0, tierCount: 8 });
    const r = advanceSmallTier(s, 'existing');
    if (r.type !== 'next') throw new Error('expected next');
    expect(r.state.mode).toBe('anchor_worst');
    expect(r.state.mid).toBe(7); // the very worst
    expect(r.state.round).toBe(2);
  });

  it('losing to the worst places at the bottom (rank tierCount)', () => {
    const s = state({ mode: 'anchor_worst', mid: 7, tierCount: 8, low: 1, high: 8, round: 2 });
    expect(advanceSmallTier(s, 'existing')).toEqual({ type: 'done', rank: 8 });
  });

  it('beating the worst enters quartile narrowing at the 25% boundary of [1, tierCount-1]', () => {
    const s = state({ mode: 'anchor_worst', mid: 7, tierCount: 8, low: 1, high: 8, round: 2 });
    const r = advanceSmallTier(s, 'new');
    if (r.type !== 'next') throw new Error('expected next');
    expect(r.state.mode).toBe('quartile');
    expect(r.state.low).toBe(1);
    expect(r.state.high).toBe(7);
    // 1 + floor((7-1) * 0.25) = 2 — the 25% pivot of the remaining span.
    expect(r.state.mid).toBe(2);
    expect(r.state.round).toBe(3);
  });

  it('full walk, 8-item tier, always existing → rank 8 in exactly two anchor rounds', () => {
    let s = state({ mode: 'anchor_best', mid: 0, tierCount: 8 });
    const r1 = advanceSmallTier(s, 'existing');
    if (r1.type !== 'next') throw new Error('round 1: expected next');
    const r2 = advanceSmallTier(r1.state, 'existing');
    expect(r2).toEqual({ type: 'done', rank: 8 });
  });

  it('full walk, 8-item tier, lose-best win-worst then always new → lands directly above the worst region top', () => {
    // best(existing) → worst(new) → quartile [1,7] mid=2: new → [1,2] mid=1:
    // new → [1,1] done rank 1 (right below the best).
    let s = state({ mode: 'anchor_best', mid: 0, tierCount: 8 });
    let r = advanceSmallTier(s, 'existing');
    if (r.type !== 'next') throw new Error('expected next');
    r = advanceSmallTier(r.state, 'new');
    if (r.type !== 'next') throw new Error('expected next');
    r = advanceSmallTier(r.state, 'new');
    if (r.type !== 'next') throw new Error('expected next');
    expect(r.state.mid).toBe(1);
    const done = advanceSmallTier(r.state, 'new');
    expect(done).toEqual({ type: 'done', rank: 1 });
  });

  it('6-item tier: anchors then quartile pivot at 2', () => {
    let s = state({ mode: 'anchor_best', mid: 0, tierCount: 6, high: 6 });
    let r = advanceSmallTier(s, 'existing');
    if (r.type !== 'next') throw new Error('expected next');
    expect(r.state.mid).toBe(5);
    r = advanceSmallTier(r.state, 'new');
    if (r.type !== 'next') throw new Error('expected next');
    expect(r.state.mode).toBe('quartile');
    expect(r.state.low).toBe(1);
    expect(r.state.high).toBe(5);
    expect(r.state.mid).toBe(2); // 1 + floor(4 * 0.25)
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
