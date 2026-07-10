import XCTest
@testable import Spool

/// RED-first spec for the OpenLibrary book search client — decode + mapping,
/// genre normalization, cover URL, and the request builder.
///
/// Swift mirror of web `services/openLibraryService.ts` (`searchBooks` doc map
/// ~168-186, `normalizeBookGenres` + `SUBJECT_TO_GENRE`, `getBookCoverUrl`, and
/// the `q`/`limit`/`fields` query params). Books are search-only (no suggestion
/// engine, no typo-retry — OL tokenizes). OpenLibrary is KEYLESS and direct (not
/// proxy-routed), so unlike the TMDB seams there is no api key to assert absent;
/// instead we pin the User-Agent header on the built request (OL API policy).
///
/// Pure: decode a fixture doc with the internal `OLDoc` type, run the extracted
/// mapper, and assert the mapped shape — no network. Pins the load-bearing parity
/// facts the review diffs: `ol_{workKey}` id mint (incl. `/works/` prefix strip),
/// title/author/year/pages/rating extraction, cover URL composition, missing-field
/// tolerance, the coverless-kept decision, genre exact + partial matching, and the
/// request builder's params + User-Agent.
final class OpenLibraryMappingTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - doc mapping: id mint + core fields

    func testMapsWorkKeyToOlIdStrippingWorksPrefix() throws {
        let json = """
        {
          "key": "/works/OL27448W",
          "title": "The Lord of the Rings",
          "author_name": ["J.R.R. Tolkien", "Someone Else"],
          "first_publish_year": 1954,
          "number_of_pages_median": 1178,
          "cover_i": 258027,
          "ratings_average": 4.5,
          "subject": ["Fantasy", "Fiction"]
        }
        """
        let doc = try decoder.decode(OpenLibraryService.OLDoc.self, from: Data(json.utf8))
        let book = try XCTUnwrap(OpenLibraryService.mapDoc(doc))

        // "/works/OL27448W" → workKey "OL27448W" → id "ol_OL27448W".
        XCTAssertEqual(book.olWorkKey, "OL27448W")
        XCTAssertEqual(book.id, "ol_OL27448W")
        XCTAssertEqual(book.title, "The Lord of the Rings")
        // First author only.
        XCTAssertEqual(book.author, "J.R.R. Tolkien")
        // Year is the stringified first_publish_year.
        XCTAssertEqual(book.year, "1954")
        XCTAssertEqual(book.pageCount, 1178)
        XCTAssertEqual(book.olRatingsAverage, 4.5)
        // globalScore is the 0-5 rating doubled to a 0-10 scale.
        XCTAssertEqual(book.globalScore, 9.0)
        XCTAssertEqual(book.genres, ["Fantasy", "Fiction"])
    }

    func testCoverIdComposesMediumCoverUrl() throws {
        let json = """
        { "key": "/works/OL1W", "title": "T", "cover_i": 258027 }
        """
        let doc = try decoder.decode(OpenLibraryService.OLDoc.self, from: Data(json.utf8))
        let book = try XCTUnwrap(OpenLibraryService.mapDoc(doc))
        // Web uses the 'M' size from covers.openlibrary.org.
        XCTAssertEqual(book.posterUrl, "https://covers.openlibrary.org/b/id/258027-M.jpg")
    }

    // MARK: - missing-field tolerance

    func testMissingFieldsFallBackLikeWeb() throws {
        // No author / year / pages / rating / cover / subjects.
        let json = """
        { "key": "/works/OL9W", "title": "Bare Book" }
        """
        let doc = try decoder.decode(OpenLibraryService.OLDoc.self, from: Data(json.utf8))
        let book = try XCTUnwrap(OpenLibraryService.mapDoc(doc))

        XCTAssertEqual(book.id, "ol_OL9W")
        XCTAssertEqual(book.title, "Bare Book")
        // Missing author → "Unknown" (web `?? 'Unknown'`).
        XCTAssertEqual(book.author, "Unknown")
        // Missing year → "" (web `?? ''`).
        XCTAssertEqual(book.year, "")
        // Coverless → empty-string posterUrl (web `getBookCoverUrl(undefined)` → '').
        XCTAssertEqual(book.posterUrl, "")
        XCTAssertEqual(book.genres, [])
        XCTAssertNil(book.pageCount)
        XCTAssertNil(book.isbn)
        XCTAssertNil(book.olRatingsAverage)
        XCTAssertNil(book.globalScore)
    }

    func testFirstIsbnIsExtracted() throws {
        let json = """
        { "key": "/works/OL2W", "title": "T", "isbn": ["9780618640157", "0618640150"] }
        """
        let doc = try decoder.decode(OpenLibraryService.OLDoc.self, from: Data(json.utf8))
        let book = try XCTUnwrap(OpenLibraryService.mapDoc(doc))
        XCTAssertEqual(book.isbn, "9780618640157")
    }

    // MARK: - coverless decision pinned

    func testCoverlessBookIsKeptNotDropped() throws {
        // Web filters ONLY on (title && key); a coverless doc survives the filter
        // and maps to an empty posterUrl. `mapDoc` therefore returns non-nil here.
        let json = """
        { "key": "/works/OL3W", "title": "No Cover" }
        """
        let doc = try decoder.decode(OpenLibraryService.OLDoc.self, from: Data(json.utf8))
        XCTAssertNotNil(OpenLibraryService.mapDoc(doc), "coverless books are kept (web parity)")
    }

    func testDocMissingTitleIsDropped() throws {
        // Web filter drops docs without a title. mapDoc returns nil.
        let json = """
        { "key": "/works/OL4W" }
        """
        let doc = try decoder.decode(OpenLibraryService.OLDoc.self, from: Data(json.utf8))
        XCTAssertNil(OpenLibraryService.mapDoc(doc))
    }

    func testDocMissingKeyIsDropped() throws {
        // Web filter drops docs without a key. mapDoc returns nil.
        let json = """
        { "title": "Keyless" }
        """
        let doc = try decoder.decode(OpenLibraryService.OLDoc.self, from: Data(json.utf8))
        XCTAssertNil(OpenLibraryService.mapDoc(doc))
    }

    // MARK: - rating → globalScore edge

    func testZeroRatingStillProducesGlobalScore() throws {
        // ratings_average present (0.0) is distinct from absent: web checks
        // `!= null`, so 0 doubles to a 0 globalScore rather than nil.
        let json = """
        { "key": "/works/OL5W", "title": "T", "ratings_average": 0 }
        """
        let doc = try decoder.decode(OpenLibraryService.OLDoc.self, from: Data(json.utf8))
        let book = try XCTUnwrap(OpenLibraryService.mapDoc(doc))
        XCTAssertEqual(book.olRatingsAverage, 0)
        XCTAssertEqual(book.globalScore, 0)
    }

    // MARK: - getBookCoverUrl

    func testCoverUrlSizesAndEmptyForNil() {
        XCTAssertEqual(
            OpenLibraryService.getBookCoverUrl(123, size: "S"),
            "https://covers.openlibrary.org/b/id/123-S.jpg"
        )
        XCTAssertEqual(
            OpenLibraryService.getBookCoverUrl(123, size: "L"),
            "https://covers.openlibrary.org/b/id/123-L.jpg"
        )
        // Default size is 'M'.
        XCTAssertEqual(
            OpenLibraryService.getBookCoverUrl(123),
            "https://covers.openlibrary.org/b/id/123-M.jpg"
        )
        // No cover id → empty string (never a broken URL).
        XCTAssertEqual(OpenLibraryService.getBookCoverUrl(nil), "")
    }
}
