/**
 * RankingSession — uniform facade over the placement strategies.
 *
 * Strategy by target-tier size:
 *   0      → immediate insert at rank 0
 *   1–5    → compare_all sequential walk       (advanceSmallTier)
 *   6–20   → seed pivot + quartile narrowing   (advanceSmallTier)
 *   21+    → 5-phase genre-anchored engine     (SpoolRankingEngine)
 *
 * Replaces the inline smallTierRef/engineRef copies previously duplicated
 * across RankingFlowModal, AddMediaModal, AddTVSeasonModal, and
 * MovieOnboardingPage. finalScore is null on small-tier/empty paths
 * (rank-only insertion; scores are recomputed by computeAllScores at
 * persist time) and numeric on the engine path.
 */

import { Tier, RankedItem, ComparisonRequest, EngineResult } from '../types';
import { TIER_SCORE_RANGES } from '../constants';
import { SpoolRankingEngine } from './spoolRankingEngine';
import { computePredictionSignals } from './spoolPrediction';
import {
  advanceSmallTier,
  classifyBracket,
  computeSeedIndex,
  computeTierScore,
  SmallTierState,
} from './rankingAlgorithm';

export type SessionChoice = 'new' | 'existing' | 'too_tough' | 'skip';

export type SessionResult =
  | { type: 'comparison'; comparison: ComparisonRequest }
  | { type: 'done'; finalRank: number; finalScore: number | null };

const SMALL_TIER_QUESTION = 'Which do you prefer?';

interface SmallSnapshot {
  state: SmallTierState;
  comparison: ComparisonRequest;
}

export class RankingSession {
  private readonly newItem: RankedItem;
  private readonly tier: Tier;
  private readonly allItems: RankedItem[];

  private engine: SpoolRankingEngine | null = null;
  private small: SmallTierState | null = null;
  private tierItems: RankedItem[] = [];
  private smallHistory: SmallSnapshot[] = [];
  private current: ComparisonRequest | null = null;

  constructor(newItem: RankedItem, tier: Tier, allItems: RankedItem[]) {
    this.newItem = newItem;
    this.tier = tier;
    this.allItems = allItems;
  }

  start(): SessionResult {
    // Reset all session state so re-entrant start() calls never leak
    // history or an active strategy from a previous run.
    this.engine = null;
    this.small = null;
    this.smallHistory = [];
    this.current = null;

    this.tierItems = this.allItems
      .filter((i) => i.tier === this.tier)
      .sort((a, b) => a.rank - b.rank);

    if (this.tierItems.length === 0) {
      return { type: 'done', finalRank: 0, finalScore: null };
    }

    if (this.tierItems.length <= 5) {
      this.small = {
        mode: 'compare_all',
        tierCount: this.tierItems.length,
        low: 0,
        high: this.tierItems.length,
        mid: 0,
        round: 1,
        seedIdx: 0,
      };
      return this.emitSmallComparison();
    }

    if (this.tierItems.length <= 20) {
      const range = TIER_SCORE_RANGES[this.tier];
      const tierScores = this.tierItems.map((_, idx) =>
        computeTierScore(idx, this.tierItems.length, range.min, range.max),
      );
      const seedIdx = computeSeedIndex(tierScores, range.min, range.max, this.newItem.globalScore);
      this.small = {
        mode: 'seed',
        tierCount: this.tierItems.length,
        low: 0,
        high: this.tierItems.length,
        mid: seedIdx,
        round: 1,
        seedIdx,
      };
      return this.emitSmallComparison();
    }

    this.engine = new SpoolRankingEngine();
    const bracket = this.newItem.bracket ?? classifyBracket(this.newItem.genres);
    const signals = computePredictionSignals(
      this.allItems,
      this.newItem.genres[0] ?? '',
      bracket,
      this.newItem.globalScore,
      this.tier,
    );
    return this.mapEngineResult(
      this.engine.start(this.newItem, this.tier, this.allItems, signals),
    );
  }

  submit(choice: SessionChoice): SessionResult {
    if (this.small) return this.submitSmall(choice);
    if (this.engine) return this.submitEngine(choice);
    // Reached before start() or after done — either way there is no active
    // comparison to resolve.
    throw new Error('RankingSession.submit: no active comparison');
  }

  undo(): SessionResult | null {
    if (this.small || this.smallHistory.length > 0) {
      const snap = this.smallHistory.pop();
      if (!snap) return null;
      this.small = snap.state;
      this.current = snap.comparison;
      return { type: 'comparison', comparison: snap.comparison };
    }
    if (this.engine) {
      const r = this.engine.undo();
      if (!r || !r.comparison) return null;
      this.current = r.comparison;
      return { type: 'comparison', comparison: r.comparison };
    }
    return null;
  }

  // ── small-tier path ──────────────────────────────────────────────────

  private submitSmall(choice: SessionChoice): SessionResult {
    const st = this.small!;
    // Snapshot the comparison being resolved (or finalized by too_tough/skip)
    // so undo() restores it, not the one from a step earlier.
    if (this.current) {
      this.smallHistory.push({ state: st, comparison: this.current });
    }
    if (choice === 'too_tough' || choice === 'skip') {
      this.small = null;
      return { type: 'done', finalRank: st.mid, finalScore: null };
    }
    const step = advanceSmallTier(st, choice);
    if (step.type === 'done') {
      this.small = null;
      return { type: 'done', finalRank: step.rank, finalScore: null };
    }
    this.small = step.state;
    return this.emitSmallComparison();
  }

  private emitSmallComparison(): SessionResult {
    const st = this.small!;
    const comparison: ComparisonRequest = {
      movieA: this.newItem,
      movieB: this.tierItems[st.mid],
      question: SMALL_TIER_QUESTION,
      phase: 'binary_search',
      round: st.round,
    };
    this.current = comparison;
    return { type: 'comparison', comparison };
  }

  // ── engine path ──────────────────────────────────────────────────────

  private submitEngine(choice: SessionChoice): SessionResult {
    const engine = this.engine!;
    if (choice === 'too_tough' || choice === 'skip') {
      return this.mapEngineResult(engine.skip());
    }
    if (!this.current) {
      // An empty-string winnerId would silently mean "movieB wins" —
      // surface the programming error instead.
      throw new Error('RankingSession.submit: no active comparison');
    }
    const winnerId = choice === 'new' ? this.newItem.id : this.current.movieB.id;
    return this.mapEngineResult(engine.submitChoice(winnerId));
  }

  private mapEngineResult(r: EngineResult): SessionResult {
    if (r.type === 'done') {
      // Clear the strategy so a stray post-done submit() fails with this
      // session's own error instead of leaking into the finished engine.
      this.engine = null;
      this.current = null;
      return { type: 'done', finalRank: r.finalRank!, finalScore: r.finalScore! };
    }
    this.current = r.comparison!;
    return { type: 'comparison', comparison: r.comparison! };
  }
}
