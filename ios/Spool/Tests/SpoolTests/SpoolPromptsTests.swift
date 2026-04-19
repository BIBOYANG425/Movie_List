import XCTest
@testable import Spool

final class SpoolPromptsTests: XCTestCase {

    func testReturnsGenrePromptWhenBothMoviesShareKnownGenre() {
        let prompt = SpoolPrompts.getComparisonPrompt(
            tier: .A, genreA: "Horror", genreB: "Horror", phase: .probe
        )
        XCTAssertEqual(prompt, "Which one unsettled you more?")
    }

    func testReturnsTierPromptForCrossGenrePhase() {
        let prompt = SpoolPrompts.getComparisonPrompt(
            tier: .A, genreA: "Horror", genreB: "Drama", phase: .crossGenre
        )
        XCTAssertEqual(prompt, "Which experience stayed with you longer?")
    }

    func testReturnsTierPromptWhenGenresDifferInNonCrossGenrePhase() {
        let prompt = SpoolPrompts.getComparisonPrompt(
            tier: .B, genreA: "Horror", genreB: "Comedy", phase: .probe
        )
        XCTAssertEqual(prompt, "Which one did you enjoy more in the moment?")
    }

    func testReturnsTierPromptForUnknownGenre() {
        let prompt = SpoolPrompts.getComparisonPrompt(
            tier: .S, genreA: "Western", genreB: "Western", phase: .probe
        )
        XCTAssertEqual(prompt, "Which one changed something in you?")
    }

    func testReturnsCorrectPromptsForEachTier() {
        let s = SpoolPrompts.getComparisonPrompt(tier: .S, genreA: "Drama", genreB: "Drama", phase: .probe)
        XCTAssertTrue(s.contains("closer to home"))

        let d = SpoolPrompts.getComparisonPrompt(tier: .D, genreA: "Drama", genreB: "Drama", phase: .probe)
        XCTAssertTrue(d.contains("forgettable"))
    }
}
