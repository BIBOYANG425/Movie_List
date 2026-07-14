/**
 * RankingSession — uniform facade over the placement strategies.
 *
 * Strategy by target-tier size:
 *   0      → immediate insert at rank 0
 *   1–5    → compare_all sequential walk         (advanceSmallTier)
 *   6+     → anchor poles + quartile narrowing   (advanceSmallTier)
 *
 * The 21+ five-phase SpoolRankingEngine was RETIRED from placement (owner,
 * 2026-07-14): its probe/settlement openers picked genre-anchored films that
 * read as random in the ceremony ("The Green Inferno vs #16 then #20"), and
 * the owner's anchor spec (best → worst → 25% rule) has no size ceiling. The
 * engine module remains for its standalone consumers/tests; placement no
 * longer calls it.
 *
 * Replaces the inline smallTierRef/engineRef copies previously duplicated
 * across RankingFlowModal, AddMediaModal, AddTVSeasonModal, and
 * MovieOnboardingPage. finalScore is always null on these paths (rank-only
 * insertion; scores are recomputed by computeAllScores at persist time).
 */

import { Tier, RankedItem, ComparisonRequest } from '../types';
import {
  advanceSmallTier,
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

    // Anchor-first ceremony for EVERY tier of 6+ (owner, 2026-07-13/14):
    // round 1 vs the tier's very best, round 2 vs the very worst, then
    // 25%-rule quartile narrowing. No size ceiling.
    this.small = {
      mode: 'anchor_best',
      tierCount: this.tierItems.length,
      low: 0,
      high: this.tierItems.length,
      mid: 0,
      round: 1,
      seedIdx: 0,
    };
    return this.emitSmallComparison();
  }

  submit(choice: SessionChoice): SessionResult {
    if (this.small) return this.submitSmall(choice);
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
}
