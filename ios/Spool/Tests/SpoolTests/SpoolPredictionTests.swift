import XCTest
@testable import Spool

final class SpoolPredictionTests: XCTestCase {

    private func makeItem(
        _ id: String, tier: Tier, rank: Int, genres: [String],
        bracket: Bracket? = nil, globalScore: Double? = nil
    ) -> RankedItem {
        RankedItem(
            id: id, title: id, year: 2020, director: "—",
            genres: genres, tier: tier, rank: rank,
            bracket: bracket, globalScore: globalScore, seed: 0
        )
    }

    // MARK: computePredictionSignals

    func testComputesGenreAffinityFromSameGenreMovies() {
        let items = [
            makeItem("1", tier: .A, rank: 0, genres: ["Horror"], bracket: .commercial),
            makeItem("2", tier: .A, rank: 1, genres: ["Horror"], bracket: .commercial),
            makeItem("3", tier: .B, rank: 0, genres: ["Comedy"], bracket: .commercial),
        ]
        let signals = SpoolPrediction.computePredictionSignals(
            allItems: items, primaryGenre: "Horror",
            bracket: .commercial, globalScore: nil, tier: .A
        )
        guard let g = signals.genreAffinity else {
            XCTFail("expected non-nil genreAffinity"); return
        }
        XCTAssertGreaterThan(g, 7)
        XCTAssertLessThan(g, 9)
    }

    func testReturnsNilGenreAffinityWhenNoSameGenreMoviesExist() {
        let items = [
            makeItem("1", tier: .A, rank: 0, genres: ["Comedy"], bracket: .commercial),
        ]
        let signals = SpoolPrediction.computePredictionSignals(
            allItems: items, primaryGenre: "Horror",
            bracket: .commercial, globalScore: nil, tier: .A
        )
        XCTAssertNil(signals.genreAffinity)
    }

    func testReturnsGlobalScoreMappedToTierRange() {
        let signals = SpoolPrediction.computePredictionSignals(
            allItems: [], primaryGenre: "Horror",
            bracket: .commercial, globalScore: 7.5, tier: .A
        )
        XCTAssertEqual(signals.globalScore, 7.5)
    }

    func testClampsGlobalScoreToTierRange() {
        let signals = SpoolPrediction.computePredictionSignals(
            allItems: [], primaryGenre: "Horror",
            bracket: .commercial, globalScore: 9.5, tier: .A
        )
        XCTAssertEqual(signals.globalScore, 8.9)
    }

    func testReturnsNilGlobalScoreWhenUndefined() {
        let signals = SpoolPrediction.computePredictionSignals(
            allItems: [], primaryGenre: "Horror",
            bracket: .commercial, globalScore: nil, tier: .A
        )
        XCTAssertNil(signals.globalScore)
    }

    func testTracksTotalRanked() {
        let items = [
            makeItem("1", tier: .A, rank: 0, genres: ["Horror"], bracket: .commercial),
            makeItem("2", tier: .B, rank: 0, genres: ["Comedy"], bracket: .commercial),
        ]
        let signals = SpoolPrediction.computePredictionSignals(
            allItems: items, primaryGenre: "Horror",
            bracket: .commercial, globalScore: nil, tier: .A
        )
        XCTAssertEqual(signals.totalRanked, 2)
    }

    // MARK: predictScore

    func testUsesAllThreeSignalsWithCorrectWeights() {
        let signals = PredictionSignals(
            genreAffinity: 8.0, globalScore: 7.5, bracketAffinity: 7.0,
            totalRanked: 20
        )
        // 8.0*0.45 + 7.5*0.35 + 7.0*0.20 = 7.625
        let score = SpoolPrediction.predictScore(signals: signals, tier: .A)
        XCTAssertEqual(score, 7.625, accuracy: 0.1)
    }

    func testFallsBackToGlobalScoreOnlyForNewUsers() {
        let signals = PredictionSignals(
            genreAffinity: 8.5, globalScore: 7.0, bracketAffinity: 8.0,
            totalRanked: 10
        )
        let score = SpoolPrediction.predictScore(signals: signals, tier: .A)
        XCTAssertEqual(score, 7.0)
    }

    func testUsesTierMidpointWhenNoSignalsAvailableForNewUser() {
        let signals = PredictionSignals(
            genreAffinity: nil, globalScore: nil, bracketAffinity: nil,
            totalRanked: 5
        )
        // A-tier midpoint: (7.0 + 8.9) / 2 = 7.95
        let score = SpoolPrediction.predictScore(signals: signals, tier: .A)
        XCTAssertEqual(score, 7.95, accuracy: 0.1)
    }

    func testRedistributesWeightsWhenSomeSignalsAreNull() {
        let signals = PredictionSignals(
            genreAffinity: nil, globalScore: 8.0, bracketAffinity: 7.0,
            totalRanked: 20
        )
        // globalScore weight: 0.35 / 0.55 ≈ 0.636
        // bracketAffinity weight: 0.20 / 0.55 ≈ 0.364
        // 8.0*0.636 + 7.0*0.364 ≈ 7.636
        let score = SpoolPrediction.predictScore(signals: signals, tier: .A)
        XCTAssertEqual(score, 7.636, accuracy: 0.1)
    }

    func testClampsResultToTierBounds() {
        let signals = PredictionSignals(
            genreAffinity: 10.0, globalScore: 10.0, bracketAffinity: 10.0,
            totalRanked: 20
        )
        let score = SpoolPrediction.predictScore(signals: signals, tier: .A)
        XCTAssertLessThanOrEqual(score, 8.9)
        XCTAssertGreaterThanOrEqual(score, 7.0)
    }
}
