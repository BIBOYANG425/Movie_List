import Foundation

/// Pure port of `services/rankingAlgorithm.ts`.
/// Four-stage ranking flow: auto-bracket, tier placement (user), adaptive
/// in-tier comparison, score assignment.
public enum RankingAlgorithm {

    // MARK: Bracket classification

    public static func classifyBracket(genres: [String]) -> Bracket {
        if genres.contains("Animation")   { return .animation }
        if genres.contains("Documentary") { return .documentary }
        if !genres.isEmpty && !genres.contains(where: { SpoolConstants.commercialSignalGenres.contains($0) }) {
            return .artisan
        }
        return .commercial
    }

    // MARK: Seed index

    /// Initial comparison pivot within a tier. If the movie's global average
    /// falls within the tier range, pick the existing item closest to it;
    /// otherwise fall back to the median.
    public static func computeSeedIndex(
        tierItemScores: [Double],
        tierMin: Double,
        tierMax: Double,
        globalAvg: Double?
    ) -> Int {
        let n = tierItemScores.count
        if n == 0 { return 0 }

        let median = n / 2

        guard let g = globalAvg, g >= tierMin, g <= tierMax else {
            return median
        }

        var closestIdx = 0
        var closestDist = abs(tierItemScores[0] - g)
        for i in 1..<n {
            let dist = abs(tierItemScores[i] - g)
            if dist < closestDist {
                closestDist = dist
                closestIdx = i
            }
        }
        return closestIdx
    }

    // MARK: Quartile narrowing

    public enum NarrowChoice: String, Sendable { case new, existing }

    public static func adaptiveNarrow(
        low: Int, high: Int, mid: Int, choice: NarrowChoice
    ) -> (newLow: Int, newHigh: Int)? {
        var newLow = low
        var newHigh = high
        switch choice {
        case .new:      newHigh = mid
        case .existing: newLow = mid + 1
        }
        return newLow >= newHigh ? nil : (newLow, newHigh)
    }

    // MARK: Tier score

    /// Linear interpolation within tier range. position = 0 is best.
    public static func computeTierScore(
        position: Int, totalInTier: Int, tierMin: Double, tierMax: Double
    ) -> Double {
        if totalInTier <= 1 {
            return (tierMin + tierMax).rounded(toPlaces: 1) / 2.0.rounded(toPlaces: 1) == 0
                ? 0
                : ((tierMin + tierMax) / 2.0).rounded(toPlaces: 1)
        }
        let ratio = Double(totalInTier - 1 - position) / Double(totalInTier - 1)
        let score = tierMin + (tierMax - tierMin) * ratio
        return score.rounded(toPlaces: 1)
    }

    // MARK: Full list scoring

    public static func computeAllScores(
        _ items: [(id: String, tier: Tier, rank: Int)]
    ) -> [String: Double] {
        var scoreMap: [String: Double] = [:]
        for tier in Tier.allCases {
            guard let range = SpoolConstants.tierScoreRanges[tier] else { continue }
            let tierItems = items
                .filter { $0.tier == tier }
                .sorted { $0.rank < $1.rank }
            for (i, item) in tierItems.enumerated() {
                scoreMap[item.id] = computeTierScore(
                    position: i, totalInTier: tierItems.count,
                    tierMin: range.min, tierMax: range.max
                )
            }
        }
        return scoreMap
    }

    // MARK: Natural tier

    public static func getNaturalTier(score: Double) -> Tier {
        for tier in Tier.allCases {
            guard let range = SpoolConstants.tierScoreRanges[tier] else { continue }
            if score >= range.min { return tier }
        }
        return .D
    }
}

// MARK: Double rounding helper

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let m = pow(10.0, Double(places))
        return (self * m).rounded() / m
    }
}
