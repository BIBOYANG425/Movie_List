import Foundation

/// Pure port of `services/spoolPrediction.ts`.
/// Signal-based score prediction (genre + global + bracket).
public enum SpoolPrediction {

    private static let weightGenreAffinity:   Double = 0.45
    private static let weightGlobalScore:     Double = 0.35
    private static let weightBracketAffinity: Double = 0.20

    public static func computePredictionSignals(
        allItems: [RankedItem],
        primaryGenre: String,
        bracket: Bracket,
        globalScore: Double?,
        tier: Tier
    ) -> PredictionSignals {
        guard let range = SpoolConstants.tierScoreRanges[tier] else {
            return PredictionSignals(totalRanked: allItems.count)
        }

        // Genre affinity: average score of items with same primary genre
        let genreItems = allItems.filter { !$0.genres.isEmpty && $0.genres[0] == primaryGenre }
        let genreAffinity: Double? = averageScore(for: genreItems, in: allItems)

        // Global score: clamp to tier range
        let mappedGlobal: Double? = globalScore.map { max(range.min, min(range.max, $0)) }

        // Bracket affinity: average score of items with same bracket
        let bracketItems = allItems.filter { $0.bracket == bracket }
        let bracketAffinity: Double? = averageScore(for: bracketItems, in: allItems)

        return PredictionSignals(
            genreAffinity: genreAffinity,
            globalScore: mappedGlobal,
            bracketAffinity: bracketAffinity,
            totalRanked: allItems.count
        )
    }

    public static func predictScore(signals: PredictionSignals, tier: Tier) -> Double {
        guard let range = SpoolConstants.tierScoreRanges[tier] else { return 0 }
        let midpoint = (range.min + range.max) / 2

        if signals.totalRanked < SpoolConstants.newUserThreshold {
            return signals.globalScore ?? midpoint
        }

        var entries: [(value: Double, weight: Double)] = []
        if let v = signals.genreAffinity   { entries.append((v, weightGenreAffinity)) }
        if let v = signals.globalScore     { entries.append((v, weightGlobalScore)) }
        if let v = signals.bracketAffinity { entries.append((v, weightBracketAffinity)) }
        if entries.isEmpty { return midpoint }

        let totalWeight = entries.reduce(0) { $0 + $1.weight }
        let raw = entries.reduce(0) { $0 + $1.value * ($1.weight / totalWeight) }
        let rounded = (raw * 100).rounded() / 100
        return max(range.min, min(range.max, rounded))
    }

    // MARK: helper

    private static func averageScore(for items: [RankedItem], in allItems: [RankedItem]) -> Double? {
        guard !items.isEmpty else { return nil }
        let scores: [Double] = items.compactMap { item in
            guard let tierRange = SpoolConstants.tierScoreRanges[item.tier] else { return nil }
            let tierPeers = allItems.filter { $0.tier == item.tier }.sorted { $0.rank < $1.rank }
            let positionInTier = tierPeers.firstIndex(where: { $0.id == item.id }) ?? 0
            return RankingAlgorithm.computeTierScore(
                position: positionInTier, totalInTier: tierPeers.count,
                tierMin: tierRange.min, tierMax: tierRange.max
            )
        }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }
}
