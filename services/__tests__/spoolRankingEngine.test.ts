import { describe, it, expect } from 'vitest';
import { SpoolRankingEngine } from '../spoolRankingEngine';
import { Tier, Bracket, RankedItem, PredictionSignals } from '../../types';

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeItem(
  id: string,
  tier: Tier,
  rank: number,
  genres: string[],
  opts?: Partial<RankedItem>,
): RankedItem {
  return {
    id,
    title: `Movie ${id}`,
    year: '2024',
    posterUrl: '',
    type: 'movie',
    genres,
    tier,
    rank,
    ...opts,
  };
}

/** The new movie being ranked (not yet placed). */
function makeNewMovie(id: string, genres: string[], tier: Tier): RankedItem {
  return makeItem(id, tier, -1, genres);
}

function makeSignals(overrides?: Partial<PredictionSignals>): PredictionSignals {
  return {
    genreAffinity: 8.0,
    globalScore: 7.5,
    bracketAffinity: 7.0,
    totalRanked: 20,
    ...overrides,
  };
}

// ── Tests ────────────────────────────────────────────────────────────────────

describe('SpoolRankingEngine', () => {
  // ── Edge case: first movie in tier ────────────────────────────────────────

  describe('first movie in tier', () => {
    it('returns done immediately with rank 0 and midpoint score', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      const allItems: RankedItem[] = []; // no items in any tier
      const signals = makeSignals();

      const result = engine.start(newMovie, Tier.A, allItems, signals);

      expect(result.type).toBe('done');
      expect(result.finalRank).toBe(0);
      // A-tier midpoint: (7.0 + 8.9) / 2 = 7.95
      expect(result.finalScore).toBeCloseTo(7.95, 1);
    });
  });

  // ── Edge case: first in genre within tier ─────────────────────────────────

  describe('first in genre within tier', () => {
    it('skips probe/escalation and goes to cross-genre comparison', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Horror'], Tier.A);
      // Existing items in A-tier but different genre
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Comedy']),
        makeItem('a2', Tier.A, 1, ['Drama']),
      ];
      const signals = makeSignals();

      const result = engine.start(newMovie, Tier.A, allItems, signals);

      expect(result.type).toBe('comparison');
      expect(result.comparison!.phase).toBe('cross_genre');
      expect(result.comparison!.movieA.id).toBe('new');
      // The cross-genre movie should be a different-genre movie
      expect(result.comparison!.movieB.genres[0]).not.toBe('Horror');
    });
  });

  // ── Edge case: only 1 same-genre movie in tier ────────────────────────────

  describe('single same-genre movie in tier', () => {
    it('starts with probe phase against the one same-genre movie', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Action']),
        makeItem('a2', Tier.A, 1, ['Comedy']),
      ];
      const signals = makeSignals();

      const result = engine.start(newMovie, Tier.A, allItems, signals);

      expect(result.type).toBe('comparison');
      expect(result.comparison!.phase).toBe('probe');
      expect(result.comparison!.movieB.genres[0]).toBe('Action');
    });
  });

  // ── Probe phase ───────────────────────────────────────────────────────────

  describe('probe phase', () => {
    it('probe loss: skips to settlement', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Action']),
        makeItem('a2', Tier.A, 1, ['Action']),
        makeItem('a3', Tier.A, 2, ['Comedy']),
      ];
      const signals = makeSignals();

      const result = engine.start(newMovie, Tier.A, allItems, signals);
      expect(result.type).toBe('comparison');
      expect(result.comparison!.phase).toBe('probe');

      // New movie LOSES to probe target (existing movie wins)
      const probeTargetId = result.comparison!.movieB.id;
      const lossResult = engine.submitChoice(probeTargetId);

      // After probe loss: should go to settlement (or done if no more comparisons needed)
      // The spec says: loss in probe → search downward in genre → skip to settlement
      expect(lossResult.type).toBe('comparison');
      expect(lossResult.comparison!.phase).toBe('settlement');
    });

    it('probe win: escalates', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Action']),
        makeItem('a2', Tier.A, 1, ['Action']),
        makeItem('a3', Tier.A, 2, ['Action']),
        makeItem('a4', Tier.A, 3, ['Comedy']),
      ];
      const signals = makeSignals();

      const result = engine.start(newMovie, Tier.A, allItems, signals);
      expect(result.comparison!.phase).toBe('probe');

      // New movie WINS (user picks new movie as winner)
      const escalateResult = engine.submitChoice('new');

      expect(escalateResult.type).toBe('comparison');
      expect(escalateResult.comparison!.phase).toBe('escalation');
    });
  });

  // ── Escalation phase ─────────────────────────────────────────────────────

  describe('escalation phase', () => {
    it('wins all in genre: becomes #1, goes to cross-genre', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Action']),
        makeItem('a2', Tier.A, 1, ['Action']),
        makeItem('a3', Tier.A, 2, ['Comedy']),
      ];
      const signals = makeSignals();

      // Start -> probe
      const probeResult = engine.start(newMovie, Tier.A, allItems, signals);
      expect(probeResult.comparison!.phase).toBe('probe');

      // Win probe -> escalation
      const escResult = engine.submitChoice('new');
      expect(escResult.comparison!.phase).toBe('escalation');

      // Win escalation against top of genre -> if this was the top, cross-genre
      // Escalation starts from top of genre and works down.
      // We need to keep winning until we've beaten all genre peers.
      let current = escResult;
      while (current.type === 'comparison' && current.comparison!.phase === 'escalation') {
        current = engine.submitChoice('new'); // keep winning
      }

      // Should be cross-genre now
      expect(current.type).toBe('comparison');
      expect(current.comparison!.phase).toBe('cross_genre');
    });

    it('loss in escalation: ceiling found, goes to cross-genre', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Action']),
        makeItem('a2', Tier.A, 1, ['Action']),
        makeItem('a3', Tier.A, 2, ['Action']),
        makeItem('a4', Tier.A, 3, ['Comedy']),
      ];
      const signals = makeSignals();

      // Start -> probe
      const probeResult = engine.start(newMovie, Tier.A, allItems, signals);
      // Win probe -> escalation
      const escResult = engine.submitChoice('new');
      expect(escResult.comparison!.phase).toBe('escalation');

      // LOSE in escalation (existing movie wins)
      const loseResult = engine.submitChoice(escResult.comparison!.movieB.id);

      // Ceiling found -> cross-genre
      expect(loseResult.type).toBe('comparison');
      expect(loseResult.comparison!.phase).toBe('cross_genre');
    });
  });

  // ── Cross-genre phase ─────────────────────────────────────────────────────

  describe('cross-genre phase', () => {
    it('confirmation: no score adjustment, proceeds to settlement or done', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Action']),
        makeItem('a2', Tier.A, 1, ['Comedy']),
        makeItem('a3', Tier.A, 2, ['Drama']),
      ];
      const signals = makeSignals();

      // Start -> probe (single genre movie, so probe)
      const probeResult = engine.start(newMovie, Tier.A, allItems, signals);
      expect(probeResult.comparison!.phase).toBe('probe');

      // Win probe -> escalation (only 1 same-genre, so skip escalation -> cross-genre)
      const afterProbe = engine.submitChoice('new');

      // With only 1 same-genre peer and winning probe, should jump to cross-genre
      let current = afterProbe;
      while (current.type === 'comparison' && current.comparison!.phase === 'escalation') {
        current = engine.submitChoice('new');
      }

      // Assert we reached cross-genre phase unconditionally
      expect(current.type).toBe('comparison');
      expect(current.comparison!.phase).toBe('cross_genre');

      // New movie wins cross-genre (confirms placement)
      const settleResult = engine.submitChoice('new');
      // After cross-genre confirmation -> settlement or done
      if (settleResult.type === 'comparison') {
        expect(settleResult.comparison!.phase).toBe('settlement');
      } else {
        expect(settleResult.type).toBe('done');
      }
    });

    it('contradiction: adjusts score, proceeds to settlement or done', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Action']),
        makeItem('a2', Tier.A, 1, ['Comedy']),
        makeItem('a3', Tier.A, 2, ['Drama']),
      ];
      const signals = makeSignals();

      // Navigate to cross-genre phase
      const probeResult = engine.start(newMovie, Tier.A, allItems, signals);
      let current = engine.submitChoice('new'); // win probe
      while (current.type === 'comparison' && current.comparison!.phase === 'escalation') {
        current = engine.submitChoice('new');
      }

      // Assert we reached cross-genre phase unconditionally
      expect(current.type).toBe('comparison');
      expect(current.comparison!.phase).toBe('cross_genre');

      const crossGenreTarget = current.comparison!.movieB.id;
      // New movie LOSES cross-genre (contradicts placement)
      const result = engine.submitChoice(crossGenreTarget);
      // Should proceed to settlement (score was adjusted down) or done
      if (result.type === 'comparison') {
        expect(result.comparison!.phase).toBe('settlement');
      } else {
        expect(result.type).toBe('done');
      }
    });
  });

  // ── Settlement phase ──────────────────────────────────────────────────────

  describe('settlement phase', () => {
    it('produces final rank and score', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Action']),
        makeItem('a2', Tier.A, 1, ['Comedy']),
      ];
      const signals = makeSignals();

      // Navigate through all phases to settlement
      let result = engine.start(newMovie, Tier.A, allItems, signals);

      // Progress through all comparisons until done
      let safetyCounter = 0;
      while (result.type === 'comparison' && safetyCounter < 20) {
        // Always pick new movie as winner to progress through phases
        result = engine.submitChoice('new');
        safetyCounter++;
      }

      expect(result.type).toBe('done');
      expect(result.finalRank).toBeDefined();
      expect(result.finalScore).toBeDefined();
      expect(result.finalRank!).toBeGreaterThanOrEqual(0);
      expect(result.finalScore!).toBeGreaterThanOrEqual(7.0); // A-tier min
      expect(result.finalScore!).toBeLessThanOrEqual(8.9); // A-tier max
    });
  });

  // ── Skip ──────────────────────────────────────────────────────────────────

  describe('skip', () => {
    it('returns done with tentative score and rank', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Action']),
        makeItem('a2', Tier.A, 1, ['Action']),
        makeItem('a3', Tier.A, 2, ['Comedy']),
      ];
      const signals = makeSignals();

      const result = engine.start(newMovie, Tier.A, allItems, signals);
      expect(result.type).toBe('comparison');

      const skipResult = engine.skip();
      expect(skipResult.type).toBe('done');
      expect(skipResult.finalRank).toBeDefined();
      expect(skipResult.finalScore).toBeDefined();
      expect(skipResult.finalScore!).toBeGreaterThanOrEqual(7.0);
      expect(skipResult.finalScore!).toBeLessThanOrEqual(8.9);
    });
  });

  // ── Undo ──────────────────────────────────────────────────────────────────

  describe('undo', () => {
    it('returns null when no history', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Action']),
        makeItem('a2', Tier.A, 1, ['Action']),
      ];
      const signals = makeSignals();

      engine.start(newMovie, Tier.A, allItems, signals);

      const undoResult = engine.undo();
      expect(undoResult).toBeNull();
    });

    it('reverts to previous comparison after one choice', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Action']),
        makeItem('a2', Tier.A, 1, ['Action']),
        makeItem('a3', Tier.A, 2, ['Action']),
        makeItem('a4', Tier.A, 3, ['Comedy']),
      ];
      const signals = makeSignals();

      const firstResult = engine.start(newMovie, Tier.A, allItems, signals);
      expect(firstResult.comparison!.phase).toBe('probe');
      const firstMovieB = firstResult.comparison!.movieB.id;

      // Make a choice
      const secondResult = engine.submitChoice('new');

      // Undo should return us to the probe comparison
      const undoResult = engine.undo();
      expect(undoResult).not.toBeNull();
      expect(undoResult!.type).toBe('comparison');
      expect(undoResult!.comparison!.phase).toBe('probe');
      expect(undoResult!.comparison!.movieB.id).toBe(firstMovieB);
    });

    it('supports multiple undos', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Action']),
        makeItem('a2', Tier.A, 1, ['Action']),
        makeItem('a3', Tier.A, 2, ['Action']),
        makeItem('a4', Tier.A, 3, ['Comedy']),
      ];
      const signals = makeSignals();

      const first = engine.start(newMovie, Tier.A, allItems, signals);
      const second = engine.submitChoice('new');  // win probe -> escalation
      const third = engine.submitChoice('new');   // win escalation -> next

      // Undo twice
      const undo1 = engine.undo();
      expect(undo1).not.toBeNull();
      expect(undo1!.comparison!.phase).toBe(second.comparison!.phase);

      const undo2 = engine.undo();
      expect(undo2).not.toBeNull();
      expect(undo2!.comparison!.phase).toBe(first.comparison!.phase);

      // No more history
      const undo3 = engine.undo();
      expect(undo3).toBeNull();
    });
  });

  // ── Full flow ─────────────────────────────────────────────────────────────

  describe('full flow', () => {
    it('completes a full ranking from start to done', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Action']),
        makeItem('a2', Tier.A, 1, ['Action']),
        makeItem('a3', Tier.A, 2, ['Action']),
        makeItem('a4', Tier.A, 3, ['Drama']),
        makeItem('a5', Tier.A, 4, ['Comedy']),
      ];
      const signals = makeSignals();

      let result = engine.start(newMovie, Tier.A, allItems, signals);
      const phases: string[] = [];
      let safetyCounter = 0;

      while (result.type === 'comparison' && safetyCounter < 20) {
        phases.push(result.comparison!.phase);
        // Alternate wins/losses for realistic flow
        if (result.comparison!.phase === 'probe') {
          result = engine.submitChoice('new'); // win probe -> escalate
        } else if (result.comparison!.phase === 'escalation') {
          // Lose in escalation to find ceiling
          result = engine.submitChoice(result.comparison!.movieB.id);
        } else if (result.comparison!.phase === 'cross_genre') {
          result = engine.submitChoice('new'); // confirm cross-genre
        } else if (result.comparison!.phase === 'settlement') {
          result = engine.submitChoice('new'); // settle
        } else {
          result = engine.submitChoice('new');
        }
        safetyCounter++;
      }

      expect(result.type).toBe('done');
      expect(result.finalRank).toBeDefined();
      expect(result.finalScore).toBeDefined();
      expect(result.finalScore!).toBeGreaterThanOrEqual(7.0);
      expect(result.finalScore!).toBeLessThanOrEqual(8.9);

      // Should have gone through probe -> escalation -> cross_genre
      expect(phases).toContain('probe');
      expect(phases).toContain('escalation');
      expect(phases).toContain('cross_genre');
    });

    it('handles losing every comparison (worst placement)', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.B);
      const allItems = [
        makeItem('b1', Tier.B, 0, ['Action']),
        makeItem('b2', Tier.B, 1, ['Action']),
        makeItem('b3', Tier.B, 2, ['Comedy']),
      ];
      const signals = makeSignals({ genreAffinity: 6.0, globalScore: 5.5, bracketAffinity: 5.0 });

      let result = engine.start(newMovie, Tier.B, allItems, signals);
      let safetyCounter = 0;

      while (result.type === 'comparison' && safetyCounter < 20) {
        // Always lose - pick the existing movie
        result = engine.submitChoice(result.comparison!.movieB.id);
        safetyCounter++;
      }

      expect(result.type).toBe('done');
      expect(result.finalRank).toBeDefined();
      expect(result.finalScore).toBeDefined();
      expect(result.finalScore!).toBeGreaterThanOrEqual(5.0); // B-tier min
      expect(result.finalScore!).toBeLessThanOrEqual(6.9); // B-tier max
    });
  });

  // ── Score-to-rank conversion ──────────────────────────────────────────────

  describe('score-to-rank conversion', () => {
    it('places at correct rank based on final score', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      // Items are ranked 0 (best) to 4 (worst) within A-tier
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Action']),
        makeItem('a2', Tier.A, 1, ['Action']),
        makeItem('a3', Tier.A, 2, ['Action']),
        makeItem('a4', Tier.A, 3, ['Action']),
        makeItem('a5', Tier.A, 4, ['Comedy']),
      ];
      const signals = makeSignals();

      let result = engine.start(newMovie, Tier.A, allItems, signals);
      let safetyCounter = 0;

      while (result.type === 'comparison' && safetyCounter < 20) {
        result = engine.submitChoice('new'); // always win
        safetyCounter++;
      }

      expect(result.type).toBe('done');
      // Winning everything should place near the top
      expect(result.finalRank).toBe(0);
    });
  });

  // ── Engine state validation ───────────────────────────────────────────────

  describe('engine state validation', () => {
    it('submitChoice throws if engine not started', () => {
      const engine = new SpoolRankingEngine();
      expect(() => engine.submitChoice('something')).toThrow();
    });

    it('skip throws if engine not started', () => {
      const engine = new SpoolRankingEngine();
      expect(() => engine.skip()).toThrow();
    });

    it('submitChoice throws if engine already complete', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      const result = engine.start(newMovie, Tier.A, [], makeSignals());
      expect(result.type).toBe('done');
      expect(() => engine.submitChoice('something')).toThrow();
    });
  });

  // ── No cross-genre when only one genre present ────────────────────────────

  describe('no cross-genre movie available', () => {
    it('skips cross-genre and goes straight to settlement when no different-genre movies in tier', () => {
      const engine = new SpoolRankingEngine();
      const newMovie = makeNewMovie('new', ['Action'], Tier.A);
      // All movies are same genre
      const allItems = [
        makeItem('a1', Tier.A, 0, ['Action']),
        makeItem('a2', Tier.A, 1, ['Action']),
        makeItem('a3', Tier.A, 2, ['Action']),
      ];
      const signals = makeSignals();

      let result = engine.start(newMovie, Tier.A, allItems, signals);
      const phases: string[] = [];
      let safetyCounter = 0;

      while (result.type === 'comparison' && safetyCounter < 20) {
        phases.push(result.comparison!.phase);
        result = engine.submitChoice('new');
        safetyCounter++;
      }

      expect(result.type).toBe('done');
      // Should NOT include cross_genre since all items are same genre
      expect(phases).not.toContain('cross_genre');
    });
  });
});
