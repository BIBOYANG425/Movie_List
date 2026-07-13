import { describe, it, expect, vi } from 'vitest';
import { createCeremonyDriver } from '../useRankingCeremony';
import { RankingSession, SessionChoice } from '../../services/rankingSession';
import { Tier, RankedItem, ComparisonLogEntry } from '../../types';

// The ceremony DRIVER is the single code path AddMediaModal (main movie flow),
// RankingFlowModal (book flow), and AgentRankPage (/agent-rank, via
// RankingFlowModal) all run. These tests exercise that driver directly — the
// same head-to-head binary-search placement loop, not a fork — so a regression
// in the comparison loop fails here regardless of which surface triggered it.

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

const mkTier = (tier: Tier, count: number): RankedItem[] =>
  Array.from({ length: count }, (_, i) => mkItem(i, tier, i));

const newItem = (id = 'new1'): RankedItem =>
  ({ id, title: 'New Movie', genres: ['Drama'], tier: Tier.A, rank: 0, globalScore: 7.5 } as RankedItem);

describe('createCeremonyDriver — comparison-selection loop (shared engine)', () => {
  it('empty tier → immediate placement at rank 0, no comparison shown', () => {
    const d = createCeremonyDriver();
    const step = d.begin(newItem(), Tier.A, []);
    expect(step).toEqual({ kind: 'placed', rank: 0 });
    expect(d.current()).toBeNull();
  });

  it('drives the SAME binary-search candidate selection as RankingSession', () => {
    // Same seed as a raw RankingSession — the driver must not reshape selection.
    const items = mkTier(Tier.A, 3);
    const d = createCeremonyDriver();
    const step = d.begin(newItem(), Tier.A, items);
    if (step.kind !== 'compare') throw new Error('expected a comparison');
    expect(step.comparison.movieB.id).toBe('m0');
    expect(step.comparison.phase).toBe('binary_search');

    const raw = new RankingSession(newItem(), Tier.A, items).start();
    if (raw.type !== 'comparison') throw new Error('expected comparison');
    expect(step.comparison.movieB.id).toBe(raw.comparison.movieB.id);
  });

  it('runs the loop to placement (compare_all: new wins round 2 → rank 1)', () => {
    const d = createCeremonyDriver();
    d.begin(newItem(), Tier.A, mkTier(Tier.A, 3));
    const r1 = d.choose('existing');
    if (r1.kind !== 'compare') throw new Error('expected comparison');
    expect(r1.comparison.movieB.id).toBe('m1');
    const r2 = d.choose('new');
    expect(r2).toEqual({ kind: 'placed', rank: 1 });
  });

  it('re-entrancy guard: a second choose while processing does not double-submit', () => {
    // Simulate the double-tap by making submit re-enter choose synchronously.
    const d = createCeremonyDriver();
    d.begin(newItem(), Tier.A, mkTier(Tier.A, 3));
    const submitSpy = vi.fn();
    // First resolve advances the loop; the guard only blocks *nested* calls.
    // Prove the guard by nesting: call choose from inside onCompare.
    const d2 = createCeremonyDriver({
      onCompare: () => {
        submitSpy();
        // Nested choose must be a no-op (idle) because processing is true.
        expect(d2.choose('new')).toEqual({ kind: 'idle' });
      },
      getLogContext: () => ({ item: newItem(), tier: Tier.A }),
    });
    d2.begin(newItem(), Tier.A, mkTier(Tier.A, 3));
    const r = d2.choose('existing');
    expect(submitSpy).toHaveBeenCalledTimes(1);
    // The outer choose still resolves to the real next step, not idle.
    expect(r.kind).toBe('compare');
  });

  it('undo steps back one comparison; replay reproduces the same placement', () => {
    const d = createCeremonyDriver();
    const first = d.begin(newItem(), Tier.A, mkTier(Tier.A, 3));
    if (first.kind !== 'compare') throw new Error('expected comparison');
    d.choose('existing');
    const undone = d.undo();
    if (undone.kind !== 'compare') throw new Error('expected restored comparison');
    expect(undone.comparison.movieB.id).toBe(first.comparison.movieB.id);
    const replay = d.choose('existing');
    if (replay.kind !== 'compare') throw new Error('expected comparison');
    expect(replay.comparison.movieB.id).toBe('m1');
  });

  it('choose with no active comparison is idle (no stale placement)', () => {
    const d = createCeremonyDriver();
    expect(d.choose('new')).toEqual({ kind: 'idle' });
  });

  it('engine path (>20 items) converges to a numeric placement', () => {
    const d = createCeremonyDriver();
    let step = d.begin(newItem(), Tier.A, mkTier(Tier.A, 25));
    let guard = 0;
    while (step.kind === 'compare' && guard < 40) {
      step = d.choose('new');
      guard++;
    }
    expect(step.kind).toBe('placed');
  });
});

describe('createCeremonyDriver — comparison logging', () => {
  it('emits one ComparisonLogEntry per choice with the run sessionId', () => {
    const logs: ComparisonLogEntry[] = [];
    const d = createCeremonyDriver({
      newSessionId: () => 'run-42',
      onCompare: (l) => logs.push(l),
      getLogContext: () => ({ item: newItem(), tier: Tier.A }),
    });
    d.begin(newItem(), Tier.A, mkTier(Tier.A, 3));
    d.choose('existing');
    d.choose('new');
    expect(logs).toHaveLength(2);
    expect(logs[0].sessionId).toBe('run-42');
    expect(logs[0].winner).toBe('b');
    expect(logs[1].winner).toBe('a');
    expect(logs[0].phase).toBe('binary_search');
  });

  it('omits the log when no (item, tier) context is set', () => {
    const logs: ComparisonLogEntry[] = [];
    const d = createCeremonyDriver({
      onCompare: (l) => logs.push(l),
      getLogContext: () => ({ item: null, tier: null }),
    });
    d.begin(newItem(), Tier.A, mkTier(Tier.A, 3));
    d.choose('existing');
    expect(logs).toHaveLength(0);
  });
});
