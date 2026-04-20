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

    // MARK: Small-tier state machine (web parity with smallTierRef)

    /// Sub-modes for the small-tier (≤20 item) ranking path. Mirrors the
    /// web's `smallTierRef.mode` literal union in `RankingFlowModal.tsx`.
    public enum SmallTierMode: Sendable, Equatable {
        case compareAll
        case seed
        case quartile
    }

    /// Immutable snapshot of the small-tier state machine. Carries every
    /// field the web holds on `smallTierRef` so transitions are pure
    /// field-copies. `tierCount` is the size of the target tier (the new
    /// item is NOT counted).
    public struct SmallTierState: Sendable, Equatable {
        public var mode: SmallTierMode
        public var tierCount: Int
        public var low: Int
        public var high: Int
        public var mid: Int
        public var round: Int
        public var seedIdx: Int

        public init(
            mode: SmallTierMode, tierCount: Int,
            low: Int, high: Int, mid: Int, round: Int, seedIdx: Int
        ) {
            self.mode = mode
            self.tierCount = tierCount
            self.low = low; self.high = high; self.mid = mid
            self.round = round; self.seedIdx = seedIdx
        }
    }

    /// Outcome of one small-tier step: either the algorithm has
    /// converged (`.done` with the insert rank) or it wants another
    /// comparison (`.next` with updated state, including the new `mid`
    /// the caller should pull from `tierItems[mid]`).
    public enum SmallTierStep: Sendable, Equatable {
        case done(rank: Int)
        case next(state: SmallTierState)
    }

    /// Advance the small-tier state machine by one user choice. Pure
    /// function — the caller is responsible for rendering the next
    /// comparison from `state.tierItems[state.mid]`. Mirrors
    /// `handleCompareChoice`'s `smallTierRef` branch in the web.
    ///
    ///  - `.compareAll`: new wins → insert at `mid`; else advance mid or
    ///    fall off the end at rank `tierCount`.
    ///  - `.seed`: new wins at seed 0 → insert at 0; new wins elsewhere
    ///    → transition to `.quartile` with `[0, mid)`; existing wins at
    ///    the last slot → insert at `tierCount`; existing wins otherwise
    ///    → transition to `.quartile` with `[mid+1, N)` and jump 75% in.
    ///  - `.quartile`: narrow `[low, high)` by quartile (25% if new won,
    ///    75% if existing won). Converged when `newLow >= newHigh` —
    ///    insert at `newLow`.
    public static func advanceSmallTier(
        state: SmallTierState, pick: NarrowChoice
    ) -> SmallTierStep {
        let st = state
        let nextRound = st.round + 1

        switch st.mode {
        case .compareAll:
            if pick == .new {
                return .done(rank: st.mid)
            } else if st.mid + 1 >= st.tierCount {
                return .done(rank: st.tierCount)
            } else {
                var nst = st
                nst.mid = st.mid + 1
                nst.round = nextRound
                return .next(state: nst)
            }

        case .seed:
            if pick == .new {
                if st.mid == 0 {
                    return .done(rank: 0)
                }
                var nst = st
                nst.mode = .quartile
                nst.low = 0; nst.high = st.mid
                nst.mid = 0
                nst.round = nextRound
                return .next(state: nst)
            } else {
                let newLow = st.mid + 1
                if newLow >= st.tierCount {
                    return .done(rank: st.tierCount)
                }
                let newHigh = st.tierCount
                let nextMid = min(newLow + Int(Double(newHigh - newLow) * 0.75), newHigh - 1)
                var nst = st
                nst.mode = .quartile
                nst.low = newLow; nst.high = newHigh
                nst.mid = nextMid
                nst.round = nextRound
                return .next(state: nst)
            }

        case .quartile:
            let newLow = pick == .new ? st.low : st.mid + 1
            let newHigh = pick == .new ? st.mid : st.high
            if newLow >= newHigh {
                return .done(rank: newLow)
            }
            let ratio = pick == .new ? 0.25 : 0.75
            let nextMid = max(newLow, min(newLow + Int(Double(newHigh - newLow) * ratio), newHigh - 1))
            var nst = st
            nst.mode = .quartile
            nst.low = newLow; nst.high = newHigh
            nst.mid = nextMid
            nst.round = nextRound
            return .next(state: nst)
        }
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
