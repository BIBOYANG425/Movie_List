import Foundation

/// Pure port of `services/spoolRankingEngine.ts`.
/// Genre-anchored ranking state machine. 5 phases:
///  1. Prediction  — compute predicted score (done on `start`)
///  2. Probe       — same-genre movie at ~predicted score
///  3. Escalation  — top-of-genre downward until loss
///  4. CrossGenre  — different-genre movie at ~same score
///  5. Settlement  — final same-genre comparison to lock position
public final class SpoolRankingEngine {

    // MARK: nested

    private struct ScoredItem: Equatable {
        let item: RankedItem
        let score: Double
    }

    private struct Snapshot {
        let phase: EnginePhase
        let tentativeScore: Double
        let probeIndex: Int
        let escalationIndex: Int
        let crossGenreAdjustment: Double
        let comparison: ComparisonRequest
        let comparedIds: Set<String>
        let comparisonCount: Int
    }

    // MARK: state

    private(set) var phase: EnginePhase = .prediction
    private var started = false

    private var newMovie: RankedItem!
    private var tier: Tier!

    private var tierItems: [ScoredItem] = []
    private var sameGenreItems: [ScoredItem] = []
    private var diffGenreItems: [ScoredItem] = []
    private var primaryGenre: String = ""

    private var tentativeScore: Double = 0
    private var crossGenreAdjustment: Double = 0

    private var probeIndex: Int = -1
    private var escalationIndex: Int = -1

    private var history: [Snapshot] = []
    private var currentComparison: ComparisonRequest?
    private var comparedIds: Set<String> = []
    private var comparisonCount: Int = 0

    public init() {}

    // MARK: public API

    public func start(
        newMovie: RankedItem,
        tier: Tier,
        allItems: [RankedItem],
        signals: PredictionSignals
    ) -> EngineResult {
        self.newMovie = newMovie
        self.tier = tier
        self.started = true
        self.phase = .prediction
        self.history = []
        self.crossGenreAdjustment = 0
        self.currentComparison = nil
        self.comparedIds = []
        self.comparisonCount = 0

        guard let range = SpoolConstants.tierScoreRanges[tier] else {
            return .done(finalRank: 0, finalScore: 0)
        }
        self.primaryGenre = newMovie.genres.first ?? ""

        // Build tier items sorted by rank with computed scores
        let tierItemsRaw = allItems
            .filter { $0.tier == tier }
            .sorted { $0.rank < $1.rank }

        self.tierItems = tierItemsRaw.enumerated().map { (i, item) in
            ScoredItem(item: item, score: RankingAlgorithm.computeTierScore(
                position: i, totalInTier: tierItemsRaw.count,
                tierMin: range.min, tierMax: range.max
            ))
        }

        self.sameGenreItems = tierItems.filter {
            !$0.item.genres.isEmpty && $0.item.genres[0] == primaryGenre
        }
        self.diffGenreItems = tierItems.filter {
            $0.item.genres.isEmpty || $0.item.genres[0] != primaryGenre
        }

        // Phase 1: prediction
        self.tentativeScore = SpoolPrediction.predictScore(signals: signals, tier: tier)

        // Edge: first movie in tier
        if tierItems.isEmpty {
            self.phase = .complete
            let midpoint = (range.min + range.max) / 2
            return .done(finalRank: 0, finalScore: (midpoint * 100).rounded() / 100)
        }

        // Edge: first in genre within tier
        if sameGenreItems.isEmpty {
            self.phase = .crossGenre
            return emitCrossGenre()
        }

        // Phase 2: probe
        self.phase = .probe
        self.probeIndex = findNearestGenreIndex(targetScore: tentativeScore)
        return emitProbeComparison()
    }

    public func submitChoice(winnerId: String) throws -> EngineResult {
        guard started, phase != .complete else {
            throw EngineError.notActive
        }
        // Match the web engine's contract: treat any id that isn't
        // `newMovie.id` as "movieB won". The stricter two-sided validation
        // was turning stale/double-tap ids into thrown errors, and the
        // RankH2HScreen catch block marked the session done — so a single
        // bad tap aborted H2H mid-flow ("aborts after 2 selections"). No
        // validation = parity with web + no spurious terminals.
        let newMovieWins = (winnerId == newMovie.id)
        pushSnapshot()

        switch phase {
        case .probe:      return handleProbeResult(newMovieWins: newMovieWins)
        case .escalation: return handleEscalationResult(newMovieWins: newMovieWins)
        case .crossGenre: return handleCrossGenreResult(newMovieWins: newMovieWins)
        case .settlement: return handleSettlementResult(newMovieWins: newMovieWins)
        default:          throw EngineError.unexpectedPhase(phase)
        }
    }

    public func skip() throws -> EngineResult {
        guard started, phase != .complete else { throw EngineError.notActive }
        phase = .complete
        return computeFinalPlacement()
    }

    public func undo() -> EngineResult? {
        guard let snap = history.popLast() else { return nil }
        phase = snap.phase
        tentativeScore = snap.tentativeScore
        probeIndex = snap.probeIndex
        escalationIndex = snap.escalationIndex
        crossGenreAdjustment = snap.crossGenreAdjustment
        currentComparison = snap.comparison
        comparedIds = snap.comparedIds
        comparisonCount = snap.comparisonCount
        return .comparison(snap.comparison)
    }

    public enum EngineError: Error {
        case notActive
        case unexpectedPhase(EnginePhase)
    }

    // MARK: phase handlers

    private func handleProbeResult(newMovieWins: Bool) -> EngineResult {
        guard let range = SpoolConstants.tierScoreRanges[tier] else {
            return .done(finalRank: 0, finalScore: 0)
        }

        if newMovieWins {
            let probeTarget = sameGenreItems[probeIndex]
            tentativeScore = min(range.max, probeTarget.score + 0.1)

            if sameGenreItems.count <= 1 {
                phase = .crossGenre
                return emitCrossGenreOrSettle()
            }

            phase = .escalation
            escalationIndex = 0
            if escalationIndex == probeIndex { escalationIndex += 1 }
            if escalationIndex >= sameGenreItems.count {
                phase = .crossGenre
                return emitCrossGenreOrSettle()
            }
            return emitEscalationComparison()
        } else {
            let probeTarget = sameGenreItems[probeIndex]
            let tierMin = range.min

            let genreBelowProbe = sameGenreItems
                .filter { $0.score < probeTarget.score }
                .sorted { $0.score > $1.score }

            if let first = genreBelowProbe.first {
                tentativeScore = first.score
            } else {
                tentativeScore = max(tierMin, probeTarget.score - 0.5)
            }

            phase = .settlement
            return emitSettlementOrDone()
        }
    }

    private func handleEscalationResult(newMovieWins: Bool) -> EngineResult {
        guard let range = SpoolConstants.tierScoreRanges[tier] else {
            return .done(finalRank: 0, finalScore: 0)
        }

        if newMovieWins {
            let target = sameGenreItems[escalationIndex]
            tentativeScore = min(range.max, target.score + 0.1)

            escalationIndex += 1
            if escalationIndex == probeIndex { escalationIndex += 1 }

            if escalationIndex >= sameGenreItems.count {
                tentativeScore = range.max
                phase = .crossGenre
                return emitCrossGenreOrSettle()
            }
            return emitEscalationComparison()
        } else {
            let target = sameGenreItems[escalationIndex]
            tentativeScore = max(range.min, target.score - 0.1)
            phase = .crossGenre
            return emitCrossGenreOrSettle()
        }
    }

    private func handleCrossGenreResult(newMovieWins: Bool) -> EngineResult {
        guard let range = SpoolConstants.tierScoreRanges[tier] else {
            return .done(finalRank: 0, finalScore: 0)
        }
        if !newMovieWins {
            crossGenreAdjustment = -0.3
            tentativeScore = max(range.min, tentativeScore - 0.3)
        }
        phase = .settlement
        return emitSettlementOrDone()
    }

    private func handleSettlementResult(newMovieWins: Bool) -> EngineResult {
        guard let range = SpoolConstants.tierScoreRanges[tier] else {
            return .done(finalRank: 0, finalScore: 0)
        }
        if let comparison = currentComparison {
            let targetScored = tierItems.first(where: { $0.item.id == comparison.movieB.id })
            if let target = targetScored {
                if newMovieWins {
                    tentativeScore = min(range.max, target.score + 0.05)
                } else {
                    tentativeScore = max(range.min, target.score - 0.05)
                }
            }
        }
        phase = .complete
        return computeFinalPlacement()
    }

    // MARK: emitters

    private func emitProbeComparison() -> EngineResult {
        let probeTarget = sameGenreItems[probeIndex]
        let comparison = makeComparison(movieB: probeTarget.item, phase: .probe)
        currentComparison = comparison
        return .comparison(comparison)
    }

    private func emitEscalationComparison() -> EngineResult {
        let target = sameGenreItems[escalationIndex]
        let comparison = makeComparison(movieB: target.item, phase: .escalation)
        currentComparison = comparison
        return .comparison(comparison)
    }

    private func emitCrossGenre() -> EngineResult {
        if diffGenreItems.isEmpty {
            phase = .settlement
            return emitSettlementOrDone()
        }
        let crossTarget = findNearestDiffGenreItem(targetScore: tentativeScore)
        let comparison = makeComparison(movieB: crossTarget.item, phase: .crossGenre)
        currentComparison = comparison
        return .comparison(comparison)
    }

    private func emitCrossGenreOrSettle() -> EngineResult {
        if diffGenreItems.isEmpty {
            phase = .settlement
            return emitSettlementOrDone()
        }
        phase = .crossGenre
        return emitCrossGenre()
    }

    private func emitSettlementOrDone() -> EngineResult {
        guard let settlementTarget = findSettlementTarget() else {
            phase = .complete
            return computeFinalPlacement()
        }
        let comparison = makeComparison(movieB: settlementTarget.item, phase: .settlement)
        currentComparison = comparison
        return .comparison(comparison)
    }

    // MARK: helpers

    private func makeComparison(movieB: RankedItem, phase: EnginePhase) -> ComparisonRequest {
        let genreA = primaryGenre
        let genreB = movieB.genres.first ?? ""
        let question = SpoolPrompts.getComparisonPrompt(
            tier: tier, genreA: genreA, genreB: genreB, phase: phase
        )
        comparedIds.insert(movieB.id)
        comparisonCount += 1
        return ComparisonRequest(
            movieA: newMovie, movieB: movieB,
            question: question, phase: phase, round: comparisonCount
        )
    }

    private func findNearestGenreIndex(targetScore: Double) -> Int {
        var bestIndex = 0
        var bestDist = abs(sameGenreItems[0].score - targetScore)
        for i in 1..<sameGenreItems.count {
            let d = abs(sameGenreItems[i].score - targetScore)
            if d < bestDist { bestDist = d; bestIndex = i }
        }
        return bestIndex
    }

    private func findNearestDiffGenreItem(targetScore: Double) -> ScoredItem {
        var best = diffGenreItems[0]
        var bestDist = abs(best.score - targetScore)
        for i in 1..<diffGenreItems.count {
            let d = abs(diffGenreItems[i].score - targetScore)
            if d < bestDist { bestDist = d; best = diffGenreItems[i] }
        }
        return best
    }

    private func findSettlementTarget() -> ScoredItem? {
        guard !sameGenreItems.isEmpty else { return nil }
        let candidates = sameGenreItems.filter { !comparedIds.contains($0.item.id) }
        guard !candidates.isEmpty else { return nil }
        var best: ScoredItem?
        var bestDist: Double = .infinity
        for si in candidates {
            let d = abs(si.score - tentativeScore)
            if d < bestDist { bestDist = d; best = si }
        }
        return best
    }

    private func computeFinalPlacement() -> EngineResult {
        guard let range = SpoolConstants.tierScoreRanges[tier] else {
            return .done(finalRank: 0, finalScore: 0)
        }
        let clamped = max(range.min, min(range.max, tentativeScore))
        let finalScore = (clamped * 100).rounded() / 100

        var finalRank = tierItems.count
        for (i, si) in tierItems.enumerated() where si.score <= finalScore {
            finalRank = i
            break
        }
        return .done(finalRank: finalRank, finalScore: finalScore)
    }

    private func pushSnapshot() {
        guard let comparison = currentComparison else { return }
        history.append(Snapshot(
            phase: phase, tentativeScore: tentativeScore,
            probeIndex: probeIndex, escalationIndex: escalationIndex,
            crossGenreAdjustment: crossGenreAdjustment,
            comparison: comparison,
            comparedIds: comparedIds,
            comparisonCount: comparisonCount
        ))
    }
}
