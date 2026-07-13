import Foundation

/// Uniform facade over the two placement strategies — mirrors the web's
/// `services/rankingSession.ts`. Strategy by target-tier size:
///   0     → engine (returns immediate .done at tier midpoint)
///   1–5   → compare-all walk       (RankingAlgorithm.advanceSmallTier)
///   6–20  → seed + quartile        (RankingAlgorithm.advanceSmallTier)
///   21+   → 5-phase engine         (SpoolRankingEngine)
/// Replaces RankH2HScreen's private SmallTierState mirror struct and the
/// enum-bridging in submitSmallTier.
public final class PlacementSession {

    private let smallTierQuestion = "which do you love more?"

    private var engine: SpoolRankingEngine?
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
        engine = nil
        small = nil
        current = nil
        tierItems = []

        self.newItem = newItem
        self.tier = tier
        self.tierItems = allItems
            .filter { $0.tier == tier }
            .sorted { $0.rank < $1.rank }

        if tierItems.isEmpty || tierItems.count > 20 {
            // Empty tier delegates to the engine, which returns an
            // immediate .done at the tier midpoint — current iOS behavior.
            let engine = SpoolRankingEngine()
            self.engine = engine
            let bracket = newItem.bracket ?? RankingAlgorithm.classifyBracket(genres: newItem.genres)
            let signals = SpoolPrediction.computePredictionSignals(
                allItems: allItems,
                primaryGenre: newItem.genres.first ?? "",
                bracket: bracket,
                globalScore: newItem.globalScore,
                tier: tier
            )
            let result = engine.start(newMovie: newItem, tier: tier, allItems: allItems, signals: signals)
            if case .comparison(let c) = result { current = c }
            return result
        }

        if tierItems.count <= 5 {
            small = RankingAlgorithm.SmallTierState(
                mode: .compareAll, tierCount: tierItems.count,
                low: 0, high: tierItems.count, mid: 0, round: 1, seedIdx: 0
            )
            return emitSmallComparison()
        }

        // 6–20: anchor-first ceremony (owner, 2026-07-13) — round 1 vs the
        // tier's very best, round 2 vs the very worst, then 25%-rule
        // quartile narrowing. Mirrors web RankingSession.start.
        small = RankingAlgorithm.SmallTierState(
            mode: .anchorBest, tierCount: tierItems.count,
            low: 0, high: tierItems.count, mid: 0, round: 1, seedIdx: 0
        )
        return emitSmallComparison()
    }

    public func submit(winnerId: String) -> EngineResult? {
        if small != nil { return submitSmall(winnerId: winnerId) }
        guard let engine else { return nil }
        do {
            let result = try engine.submitChoice(winnerId: winnerId)
            if case .comparison(let c) = result { current = c }
            return result
        } catch {
            // Out-of-sync tap (stale double-tap) — caller ignores,
            // session stays alive. Matches previous screen behavior.
            return nil
        }
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
        guard let engine else { return nil }
        do {
            let result = try engine.skip()
            if case .comparison(let c) = result { current = c }
            return result
        } catch {
            return nil
        }
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
