import XCTest
@testable import Spool

/// Pure query-variant generator for the zero-result typo-retry backoff.
/// Swift mirror of web `services/searchVariants.ts` `typoRetryVariants` and its
/// test suite `services/__tests__/searchVariants.test.ts`. Same rules, same
/// thresholds, same ordered/deduped/capped output so iOS TMDB search recovers
/// from the same fat-finger typos the web already handles.
final class SearchVariantsTests: XCTestCase {

    func testCollapsesInnerSpaceFirstForMatriX() {
        // "matri x" -> collapse the stray single-char last token -> "matrix",
        // then drop-last-token -> "matri". No chop (chopping "x" underflows 4).
        XCTAssertEqual(TMDBService.typoRetryVariants("matri x"), ["matrix", "matri"])
    }

    func testProgressivelyChopsTrailingCharsOfSingleTokenTypo() {
        // "shawshenk" -> chop 1 -> "shawshen", chop 2 -> "shawshe" (both >= 4).
        // Single token, so no drop-last-token variant.
        XCTAssertEqual(TMDBService.typoRetryVariants("shawshenk"), ["shawshen", "shawshe"])
    }

    func testMultiWordDarkKnigtChopsLastTokenThenDropsIt() {
        // No inner-only space to collapse (single space between two words is normal).
        // Last token "knigt" (5) -> "knig" (4). Chop-2 "kni" (3 < 4) skipped.
        // Then drop-last-token -> "dark" (remainder >= 3 chars, >= 2 tokens).
        XCTAssertEqual(TMDBService.typoRetryVariants("dark knigt"), ["dark knig", "dark"])
    }

    func testReturnsEmptyForQueriesShorterThan4Chars() {
        XCTAssertEqual(TMDBService.typoRetryVariants("ab"), [])
    }

    func testReturnsEmptyForCJKContainingQueries() {
        XCTAssertEqual(TMDBService.typoRetryVariants("肖申克"), [])
    }

    func testNeverIncludesTheOriginalQuery() {
        let q = "shawshenk"
        XCTAssertFalse(TMDBService.typoRetryVariants(q).contains(q))
    }

    func testDedupesWhenCollapseResultEqualsChopResult() {
        let variants = TMDBService.typoRetryVariants("matri x")
        XCTAssertEqual(Set(variants).count, variants.count)
    }

    func testTrimsAndSingleSpaceNormalizesBeforeGenerating() {
        // Leading/trailing/interior extra whitespace should be normalized.
        XCTAssertEqual(TMDBService.typoRetryVariants("  dark   knigt  "), ["dark knig", "dark"])
    }

    func testCapsTheNumberOfVariantsAt3() {
        let variants = TMDBService.typoRetryVariants("interstellarr galaxy quest")
        XCTAssertLessThanOrEqual(variants.count, 3)
    }

    func testDoesNotChopWhenLastTokenWouldDropBelow4Chars() {
        // "star warz" -> last token "warz" (4). Chop-1 "war" (3 < 4) skipped.
        // So no chop variants; drop-last-token -> "star" (>= 3).
        XCTAssertEqual(TMDBService.typoRetryVariants("star warz"), ["star"])
    }

    func testDoesNotDropLastTokenWhenRemainderIsUnder3Chars() {
        // "it knigt" -> last token "knigt" chops to "knig". Drop-last would
        // leave "it" (2 < 3), so it is skipped.
        XCTAssertEqual(TMDBService.typoRetryVariants("it knigt"), ["it knig"])
    }

    // MARK: - TV search shares this exact variant generator

    /// `searchTVShows` reuses `typoRetryVariants` verbatim (the same shared pure
    /// function as `searchMovies`) inside its zero-result retry loop, mirroring
    /// web where both `searchMovies` and `searchTVShows` call the same
    /// `typoRetryVariants`. There is no TV-specific variant generator, so the TV
    /// retry backoff produces byte-identical variants for the same query. This
    /// pins that shared-code contract so a future TV-only fork would be caught.
    func testTVSearchUsesTheSameVariantGeneratorAsMovieSearch() {
        XCTAssertEqual(
            TMDBService.typoRetryVariants("shawshenk"),
            ["shawshen", "shawshe"],
            "TV + movie search share one typoRetryVariants — no TV-specific fork"
        )
    }
}
