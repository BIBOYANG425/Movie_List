import XCTest
@testable import Spool

/// C5 Task 2 — media-parameterized ranking READS.
///
/// The reads (`getTierItems(tier:media:)` / `getAllRankedItems(media:)`) need a
/// live client, so the network path itself can't be unit-tested here. What CAN
/// (and must) be pinned is the PURE seam those reads sit on:
///
///  1. TABLE ROUTING — a media discriminator selects the same table
///     `insertRanking` writes (`user_rankings` / `tv_rankings` / `book_rankings`)
///     via `rankingsTable(forType:)`, so a read and a write for the same media
///     never target different tables.
///  2. ROW → RankedItem MAPPING (`RankingRepository.rankedItem(from:)`) — the
///     per-media projection the shelf + engine render: `attribution`
///     (director → creator → author) fills the subtitle slot, and a TV row's
///     `season_title` rides through as `seasonTitle` for the season line. A
///     malformed tier drops the row (compactMap contract).
///
/// These are the Task 2 read contracts; the network wiring is exercised by the
/// integration harness, not XCTest.
final class MediaReadRoutingTests: XCTestCase {

    // MARK: - 1. table routing (read == write for the same media)

    func testRankingsTableRoutingPerMedia() {
        XCTAssertEqual(RankingRepository.rankingsTable(forType: "movie"), "user_rankings")
        XCTAssertEqual(RankingRepository.rankingsTable(forType: "tv"), "tv_rankings")
        XCTAssertEqual(RankingRepository.rankingsTable(forType: "book"), "book_rankings")
        // Unknown media falls back to the movie table (default surface).
        XCTAssertEqual(RankingRepository.rankingsTable(forType: "zork"), "user_rankings")
    }

    func testPMediaRoutingPerMedia() {
        XCTAssertEqual(RankingRepository.pMedia(forType: "movie"), "movie")
        XCTAssertEqual(RankingRepository.pMedia(forType: "tv"), "tv")
        XCTAssertEqual(RankingRepository.pMedia(forType: "book"), "book")
        XCTAssertEqual(RankingRepository.pMedia(forType: "zork"), "movie")
    }

    // MARK: - 2. row → RankedItem per-media mapping

    private func row(
        tmdbId: String, title: String, tier: String, rank: Int,
        director: String? = nil, creator: String? = nil, author: String? = nil,
        seasonTitle: String? = nil, seasonNumber: Int? = nil,
        genres: [String] = ["Drama"], year: String? = "2011"
    ) -> RankingRow {
        RankingRow(
            id: UUID(), user_id: UUID(), tmdb_id: tmdbId, title: title,
            year: year, poster_url: "p.jpg", type: "x", genres: genres,
            director: director,
            show_tmdb_id: seasonNumber != nil ? 1399 : nil,
            season_number: seasonNumber, season_title: seasonTitle,
            creator: creator, episode_count: nil,
            author: author,
            tier: tier, rank_position: rank, notes: nil
        )
    }

    func testMovieRowMapsDirectorAsAttribution() throws {
        let r = row(tmdbId: "tmdb_42", title: "Heat", tier: "S", rank: 0,
                    director: "Michael Mann")
        let item = try XCTUnwrap(RankingRepository.rankedItem(from: r))
        XCTAssertEqual(item.id, "tmdb_42")
        XCTAssertEqual(item.title, "Heat")
        XCTAssertEqual(item.director, "Michael Mann", "movie subtitle = director")
        XCTAssertEqual(item.tier, .S)
        XCTAssertEqual(item.rank, 0)
        XCTAssertNil(item.seasonTitle, "movies carry no season line")
    }

    func testTVRowMapsCreatorAsAttributionAndCarriesSeasonTitle() throws {
        let r = row(tmdbId: "tv_1399_s1", title: "Game of Thrones", tier: "A", rank: 2,
                    creator: "David Benioff", seasonTitle: "Season 1", seasonNumber: 1)
        let item = try XCTUnwrap(RankingRepository.rankedItem(from: r))
        XCTAssertEqual(item.title, "Game of Thrones", "title stays the SHOW name")
        XCTAssertEqual(item.director, "David Benioff",
                       "TV subtitle slot = creator (attribution)")
        XCTAssertEqual(item.seasonTitle, "Season 1",
                       "TV row carries the season line for the shelf")
        XCTAssertEqual(item.tier, .A)
        XCTAssertEqual(item.rank, 2)
    }

    func testBookRowMapsAuthorAsAttribution() throws {
        let r = row(tmdbId: "ol_OL27448W", title: "The Hobbit", tier: "S", rank: 0,
                    author: "J.R.R. Tolkien", year: "1937")
        let item = try XCTUnwrap(RankingRepository.rankedItem(from: r))
        XCTAssertEqual(item.title, "The Hobbit")
        XCTAssertEqual(item.director, "J.R.R. Tolkien",
                       "book subtitle slot = author (attribution)")
        XCTAssertNil(item.seasonTitle, "books carry no season line")
    }

    func testRowWithMissingAttributionFallsBackToDash() throws {
        let r = row(tmdbId: "tmdb_9", title: "Anon", tier: "B", rank: 0)
        let item = try XCTUnwrap(RankingRepository.rankedItem(from: r))
        XCTAssertEqual(item.director, "—",
                       "no director/creator/author → the em-dash placeholder")
    }

    func testMalformedTierRowIsDropped() {
        let r = row(tmdbId: "tmdb_1", title: "X", tier: "Z", rank: 0)
        XCTAssertNil(RankingRepository.rankedItem(from: r),
                     "a row with an unknown tier is dropped by the read")
    }
}
