import XCTest
@testable import Spool

/// C5 Task 1 — per-media insert payloads + row decodes.
///
/// The bug this guards: iOS `insertRanking`'s tv/book path was LATENT-BROKEN —
/// `RankingPayload` was movie-shaped, so a `type:"tv"` insert 23502'd on the
/// `show_tmdb_id`/`season_number` NOT NULL columns and a `type:"book"` insert
/// silently dropped author + every OpenLibrary column. This suite pins the
/// per-media JSON KEY-SET (the C2 no-silent-drop convention) for all three
/// media, proves the movie body is unchanged byte-for-byte, and round-trips the
/// vertical `RankingRow` columns Task 2's reads will map.
///
/// The payload key-set is derived from the DDLs:
///   - `tv_rankings`      (`supabase_tv_rankings.sql:6-28` + `supabase_watched_with.sql`)
///   - `book_rankings`    (`supabase_book_rankings.sql:6-29`)
///   - `user_rankings`    (`supabase_schema.sql`, movie)
final class PerMediaPayloadTests: XCTestCase {

    private static let uid = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private static let friend = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

    private func keys(_ payload: RankingPayload) throws -> Set<String> {
        let data = try JSONEncoder().encode(payload)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(obj.keys)
    }

    private func object(_ payload: RankingPayload) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - MOVIE (unchanged byte-for-byte)

    /// The movie insert still produces EXACTLY the historical key-set (director,
    /// no vertical columns). Full-value insert: every optional present.
    func testMoviePayloadKeySetUnchanged() throws {
        let insert = RankingInsert.movie(
            tmdbId: "tmdb_42", title: "Heat", year: "1995",
            posterURL: "p.jpg", genres: ["Crime"], director: "Michael Mann",
            tier: .S, rankPosition: 0, notes: "the diner scene"
        )
        let payload = RankingPayload.make(from: insert, userID: Self.uid)
        XCTAssertEqual(try keys(payload), [
            "user_id", "tmdb_id", "title", "year", "poster_url", "type",
            "genres", "director", "tier", "rank_position", "notes",
        ])
        let obj = try object(payload)
        XCTAssertEqual(obj["type"] as? String, "movie")
        XCTAssertEqual(obj["director"] as? String, "Michael Mann")
        // No tv/book columns can ever appear on a movie row.
        XCTAssertNil(obj["show_tmdb_id"])
        XCTAssertNil(obj["author"])
        XCTAssertNil(obj["watched_with_user_ids"])
    }

    /// A nil-optionals movie insert OMITS year/poster_url/director/notes (the
    /// PostgREST re-rank-preserve contract) — the movie body is unchanged.
    func testMoviePayloadOmitsNilOptionals() throws {
        let insert = RankingInsert.movie(
            tmdbId: "tmdb_1", title: "Untitled", year: nil, posterURL: nil,
            genres: [], director: nil, tier: .B, rankPosition: 2, notes: nil
        )
        XCTAssertEqual(try keys(RankingPayload.make(from: insert, userID: Self.uid)), [
            "user_id", "tmdb_id", "title", "type", "genres", "tier", "rank_position",
        ])
    }

    // MARK: - TV

    /// A full TV insert encodes EXACTLY the tv_rankings key-set: show_tmdb_id +
    /// season_number (NOT NULL) always present, the nullable verticals present
    /// when set, watched_with_user_ids always present — and NO director.
    func testTVPayloadKeySetFull() throws {
        let insert = RankingInsert.tv(
            tmdbId: "tv_1399_s1", title: "Game of Thrones", year: "2011",
            posterURL: "got.jpg", genres: ["Drama"],
            showTmdbId: 1399, season: 1, seasonTitle: "Season 1",
            creator: "David Benioff", episodeCount: 10,
            tier: .A, rankPosition: 0, notes: "winter",
            watchedWithUserIds: [Self.friend]
        )
        let payload = RankingPayload.make(from: insert, userID: Self.uid)
        XCTAssertEqual(try keys(payload), [
            "user_id", "tmdb_id", "show_tmdb_id", "season_number", "title",
            "season_title", "year", "poster_url", "type", "genres", "creator",
            "tier", "rank_position", "notes", "episode_count", "watched_with_user_ids",
        ])
        let obj = try object(payload)
        XCTAssertEqual(obj["type"] as? String, "tv_season")
        XCTAssertEqual(obj["show_tmdb_id"] as? Int, 1399)
        XCTAssertEqual(obj["season_number"] as? Int, 1)
        XCTAssertEqual(obj["episode_count"] as? Int, 10)
    }

    /// A TV insert NEVER writes a `director` key (tv_rankings has no such
    /// column — a non-nil director there 400s). This is THE latent-break guard.
    func testTVPayloadNeverHasDirector() throws {
        let insert = RankingInsert.tv(
            tmdbId: "tv_1_s1", title: "Show", year: nil, posterURL: nil,
            showTmdbId: 1, season: 1, tier: .C, rankPosition: 0
        )
        XCTAssertFalse(try keys(RankingPayload.make(from: insert, userID: Self.uid)).contains("director"))
    }

    /// A TV insert with the nullable verticals nil OMITS season_title/creator/
    /// episode_count/year/poster_url/notes — but show_tmdb_id/season_number and
    /// watched_with_user_ids are ALWAYS present (NOT NULL / defaulted `[]`).
    func testTVPayloadOmitsNilVerticalsKeepsRequired() throws {
        let insert = RankingInsert.tv(
            tmdbId: "tv_5_s2", title: "Show", year: nil, posterURL: nil,
            genres: [], showTmdbId: 5, season: 2, seasonTitle: nil,
            creator: nil, episodeCount: nil, tier: .D, rankPosition: 1,
            notes: nil, watchedWithUserIds: nil
        )
        let payload = RankingPayload.make(from: insert, userID: Self.uid)
        XCTAssertEqual(try keys(payload), [
            "user_id", "tmdb_id", "show_tmdb_id", "season_number", "title",
            "type", "genres", "tier", "rank_position", "watched_with_user_ids",
        ])
        // watched-with is present-but-empty when the caller passes nil (web `?? []`).
        let obj = try object(payload)
        XCTAssertEqual(obj["watched_with_user_ids"] as? [String], [])
    }

    // MARK: - BOOK

    /// A full book insert encodes EXACTLY the book_rankings key-set: all five OL
    /// columns present when set, watched_with_user_ids present, NO director, NO
    /// show/season keys.
    func testBookPayloadKeySetFull() throws {
        let insert = RankingInsert.book(
            tmdbId: "ol_OL27448W", title: "The Hobbit", year: "1937",
            posterURL: "hobbit.jpg", genres: ["Fantasy"],
            author: "J.R.R. Tolkien", pageCount: 310, isbn: "9780261102217",
            olWorkKey: "OL27448W", olRatingsAverage: 4.3,
            tier: .S, rankPosition: 0, notes: "there and back",
            watchedWithUserIds: [Self.friend]
        )
        let payload = RankingPayload.make(from: insert, userID: Self.uid)
        XCTAssertEqual(try keys(payload), [
            "user_id", "tmdb_id", "title", "year", "poster_url", "type",
            "genres", "author", "tier", "rank_position", "notes", "page_count",
            "isbn", "ol_work_key", "ol_ratings_average", "watched_with_user_ids",
        ])
        let obj = try object(payload)
        XCTAssertEqual(obj["type"] as? String, "book")
        XCTAssertEqual(obj["author"] as? String, "J.R.R. Tolkien")
        XCTAssertEqual(obj["page_count"] as? Int, 310)
        XCTAssertEqual(obj["ol_ratings_average"] as? Double, 4.3)
    }

    /// A book insert NEVER writes a `director` key nor any show/season key
    /// (book_rankings has none of those columns).
    func testBookPayloadNeverHasDirectorOrShowFields() throws {
        let insert = RankingInsert.book(
            tmdbId: "ol_OL1W", title: "Book", year: nil, posterURL: nil,
            tier: .B, rankPosition: 0
        )
        let ks = try keys(RankingPayload.make(from: insert, userID: Self.uid))
        XCTAssertFalse(ks.contains("director"))
        XCTAssertFalse(ks.contains("show_tmdb_id"))
        XCTAssertFalse(ks.contains("season_number"))
    }

    /// A book insert with the OL columns nil OMITS them (author/page_count/isbn/
    /// ol_work_key/ol_ratings_average/year/poster_url/notes) — but
    /// watched_with_user_ids is always present.
    func testBookPayloadOmitsNilOptionals() throws {
        let insert = RankingInsert.book(
            tmdbId: "ol_OL2W", title: "Sparse", year: nil, posterURL: nil,
            genres: [], author: nil, pageCount: nil, isbn: nil,
            olWorkKey: nil, olRatingsAverage: nil, tier: .C, rankPosition: 3,
            notes: nil, watchedWithUserIds: nil
        )
        XCTAssertEqual(try keys(RankingPayload.make(from: insert, userID: Self.uid)), [
            "user_id", "tmdb_id", "title", "type", "genres", "tier",
            "rank_position", "watched_with_user_ids",
        ])
    }

    // MARK: - illegal-states-unrepresentable (compile-time, documented)

    /// The `.tv` factory REQUIRES `showTmdbId`+`season` — a TV insert without
    /// them does not compile (there is no default). This test exists so a
    /// future refactor that makes them optional trips a review here; the guard
    /// itself is the type system. Constructing a `.tv` proves both are required.
    func testTVRequiresShowAndSeasonAtCompileTime() {
        let insert = RankingInsert.tv(
            tmdbId: "tv_9_s3", title: "S", year: nil, posterURL: nil,
            showTmdbId: 9, season: 3, tier: .A, rankPosition: 0
        )
        guard case let .tv(showTmdbId, season, _, _, _) = insert.media else {
            return XCTFail("expected .tv media")
        }
        XCTAssertEqual(showTmdbId, 9)
        XCTAssertEqual(season, 3)
        XCTAssertEqual(insert.type, "tv")
        XCTAssertNil(insert.director, "director is movie-only")
    }

    // MARK: - RankingRow per-media decode (vertical round-trip for Task 2)

    /// A TV row decodes its vertical columns (show_tmdb_id/season_number/
    /// season_title/creator/episode_count) and exposes `creator` as the
    /// attribution — the fields Task 2's per-media read maps into `RankedItem`.
    func testRankingRowDecodesTVVerticals() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "user_id": "22222222-2222-2222-2222-222222222222",
          "tmdb_id": "tv_1399_s1", "title": "Game of Thrones",
          "year": "2011", "poster_url": "got.jpg", "type": "tv_season",
          "genres": ["Drama"], "show_tmdb_id": 1399, "season_number": 1,
          "season_title": "Season 1", "creator": "David Benioff",
          "episode_count": 10, "tier": "A", "rank_position": 0, "notes": "winter"
        }
        """.data(using: .utf8)!
        let row = try JSONDecoder().decode(RankingRow.self, from: json)
        XCTAssertEqual(row.show_tmdb_id, 1399)
        XCTAssertEqual(row.season_number, 1)
        XCTAssertEqual(row.season_title, "Season 1")
        XCTAssertEqual(row.creator, "David Benioff")
        XCTAssertEqual(row.episode_count, 10)
        XCTAssertEqual(row.attribution, "David Benioff")
        XCTAssertNil(row.author)
    }

    /// A book row decodes its vertical columns (author/page_count/isbn/
    /// ol_work_key/ol_ratings_average) and exposes `author` as the attribution.
    func testRankingRowDecodesBookVerticals() throws {
        let json = """
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "user_id": "22222222-2222-2222-2222-222222222222",
          "tmdb_id": "ol_OL27448W", "title": "The Hobbit",
          "year": "1937", "poster_url": "hobbit.jpg", "type": "book",
          "genres": ["Fantasy"], "author": "J.R.R. Tolkien", "page_count": 310,
          "isbn": "9780261102217", "ol_work_key": "OL27448W",
          "ol_ratings_average": 4.3, "tier": "S", "rank_position": 0, "notes": null
        }
        """.data(using: .utf8)!
        let row = try JSONDecoder().decode(RankingRow.self, from: json)
        XCTAssertEqual(row.author, "J.R.R. Tolkien")
        XCTAssertEqual(row.page_count, 310)
        XCTAssertEqual(row.isbn, "9780261102217")
        XCTAssertEqual(row.ol_work_key, "OL27448W")
        XCTAssertEqual(row.ol_ratings_average, 4.3)
        XCTAssertEqual(row.attribution, "J.R.R. Tolkien")
        XCTAssertNil(row.creator)
        XCTAssertNil(row.notes)
    }

    /// A MOVIE row (from `user_rankings`, no vertical columns in the JSON) still
    /// decodes — the vertical fields are nil, director drives attribution. This
    /// proves the widened `RankingRow` is backward-compatible with the movie
    /// reads (`ProfileScreen`/`StubRepository`/engine walk) that predate C5.
    func testRankingRowDecodesMovieRowBackwardCompatible() throws {
        let json = """
        {
          "id": "44444444-4444-4444-4444-444444444444",
          "user_id": "22222222-2222-2222-2222-222222222222",
          "tmdb_id": "tmdb_42", "title": "Heat", "year": "1995",
          "poster_url": "p.jpg", "type": "movie", "genres": ["Crime"],
          "director": "Michael Mann", "tier": "S", "rank_position": 0, "notes": null
        }
        """.data(using: .utf8)!
        let row = try JSONDecoder().decode(RankingRow.self, from: json)
        XCTAssertEqual(row.director, "Michael Mann")
        XCTAssertEqual(row.attribution, "Michael Mann")
        XCTAssertNil(row.show_tmdb_id)
        XCTAssertNil(row.season_number)
        XCTAssertNil(row.author)
        XCTAssertNil(row.ol_ratings_average)
    }
}
