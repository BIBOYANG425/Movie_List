import XCTest
@testable import Spool

/// C5-iOS Task 5 — the rank ceremony is media-generic. These pins fix the
/// per-media SEAMS the ceremony threads through `RankPersistence.save`:
///   1. media derivation — `Movie.mediaType` → the right `RankingInsert`
///      (`.movie`/`.tv`/`.book`), which routes to the right table;
///   2. stub decision — movie → `"movie"` stub, tv → `"tv_season"` stub,
///      book → NO stub (the `movie_stubs` CHECK allows only movie|tv_season);
///   3. quick-entry UNREACHABLE for tv/book (movie-only stage-A journal write);
///   4. global-score seed per media (tv from TMDB `vote_average`, book from
///      OpenLibrary `ratings_average` ×2, NEVER TMDB for an ol_ id);
///   5. emission `media_tmdb_id` carries the composite / ol_ id verbatim.
///
/// All seams are PURE — no client, no network. The H2H same-media pool read is
/// pinned at the model level (`Movie.mediaType.mediaParam` → the `media:` param
/// `getAllRankedItems`/`getTierItems` route on, which `RankingRepository`
/// already maps to the SAME table the write uses).
final class MediaGenericCeremonyTests: XCTestCase {

    private static let uid = UUID(uuidString: "00000000-0000-0000-0000-0000000000A5")!

    private func payloadObject(_ insert: RankingInsert) throws -> [String: Any] {
        let payload = RankingPayload.make(from: insert, userID: Self.uid)
        let data = try JSONEncoder().encode(payload)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 1. Media derivation matrix (Movie → RankingInsert → table)

    /// A movie item derives a `.movie` insert routed to `user_rankings`, with the
    /// director on the payload — byte-identical to the pre-C5 movie shape.
    func testMovieItemDerivesMovieInsertAndTable() throws {
        let m = Movie(id: "603", title: "The Matrix", year: 1999, director: "Lana Wachowski")
        let insert = m.rankingInsert(
            year: "1999", genres: ["Sci-Fi"], director: "Lana Wachowski",
            tier: .S, rankPosition: 0, notes: nil)
        XCTAssertEqual(insert.type, "movie")
        XCTAssertEqual(RankingRepository.rankingsTable(forType: insert.type), "user_rankings")
        XCTAssertEqual(RankingRepository.pMedia(forType: insert.type), "movie")
        let obj = try payloadObject(insert)
        XCTAssertEqual(obj["type"] as? String, "movie")
        XCTAssertEqual(obj["director"] as? String, "Lana Wachowski")
        XCTAssertNil(obj["show_tmdb_id"])
        XCTAssertNil(obj["author"])
    }

    /// A tv item derives a `.tv` insert routed to `tv_rankings`, carrying the
    /// NOT-NULL show/season identity, `type:"tv_season"`, NO director key.
    func testTVItemDerivesTVInsertAndTable() throws {
        let m = Movie(
            id: "tv_1396_s5", title: "Breaking Bad", year: 2013, director: "—",
            mediaType: .tv, showTmdbId: 1396, seasonNumber: 5,
            seasonTitle: "Season 5", creator: "Vince Gilligan", episodeCount: 16)
        let insert = m.rankingInsert(
            year: "2013", genres: ["Drama"], director: nil,
            tier: .S, rankPosition: 0, notes: nil)
        XCTAssertEqual(insert.type, "tv")
        XCTAssertEqual(RankingRepository.rankingsTable(forType: insert.type), "tv_rankings")
        XCTAssertEqual(RankingRepository.pMedia(forType: insert.type), "tv")
        let obj = try payloadObject(insert)
        XCTAssertEqual(obj["type"] as? String, "tv_season")
        XCTAssertEqual(obj["show_tmdb_id"] as? Int, 1396)
        XCTAssertEqual(obj["season_number"] as? Int, 5)
        XCTAssertEqual(obj["creator"] as? String, "Vince Gilligan")
        XCTAssertEqual(obj["episode_count"] as? Int, 16)
        XCTAssertNil(obj["director"], "tv_rankings has no director column")
        // The composite id rides through as tmdb_id.
        XCTAssertEqual(obj["tmdb_id"] as? String, "tv_1396_s5")
    }

    /// A book item derives a `.book` insert routed to `book_rankings`, carrying
    /// the OpenLibrary columns, `type:"book"`, NO director and NO show/season.
    func testBookItemDerivesBookInsertAndTable() throws {
        let m = Movie(
            id: "ol_OL27448W", title: "The Lord of the Rings", year: 1954, director: "—",
            mediaType: .book, author: "J.R.R. Tolkien", pageCount: 1178,
            isbn: "9780618640157", olWorkKey: "OL27448W", olRatingsAverage: 4.5)
        let insert = m.rankingInsert(
            year: "1954", genres: ["Fantasy"], director: nil,
            tier: .S, rankPosition: 0, notes: nil)
        XCTAssertEqual(insert.type, "book")
        XCTAssertEqual(RankingRepository.rankingsTable(forType: insert.type), "book_rankings")
        XCTAssertEqual(RankingRepository.pMedia(forType: insert.type), "book")
        let obj = try payloadObject(insert)
        XCTAssertEqual(obj["type"] as? String, "book")
        XCTAssertEqual(obj["author"] as? String, "J.R.R. Tolkien")
        XCTAssertEqual(obj["page_count"] as? Int, 1178)
        XCTAssertEqual(obj["ol_work_key"] as? String, "OL27448W")
        XCTAssertEqual(obj["ol_ratings_average"] as? Double, 4.5)
        XCTAssertNil(obj["director"], "book_rankings has no director column")
        XCTAssertNil(obj["show_tmdb_id"], "book_rankings has no show/season columns")
        XCTAssertEqual(obj["tmdb_id"] as? String, "ol_OL27448W")
    }

    // MARK: - 2. Stub decision matrix

    /// movie → `"movie"` stub, tv → `"tv_season"` stub, book → NO stub (nil).
    /// The DB CHECK allows only movie|tv_season (`20260325_movie_stubs.sql:11`).
    func testStubMediaTypeDecisionMatrix() {
        XCTAssertEqual(StubWriteContract.stubMediaType(for: .movie), "movie")
        XCTAssertEqual(StubWriteContract.stubMediaType(for: .tv), "tv_season")
        XCTAssertNil(StubWriteContract.stubMediaType(for: .book),
                     "books write NO stub — a 'book' media_type would 400 on the CHECK")
    }

    /// The tv stub INSERT payload carries `media_type:"tv_season"` and the
    /// composite `tv_{id}_s{n}` id verbatim as `tmdb_id` — web parity with
    /// `createStub({mediaType:'tv_season', tmdbId:newItem.id})`.
    func testTVStubInsertPayloadShape() {
        let m = Movie(
            id: "tv_1396_s5", title: "Breaking Bad", year: 2013, director: "—",
            posterUrl: "https://image.tmdb.org/t/p/w500/bb.jpg",
            mediaType: .tv, showTmdbId: 1396, seasonNumber: 5)
        let p = StubWriteContract.insertPayload(
            userID: Self.uid, movie: m, tier: .S, mediaType: "tv_season")
        XCTAssertEqual(p.media_type, "tv_season")
        XCTAssertEqual(p.tmdb_id, "tv_1396_s5", "composite tv id is the stub tmdb_id")
        XCTAssertEqual(p.title, "Breaking Bad")
        XCTAssertEqual(p.tier, "S")
        XCTAssertEqual(p.template_id, "s_tier_gold")
    }

    // MARK: - 3. Quick-entry UNREACHABLE cross-media

    /// The stage-A journal quick-write is MOVIE-ONLY. A tv/book rank ALWAYS
    /// resolves `.skip` regardless of the flag, outcome, or ceremony input — the
    /// movie-shaped stage-A path is structurally unreachable cross-media.
    func testQuickEntryUnreachableForTVAndBook() {
        for media in [RankMedia.tv, .book] {
            for outcome in [RankingRepository.InsertOutcome.inserted, .moved(fromTier: "B")] {
                for hasInput in [true, false] {
                    XCTAssertEqual(
                        RankPersistence.quickEntryDecision(
                            writeJournalQuickEntry: true, media: media,
                            outcome: outcome, hasInput: hasInput),
                        .skip,
                        "quick-write must never fire for \(media)")
                }
            }
        }
    }

    /// The media-aware base gate: `writeJournalQuickEntry && media == .movie`.
    func testShouldWriteQuickEntryIsMovieOnly() {
        XCTAssertTrue(RankPersistence.shouldWriteQuickEntry(writeJournalQuickEntry: true, media: .movie))
        XCTAssertFalse(RankPersistence.shouldWriteQuickEntry(writeJournalQuickEntry: true, media: .tv))
        XCTAssertFalse(RankPersistence.shouldWriteQuickEntry(writeJournalQuickEntry: true, media: .book))
        // A false flag skips even for a movie (write-more path unchanged).
        XCTAssertFalse(RankPersistence.shouldWriteQuickEntry(writeJournalQuickEntry: false, media: .movie))
    }

    /// The MOVIE decision table is UNCHANGED by the media dimension — the
    /// `.movie` overload matches the historical behavior exactly.
    func testMovieQuickEntryTableUnchanged() {
        XCTAssertEqual(
            RankPersistence.quickEntryDecision(
                writeJournalQuickEntry: true, media: .movie,
                outcome: .inserted, hasInput: false),
            .quickWrite)
        XCTAssertEqual(
            RankPersistence.quickEntryDecision(
                writeJournalQuickEntry: true, media: .movie,
                outcome: .moved(fromTier: "B"), hasInput: false),
            .skip)
        XCTAssertEqual(
            RankPersistence.quickEntryDecision(
                writeJournalQuickEntry: true, media: .movie,
                outcome: .moved(fromTier: "B"), hasInput: true),
            .probedMerge)
    }

    // MARK: - 4. Per-media global-score seed

    /// A movie seeds from TMDB `vote_average`; a tv item seeds from the show's
    /// TMDB score (Task 3, carried on `voteAverage`); a book seeds from
    /// OpenLibrary `ratings_average` scaled 0-5 → 0-10 (×2) — NEVER TMDB.
    func testRankGlobalScorePerMedia() {
        let movie = Movie(id: "1", title: "M", year: 2000, director: "D", voteAverage: 7.4)
        XCTAssertEqual(movie.rankGlobalScore, 7.4)

        let tv = Movie(id: "tv_1_s1", title: "T", year: 2001, director: "—",
                       voteAverage: 8.6, mediaType: .tv, showTmdbId: 1, seasonNumber: 1)
        XCTAssertEqual(tv.rankGlobalScore, 8.6, "tv seeds from the show's TMDB vote_average")

        let book = Movie(id: "ol_OL1W", title: "B", year: 1999, director: "—",
                         mediaType: .book, olWorkKey: "OL1W", olRatingsAverage: 4.0)
        XCTAssertEqual(book.rankGlobalScore, 8.0, "book seeds from OL ratings_average ×2")
        // A book NEVER uses TMDB voteAverage even if one leaked in.
        let bookWithBogusVote = Movie(id: "ol_OL2W", title: "B2", year: 1999, director: "—",
                                      voteAverage: 9.9, mediaType: .book, olRatingsAverage: 3.0)
        XCTAssertEqual(bookWithBogusVote.rankGlobalScore, 6.0,
                       "book must ignore TMDB voteAverage and use OL ×2")
    }

    /// A book with no OL rating seeds nil (not 0 from a stray TMDB vote).
    func testBookGlobalScoreNilWhenNoRating() {
        let book = Movie(id: "ol_OL3W", title: "B3", year: 2010, director: "—",
                         mediaType: .book, olWorkKey: "OL3W", olRatingsAverage: nil)
        XCTAssertNil(book.rankGlobalScore)
    }

    // MARK: - 5. Attribution per media (display seam)

    func testAttributionPerMedia() {
        let movie = Movie(id: "1", title: "M", year: 2000, director: "Denis Villeneuve")
        XCTAssertEqual(movie.attribution, "Denis Villeneuve")

        let tv = Movie(id: "tv_1_s1", title: "T", year: 2001, director: "—",
                       mediaType: .tv, showTmdbId: 1, seasonNumber: 1, creator: "Vince Gilligan")
        XCTAssertEqual(tv.attribution, "Vince Gilligan", "tv shows creator")

        let book = Movie(id: "ol_OL1W", title: "B", year: 1999, director: "—",
                         mediaType: .book, author: "Ursula K. Le Guin")
        XCTAssertEqual(book.attribution, "Ursula K. Le Guin", "book shows author")

        // Falls back to director when the media attribution is empty/missing.
        let tvNoCreator = Movie(id: "tv_2_s1", title: "T2", year: 2002, director: "fallback",
                                mediaType: .tv, showTmdbId: 2, seasonNumber: 1, creator: nil)
        XCTAssertEqual(tvNoCreator.attribution, "fallback")
    }

    // MARK: - 6. H2H same-media pool param

    /// The pool read routes to the SAME vertical the new item belongs to:
    /// `Movie.mediaType.mediaParam` is the `media:` string
    /// `getAllRankedItems`/`getTierItems` accept, which `RankingRepository` maps
    /// to the matching table — so the H2H pool is SAME-MEDIA.
    func testMediaParamRoutesPoolToSameTable() {
        XCTAssertEqual(RankMedia.movie.mediaParam, "movie")
        XCTAssertEqual(RankMedia.tv.mediaParam, "tv")
        XCTAssertEqual(RankMedia.book.mediaParam, "book")
        XCTAssertEqual(RankingRepository.rankingsTable(forType: RankMedia.tv.mediaParam), "tv_rankings")
        XCTAssertEqual(RankingRepository.rankingsTable(forType: RankMedia.book.mediaParam), "book_rankings")
        XCTAssertEqual(RankingRepository.rankingsTable(forType: RankMedia.movie.mediaParam), "user_rankings")
    }

    // MARK: - 7. Emission media_tmdb_id format

    /// The activity-event `media_tmdb_id` is the ranking's `tmdbId` verbatim (the
    /// `insertRanking` event builder passes `ranking.tmdbId`). For tv that is the
    /// composite `tv_{id}_s{n}`; for book the `ol_{workKey}`. The pure emission
    /// seam is media-agnostic — it never rewrites the id — so a tv/book event
    /// carries the composite/ol_ id unchanged.
    func testEmissionMediaTmdbIdIsInsertIdVerbatim() {
        let tv = Movie(id: "tv_1396_s5", title: "Breaking Bad", year: 2013, director: "—",
                       mediaType: .tv, showTmdbId: 1396, seasonNumber: 5)
        let tvInsert = tv.rankingInsert(year: "2013", genres: [], director: nil,
                                        tier: .S, rankPosition: 0, notes: nil)
        XCTAssertEqual(tvInsert.tmdbId, "tv_1396_s5")

        let book = Movie(id: "ol_OL27448W", title: "LOTR", year: 1954, director: "—",
                         mediaType: .book, olWorkKey: "OL27448W")
        let bookInsert = book.rankingInsert(year: "1954", genres: [], director: nil,
                                            tier: .S, rankPosition: 0, notes: nil)
        XCTAssertEqual(bookInsert.tmdbId, "ol_OL27448W")

        // The emission decision is pure + media-agnostic: same event/metadata
        // shape regardless of media (the id is carried by the caller separately).
        let fresh = CeremonyEmission.decide(
            outcome: .inserted, notes: nil, year: "2013", watchedWithUserIds: nil)
        XCTAssertEqual(fresh.eventType, "ranking_add")
    }

    // MARK: - 8. RankingInsert(type:) misroute guard (Task 1 fold-in)

    /// The back-compat `RankingInsert(type:)` init now traps a non-movie `type:`
    /// — nothing can silently mint a movie-shaped tv/book row during the wiring.
    /// (A `precondition` fires a fatalError; we assert the ALLOWED movie path
    /// still builds a `.movie` insert. The trap itself is covered by review.)
    func testBackCompatInitStillBuildsMovie() {
        let insert = RankingInsert(
            tmdbId: "603", title: "The Matrix", year: "1999", posterURL: nil,
            type: "movie", genres: ["Sci-Fi"], director: "Lana Wachowski",
            tier: .S, rankPosition: 0)
        XCTAssertEqual(insert.type, "movie")
        XCTAssertEqual(insert.director, "Lana Wachowski")
    }
}
