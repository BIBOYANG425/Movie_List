import XCTest
@testable import Spool

final class SpoolRankingEngineTests: XCTestCase {

    // MARK: helpers

    private func makeItem(
        _ id: String, tier: Tier, rank: Int, genres: [String]
    ) -> RankedItem {
        RankedItem(
            id: id, title: "Movie \(id)", year: 2024, director: "—",
            genres: genres, tier: tier, rank: rank,
            bracket: nil, globalScore: nil, seed: 0
        )
    }

    private func makeNewMovie(_ id: String, genres: [String], tier: Tier) -> RankedItem {
        makeItem(id, tier: tier, rank: -1, genres: genres)
    }

    private func makeSignals(
        genreAffinity: Double? = 8.0,
        globalScore: Double? = 7.5,
        bracketAffinity: Double? = 7.0,
        totalRanked: Int = 20
    ) -> PredictionSignals {
        PredictionSignals(
            genreAffinity: genreAffinity, globalScore: globalScore,
            bracketAffinity: bracketAffinity, totalRanked: totalRanked
        )
    }

    private func phase(of result: EngineResult) -> EnginePhase? {
        if case .comparison(let c) = result { return c.phase }
        return nil
    }

    // MARK: first movie in tier

    func testFirstMovieInTierReturnsDoneWithMidpointScore() {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let result = engine.start(
            newMovie: newMovie, tier: .A, allItems: [], signals: makeSignals()
        )

        guard case .done(let rank, let score) = result else {
            XCTFail("expected .done, got \(result)"); return
        }
        XCTAssertEqual(rank, 0)
        // A-tier midpoint: 7.95
        XCTAssertEqual(score, 7.95, accuracy: 0.1)
    }

    // MARK: first in genre within tier

    func testFirstInGenreWithinTierGoesToCrossGenre() {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Horror"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Comedy"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Drama"]),
        ]

        let result = engine.start(newMovie: newMovie, tier: .A,
                                  allItems: allItems, signals: makeSignals())
        guard case .comparison(let c) = result else {
            XCTFail("expected .comparison, got \(result)"); return
        }
        XCTAssertEqual(c.phase, .crossGenre)
        XCTAssertEqual(c.movieA.id, "new")
        XCTAssertNotEqual(c.movieB.genres.first, "Horror")
    }

    // MARK: single same-genre movie

    func testSingleSameGenreStartsWithProbe() {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Comedy"]),
        ]
        let result = engine.start(newMovie: newMovie, tier: .A,
                                  allItems: allItems, signals: makeSignals())
        guard case .comparison(let c) = result else {
            XCTFail("expected .comparison, got \(result)"); return
        }
        XCTAssertEqual(c.phase, .probe)
        XCTAssertEqual(c.movieB.genres.first, "Action")
    }

    // MARK: probe phase

    func testProbeLossGoesToSettlement() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Action"]),
            makeItem("a3", tier: .A, rank: 2, genres: ["Comedy"]),
        ]
        let probe = engine.start(newMovie: newMovie, tier: .A,
                                 allItems: allItems, signals: makeSignals())
        guard case .comparison(let c) = probe else { XCTFail(); return }
        XCTAssertEqual(c.phase, .probe)

        let loss = try engine.submitChoice(winnerId: c.movieB.id)
        guard case .comparison(let next) = loss else {
            XCTFail("expected follow-up comparison after probe loss"); return
        }
        XCTAssertEqual(next.phase, .settlement)
    }

    func testProbeWinEscalates() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Action"]),
            makeItem("a3", tier: .A, rank: 2, genres: ["Action"]),
            makeItem("a4", tier: .A, rank: 3, genres: ["Comedy"]),
        ]
        let probe = engine.start(newMovie: newMovie, tier: .A,
                                 allItems: allItems, signals: makeSignals())
        XCTAssertEqual(phase(of: probe), .probe)

        let escalation = try engine.submitChoice(winnerId: "new")
        XCTAssertEqual(phase(of: escalation), .escalation)
    }

    // MARK: escalation

    func testEscalationSweepEndsInCrossGenre() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Action"]),
            makeItem("a3", tier: .A, rank: 2, genres: ["Comedy"]),
        ]
        _ = engine.start(newMovie: newMovie, tier: .A,
                         allItems: allItems, signals: makeSignals())
        var current = try engine.submitChoice(winnerId: "new")  // win probe → escalation
        while case .comparison(let c) = current, c.phase == .escalation {
            current = try engine.submitChoice(winnerId: "new")
        }
        XCTAssertEqual(phase(of: current), .crossGenre)
    }

    func testEscalationLossGoesToCrossGenre() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Action"]),
            makeItem("a3", tier: .A, rank: 2, genres: ["Action"]),
            makeItem("a4", tier: .A, rank: 3, genres: ["Comedy"]),
        ]
        _ = engine.start(newMovie: newMovie, tier: .A,
                         allItems: allItems, signals: makeSignals())
        let escalation = try engine.submitChoice(winnerId: "new")
        guard case .comparison(let esc) = escalation else { XCTFail(); return }
        XCTAssertEqual(esc.phase, .escalation)

        let loss = try engine.submitChoice(winnerId: esc.movieB.id)
        XCTAssertEqual(phase(of: loss), .crossGenre)
    }

    // MARK: cross-genre

    func testCrossGenreConfirmationProceedsToSettlementOrDone() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Comedy"]),
            makeItem("a3", tier: .A, rank: 2, genres: ["Drama"]),
        ]
        _ = engine.start(newMovie: newMovie, tier: .A,
                         allItems: allItems, signals: makeSignals())
        var current = try engine.submitChoice(winnerId: "new")
        while case .comparison(let c) = current, c.phase == .escalation {
            current = try engine.submitChoice(winnerId: "new")
        }
        XCTAssertEqual(phase(of: current), .crossGenre)

        let result = try engine.submitChoice(winnerId: "new")
        switch result {
        case .comparison(let c): XCTAssertEqual(c.phase, .settlement)
        case .done: break
        }
    }

    func testCrossGenreContradictionProceedsToSettlementOrDone() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Comedy"]),
            makeItem("a3", tier: .A, rank: 2, genres: ["Drama"]),
        ]
        _ = engine.start(newMovie: newMovie, tier: .A,
                         allItems: allItems, signals: makeSignals())
        var current = try engine.submitChoice(winnerId: "new")
        while case .comparison(let c) = current, c.phase == .escalation {
            current = try engine.submitChoice(winnerId: "new")
        }
        guard case .comparison(let crossGenre) = current else { XCTFail(); return }

        let result = try engine.submitChoice(winnerId: crossGenre.movieB.id)
        switch result {
        case .comparison(let c): XCTAssertEqual(c.phase, .settlement)
        case .done: break
        }
    }

    // MARK: settlement

    func testSettlementProducesFinalRankAndScore() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Comedy"]),
        ]
        var result = engine.start(newMovie: newMovie, tier: .A,
                                  allItems: allItems, signals: makeSignals())
        var safety = 0
        while case .comparison = result, safety < 20 {
            result = try engine.submitChoice(winnerId: "new")
            safety += 1
        }
        guard case .done(let rank, let score) = result else {
            XCTFail("expected .done"); return
        }
        XCTAssertGreaterThanOrEqual(rank, 0)
        XCTAssertGreaterThanOrEqual(score, 7.0)
        XCTAssertLessThanOrEqual(score, 8.9)
    }

    // MARK: skip

    func testSkipReturnsDoneWithTentativeScoreAndRank() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Action"]),
            makeItem("a3", tier: .A, rank: 2, genres: ["Comedy"]),
        ]
        _ = engine.start(newMovie: newMovie, tier: .A,
                         allItems: allItems, signals: makeSignals())
        let result = try engine.skip()
        guard case .done(_, let score) = result else {
            XCTFail("expected .done from skip"); return
        }
        XCTAssertGreaterThanOrEqual(score, 7.0)
        XCTAssertLessThanOrEqual(score, 8.9)
    }

    // MARK: undo

    func testUndoReturnsNilWhenNoHistory() {
        let engine = SpoolRankingEngine()
        _ = engine.start(
            newMovie: makeNewMovie("new", genres: ["Action"], tier: .A),
            tier: .A,
            allItems: [
                makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
                makeItem("a2", tier: .A, rank: 1, genres: ["Action"]),
            ],
            signals: makeSignals()
        )
        XCTAssertNil(engine.undo())
    }

    func testUndoRevertsToPreviousComparisonAfterOneChoice() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Action"]),
            makeItem("a3", tier: .A, rank: 2, genres: ["Action"]),
            makeItem("a4", tier: .A, rank: 3, genres: ["Comedy"]),
        ]
        let first = engine.start(newMovie: newMovie, tier: .A,
                                 allItems: allItems, signals: makeSignals())
        guard case .comparison(let firstC) = first else { XCTFail(); return }
        XCTAssertEqual(firstC.phase, .probe)

        _ = try engine.submitChoice(winnerId: "new")
        let undone = engine.undo()
        guard case .comparison(let undoneC) = undone else {
            XCTFail("expected undo to return a comparison"); return
        }
        XCTAssertEqual(undoneC.phase, .probe)
        XCTAssertEqual(undoneC.movieB.id, firstC.movieB.id)
    }

    func testSupportsMultipleUndos() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Action"]),
            makeItem("a3", tier: .A, rank: 2, genres: ["Action"]),
            makeItem("a4", tier: .A, rank: 3, genres: ["Comedy"]),
        ]
        let first = engine.start(newMovie: newMovie, tier: .A,
                                 allItems: allItems, signals: makeSignals())
        let second = try engine.submitChoice(winnerId: "new")
        _ = try engine.submitChoice(winnerId: "new")

        let undo1 = engine.undo()
        XCTAssertEqual(phase(of: undo1 ?? .done(finalRank: 0, finalScore: 0)), phase(of: second))

        let undo2 = engine.undo()
        XCTAssertEqual(phase(of: undo2 ?? .done(finalRank: 0, finalScore: 0)), phase(of: first))

        XCTAssertNil(engine.undo())
    }

    // MARK: full flow

    func testCompletesFullRankingFromStartToDone() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Action"]),
            makeItem("a3", tier: .A, rank: 2, genres: ["Action"]),
            makeItem("a4", tier: .A, rank: 3, genres: ["Drama"]),
            makeItem("a5", tier: .A, rank: 4, genres: ["Comedy"]),
        ]
        var result = engine.start(newMovie: newMovie, tier: .A,
                                  allItems: allItems, signals: makeSignals())
        var phases: [EnginePhase] = []
        var safety = 0

        while case .comparison(let c) = result, safety < 20 {
            phases.append(c.phase)
            switch c.phase {
            case .probe:      result = try engine.submitChoice(winnerId: "new")
            case .escalation: result = try engine.submitChoice(winnerId: c.movieB.id)
            case .crossGenre: result = try engine.submitChoice(winnerId: "new")
            case .settlement: result = try engine.submitChoice(winnerId: "new")
            default:          result = try engine.submitChoice(winnerId: "new")
            }
            safety += 1
        }
        guard case .done(_, let score) = result else { XCTFail(); return }
        XCTAssertGreaterThanOrEqual(score, 7.0)
        XCTAssertLessThanOrEqual(score, 8.9)
        XCTAssertTrue(phases.contains(.probe))
        XCTAssertTrue(phases.contains(.escalation))
        XCTAssertTrue(phases.contains(.crossGenre))
    }

    func testHandlesLosingEveryComparisonWorstPlacement() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .B)
        let allItems = [
            makeItem("b1", tier: .B, rank: 0, genres: ["Action"]),
            makeItem("b2", tier: .B, rank: 1, genres: ["Action"]),
            makeItem("b3", tier: .B, rank: 2, genres: ["Comedy"]),
        ]
        let signals = makeSignals(genreAffinity: 6.0, globalScore: 5.5, bracketAffinity: 5.0)
        var result = engine.start(newMovie: newMovie, tier: .B,
                                  allItems: allItems, signals: signals)
        var safety = 0
        while case .comparison(let c) = result, safety < 20 {
            result = try engine.submitChoice(winnerId: c.movieB.id)
            safety += 1
        }
        guard case .done(_, let score) = result else { XCTFail(); return }
        XCTAssertGreaterThanOrEqual(score, 5.0)
        XCTAssertLessThanOrEqual(score, 6.9)
    }

    // MARK: score-to-rank

    func testPlacesAtCorrectRankBasedOnFinalScore() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Action"]),
            makeItem("a3", tier: .A, rank: 2, genres: ["Action"]),
            makeItem("a4", tier: .A, rank: 3, genres: ["Action"]),
            makeItem("a5", tier: .A, rank: 4, genres: ["Comedy"]),
        ]
        var result = engine.start(newMovie: newMovie, tier: .A,
                                  allItems: allItems, signals: makeSignals())
        var safety = 0
        while case .comparison = result, safety < 20 {
            result = try engine.submitChoice(winnerId: "new")
            safety += 1
        }
        guard case .done(let rank, _) = result else { XCTFail(); return }
        XCTAssertEqual(rank, 0)
    }

    // MARK: state validation

    func testSubmitChoiceThrowsIfEngineNotStarted() {
        let engine = SpoolRankingEngine()
        XCTAssertThrowsError(try engine.submitChoice(winnerId: "something"))
    }

    func testSkipThrowsIfEngineNotStarted() {
        let engine = SpoolRankingEngine()
        XCTAssertThrowsError(try engine.skip())
    }

    func testSubmitChoiceThrowsIfEngineAlreadyComplete() {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let result = engine.start(newMovie: newMovie, tier: .A,
                                  allItems: [], signals: makeSignals())
        if case .done = result {
            XCTAssertThrowsError(try engine.submitChoice(winnerId: "something"))
        } else {
            XCTFail("expected .done for empty tier")
        }
    }

    // MARK: no cross-genre

    func testSkipsCrossGenreWhenNoDifferentGenreMoviesInTier() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Action"]),
            makeItem("a3", tier: .A, rank: 2, genres: ["Action"]),
        ]
        var result = engine.start(newMovie: newMovie, tier: .A,
                                  allItems: allItems, signals: makeSignals())
        var phases: [EnginePhase] = []
        var safety = 0
        while case .comparison(let c) = result, safety < 20 {
            phases.append(c.phase)
            result = try engine.submitChoice(winnerId: "new")
            safety += 1
        }
        guard case .done = result else { XCTFail(); return }
        XCTAssertFalse(phases.contains(.crossGenre))
    }

    // MARK: non-contiguous ranks

    func testComputesCorrectScoresWhenItemRanksHaveGaps() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Drama"], tier: .B)
        let allItems = [
            makeItem("b1", tier: .B, rank: 0, genres: ["Drama"]),
            makeItem("b2", tier: .B, rank: 2, genres: ["Drama"]),
        ]
        let signals = makeSignals(genreAffinity: 6.0, globalScore: 5.5, bracketAffinity: 5.0)
        var result = engine.start(newMovie: newMovie, tier: .B,
                                  allItems: allItems, signals: signals)
        var safety = 0
        while case .comparison = result, safety < 20 {
            result = try engine.submitChoice(winnerId: "new")
            safety += 1
        }
        guard case .done(let rank, let score) = result else { XCTFail(); return }
        XCTAssertEqual(rank, 0)
        XCTAssertGreaterThanOrEqual(score, 5.0)
        XCTAssertLessThanOrEqual(score, 6.9)
    }

    func testHandlesLargeRankGapsCorrectly() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 5, genres: ["Action"]),
            makeItem("a3", tier: .A, rank: 10, genres: ["Comedy"]),
        ]
        var result = engine.start(newMovie: newMovie, tier: .A,
                                  allItems: allItems, signals: makeSignals())
        var safety = 0
        while case .comparison = result, safety < 20 {
            result = try engine.submitChoice(winnerId: "new")
            safety += 1
        }
        guard case .done(let rank, let score) = result else { XCTFail(); return }
        XCTAssertEqual(rank, 0)
        XCTAssertGreaterThanOrEqual(score, 7.0)
        XCTAssertLessThanOrEqual(score, 8.9)
    }

    func testProducesValidTierScoresDespiteRankGaps() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Drama"], tier: .B)
        let allItems = [
            makeItem("b1", tier: .B, rank: 0, genres: ["Drama"]),
            makeItem("b2", tier: .B, rank: 3, genres: ["Drama"]),
            makeItem("b3", tier: .B, rank: 7, genres: ["Comedy"]),
        ]
        let signals = makeSignals(genreAffinity: 5.5, globalScore: 5.0, bracketAffinity: 5.0)
        let probe = engine.start(newMovie: newMovie, tier: .B,
                                 allItems: allItems, signals: signals)
        guard case .comparison(let probeC) = probe else { XCTFail(); return }
        XCTAssertEqual(probeC.phase, .probe)

        var result = try engine.submitChoice(winnerId: probeC.movieB.id)
        var safety = 0
        while case .comparison(let c) = result, safety < 20 {
            result = try engine.submitChoice(winnerId: c.movieB.id)
            safety += 1
        }
        guard case .done(_, let score) = result else { XCTFail(); return }
        XCTAssertGreaterThanOrEqual(score, 5.0)
        XCTAssertLessThanOrEqual(score, 6.9)
    }

    // MARK: settlement stability

    func testWinningSettlementDoesNotLowerScoreBelowBeatenItems() throws {
        let engine = SpoolRankingEngine()
        let newMovie = makeNewMovie("new", genres: ["Drama"], tier: .A)
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Drama"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Drama"]),
            makeItem("a3", tier: .A, rank: 2, genres: ["Drama"]),
            makeItem("a4", tier: .A, rank: 3, genres: ["Comedy"]),
        ]
        var result = engine.start(newMovie: newMovie, tier: .A,
                                  allItems: allItems, signals: makeSignals())
        var safety = 0
        while case .comparison = result, safety < 20 {
            result = try engine.submitChoice(winnerId: "new")
            safety += 1
        }
        guard case .done(let rank, _) = result else { XCTFail(); return }
        XCTAssertEqual(rank, 0)
    }

    // MARK: round counter

    func testRoundCounterIncrementsAndResetsOnUndo() throws {
        let engine = SpoolRankingEngine()
        let allItems = [
            makeItem("a1", tier: .A, rank: 0, genres: ["Action"]),
            makeItem("a2", tier: .A, rank: 1, genres: ["Action"]),
            makeItem("a3", tier: .A, rank: 2, genres: ["Drama"]),
        ]
        let newMovie = makeNewMovie("new", genres: ["Action"], tier: .A)
        let r1 = engine.start(newMovie: newMovie, tier: .A,
                              allItems: allItems, signals: makeSignals())
        guard case .comparison(let c1) = r1 else { XCTFail(); return }
        XCTAssertEqual(c1.round, 1)

        let r2 = try engine.submitChoice(winnerId: newMovie.id)
        guard case .comparison(let c2) = r2 else { return }
        XCTAssertEqual(c2.round, 2)

        let undone = engine.undo()
        guard case .comparison(let undoneC) = undone else {
            XCTFail("expected undone comparison"); return
        }
        XCTAssertEqual(undoneC.round, 1)

        let r2b = try engine.submitChoice(winnerId: newMovie.id)
        if case .comparison(let c2b) = r2b {
            XCTAssertEqual(c2b.round, 2)
        }
    }
}
