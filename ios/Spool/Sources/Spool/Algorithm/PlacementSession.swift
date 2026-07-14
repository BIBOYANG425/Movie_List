import Foundation

/// Uniform facade over the placement strategies — mirrors the web's
/// `services/rankingSession.ts`. Strategy by target-tier size:
///   0     → immediate .done at the tier midpoint
///   1–5   → compare-all walk       (RankingAlgorithm.advanceSmallTier)
///   6+    → anchor poles + 25% rule (RankingAlgorithm.advanceSmallTier)
/// The 21+ five-phase SpoolRankingEngine was RETIRED from placement (owner,
/// 2026-07-14): the anchor spec (best → worst → 25% rule) has no size
/// ceiling. The engine module remains for its standalone tests; placement
/// no longer calls it.
/// Replaces RankH2HScreen's private SmallTierState mirror struct and the
/// enum-bridging in submitSmallTier.
public final class PlacementSession {

    private let smallTierQuestion = "which do you love more?"

    private var small: RankingAlgorithm.SmallTierState?
    private var tierItems: [RankedItem] = []
    private var newItem: RankedItem!
    private var tier: Tier!
    private var current: ComparisonRequest?

    public init() {}

    public func start(newItem: RankedItem, tier: Tier, allItems: [RankedItem]) -> EngineResult {
        // Reset all session state so re-entrant start() calls never leak an
        // active strategy from a previous run (mirrors the web facade's
        // dd00e7b hardening).
        small = nil
        current = nil
        tierItems = []

        self.newItem = newItem
        self.tier = tier
        self.tierItems = allItems
            .filter { $0.tier == tier }
            .sorted { $0.rank < $1.rank }

        if tierItems.isEmpty {
            // Empty tier: immediate placement at rank 0 with the tier's
            // midpoint score for celebration copy (the retired engine's
            // empty-tier behavior, now computed inline).
            let range = tier.scoreRange
            let score = ((range.min + range.max) / 2 * 100).rounded() / 100
            return .done(finalRank: 0, finalScore: score)
        }

        if tierItems.count <= 5 {
            small = RankingAlgorithm.SmallTierState(
                mode: .compareAll, tierCount: tierItems.count,
                low: 0, high: tierItems.count, mid: 0, round: 1, seedIdx: 0
            )
            return emitSmallComparison()
        }

        // 6+: anchor-first ceremony (owner, 2026-07-13/14) — round 1 vs the
        // tier's very best, round 2 vs the very worst, then 25%-rule
        // quartile narrowing. No size ceiling. Mirrors web RankingSession.
        small = RankingAlgorithm.SmallTierState(
            mode: .anchorBest, tierCount: tierItems.count,
            low: 0, high: tierItems.count, mid: 0, round: 1, seedIdx: 0
        )
        return emitSmallComparison()
    }

    public func submit(winnerId: String) -> EngineResult? {
        if small != nil { return submitSmall(winnerId: winnerId) }
        // No active strategy (before start() or after done) — out-of-sync
        // tap; caller ignores. Matches previous screen behavior.
        return nil
    }

    public func skip() -> EngineResult? {
        if let st = small {
            // "Too tough" inserts at the current cursor with a midpoint
            // score for celebration copy — matches previous screen behavior.
            small = nil
            current = nil
            let range = tier.scoreRange
            let score = ((range.min + range.max) / 2 * 100).rounded() / 100
            return .done(finalRank: st.mid, finalScore: score)
        }
        return nil
    }

    // MARK: small-tier internals

    private func submitSmall(winnerId: String) -> EngineResult? {
        guard let st = small, let c = current else { return nil }
        let pick: RankingAlgorithm.NarrowChoice = winnerId == c.movieA.id ? .new : .existing

        switch RankingAlgorithm.advanceSmallTier(state: st, pick: pick) {
        case .done(let rank):
            small = nil
            current = nil
            // Approximate score for celebration copy only — true insertion
            // order is set by rank_position in the DB.
            let range = tier.scoreRange
            let total = max(st.tierCount + 1, 1)
            let frac = Double(total - rank - 1) / Double(total)
            let score = ((range.min + (range.max - range.min) * frac) * 100).rounded() / 100
            return .done(finalRank: rank, finalScore: score)

        case .next(let nextState):
            small = nextState
            return emitSmallComparison()
        }
    }

    private func emitSmallComparison() -> EngineResult {
        guard let st = small else {
            return .done(finalRank: 0, finalScore: 0)
        }
        let comparison = ComparisonRequest(
            movieA: newItem,
            movieB: tierItems[st.mid],
            question: smallTierQuestion,
            phase: .binarySearch, // aligned with web (compare-all previously used .probe)
            round: st.round
        )
        current = comparison
        return .comparison(comparison)
    }
}
