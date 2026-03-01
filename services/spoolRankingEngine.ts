/**
 * SpoolRankingEngine — Genre-Anchored Ranking State Machine
 *
 * Pure TypeScript class with no React, no Supabase, no side effects.
 * Determines movie placement within a tier through a 5-phase
 * genre-anchored comparison flow:
 *
 *   1. Prediction  — compute predicted score
 *   2. Probe       — compare vs nearest same-genre movie at ~predicted score
 *   3. Escalation  — compare from top of genre downward until loss
 *   4. Cross-Genre — compare vs different-genre movie at ~same score
 *   5. Settlement  — final same-genre comparison to lock position
 */

import {
  Tier,
  RankedItem,
  EnginePhase,
  ComparisonRequest,
  EngineResult,
  PredictionSignals,
} from '../types';
import { TIER_SCORE_RANGES } from '../constants';
import { predictScore } from './spoolPrediction';
import { getComparisonPrompt } from './spoolPrompts';
import { computeTierScore } from './rankingAlgorithm';

// ── Internal State ──────────────────────────────────────────────────────────

interface EngineSnapshot {
  phase: EnginePhase;
  tentativeScore: number;
  probeIndex: number;
  escalationIndex: number;
  crossGenreAdjustment: number;
  comparisonResult: ComparisonRequest;
  comparedIds: Set<string>;
  comparisonCount: number;
}

interface ScoredItem {
  item: RankedItem;
  score: number;
}

// ── Engine ──────────────────────────────────────────────────────────────────

export class SpoolRankingEngine {
  // Core state
  private phase: EnginePhase = 'prediction';
  private started = false;

  // Movie being ranked
  private newMovie!: RankedItem;
  private tier!: Tier;

  // Tier items and genre items (computed at start)
  private tierItems: ScoredItem[] = [];
  private sameGenreItems: ScoredItem[] = [];
  private diffGenreItems: ScoredItem[] = [];
  private primaryGenre = '';

  // Score tracking
  private tentativeScore = 0;
  private crossGenreAdjustment = 0;

  // Phase cursors
  private probeIndex = -1;       // index into sameGenreItems for probe target
  private escalationIndex = -1;  // index into sameGenreItems, starts from top (0)

  // Undo stack
  private history: EngineSnapshot[] = [];

  // Current comparison (for validation)
  private currentComparison: ComparisonRequest | null = null;

  // Track IDs of movies already compared against (for dedup in settlement)
  private comparedIds: Set<string> = new Set();

  // Comparison counter (1-indexed, incremented each time a comparison is emitted)
  private comparisonCount = 0;

  // ── Public API ──────────────────────────────────────────────────────────

  /**
   * Start the ranking engine for a new movie.
   *
   * @param newMovie   The movie to rank (rank field is ignored)
   * @param tier       The tier the user placed the movie into
   * @param allItems   All currently ranked items across all tiers
   * @param signals    Pre-computed prediction signals
   * @returns          First comparison request, or done if no comparisons needed
   */
  start(
    newMovie: RankedItem,
    tier: Tier,
    allItems: RankedItem[],
    signals: PredictionSignals,
  ): EngineResult {
    this.newMovie = newMovie;
    this.tier = tier;
    this.started = true;
    this.phase = 'prediction';
    this.history = [];
    this.crossGenreAdjustment = 0;
    this.currentComparison = null;
    this.comparedIds = new Set();
    this.comparisonCount = 0;

    const range = TIER_SCORE_RANGES[tier];
    this.primaryGenre = newMovie.genres.length > 0 ? newMovie.genres[0] : '';

    // Compute tier items with scores
    const tierItemsRaw = allItems
      .filter((item) => item.tier === tier)
      .sort((a, b) => a.rank - b.rank);

    this.tierItems = tierItemsRaw.map((item) => ({
      item,
      score: computeTierScore(item.rank, tierItemsRaw.length, range.min, range.max),
    }));

    // Split by genre
    this.sameGenreItems = this.tierItems.filter(
      (si) => si.item.genres.length > 0 && si.item.genres[0] === this.primaryGenre,
    );
    this.diffGenreItems = this.tierItems.filter(
      (si) => si.item.genres.length === 0 || si.item.genres[0] !== this.primaryGenre,
    );

    // ── Phase 1: Prediction ─────────────────────────────────────────────
    this.tentativeScore = predictScore(signals, tier);

    // ── Edge case: first movie in tier ──────────────────────────────────
    if (this.tierItems.length === 0) {
      this.phase = 'complete';
      const midpoint = (range.min + range.max) / 2;
      return {
        type: 'done',
        finalRank: 0,
        finalScore: Math.round(midpoint * 100) / 100,
      };
    }

    // ── Edge case: first in genre within tier ───────────────────────────
    if (this.sameGenreItems.length === 0) {
      // Skip probe and escalation, go directly to cross-genre
      this.phase = 'cross_genre';
      return this.emitCrossGenre();
    }

    // ── Phase 2: Probe ──────────────────────────────────────────────────
    this.phase = 'probe';
    this.probeIndex = this.findNearestGenreIndex(this.tentativeScore);
    return this.emitProbeComparison();
  }

  /**
   * Submit the user's choice for the current comparison.
   *
   * @param winnerId  The id of the movie the user preferred
   * @returns         Next comparison request, or done
   */
  submitChoice(winnerId: string): EngineResult {
    if (!this.started || this.phase === 'complete') {
      throw new Error('Engine not in active comparison state');
    }

    const newMovieWins = winnerId === this.newMovie.id;

    // Save snapshot before state transition
    this.pushSnapshot();

    switch (this.phase) {
      case 'probe':
        return this.handleProbeResult(newMovieWins);
      case 'escalation':
        return this.handleEscalationResult(newMovieWins);
      case 'cross_genre':
        return this.handleCrossGenreResult(newMovieWins);
      case 'settlement':
        return this.handleSettlementResult(newMovieWins);
      default:
        throw new Error(`Unexpected phase: ${this.phase}`);
    }
  }

  /**
   * Skip the current comparison. Places at tentative score.
   */
  skip(): EngineResult {
    if (!this.started || this.phase === 'complete') {
      throw new Error('Engine not in active comparison state');
    }

    this.phase = 'complete';
    return this.computeFinalPlacement();
  }

  /**
   * Undo the last comparison choice.
   *
   * @returns  The previous comparison request, or null if no history
   */
  undo(): EngineResult | null {
    if (this.history.length === 0) {
      return null;
    }

    const snapshot = this.history.pop()!;
    this.phase = snapshot.phase;
    this.tentativeScore = snapshot.tentativeScore;
    this.probeIndex = snapshot.probeIndex;
    this.escalationIndex = snapshot.escalationIndex;
    this.crossGenreAdjustment = snapshot.crossGenreAdjustment;
    this.currentComparison = snapshot.comparisonResult;
    this.comparedIds = snapshot.comparedIds;
    this.comparisonCount = snapshot.comparisonCount;

    return {
      type: 'comparison',
      comparison: snapshot.comparisonResult,
    };
  }

  // ── Phase Handlers ────────────────────────────────────────────────────

  private handleProbeResult(newMovieWins: boolean): EngineResult {
    if (newMovieWins) {
      // Probe WIN -> escalate
      // Update tentative score upward (above probe target)
      const probeTarget = this.sameGenreItems[this.probeIndex];
      this.tentativeScore = Math.min(
        TIER_SCORE_RANGES[this.tier].max,
        probeTarget.score + 0.1,
      );

      // If only 1 same-genre movie (already beaten in probe), skip escalation
      if (this.sameGenreItems.length <= 1) {
        this.phase = 'cross_genre';
        return this.emitCrossGenreOrSettle();
      }

      // Escalation: start from top of genre, work down
      this.phase = 'escalation';
      this.escalationIndex = 0;

      // Skip the probe target in escalation (already compared)
      if (this.escalationIndex === this.probeIndex) {
        this.escalationIndex++;
      }
      if (this.escalationIndex >= this.sameGenreItems.length) {
        // Already beaten all (probe target was the only one or the top)
        this.phase = 'cross_genre';
        return this.emitCrossGenreOrSettle();
      }

      return this.emitEscalationComparison();
    } else {
      // Probe LOSS -> set ceiling, search downward through genre movies
      const probeTarget = this.sameGenreItems[this.probeIndex];
      const tierMin = TIER_SCORE_RANGES[this.tier].min;

      // Look for same-genre items with score below the probe target
      const genreBelowProbe = this.sameGenreItems
        .filter((si) => si.score < probeTarget.score)
        .sort((a, b) => b.score - a.score); // highest first (nearest below)

      if (genreBelowProbe.length > 0) {
        // Set tentative score to the next nearest lower genre movie
        this.tentativeScore = genreBelowProbe[0].score;
      } else {
        // No genre movies below probe — use floor
        this.tentativeScore = Math.max(tierMin, probeTarget.score - 0.5);
      }

      // Skip to settlement
      this.phase = 'settlement';
      return this.emitSettlementOrDone();
    }
  }

  private handleEscalationResult(newMovieWins: boolean): EngineResult {
    if (newMovieWins) {
      // Beat this escalation target, update score above it
      const target = this.sameGenreItems[this.escalationIndex];
      this.tentativeScore = Math.min(
        TIER_SCORE_RANGES[this.tier].max,
        target.score + 0.1,
      );

      // Move to next escalation target
      this.escalationIndex++;
      // Skip probe target (already compared)
      if (this.escalationIndex === this.probeIndex) {
        this.escalationIndex++;
      }

      if (this.escalationIndex >= this.sameGenreItems.length) {
        // Won all escalation comparisons -> new #1 in genre
        this.tentativeScore = TIER_SCORE_RANGES[this.tier].max;
        this.phase = 'cross_genre';
        return this.emitCrossGenreOrSettle();
      }

      return this.emitEscalationComparison();
    } else {
      // Ceiling found: place below this target
      const target = this.sameGenreItems[this.escalationIndex];
      this.tentativeScore = Math.max(
        TIER_SCORE_RANGES[this.tier].min,
        target.score - 0.1,
      );

      this.phase = 'cross_genre';
      return this.emitCrossGenreOrSettle();
    }
  }

  private handleCrossGenreResult(newMovieWins: boolean): EngineResult {
    if (!newMovieWins) {
      // Contradiction: new movie lost to a cross-genre peer -> adjust down
      this.crossGenreAdjustment = -0.3;
      this.tentativeScore = Math.max(
        TIER_SCORE_RANGES[this.tier].min,
        this.tentativeScore - 0.3,
      );
    }
    // If newMovieWins: confirmation, no adjustment

    // Proceed to settlement
    this.phase = 'settlement';
    return this.emitSettlementOrDone();
  }

  private handleSettlementResult(newMovieWins: boolean): EngineResult {
    // Settlement is the final comparison to lock position
    if (newMovieWins) {
      // Nudge score slightly up within bounds
      const settlementTarget = this.currentComparison!.movieB;
      const targetScored = this.tierItems.find((si) => si.item.id === settlementTarget.id);
      if (targetScored) {
        this.tentativeScore = Math.min(
          TIER_SCORE_RANGES[this.tier].max,
          targetScored.score + 0.05,
        );
      }
    } else {
      // Nudge score slightly down within bounds
      const settlementTarget = this.currentComparison!.movieB;
      const targetScored = this.tierItems.find((si) => si.item.id === settlementTarget.id);
      if (targetScored) {
        this.tentativeScore = Math.max(
          TIER_SCORE_RANGES[this.tier].min,
          targetScored.score - 0.05,
        );
      }
    }

    this.phase = 'complete';
    return this.computeFinalPlacement();
  }

  // ── Comparison Emitters ───────────────────────────────────────────────

  private emitProbeComparison(): EngineResult {
    const probeTarget = this.sameGenreItems[this.probeIndex];
    const comparison = this.makeComparison(probeTarget.item, 'probe');
    this.currentComparison = comparison;
    return { type: 'comparison', comparison };
  }

  private emitEscalationComparison(): EngineResult {
    const target = this.sameGenreItems[this.escalationIndex];
    const comparison = this.makeComparison(target.item, 'escalation');
    this.currentComparison = comparison;
    return { type: 'comparison', comparison };
  }

  private emitCrossGenre(): EngineResult {
    if (this.diffGenreItems.length === 0) {
      // No different-genre movies in tier -> skip cross-genre entirely
      this.phase = 'settlement';
      return this.emitSettlementOrDone();
    }

    const crossTarget = this.findNearestDiffGenreItem(this.tentativeScore);
    const comparison = this.makeComparison(crossTarget.item, 'cross_genre');
    this.currentComparison = comparison;
    return { type: 'comparison', comparison };
  }

  private emitCrossGenreOrSettle(): EngineResult {
    if (this.diffGenreItems.length === 0) {
      // No different-genre items available -> skip to settlement
      this.phase = 'settlement';
      return this.emitSettlementOrDone();
    }

    this.phase = 'cross_genre';
    return this.emitCrossGenre();
  }

  private emitSettlementOrDone(): EngineResult {
    // Find a same-genre movie near tentative score for settlement comparison
    const settlementTarget = this.findSettlementTarget();
    if (!settlementTarget) {
      // No suitable settlement target -> done
      this.phase = 'complete';
      return this.computeFinalPlacement();
    }

    const comparison = this.makeComparison(settlementTarget.item, 'settlement');
    this.currentComparison = comparison;
    return { type: 'comparison', comparison };
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  private makeComparison(movieB: RankedItem, phase: EnginePhase): ComparisonRequest {
    const genreA = this.primaryGenre;
    const genreB = movieB.genres.length > 0 ? movieB.genres[0] : '';
    const question = getComparisonPrompt(this.tier, genreA, genreB, phase);

    // Track this movie as compared for dedup
    this.comparedIds.add(movieB.id);

    this.comparisonCount++;

    return {
      movieA: this.newMovie,
      movieB,
      question,
      phase,
      round: this.comparisonCount,
    };
  }

  /**
   * Find the same-genre item whose score is closest to the target score.
   */
  private findNearestGenreIndex(targetScore: number): number {
    let bestIndex = 0;
    let bestDist = Math.abs(this.sameGenreItems[0].score - targetScore);

    for (let i = 1; i < this.sameGenreItems.length; i++) {
      const dist = Math.abs(this.sameGenreItems[i].score - targetScore);
      if (dist < bestDist) {
        bestDist = dist;
        bestIndex = i;
      }
    }

    return bestIndex;
  }

  /**
   * Find the different-genre item whose score is closest to the target score.
   */
  private findNearestDiffGenreItem(targetScore: number): ScoredItem {
    let best = this.diffGenreItems[0];
    let bestDist = Math.abs(best.score - targetScore);

    for (let i = 1; i < this.diffGenreItems.length; i++) {
      const dist = Math.abs(this.diffGenreItems[i].score - targetScore);
      if (dist < bestDist) {
        bestDist = dist;
        best = this.diffGenreItems[i];
      }
    }

    return best;
  }

  /**
   * Find a same-genre movie near the tentative score for settlement.
   * Picks the closest same-genre item that hasn't already been compared against.
   * Returns null if no suitable target exists.
   */
  private findSettlementTarget(): ScoredItem | null {
    if (this.sameGenreItems.length === 0) return null;

    // Filter out movies already compared against
    const candidates = this.sameGenreItems.filter(
      (si) => !this.comparedIds.has(si.item.id),
    );
    if (candidates.length === 0) return null;

    // Find the candidate closest to tentative score
    let best: ScoredItem | null = null;
    let bestDist = Infinity;

    for (const si of candidates) {
      const dist = Math.abs(si.score - this.tentativeScore);
      if (dist < bestDist) {
        bestDist = dist;
        best = si;
      }
    }

    return best;
  }

  /**
   * Convert the tentative score into a final rank position within the tier.
   */
  private computeFinalPlacement(): EngineResult {
    const range = TIER_SCORE_RANGES[this.tier];
    // Clamp tentative score to tier range
    const finalScore = Math.round(
      Math.max(range.min, Math.min(range.max, this.tentativeScore)) * 100,
    ) / 100;

    // Score-to-rank: find where this score slots in.
    // tierItems are sorted by rank (0=best=highest score), so we find the first
    // item whose score is less than or equal to our finalScore, and insert
    // before it. Using <= ensures that when the new movie ties an existing item
    // (e.g. both at tier max after winning all comparisons), the new movie is
    // placed at or above the tied item rather than below it.
    let finalRank = this.tierItems.length; // default: insert at end (worst)
    for (let i = 0; i < this.tierItems.length; i++) {
      if (this.tierItems[i].score <= finalScore) {
        finalRank = i;
        break;
      }
    }

    return {
      type: 'done',
      finalRank,
      finalScore,
    };
  }

  /**
   * Save a snapshot of engine state for undo support.
   */
  private pushSnapshot(): void {
    if (!this.currentComparison) return;

    this.history.push({
      phase: this.phase,
      tentativeScore: this.tentativeScore,
      probeIndex: this.probeIndex,
      escalationIndex: this.escalationIndex,
      crossGenreAdjustment: this.crossGenreAdjustment,
      comparisonResult: { ...this.currentComparison },
      comparedIds: new Set(this.comparedIds),
      comparisonCount: this.comparisonCount,
    });
  }
}
