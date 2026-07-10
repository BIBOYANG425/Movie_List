import XCTest
@testable import Spool

/// Entry-for-entry parity spec for the TV genre table + normalization.
///
/// Swift mirror of web `TV_GENRE_MAP` and `normalizeTVGenres`
/// (`services/tmdbService.ts` §TV Show Types & Service Functions). The review
/// diffs these tables directly, so the map is pinned entry-by-entry (id → name)
/// and the normalization covers the compound expansions, the drop-to-empty
/// genres, unknown pass-through, dedupe, the 3-cap, and the empty input.
final class TVGenreTests: XCTestCase {

    // MARK: - TV_GENRE_MAP entry parity

    /// Pins every id→name entry against the web `TV_GENRE_MAP`, and pins the
    /// table SIZE so an added/removed web entry that isn't mirrored here fails.
    func testGenreMapMatchesWebTableEntryForEntry() {
        let expected: [Int: String] = [
            10759: "Action & Adventure",
            16: "Animation",
            35: "Comedy",
            80: "Crime",
            99: "Documentary",
            18: "Drama",
            10751: "Family",
            10762: "Kids",
            9648: "Mystery",
            10763: "News",
            10764: "Reality",
            10765: "Sci-Fi & Fantasy",
            10766: "Soap",
            10767: "Talk",
            10768: "War & Politics",
            37: "Western",
        ]
        XCTAssertEqual(TMDBTVGenres.genreMap, expected)
        XCTAssertEqual(TMDBTVGenres.genreMap.count, 16, "web TV_GENRE_MAP has 16 entries")
    }

    /// The TV namespace is distinct from the movie one: `10759`/`10765`/`10768`
    /// are TV-only compound ids and must NOT collide with the movie meanings.
    func testTVGenreIdsAreTVNamespace() {
        XCTAssertEqual(TMDBTVGenres.genreMap[10759], "Action & Adventure")
        XCTAssertEqual(TMDBTVGenres.genreMap[10765], "Sci-Fi & Fantasy")
        XCTAssertEqual(TMDBTVGenres.genreMap[10768], "War & Politics")
        // 878 is the MOVIE Sci-Fi id — not a TV genre id, so it must be unmapped.
        XCTAssertNil(TMDBTVGenres.genreMap[878])
    }

    // MARK: - mapGenreIds

    func testMapGenreIdsMapsKnownDropsUnknownCapsAt3() {
        // 99999 is unknown → dropped; 4 known ids → capped at 3.
        let out = TMDBTVGenres.mapGenreIds([18, 99999, 35, 80, 16])
        XCTAssertEqual(out, ["Drama", "Comedy", "Crime"])
    }

    func testMapGenreIdsEmptyStaysEmpty() {
        XCTAssertEqual(TMDBTVGenres.mapGenreIds([]), [])
    }

    // MARK: - normalizeTVGenres compound expansions

    func testNormalizesActionAndAdventureCompound() {
        XCTAssertEqual(
            TMDBTVGenres.normalize(["Action & Adventure"]),
            ["Action", "Adventure"]
        )
    }

    func testNormalizesSciFiAndFantasyCompound() {
        XCTAssertEqual(
            TMDBTVGenres.normalize(["Sci-Fi & Fantasy"]),
            ["Sci-Fi", "Fantasy"]
        )
    }

    func testNormalizesWarAndPoliticsToWarOnly() {
        XCTAssertEqual(TMDBTVGenres.normalize(["War & Politics"]), ["War"])
    }

    func testNormalizesKidsToFamily() {
        XCTAssertEqual(TMDBTVGenres.normalize(["Kids"]), ["Family"])
    }

    func testNormalizesSoapToDrama() {
        XCTAssertEqual(TMDBTVGenres.normalize(["Soap"]), ["Drama"])
    }

    // MARK: - normalizeTVGenres drop-to-empty exclusions

    func testDropsNewsRealityTalkToEmpty() {
        XCTAssertEqual(TMDBTVGenres.normalize(["News"]), [])
        XCTAssertEqual(TMDBTVGenres.normalize(["Reality"]), [])
        XCTAssertEqual(TMDBTVGenres.normalize(["Talk"]), [])
        XCTAssertEqual(TMDBTVGenres.normalize(["News", "Reality", "Talk"]), [])
    }

    // MARK: - normalizeTVGenres pass-through, dedupe, cap, empty

    func testPassesNonCompoundNamesThroughUnchanged() {
        XCTAssertEqual(
            TMDBTVGenres.normalize(["Drama", "Comedy", "Crime"]),
            ["Drama", "Comedy", "Crime"]
        )
    }

    func testDedupesExpandedNamesPreservingFirstSeenOrder() {
        // "Action & Adventure" → Action, Adventure; then a bare "Action" dupes.
        XCTAssertEqual(
            TMDBTVGenres.normalize(["Action & Adventure", "Action"]),
            ["Action", "Adventure"]
        )
    }

    func testCapsResultAt3AfterExpansion() {
        // Action & Adventure (2) + Sci-Fi & Fantasy (2) = 4 → capped at 3.
        XCTAssertEqual(
            TMDBTVGenres.normalize(["Action & Adventure", "Sci-Fi & Fantasy"]),
            ["Action", "Adventure", "Sci-Fi"]
        )
    }

    func testEmptyInputMapsToEmpty() {
        XCTAssertEqual(TMDBTVGenres.normalize([]), [])
    }

    func testMixedDropAndKeepOnlyKeepsKept() {
        // News (drop) + Drama (keep) + Talk (drop) → just Drama.
        XCTAssertEqual(
            TMDBTVGenres.normalize(["News", "Drama", "Talk"]),
            ["Drama"]
        )
    }
}
