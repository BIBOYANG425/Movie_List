import { describe, it, expect } from 'vitest';
import { RankingSession } from '../rankingSession';
import { Tier, RankedItem } from '../../types';

const GENRES = ['Drama', 'Action', 'Comedy', 'Horror', 'Sci-Fi'];

// Factory for test items. If RankedItem gains new required fields,
// extend here — tsc will flag it.
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

const newItem = (id = 'new1'): RankedItem =>
  ({ id, title: 'New Movie', genres: ['Drama'], tier: Tier.A, rank: 0, globalScore: 7.5 } as RankedItem);

describe('RankingSession — strategy selection', () => {
  it('empty tier → immediate done at rank 0, null score', () => {
    const s = new RankingSession(newItem(), Tier.A, []);
    expect(s.start()).toEqual({ type: 'done', finalRank: 0, finalScore: null });
  });

  it('≤5 items → compare_all starting at rank 0, phase binary_search', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 3));
    const r = s.start();
    if (r.type !== 'comparison') throw new Error('expected comparison');
    expect(r.comparison.movieB.id).toBe('m0');
    expect(r.comparison.phase).toBe('binary_search');
    expect(r.comparison.round).toBe(1);
  });

  it('6–20 items → anchor mode opens against the tier BEST', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 8));
    const r = s.start();
    if (r.type !== 'comparison') throw new Error('expected comparison');
    expect(r.comparison.phase).toBe('binary_search');
    expect(r.comparison.movieB.id).toBe('m0'); // the very best, always
  });

  it('>20 items → SAME anchor mode (the five-phase engine is retired; no size ceiling)', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 25));
    const r = s.start();
    if (r.type !== 'comparison') throw new Error('expected comparison');
    expect(r.comparison.phase).toBe('binary_search');
    expect(r.comparison.movieB.id).toBe('m0');
  });
});

describe('RankingSession — small-tier flow', () => {
  it('compare_all: new wins on round 2 → done at rank 1', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 3));
    s.start();
    const r1 = s.submit('existing');
    if (r1.type !== 'comparison') throw new Error('expected comparison');
    expect(r1.comparison.movieB.id).toBe('m1');
    const r2 = s.submit('new');
    expect(r2).toEqual({ type: 'done', finalRank: 1, finalScore: null });
  });

  it('too_tough / skip inserts at current cursor', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 3));
    s.start();
    s.submit('existing'); // cursor now at mid=1
    const r = s.submit('too_tough');
    expect(r).toEqual({ type: 'done', finalRank: 1, finalScore: null });
  });

  it('undo after too_tough finalization restores the comparison that was finalized', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 3));
    s.start();
    s.submit('existing'); // cursor now at mid=1
    const done = s.submit('too_tough');
    expect(done).toEqual({ type: 'done', finalRank: 1, finalScore: null });
    const undone = s.undo();
    if (!undone || undone.type !== 'comparison') throw new Error('expected restored comparison');
    expect(undone.comparison.movieB.id).toBe('m1');
    // Replaying resolves the same comparison the user was actually shown
    const replay = s.submit('new');
    expect(replay).toEqual({ type: 'done', finalRank: 1, finalScore: null });
  });

  it('undo restores the previous small-tier comparison', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 3));
    const first = s.start();
    if (first.type !== 'comparison') throw new Error('expected comparison');
    s.submit('existing');
    const undone = s.undo();
    if (!undone || undone.type !== 'comparison') throw new Error('expected restored comparison');
    expect(undone.comparison.movieB.id).toBe(first.comparison.movieB.id);
    // Replaying the same choice reproduces the same next state
    const replay = s.submit('existing');
    if (replay.type !== 'comparison') throw new Error('expected comparison');
    expect(replay.comparison.movieB.id).toBe('m1');
  });
});

describe('RankingSession — start() re-entrancy', () => {
  it('restarting a session clears stale history — undo returns null', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 3));
    s.start();
    s.submit('existing'); // pushes one small-tier history snapshot
    const restarted = s.start();
    if (restarted.type !== 'comparison') throw new Error('expected comparison');
    expect(restarted.comparison.movieB.id).toBe('m0');
    expect(s.undo()).toBeNull();
  });
});

describe('RankingSession — large-tier anchor flow (engine retired)', () => {
  it('a 25-item tier converges through anchors + quartiles with null score', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 25));
    let r = s.start();
    let guard = 0;
    while (r.type === 'comparison' && guard < 30) {
      r = s.submit('new');
      guard++;
    }
    if (r.type !== 'done') throw new Error('anchor flow did not converge');
    // Always-new beats the best at round 1 → rank 0. Scores are recomputed
    // at persist time (computeAllScores); the session reports null.
    expect(r.finalRank).toBe(0);
    expect(r.finalScore).toBeNull();
  });

  it('after done, submit throws the session error', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 25));
    let r = s.start();
    let guard = 0;
    while (r.type === 'comparison' && guard < 30) {
      r = s.submit('new');
      guard++;
    }
    if (r.type !== 'done') throw new Error('anchor flow did not converge');
    expect(() => s.submit('existing')).toThrow('RankingSession.submit: no active comparison');
  });

  it('skip on a large tier finalizes at the current cursor', () => {
    const s = new RankingSession(newItem(), Tier.A, mkTier(Tier.A, 25));
    s.start();
    const r = s.submit('skip');
    if (r.type !== 'done') throw new Error('expected done after skip');
    expect(r.finalScore).toBeNull();
  });
});
