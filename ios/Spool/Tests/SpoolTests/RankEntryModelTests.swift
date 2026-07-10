import XCTest
@testable import Spool

/// C5-iOS Task 6 — the rank-entry state machine (`RankEntryModel`) + the per-media
/// `Movie` construction seams. Covers: mode switch resets stage + clears results,
/// the signed-in gate for tv/book, the show → season-grid transition (Specials
/// already filtered upstream, already-ranked seasons disabled), the season/book
/// `Movie` construction (T5 conventions), and the season-grid seeding for the
/// whole-show watchlist path. All IO injected — no live client.
@MainActor
final class RankEntryModelTests: XCTestCase {

    // MARK: fixtures

    private func show(_ id: Int, name: String = "Show", genres: [String] = ["Drama"],
                      creators: [String] = ["A Creator"],
                      seasons: [TMDBTVSeasonSummary]) -> TMDBTVShow {
        TMDBTVShow(
            id: "tv_\(id)", tmdbId: id, name: name, year: "2011",
            posterUrl: "http://p/show.jpg", backdropUrl: nil, genres: genres,
            overview: "", seasonCount: seasons.count, status: "Ended",
            creators: creators, voteAverage: 8.4, seasons: seasons)
    }

    private func season(_ n: Int, eps: Int = 10, air: String? = "2011-04-17") -> TMDBTVSeasonSummary {
        TMDBTVSeasonSummary(seasonNumber: n, name: "Season \(n)",
                            posterUrl: "http://p/s\(n).jpg", episodeCount: eps, airDate: air)
    }

    private func book(_ key: String = "OL27448W", title: String = "Dune",
                      author: String = "Frank Herbert", rating: Double? = 4.2) -> OpenLibraryBook {
        OpenLibraryBook(
            id: "ol_\(key)", title: title, author: author, year: "1965",
            posterUrl: "http://c/dune.jpg", genres: ["Sci-Fi"], pageCount: 412,
            isbn: "9780441013593", olWorkKey: key, olRatingsAverage: rating,
            globalScore: rating.map { $0 * 2 })
    }

    // MARK: - mode switch

    func testDefaultModeIsMovieSearchStage() {
        let m = RankEntryModel(isSignedIn: { true })
        XCTAssertEqual(m.mode, .movie)
        XCTAssertEqual(m.stage, .search)
    }

    func testSetModeClearsResultsAndStage() async {
        let m = RankEntryModel(
            searchMovies: { _ in [TMDBMovie(id: "tmdb_1", tmdbId: 1, title: "X", year: "2020",
                                            posterUrl: "p", genres: [], overview: "", voteAverage: 7)] },
            isSignedIn: { true })
        m.runSearch("x")
        // Let the injected search resolve.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(m.movieResults.isEmpty)

        m.setMode(.tv)
        XCTAssertEqual(m.mode, .tv)
        XCTAssertEqual(m.stage, .search)
        XCTAssertTrue(m.movieResults.isEmpty, "switching media clears the old results")
    }

    func testSetModeIsNoOpForSameMode() {
        let m = RankEntryModel(isSignedIn: { true })
        m.setMode(.movie)     // already movie
        XCTAssertEqual(m.mode, .movie)
    }

    // MARK: - signed-in gate

    func testTVRequiresSignInWhenSignedOut() {
        let m = RankEntryModel(isSignedIn: { false })
        m.setMode(.tv)
        XCTAssertTrue(m.requiresSignIn)
    }

    func testBookRequiresSignInWhenSignedOut() {
        let m = RankEntryModel(isSignedIn: { false })
        m.setMode(.book)
        XCTAssertTrue(m.requiresSignIn)
    }

    func testMovieNeverRequiresSignIn() {
        let m = RankEntryModel(isSignedIn: { false })
        XCTAssertFalse(m.requiresSignIn, "movie mode has a fixture fallback")
    }

    func testSignedOutTVSearchFetchesNothing() async {
        var tvFetches = 0
        let m = RankEntryModel(
            searchTV: { _ in tvFetches += 1; return [] },
            isSignedIn: { false })
        m.setMode(.tv)
        m.runSearch("game of thrones")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(tvFetches, 0, "a signed-out tv search fires no request")
    }

    // MARK: - show → season grid

    func testPickShowLoadsSeasonsAndDisabledSet() async {
        let s = show(1399, name: "GoT", seasons: [season(1), season(2), season(3)])
        let m = RankEntryModel(
            loadShowDetails: { _ in s },
            loadShowGlobalScore: { _ in 9.1 },
            loadRankedTVIds: { ["tv_1399_s2"] },   // season 2 already ranked
            isSignedIn: { true })
        m.setMode(.tv)
        m.pickShow(s)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(m.stage, .seasonGrid(show: s))
        XCTAssertEqual(m.seasons.map(\.seasonNumber), [1, 2, 3])
        XCTAssertEqual(m.rankedSeasonNumbers, [2], "already-ranked season disabled")
        XCTAssertEqual(m.showGlobalScore, 9.1)
    }

    func testBackToSearchClearsGrid() async {
        let s = show(1399, seasons: [season(1)])
        let m = RankEntryModel(loadShowDetails: { _ in s }, isSignedIn: { true })
        m.setMode(.tv)
        m.pickShow(s)
        try? await Task.sleep(nanoseconds: 50_000_000)
        m.backToSearch()
        XCTAssertEqual(m.stage, .search)
        XCTAssertTrue(m.seasons.isEmpty)
    }

    // MARK: - season Movie construction (T5 conventions)

    func testSeasonMovieCarriesCompositeIdAndTVFields() async {
        let s = show(1399, name: "GoT", genres: ["Sci-Fi & Fantasy"],
                     creators: ["D. Benioff"], seasons: [season(3, eps: 10)])
        let m = RankEntryModel(
            loadShowDetails: { _ in s },
            loadShowGlobalScore: { _ in 9.3 },
            loadRankedTVIds: { [] },
            isSignedIn: { true })
        m.setMode(.tv)
        m.pickShow(s)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let movie = m.seasonMovie(for: season(3, eps: 10))
        XCTAssertNotNil(movie)
        XCTAssertEqual(movie?.id, "tv_1399_s3", "composite stub/ranking id")
        XCTAssertEqual(movie?.mediaType, .tv)
        XCTAssertEqual(movie?.showTmdbId, 1399, "REAL show id")
        XCTAssertEqual(movie?.seasonNumber, 3)
        XCTAssertEqual(movie?.seasonTitle, "Season 3")
        XCTAssertEqual(movie?.creator, "D. Benioff")
        XCTAssertEqual(movie?.episodeCount, 10)
        XCTAssertEqual(movie?.title, "GoT", "title is the SHOW name")
        // Genres normalized (compound → split).
        XCTAssertEqual(movie?.genres, ["Sci-Fi", "Fantasy"])
        // voteAverage seeds from the show's global score.
        XCTAssertEqual(movie?.voteAverage, 9.3)
    }

    func testSeasonMovieNilForAlreadyRankedSeason() async {
        let s = show(1399, seasons: [season(1)])
        let m = RankEntryModel(
            loadShowDetails: { _ in s },
            loadRankedTVIds: { ["tv_1399_s1"] },
            isSignedIn: { true })
        m.setMode(.tv)
        m.pickShow(s)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(m.seasonMovie(for: season(1)), "a disabled season builds no Movie")
    }

    func testSeasonMovieNilOutsideGridStage() {
        let m = RankEntryModel(isSignedIn: { true })
        XCTAssertNil(m.seasonMovie(for: season(1)))
    }

    // MARK: - book Movie construction

    func testBookMovieCarriesOLFieldsAndNoVoteAverage() {
        let m = RankEntryModel(isSignedIn: { true })
        let movie = m.bookMovie(for: book("OL27448W", title: "Dune", author: "Frank Herbert", rating: 4.2))
        XCTAssertEqual(movie.id, "ol_OL27448W")
        XCTAssertEqual(movie.mediaType, .book)
        XCTAssertEqual(movie.author, "Frank Herbert")
        XCTAssertEqual(movie.olWorkKey, "OL27448W")
        XCTAssertEqual(movie.olRatingsAverage, 4.2)
        XCTAssertNil(movie.voteAverage, "books never carry a TMDB voteAverage")
        // Book seeds the engine from OL rating ×2.
        XCTAssertEqual(movie.rankGlobalScore, 8.4)
    }

    // MARK: - whole-show season grid seeding (watchlist path)

    func testLoadSeasonGridSeedsFromShowId() async {
        let s = show(1399, name: "GoT", seasons: [season(1), season(2)])
        let m = RankEntryModel(
            loadShowDetails: { _ in s },
            loadShowGlobalScore: { _ in 9.0 },
            loadRankedTVIds: { [] },
            isSignedIn: { true })
        m.loadSeasonGrid(forShowId: 1399, fallbackName: "Game of Thrones")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(m.mode, .tv)
        if case .seasonGrid(let sh) = m.stage {
            XCTAssertEqual(sh.tmdbId, 1399)
        } else {
            XCTFail("expected season-grid stage")
        }
        XCTAssertEqual(m.seasons.map(\.seasonNumber), [1, 2])
    }

    func testLoadSeasonGridFallsBackWhenDetailFails() async {
        let m = RankEntryModel(
            loadShowDetails: { _ in nil },       // detail load failed
            loadShowGlobalScore: { _ in nil },
            loadRankedTVIds: { [] },
            isSignedIn: { true })
        m.loadSeasonGrid(forShowId: 1399, fallbackName: "Game of Thrones")
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Still enters the grid stage with a placeholder show (name preserved) so
        // the screen can show its empty/back state rather than hanging.
        if case .seasonGrid(let sh) = m.stage {
            XCTAssertEqual(sh.name, "Game of Thrones")
        } else {
            XCTFail("expected season-grid stage even on a failed detail load")
        }
        XCTAssertTrue(m.seasons.isEmpty)
    }

    // MARK: - live sign-in gate (Fix round 1)

    /// After signing in the live isSignedIn closure re-evaluates: requiresSignIn
    /// flips from true to false without the flow being re-entered. This tests the
    /// root cause of the dead-end after sign-in (frozen Bool vs live closure).
    func testLiveSignInGateReEvaluatesAfterSignIn() {
        var signedIn = false
        let m = RankEntryModel(isSignedIn: { signedIn })
        m.setMode(.tv)
        XCTAssertTrue(m.requiresSignIn, "signed-out user sees the nudge")
        // Simulate signing in externally (SpoolClient session becomes non-nil,
        // previewMode cleared) — the closure now returns true.
        signedIn = true
        XCTAssertFalse(m.requiresSignIn,
                       "requiresSignIn must re-evaluate immediately after sign-in")
    }

    // MARK: - media inference (shelf re-rank routing)

    func testMediaForRankingIdInfersVertical() {
        XCTAssertEqual(TVPreselectRouter.mediaForRankingId("tmdb_603"), .movie)
        XCTAssertEqual(TVPreselectRouter.mediaForRankingId("603"), .movie)
        XCTAssertEqual(TVPreselectRouter.mediaForRankingId("tv_1399_s3"), .tv)
        XCTAssertEqual(TVPreselectRouter.mediaForRankingId("tv_1399"), .tv)
        XCTAssertEqual(TVPreselectRouter.mediaForRankingId("ol_OL27448W"), .book)
    }

    func testShowAndSeasonParsedFromSeasonId() {
        let split = TVPreselectRouter.showAndSeason(fromSeasonId: "tv_1399_s3")
        XCTAssertEqual(split?.show, 1399)
        XCTAssertEqual(split?.season, 3)
        XCTAssertNil(TVPreselectRouter.showAndSeason(fromSeasonId: "tv_1399"))
        XCTAssertNil(TVPreselectRouter.showAndSeason(fromSeasonId: "tmdb_603"))
        XCTAssertNil(TVPreselectRouter.showAndSeason(fromSeasonId: "tv_1399_sx"))
    }
}
