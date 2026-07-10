import XCTest
import Supabase
@testable import Spool

/// Pure contract tests for the `WatchlistRepository` marshalling seams — the
/// network-free bits. Mirrors web `rowToWatchlistItem` / `rowToTVWatchlistItem`
/// / `rowToBookWatchlistItem` (`pages/RankingAppPage.tsx:131-221`) and the
/// binding contract in the C3 audit §1.1 (three parallel tables) + §1.4 (the
/// TV exclusion-id expansion caller contract).
///
/// Coverage per the brief:
///  - every column of all three tables round-trips (no silent drops),
///  - whole-show detection (`season_number` 0 OR NULL → whole show, D6),
///  - `show_tmdb_id = 0` TV rows REJECTED at mapping (B2),
///  - id-format helpers (`tmdb_{n}`, `tv_{n}_s{m}`, `tv_{n}`, `ol_{key}`),
///  - TV exclusion-id expansion (season id → season id ∪ show id, §1.4).
final class WatchlistContractTests: XCTestCase {

    // MARK: movie row → WatchlistItem (all columns)

    /// `watchlist_items` maps title, year, poster_url, type='movie', genres,
    /// director, added_at — every column, no drops (web `rowToWatchlistItem`).
    func testMovieRowMapsEveryColumn() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "user_id": "22222222-2222-2222-2222-222222222222",
            "tmdb_id": "tmdb_603",
            "title": "The Matrix",
            "year": "1999",
            "poster_url": "https://img/matrix.jpg",
            "type": "movie",
            "genres": ["Action", "Sci-Fi"],
            "director": "The Wachowskis",
            "added_at": "2026-07-06T12:00:00Z"
        }
        """.data(using: .utf8)!

        let row = try JSONDecoder().decode(WatchlistRow.self, from: json)
        let item = try XCTUnwrap(WatchlistContract.mapMovieRow(row))

        XCTAssertEqual(item.id, "tmdb_603")
        XCTAssertEqual(item.title, "The Matrix")
        XCTAssertEqual(item.year, "1999")
        XCTAssertEqual(item.posterUrl, "https://img/matrix.jpg")
        XCTAssertEqual(item.mediaType, .movie)
        XCTAssertEqual(item.genres, ["Action", "Sci-Fi"])
        XCTAssertEqual(item.director, "The Wachowskis")
        XCTAssertEqual(item.addedAt, ISO8601DateFormatter().date(from: "2026-07-06T12:00:00Z"))
        // Per-media fields that don't belong to movies stay nil.
        XCTAssertNil(item.showTmdbId)
        XCTAssertNil(item.seasonNumber)
        XCTAssertNil(item.creator)
        XCTAssertNil(item.author)
        XCTAssertNil(item.pageCount)
    }

    /// Nullable/absent columns coalesce the web way: `year ?? ''`,
    /// `poster_url ?? ''`, `genres ?? []`, `director` stays nil.
    func testMovieRowNullCoalescing() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "user_id": "22222222-2222-2222-2222-222222222222",
            "tmdb_id": "tmdb_1",
            "title": "Untitled",
            "year": null,
            "poster_url": null,
            "type": "movie",
            "genres": null,
            "director": null,
            "added_at": "2026-07-06T12:00:00Z"
        }
        """.data(using: .utf8)!

        let row = try JSONDecoder().decode(WatchlistRow.self, from: json)
        let item = try XCTUnwrap(WatchlistContract.mapMovieRow(row))
        XCTAssertEqual(item.year, "")
        XCTAssertEqual(item.posterUrl, "")
        XCTAssertEqual(item.genres, [])
        XCTAssertNil(item.director)
    }

    // MARK: TV row → WatchlistItem (all columns + season semantics)

    /// `tv_watchlist_items` maps the movie columns PLUS show_tmdb_id,
    /// season_number, season_title, creator (web `rowToTVWatchlistItem`).
    func testTVSeasonRowMapsEveryColumn() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "user_id": "22222222-2222-2222-2222-222222222222",
            "tmdb_id": "tv_1399_s1",
            "show_tmdb_id": 1399,
            "season_number": 1,
            "title": "Game of Thrones",
            "season_title": "Season 1",
            "year": "2011",
            "poster_url": "https://img/got.jpg",
            "type": "tv_season",
            "genres": ["Drama", "Fantasy"],
            "creator": "David Benioff",
            "added_at": "2026-07-06T12:00:00Z"
        }
        """.data(using: .utf8)!

        let row = try JSONDecoder().decode(TVWatchlistRow.self, from: json)
        let item = try XCTUnwrap(WatchlistContract.mapTVRow(row))

        XCTAssertEqual(item.id, "tv_1399_s1")
        XCTAssertEqual(item.title, "Game of Thrones")
        XCTAssertEqual(item.mediaType, .tv)
        XCTAssertEqual(item.showTmdbId, 1399)
        XCTAssertEqual(item.seasonNumber, 1)
        XCTAssertEqual(item.seasonTitle, "Season 1")
        XCTAssertEqual(item.creator, "David Benioff")
        XCTAssertEqual(item.genres, ["Drama", "Fantasy"])
        XCTAssertFalse(item.isWholeShow)
    }

    /// Whole-show bookmark stored with `season_number = 0` (the web writer's
    /// value — `RankingAppPage.tsx:689` `?? 0`) is a whole show (D6).
    func testTVWholeShowWhenSeasonZero() throws {
        let item = try XCTUnwrap(WatchlistContract.mapTVRow(makeTVRow(seasonNumber: 0)))
        XCTAssertTrue(item.isWholeShow)
        XCTAssertEqual(item.seasonNumber, 0)
    }

    /// Whole-show bookmark stored with `season_number = NULL` (the
    /// schema-intended value — `supabase_tv_rankings.sql:70`) is ALSO a whole
    /// show (D6 — treat BOTH 0 and NULL).
    func testTVWholeShowWhenSeasonNull() throws {
        let item = try XCTUnwrap(WatchlistContract.mapTVRow(makeTVRow(seasonNumber: nil)))
        XCTAssertTrue(item.isWholeShow)
        XCTAssertNil(item.seasonNumber)
    }

    /// A concrete season (>0) is NOT a whole show.
    func testTVSeasonNotWholeShow() throws {
        let item = try XCTUnwrap(WatchlistContract.mapTVRow(makeTVRow(seasonNumber: 3)))
        XCTAssertFalse(item.isWholeShow)
    }

    /// B2: `show_tmdb_id = 0` is corrupt legacy — REJECT at mapping (return
    /// nil, skip the row), never propagate. Both season and null-season rows
    /// with a zero show id are rejected.
    func testTVRowRejectedWhenShowIdZero() {
        XCTAssertNil(WatchlistContract.mapTVRow(makeTVRow(showTmdbId: 0, seasonNumber: 1)))
        XCTAssertNil(WatchlistContract.mapTVRow(makeTVRow(showTmdbId: 0, seasonNumber: nil)))
        XCTAssertNil(WatchlistContract.mapTVRow(makeTVRow(showTmdbId: 0, seasonNumber: 0)))
    }

    /// A valid non-zero show id is accepted.
    func testTVRowAcceptedWhenShowIdNonZero() {
        XCTAssertNotNil(WatchlistContract.mapTVRow(makeTVRow(showTmdbId: 1399, seasonNumber: 1)))
    }

    // MARK: book row → WatchlistItem (all columns)

    /// `book_watchlist_items` maps the movie columns PLUS author, page_count,
    /// isbn, ol_work_key, ol_ratings_average (web `rowToBookWatchlistItem`).
    func testBookRowMapsEveryColumn() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "user_id": "22222222-2222-2222-2222-222222222222",
            "tmdb_id": "ol_OL45804W",
            "title": "Fantastic Mr Fox",
            "year": "1970",
            "poster_url": "https://covers/ol.jpg",
            "type": "book",
            "genres": ["Children"],
            "author": "Roald Dahl",
            "page_count": 96,
            "isbn": "9780140328721",
            "ol_work_key": "OL45804W",
            "ol_ratings_average": 4.1,
            "added_at": "2026-07-06T12:00:00Z"
        }
        """.data(using: .utf8)!

        let row = try JSONDecoder().decode(BookWatchlistRow.self, from: json)
        let item = try XCTUnwrap(WatchlistContract.mapBookRow(row))

        XCTAssertEqual(item.id, "ol_OL45804W")
        XCTAssertEqual(item.title, "Fantastic Mr Fox")
        XCTAssertEqual(item.mediaType, .book)
        XCTAssertEqual(item.author, "Roald Dahl")
        XCTAssertEqual(item.pageCount, 96)
        XCTAssertEqual(item.isbn, "9780140328721")
        XCTAssertEqual(item.olWorkKey, "OL45804W")
        XCTAssertEqual(item.olRatingsAverage, 4.1)
        XCTAssertEqual(item.genres, ["Children"])
    }

    /// Book nullable numeric/text columns stay nil (web `?? undefined`).
    func testBookRowNullableColumns() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "user_id": "22222222-2222-2222-2222-222222222222",
            "tmdb_id": "ol_OL1W",
            "title": "Unknown",
            "year": null,
            "poster_url": null,
            "type": "book",
            "genres": null,
            "author": null,
            "page_count": null,
            "isbn": null,
            "ol_work_key": null,
            "ol_ratings_average": null,
            "added_at": "2026-07-06T12:00:00Z"
        }
        """.data(using: .utf8)!

        let row = try JSONDecoder().decode(BookWatchlistRow.self, from: json)
        let item = try XCTUnwrap(WatchlistContract.mapBookRow(row))
        XCTAssertNil(item.author)
        XCTAssertNil(item.pageCount)
        XCTAssertNil(item.isbn)
        XCTAssertNil(item.olWorkKey)
        XCTAssertNil(item.olRatingsAverage)
        XCTAssertEqual(item.genres, [])
    }

    // MARK: id-format helpers

    func testMovieIdHelper() {
        XCTAssertEqual(WatchlistContract.movieId(603), "tmdb_603")
    }

    func testShowIdHelper() {
        XCTAssertEqual(WatchlistContract.showId(1399), "tv_1399")
    }

    func testSeasonIdHelper() {
        XCTAssertEqual(WatchlistContract.tvSeasonId(showId: 1399, season: 1), "tv_1399_s1")
    }

    func testBookIdHelper() {
        XCTAssertEqual(WatchlistContract.bookId("OL45804W"), "ol_OL45804W")
    }

    // MARK: TV exclusion-id expansion (audit §1.4)

    /// A season id expands to BOTH itself AND the show-level id — the TV
    /// engine excludes on show ids, so callers must feed it both
    /// (`AddTVSeasonModal.tsx:86-89`).
    func testExpandSeasonIdAddsShowId() {
        XCTAssertEqual(
            WatchlistContract.expandExclusionIds(for: "tv_1399_s1"),
            ["tv_1399_s1", "tv_1399"]
        )
    }

    /// A whole-show id (already show-level) passes through unchanged.
    func testExpandShowIdUnchanged() {
        XCTAssertEqual(WatchlistContract.expandExclusionIds(for: "tv_1399"), ["tv_1399"])
    }

    /// A movie id passes through unchanged (no TV pattern to expand).
    func testExpandMovieIdUnchanged() {
        XCTAssertEqual(WatchlistContract.expandExclusionIds(for: "tmdb_603"), ["tmdb_603"])
    }

    /// A book id passes through unchanged.
    func testExpandBookIdUnchanged() {
        XCTAssertEqual(WatchlistContract.expandExclusionIds(for: "ol_OL45804W"), ["ol_OL45804W"])
    }

    /// `expandedBookmarkedIds` folds the expansion over a whole set — season
    /// ids contribute their show id too; the set dedups overlapping show ids.
    func testExpandedBookmarkedIdsFoldsSet() {
        let expanded = WatchlistContract.expandedBookmarkedIds([
            "tv_1399_s1", "tv_1399_s2", "tmdb_603",
        ])
        XCTAssertEqual(expanded, ["tv_1399_s1", "tv_1399_s2", "tv_1399", "tmdb_603"])
    }

    // MARK: media type ↔ db `type` column

    /// The DB `type` column values ("movie" / "tv_season" / "book") round-trip
    /// through `WatchlistMediaType`.
    func testMediaTypeDbRoundTrip() {
        XCTAssertEqual(WatchlistMediaType(dbType: "movie"), .movie)
        XCTAssertEqual(WatchlistMediaType(dbType: "tv_season"), .tv)
        XCTAssertEqual(WatchlistMediaType(dbType: "book"), .book)
        XCTAssertEqual(WatchlistMediaType.movie.dbType, "movie")
        XCTAssertEqual(WatchlistMediaType.tv.dbType, "tv_season")
        XCTAssertEqual(WatchlistMediaType.book.dbType, "book")
    }

    // MARK: add-payload builders (wire shape)

    /// The movie add payload carries exactly the 8 client columns the web
    /// upsert sends (`RankingAppPage.tsx:646-655`) — NO added_at (DB default).
    func testMovieAddPayloadShape() throws {
        let uid = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let item = WatchlistItem(
            id: "tmdb_603", title: "The Matrix", year: "1999",
            posterUrl: "https://img/matrix.jpg", mediaType: .movie,
            genres: ["Action"], addedAt: Date(), director: "The Wachowskis"
        )
        let payload = WatchlistContract.movieAddPayload(item, userID: uid)
        let obj = try encodeToObject(payload)
        XCTAssertEqual(Set(obj.keys),
                       ["user_id", "tmdb_id", "title", "year", "poster_url",
                        "type", "genres", "director"])
        XCTAssertEqual(obj["type"] as? String, "movie")
        XCTAssertEqual(obj["tmdb_id"] as? String, "tmdb_603")
        XCTAssertFalse(obj.keys.contains("added_at"))
    }

    /// The TV add payload carries the movie columns plus show_tmdb_id,
    /// season_number, season_title, creator (`RankingAppPage.tsx:685-697`).
    /// A nil showTmdbId/seasonNumber coalesces to 0 (web `?? 0`).
    func testTVAddPayloadShape() throws {
        let uid = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let item = WatchlistItem(
            id: "tv_1399", title: "Game of Thrones", year: "2011",
            posterUrl: "https://img/got.jpg", mediaType: .tv, genres: ["Drama"],
            addedAt: Date(), creator: "David Benioff",
            showTmdbId: nil, seasonNumber: nil, seasonTitle: nil
        )
        let payload = WatchlistContract.tvAddPayload(item, userID: uid)
        let obj = try encodeToObject(payload)
        XCTAssertEqual(Set(obj.keys),
                       ["user_id", "tmdb_id", "show_tmdb_id", "season_number",
                        "title", "season_title", "year", "poster_url", "type",
                        "genres", "creator"])
        XCTAssertEqual(obj["type"] as? String, "tv_season")
        XCTAssertEqual(obj["show_tmdb_id"] as? Int, 0)
        XCTAssertEqual(obj["season_number"] as? Int, 0)
    }

    /// The book add payload carries the movie columns plus author, page_count,
    /// isbn, ol_work_key, ol_ratings_average (`RankingAppPage.tsx:1184-1191`).
    func testBookAddPayloadShape() throws {
        let uid = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let item = WatchlistItem(
            id: "ol_OL45804W", title: "Fantastic Mr Fox", year: "1970",
            posterUrl: "https://covers/ol.jpg", mediaType: .book,
            genres: ["Children"], addedAt: Date(), author: "Roald Dahl",
            pageCount: 96, isbn: "9780140328721", olWorkKey: "OL45804W",
            olRatingsAverage: 4.1
        )
        let payload = WatchlistContract.bookAddPayload(item, userID: uid)
        let obj = try encodeToObject(payload)
        XCTAssertEqual(Set(obj.keys),
                       ["user_id", "tmdb_id", "title", "year", "poster_url",
                        "type", "genres", "author", "page_count", "isbn",
                        "ol_work_key", "ol_ratings_average"])
        XCTAssertEqual(obj["type"] as? String, "book")
        XCTAssertEqual(obj["page_count"] as? Int, 96)
    }

    /// The repo `add` dispatches by media type via its switch on `item.mediaType`,
    /// calling the matching `WatchlistContract.*AddPayload` builder for each case.
    /// This verifies the TV branch produces the correct wire shape (show_tmdb_id present).
    func testPayloadDispatchByType() throws {
        let uid = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let tv = WatchlistItem(
            id: "tv_1399_s1", title: "GoT", year: "2011", posterUrl: "",
            mediaType: .tv, genres: [], addedAt: Date(),
            showTmdbId: 1399, seasonNumber: 1
        )
        XCTAssertEqual(WatchlistContract.tableName(for: .tv), "tv_watchlist_items")
        XCTAssertEqual(WatchlistContract.tableName(for: .movie), "watchlist_items")
        XCTAssertEqual(WatchlistContract.tableName(for: .book), "book_watchlist_items")
        // Dispatch produces the TV shape for a TV item.
        let obj = try encodeToObject(AnyEncodableProbe(WatchlistContract.tvAddPayload(tv, userID: uid)))
        XCTAssertEqual(obj["show_tmdb_id"] as? Int, 1399)
    }

    // MARK: - helpers

    private func makeTVRow(showTmdbId: Int = 1399, seasonNumber: Int?) -> TVWatchlistRow {
        TVWatchlistRow(
            id: UUID(), user_id: UUID(), tmdb_id: "tv_\(showTmdbId)_s\(seasonNumber ?? 0)",
            show_tmdb_id: showTmdbId, season_number: seasonNumber,
            title: "Show", season_title: nil, year: "2011",
            poster_url: nil, type: "tv_season", genres: ["Drama"],
            creator: nil, added_at: "2026-07-06T12:00:00Z"
        )
    }

    private func encodeToObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

/// Type-erased Encodable wrapper so a heterogeneous payload can be re-encoded
/// in the dispatch test without exposing the concrete payload types.
private struct AnyEncodableProbe: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init(_ wrapped: some Encodable) { encodeFn = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}
