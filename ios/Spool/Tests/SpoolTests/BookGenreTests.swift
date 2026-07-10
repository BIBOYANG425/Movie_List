import XCTest
@testable import Spool

/// Entry-for-entry parity spec for the book genre normalization table.
///
/// Swift mirror of web `normalizeBookGenres` + `SUBJECT_TO_GENRE`
/// (`services/openLibraryService.ts`) and `ALL_BOOK_GENRES` (`constants.ts`).
/// The review diffs these tables directly, so the map is pinned entry-by-entry
/// (subject → canonical genre) and the normalization covers exact matching,
/// the partial-match fallback (longest-keyword-first, break per subject, stop at
/// 3), the 5-cap, dedupe, invalid-genre rejection, and the empty input.
final class BookGenreTests: XCTestCase {

    // MARK: - SUBJECT_TO_GENRE entry parity

    /// Pins every subject→genre entry against the web `SUBJECT_TO_GENRE` map, and
    /// pins the table SIZE so an added/removed web entry that isn't mirrored here
    /// fails.
    func testSubjectMapMatchesWebTableEntryForEntry() {
        let expected: [String: String] = [
            // Fiction genres
            "fiction": "Fiction",
            "literary fiction": "Literary Fiction",
            "fantasy": "Fantasy",
            "fantasy fiction": "Fantasy",
            "science fiction": "Sci-Fi",
            "sci-fi": "Sci-Fi",
            "mystery": "Mystery",
            "mystery and detective stories": "Mystery",
            "detective": "Mystery",
            "thriller": "Thriller",
            "thrillers": "Thriller",
            "suspense": "Thriller",
            "romance": "Romance",
            "romance fiction": "Romance",
            "love stories": "Romance",
            "horror": "Horror",
            "horror fiction": "Horror",
            "humor": "Humor",
            "humorous fiction": "Humor",
            "comedy": "Humor",
            "satire": "Humor",
            "young adult": "Young Adult",
            "young adult fiction": "Young Adult",
            "juvenile fiction": "Children",
            "children's fiction": "Children",
            "children": "Children",
            "graphic novels": "Graphic Novel",
            "comics": "Graphic Novel",
            "manga": "Graphic Novel",
            "poetry": "Poetry",
            "poems": "Poetry",
            // Non-fiction genres
            "non-fiction": "Non-fiction",
            "nonfiction": "Non-fiction",
            "biography": "Biography",
            "biographies": "Biography",
            "autobiography": "Biography",
            "memoirs": "Biography",
            "memoir": "Biography",
            "history": "History",
            "historical": "History",
            "philosophy": "Philosophy",
            "self-help": "Self-help",
            "self help": "Self-help",
            "personal development": "Self-help",
            "science": "Science",
            "popular science": "Science",
            "travel": "Travel",
            "travel writing": "Travel",
        ]
        XCTAssertEqual(OpenLibraryService.subjectToGenre, expected)
        XCTAssertEqual(OpenLibraryService.subjectToGenre.count, 48, "web SUBJECT_TO_GENRE has 48 entries")
    }

    /// Pins `ALL_BOOK_GENRES` entry-for-entry (order + size) against web.
    func testAllBookGenresMatchesWebList() {
        XCTAssertEqual(OpenLibraryService.allBookGenres, [
            "Fiction", "Non-fiction", "Fantasy", "Sci-Fi", "Mystery", "Thriller",
            "Romance", "Horror", "Biography", "History", "Philosophy", "Poetry",
            "Self-help", "Science", "Travel", "Young Adult", "Children",
            "Graphic Novel", "Humor", "Literary Fiction",
        ])
        XCTAssertEqual(OpenLibraryService.allBookGenres.count, 20)
    }

    // MARK: - exact matching

    func testExactMatchIsCaseAndWhitespaceInsensitive() {
        // Web lowercases + trims each subject before the map lookup.
        XCTAssertEqual(
            OpenLibraryService.normalizeBookGenres(["  SCIENCE Fiction  "]),
            ["Sci-Fi"]
        )
    }

    func testExactMatchesDedupeAcrossSynonyms() {
        // "fantasy" and "fantasy fiction" both map to Fantasy → single entry.
        XCTAssertEqual(
            OpenLibraryService.normalizeBookGenres(["Fantasy", "Fantasy Fiction"]),
            ["Fantasy"]
        )
    }

    func testMultipleDistinctExactMatches() {
        XCTAssertEqual(
            OpenLibraryService.normalizeBookGenres(["Fiction", "Romance", "Horror"]),
            ["Fiction", "Romance", "Horror"]
        )
    }

    // MARK: - partial-match fallback

    func testPartialMatchFallbackWhenNoExactMatch() {
        // "Epic fantasy sagas" has no exact map entry, but contains "fantasy".
        XCTAssertEqual(
            OpenLibraryService.normalizeBookGenres(["Epic fantasy sagas"]),
            ["Fantasy"]
        )
    }

    func testPartialMatchPrefersLongerKeyword() {
        // A subject containing both "science" (7) and "science fiction" (15):
        // longest keyword wins, so Sci-Fi (from "science fiction"), not Science.
        XCTAssertEqual(
            OpenLibraryService.normalizeBookGenres(["A history of science fiction cinema"]),
            ["Sci-Fi"]
        )
    }

    func testPartialMatchBreaksAfterFirstHitPerSubjectAndTieResolvesInWebSourceOrder() {
        // Each subject contributes at most one partial-match genre (web `break`).
        // "fantasy romance novels" contains both "fantasy" (7 chars, source index 2)
        // and "romance" (7 chars, source index 12). Both are 7 characters, so length
        // alone can't disambiguate. Web's `Array.prototype.sort` is STABLE, so equal-
        // length keywords keep their insertion order — "fantasy" (earlier in
        // SUBJECT_TO_GENRE) sorts before "romance". iOS must reproduce this: Fantasy
        // wins, not Romance, and not a random result that varies per launch.
        let out = OpenLibraryService.normalizeBookGenres(["fantasy romance novels"])
        XCTAssertEqual(out.count, 1, "only one genre per subject (web break)")
        XCTAssertEqual(out.first, "Fantasy",
            "tie resolved in web source order: 'fantasy' (index 2) beats 'romance' (index 12)")
    }

    func testPartialMatchStopsAtThreeSubjects() {
        // Web caps the partial-match loop at 3 accumulated genres.
        let out = OpenLibraryService.normalizeBookGenres([
            "great fantasy tales",
            "classic horror stories",
            "epic science fiction",
            "thriller collections",
            "romance anthology",
        ])
        XCTAssertEqual(out.count, 3)
    }

    // MARK: - caps + invalid rejection

    func testResultCappedAtFiveGenres() {
        let out = OpenLibraryService.normalizeBookGenres([
            "Fiction", "Fantasy", "Sci-Fi", "Mystery", "Thriller", "Romance", "Horror",
        ])
        XCTAssertEqual(out.count, 5)
    }

    func testUnknownSubjectsYieldEmpty() {
        // No exact and no partial keyword present → empty.
        XCTAssertEqual(OpenLibraryService.normalizeBookGenres(["Cooking", "Gardening"]), [])
    }

    func testEmptyInputYieldsEmpty() {
        XCTAssertEqual(OpenLibraryService.normalizeBookGenres([]), [])
    }
}
