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

    // Movie-mode adjudication (Fix round 1 — wording correction): the original
    // brief described deferring the movie suggestions grid as "no precedent on
    // web". That was wrong. Web `AddMediaModal` (lines ~80-124) has an identical
    // movie grid choreography (suggestions/backfill/session-excludes/consume-
    // splice). Deferring is still the right call — this brief was scoped to
    // tv/book — but it is a real web-parity gap that should live in the ledger,
    // not be dismissed as "no precedent".

    // MARK: - TV suggestions grid (Task 7)

    /// A tv `SuggestionItem` fixture (`tv_{n}` show id, mediaType .tv).
    private func suggestion(_ n: Int, title: String? = nil) -> SuggestionItem {
        SuggestionItem(
            id: "tv_\(n)", tmdbId: n, title: title ?? "Show \(n)", year: "2020",
            posterUrl: "http://p/\(n).jpg", backdropUrl: nil, mediaType: .tv,
            genres: ["Drama"], overview: "", voteAverage: 8.0, seasonCount: 3,
            pool: .trending)
    }

    /// A recording fake for the suggestions fetch — returns per-mode/page fixtures
    /// and records every (media, mode, page, excludes) call for choreography
    /// assertions. The `media` arg was added by the C7-iOS Task 3 media-parameterized
    /// seam (the closure widened from `(mode,page,excludes)` to `(media,mode,page,
    /// excludes)`); the tv choreography tests read the same `mode/page/excludes`
    /// fields and are otherwise unchanged.
    @MainActor
    final class SuggestionsFake {
        var suggestionsByPage: [Int: [SuggestionItem]] = [:]
        var backfillByPage: [Int: [SuggestionItem]] = [:]
        var suggestionsError: Error? = nil
        private(set) var calls: [(media: SuggestionMediaType, mode: SuggestionMode, page: Int, excludes: [String])] = []

        func fetch(_ media: SuggestionMediaType, _ mode: SuggestionMode, _ page: Int, _ excludes: [String]) async throws -> [SuggestionItem] {
            calls.append((media, mode, page, excludes))
            switch mode {
            case .suggestions:
                if let e = suggestionsError { throw e }
                return suggestionsByPage[page] ?? []
            case .backfill:
                return backfillByPage[page] ?? []
            case .newReleases:
                return []
            }
        }
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    func testEnteringTVLoadsSuggestionsGridAndPrefetchesBackfill() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = (1...5).map { suggestion($0) }
        fake.backfillByPage[1] = (100...104).map { suggestion($0) }
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv)
        await settle()

        XCTAssertEqual(m.tvSuggestions.map(\.tmdbId), [1, 2, 3, 4, 5])
        XCTAssertFalse(m.isLoadingTVSuggestions)
        // Both a suggestions(page 1) and a backfill(page 1) call fired.
        XCTAssertTrue(fake.calls.contains { $0.mode == .suggestions && $0.page == 1 })
        XCTAssertTrue(fake.calls.contains { $0.mode == .backfill && $0.page == 1 })
    }

    func testSignedOutTVLoadsNoSuggestions() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = [suggestion(1)]
        let m = RankEntryModel(isSignedIn: { false }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv)
        await settle()

        XCTAssertTrue(m.tvSuggestions.isEmpty)
        XCTAssertTrue(fake.calls.isEmpty, "signed-out tv fires no suggestions request")
    }

    func testConsumeSplicesShowOutAndRefillsFromBackfill() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = (1...3).map { suggestion($0) }
        fake.backfillByPage[1] = (100...105).map { suggestion($0) }
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv)
        await settle()

        let picked = m.tvSuggestions.first { $0.tmdbId == 2 }!
        m.pickSuggestedShow(picked)

        // Show 2 spliced out; a backfill item (100) appended to keep the grid full.
        XCTAssertFalse(m.tvSuggestions.contains { $0.tmdbId == 2 })
        XCTAssertEqual(m.tvSuggestions.map(\.tmdbId), [1, 3, 100])
        XCTAssertTrue(m.tvSuggestionsHasBackfill, "a backfill item mixed in flips the flag")
    }

    func testConsumeRefillSkipsIdsAlreadyPresent() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = (1...3).map { suggestion($0) }
        // Backfill pool leads with an id ALREADY in the grid (3) — it must be skipped.
        fake.backfillByPage[1] = [suggestion(3), suggestion(200)]
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv)
        await settle()

        m.pickSuggestedShow(m.tvSuggestions.first { $0.tmdbId == 1 }!)
        // Duplicate id 3 skipped; 200 fills the slot.
        XCTAssertEqual(m.tvSuggestions.map(\.tmdbId), [2, 3, 200])
    }

    func testBackfillRefetchWhenPoolDropsBelowThreshold() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = (1...5).map { suggestion($0) }
        // Pool has exactly 3 — consuming one refills (pool→2) which is < 3, so a
        // page-2 backfill re-request fires.
        fake.backfillByPage[1] = (100...102).map { suggestion($0) }
        fake.backfillByPage[2] = (200...205).map { suggestion($0) }
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv)
        await settle()

        m.pickSuggestedShow(m.tvSuggestions.first!)
        await settle()

        XCTAssertTrue(fake.calls.contains { $0.mode == .backfill && $0.page == 2 },
                      "pool dropping below 3 re-requests backfill at page+1")
    }

    func testRefreshAdvancesSuggestionsPage() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = [suggestion(1)]
        fake.suggestionsByPage[2] = [suggestion(2)]
        fake.backfillByPage[1] = []
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv)
        await settle()
        XCTAssertEqual(m.tvSuggestions.map(\.tmdbId), [1])

        m.refreshTVSuggestions()
        await settle()

        XCTAssertEqual(m.tvSuggestions.map(\.tmdbId), [2], "Refresh = suggestions page+1, whole swap")
        XCTAssertTrue(fake.calls.contains { $0.mode == .suggestions && $0.page == 2 })
    }

    func testSessionExcludesAccumulateConsumedShowIds() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = (1...3).map { suggestion($0) }
        fake.backfillByPage[1] = []
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv)
        await settle()

        m.pickSuggestedShow(m.tvSuggestions.first { $0.tmdbId == 1 }!)
        m.pickSuggestedShow(m.tvSuggestions.first { $0.tmdbId == 2 }!)
        // A Refresh forwards the accumulated excludes to the next suggestions call.
        m.refreshTVSuggestions()
        await settle()

        let refreshCall = fake.calls.last { $0.mode == .suggestions }
        XCTAssertEqual(Set(refreshCall?.excludes ?? []), ["tv_1", "tv_2"],
                       "consumed SHOW ids forwarded as session excludes")
    }

    func testSessionExcludesCappedAt200() async {
        let fake = SuggestionsFake()
        // 205 shows so 205 consumes overflow the 200 cap.
        fake.suggestionsByPage[1] = (1...205).map { suggestion($0) }
        fake.backfillByPage[1] = []
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv)
        await settle()

        for show in m.tvSuggestions { m.consumeForTest(show) }
        m.refreshTVSuggestions()
        await settle()

        let refreshCall = fake.calls.last { $0.mode == .suggestions }
        XCTAssertEqual(refreshCall?.excludes.count, 200, "session excludes cap at 200")
        // The cap keeps the MOST RECENT ids (web slice(-200)) — earliest dropped.
        XCTAssertFalse(refreshCall!.excludes.contains("tv_1"))
        XCTAssertTrue(refreshCall!.excludes.contains("tv_205"))
    }

    func testSuggestions401MapsToSilentEmpty() async {
        let fake = SuggestionsFake()
        fake.suggestionsError = SuggestionsClient.SuggestionsError.http(status: 401)
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv)
        await settle()

        XCTAssertTrue(m.tvSuggestions.isEmpty)
        XCTAssertFalse(m.tvSuggestionsFailed, "401 → silent empty, no retry affordance")
    }

    func testSuggestionsNotAuthenticatedMapsToSilentEmpty() async {
        let fake = SuggestionsFake()
        fake.suggestionsError = SuggestionsClient.SuggestionsError.notAuthenticated
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv)
        await settle()

        XCTAssertTrue(m.tvSuggestions.isEmpty)
        XCTAssertFalse(m.tvSuggestionsFailed)
    }

    func testSuggestionsOtherErrorFlagsRetry() async {
        let fake = SuggestionsFake()
        fake.suggestionsError = SuggestionsClient.SuggestionsError.http(status: 502)
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv)
        await settle()

        XCTAssertTrue(m.tvSuggestions.isEmpty)
        XCTAssertTrue(m.tvSuggestionsFailed, "a 502 → retry affordance")
    }

    func testPickSuggestedShowRoutesIntoSeasonGrid() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = [suggestion(1399, title: "GoT")]
        fake.backfillByPage[1] = []
        let detail = show(1399, name: "GoT", seasons: [season(1), season(2)])
        var loadedShowId: Int? = nil
        let m = RankEntryModel(
            loadShowDetails: { id in loadedShowId = id; return detail },
            loadShowGlobalScore: { _ in 9.1 },
            loadRankedTVIds: { [] },
            isSignedIn: { true },
            fetchTVSuggestions: fake.fetch)
        m.setMode(.tv)
        await settle()

        let picked = m.tvSuggestions.first!
        m.pickSuggestedShow(picked)
        // Immediately routes into the season-grid stage with the SHOW.
        XCTAssertEqual(m.stage, .seasonGrid(show: RankEntryModel.show(from: suggestion(1399, title: "GoT"))))
        await settle()
        XCTAssertEqual(loadedShowId, 1399, "the same season-load path a search pick uses fires")
        XCTAssertEqual(m.seasons.map(\.seasonNumber), [1, 2])
    }

    func testLeavingTVTearsSuggestionsDown() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = [suggestion(1)]
        fake.backfillByPage[1] = []
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv)
        await settle()
        XCTAssertFalse(m.tvSuggestions.isEmpty)

        m.setMode(.book)
        XCTAssertTrue(m.tvSuggestions.isEmpty, "leaving tv clears the grid")
    }

    // MARK: - Movie suggestions grid (C7-iOS Task 3)
    //
    // The SAME media-parameterized machinery drives the movie grid. These mirror
    // the tv choreography tests above (consume/refill/refresh/excludes/error+401)
    // for the movie path: a picked movie goes STRAIGHT to the ceremony (no season
    // grid), threading voteAverage; excludes are movie ids `tmdb_{n}`; signed-out
    // movie fires NO request (fixtures posture) despite requiresSignIn == false.

    /// A movie `SuggestionItem` fixture (`tmdb_{n}` movie id, mediaType .movie).
    private func movieSuggestion(_ n: Int, title: String? = nil, vote: Double? = 8.0) -> SuggestionItem {
        SuggestionItem(
            id: "tmdb_\(n)", tmdbId: n, title: title ?? "Movie \(n)", year: "2020",
            posterUrl: "http://p/\(n).jpg", backdropUrl: nil, mediaType: .movie,
            genres: ["Drama"], overview: "", voteAverage: vote, seasonCount: 0,
            pool: .trending)
    }

    func testEnteringMovieLoadsSuggestionsGridAndPrefetchesBackfill() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = (1...5).map { movieSuggestion($0) }
        fake.backfillByPage[1] = (100...104).map { movieSuggestion($0) }
        // Start in tv (so setMode(.movie) is a real switch that loads the grid).
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv)
        await settle()
        m.setMode(.movie)
        await settle()

        XCTAssertEqual(m.movieSuggestions.map(\.tmdbId), [1, 2, 3, 4, 5])
        XCTAssertFalse(m.isLoadingTVSuggestions)
        // Both calls fired under the MOVIE media.
        XCTAssertTrue(fake.calls.contains { $0.media == .movie && $0.mode == .suggestions && $0.page == 1 })
        XCTAssertTrue(fake.calls.contains { $0.media == .movie && $0.mode == .backfill && $0.page == 1 })
    }

    func testSignedOutMovieLoadsNoSuggestions() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = [movieSuggestion(1)]
        let m = RankEntryModel(isSignedIn: { false }, fetchTVSuggestions: fake.fetch)
        // Movie is the default mode; force a reload path the way the view would.
        m.loadTVSuggestions()
        await settle()

        XCTAssertTrue(m.movieSuggestions.isEmpty)
        XCTAssertFalse(m.requiresSignIn, "movie mode never requires sign-in (fixtures)")
        XCTAssertTrue(fake.calls.isEmpty, "signed-out movie fires no engine request")
    }

    func testMovieConsumeSplicesOutAndRefillsFromBackfill() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = (1...3).map { movieSuggestion($0) }
        fake.backfillByPage[1] = (100...105).map { movieSuggestion($0) }
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv); await settle()
        m.setMode(.movie); await settle()

        let picked = m.movieSuggestions.first { $0.tmdbId == 2 }!
        _ = m.pickSuggestedMovie(picked)

        XCTAssertFalse(m.movieSuggestions.contains { $0.tmdbId == 2 })
        XCTAssertEqual(m.movieSuggestions.map(\.tmdbId), [1, 3, 100])
        XCTAssertTrue(m.tvSuggestionsHasBackfill, "a backfill item mixed in flips the header flag")
    }

    func testMovieRefreshAdvancesSuggestionsPage() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = [movieSuggestion(1)]
        fake.suggestionsByPage[2] = [movieSuggestion(2)]
        fake.backfillByPage[1] = []
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv); await settle()
        m.setMode(.movie); await settle()
        XCTAssertEqual(m.movieSuggestions.map(\.tmdbId), [1])

        m.refreshTVSuggestions()
        await settle()

        XCTAssertEqual(m.movieSuggestions.map(\.tmdbId), [2], "Refresh = suggestions page+1, whole swap")
        XCTAssertTrue(fake.calls.contains { $0.media == .movie && $0.mode == .suggestions && $0.page == 2 })
    }

    func testMovieBackfillRefetchWhenPoolDropsBelowThreshold() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = (1...5).map { movieSuggestion($0) }
        fake.backfillByPage[1] = (100...102).map { movieSuggestion($0) }   // exactly 3
        fake.backfillByPage[2] = (200...205).map { movieSuggestion($0) }
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv); await settle()
        m.setMode(.movie); await settle()

        _ = m.pickSuggestedMovie(m.movieSuggestions.first!)
        await settle()

        XCTAssertTrue(fake.calls.contains { $0.media == .movie && $0.mode == .backfill && $0.page == 2 },
                      "pool dropping below 3 re-requests backfill at page+1")
    }

    func testMovieSessionExcludesAccumulateConsumedMovieIds() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = (1...3).map { movieSuggestion($0) }
        fake.backfillByPage[1] = []
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv); await settle()
        m.setMode(.movie); await settle()

        _ = m.pickSuggestedMovie(m.movieSuggestions.first { $0.tmdbId == 1 }!)
        _ = m.pickSuggestedMovie(m.movieSuggestions.first { $0.tmdbId == 2 }!)
        m.refreshTVSuggestions()
        await settle()

        let refreshCall = fake.calls.last { $0.media == .movie && $0.mode == .suggestions }
        XCTAssertEqual(Set(refreshCall?.excludes ?? []), ["tmdb_1", "tmdb_2"],
                       "consumed MOVIE ids forwarded as session excludes")
    }

    func testMovieSessionExcludesCappedAt200() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = (1...205).map { movieSuggestion($0) }
        fake.backfillByPage[1] = []
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv); await settle()
        m.setMode(.movie); await settle()

        for movie in m.movieSuggestions { m.consumeForTest(movie) }
        m.refreshTVSuggestions()
        await settle()

        let refreshCall = fake.calls.last { $0.media == .movie && $0.mode == .suggestions }
        XCTAssertEqual(refreshCall?.excludes.count, 200, "session excludes cap at 200")
        XCTAssertFalse(refreshCall!.excludes.contains("tmdb_1"))
        XCTAssertTrue(refreshCall!.excludes.contains("tmdb_205"))
    }

    func testMovieSuggestions401MapsToSilentEmpty() async {
        let fake = SuggestionsFake()
        fake.suggestionsError = SuggestionsClient.SuggestionsError.http(status: 401)
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv); await settle()
        m.setMode(.movie); await settle()

        XCTAssertTrue(m.movieSuggestions.isEmpty)
        XCTAssertFalse(m.tvSuggestionsFailed, "401 → silent empty, no retry affordance")
    }

    func testMovieSuggestionsOtherErrorFlagsRetry() async {
        let fake = SuggestionsFake()
        fake.suggestionsError = SuggestionsClient.SuggestionsError.http(status: 502)
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv); await settle()
        m.setMode(.movie); await settle()

        XCTAssertTrue(m.movieSuggestions.isEmpty)
        XCTAssertTrue(m.tvSuggestionsFailed, "a 502 → retry affordance")
    }

    func testPickSuggestedMovieRoutesToCeremonyWithVoteAverage() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = [movieSuggestion(603, title: "The Matrix", vote: 8.2)]
        fake.backfillByPage[1] = []
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv); await settle()
        m.setMode(.movie); await settle()

        let picked = m.movieSuggestions.first!
        let movie = m.pickSuggestedMovie(picked)

        // Straight to the ceremony — NO season-grid transition; stage stays search.
        XCTAssertEqual(m.stage, .search, "a picked movie never enters the season grid")
        XCTAssertNotNil(movie)
        XCTAssertEqual(movie?.id, "tmdb_603")
        XCTAssertEqual(movie?.mediaType, .movie)
        XCTAssertEqual(movie?.title, "The Matrix")
        XCTAssertEqual(movie?.voteAverage, 8.2, "voteAverage threads through so the prediction seeds")
        XCTAssertEqual(movie?.rankGlobalScore, 8.2, "movie seeds the engine from voteAverage")
    }

    func testLeavingMovieForBookTearsSuggestionsDown() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = [movieSuggestion(1)]
        fake.backfillByPage[1] = []
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv); await settle()
        m.setMode(.movie); await settle()
        XCTAssertFalse(m.movieSuggestions.isEmpty)

        m.setMode(.book)
        XCTAssertTrue(m.movieSuggestions.isEmpty, "leaving movie clears the grid")
    }

    func testModeSwitchResetsCrossMediaExcludesAndPage() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = (1...3).map { movieSuggestion($0) }
        fake.suggestionsByPage[2] = (10...12).map { suggestion($0) }
        fake.backfillByPage[1] = []
        let m = RankEntryModel(isSignedIn: { true }, fetchTVSuggestions: fake.fetch)
        m.setMode(.tv); await settle()
        m.setMode(.movie); await settle()

        // Consume movies + refresh (advances the movie page to 2, excludes tmdb_).
        _ = m.pickSuggestedMovie(m.movieSuggestions.first!)
        m.refreshTVSuggestions()
        await settle()

        // Switch back to tv — a mode switch resets the shared page + excludes so the
        // tv grid loads page 1 with a clean (no tmdb_) exclude set.
        m.setMode(.tv)
        await settle()

        let tvCall = fake.calls.last { $0.media == .tv && $0.mode == .suggestions }
        XCTAssertEqual(tvCall?.page, 1, "mode switch resets the shared suggestions page")
        XCTAssertEqual(tvCall?.excludes ?? [], [], "mode switch drops cross-media excludes")
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

    // MARK: - suggestion-grid save-for-later (C7-iOS Task 4)

    /// The movie-suggestion mapper mints a MOVIE `WatchlistItem` — `tmdb_{n}` id,
    /// `.movie` media, year/poster coalesced. Mirrors web `AddMediaModal`'s
    /// whole-movie bookmark.
    func testMovieSuggestionMapsToMovieWatchlistItem() {
        let movie = RankEntryModel.movieDTO(from: movieSuggestion(603, title: "The Matrix"))
        let item = RankEntryModel.movieWatchlistItem(from: movie)
        XCTAssertEqual(item.id, "tmdb_603")
        XCTAssertEqual(item.mediaType, .movie)
        XCTAssertEqual(item.title, "The Matrix")
        XCTAssertEqual(item.year, "2020")
        XCTAssertEqual(item.posterUrl, "http://p/603.jpg")
        XCTAssertFalse(item.isWholeShow, "a movie item is never a whole-show bookmark")
    }

    /// The show-suggestion mapper mints a WHOLE-SHOW tv `WatchlistItem` per web
    /// `handleBookmarkSuggestion`: `tv_{showId}` id, `.tv` media, `showTmdbId`
    /// set, `seasonNumber` nil → `isWholeShow`. NOT a season item, and never a
    /// B2-corrupt row (`showTmdbId` is always non-nil).
    func testShowSuggestionMapsToWholeShowWatchlistItem() {
        let s = show(1399, name: "Game of Thrones", creators: ["David Benioff"], seasons: [])
        let item = RankEntryModel.showWatchlistItem(from: s)
        XCTAssertEqual(item.id, "tv_1399", "grid bookmark saves the SHOW-level id")
        XCTAssertEqual(item.mediaType, .tv)
        XCTAssertEqual(item.title, "Game of Thrones")
        XCTAssertEqual(item.showTmdbId, 1399, "non-nil show id → never a B2-corrupt row")
        XCTAssertNil(item.seasonNumber, "grid bookmark is whole-show, no season")
        XCTAssertTrue(item.isWholeShow, "a nil season number reads as whole show")
        XCTAssertEqual(item.creator, "David Benioff")
    }

    /// Saving a movie suggestion writes the mapped item, toasts success, and
    /// CONSUMES the card (web parity: `AddMediaModal.tsx:330` calls
    /// `consumeSuggestion(movie.id)` when `fromSuggestion`). The card is spliced
    /// out of the visible grid; `savedIds` retains the id for the dedup guard.
    func testSaveMovieSuggestionAddsAndToastsAndConsumes() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = (1...3).map { movieSuggestion($0) }
        fake.backfillByPage[1] = (100...105).map { movieSuggestion($0) }
        var saved: WatchlistItem?
        var toastLevel: ToastLevel?
        let m = RankEntryModel(
            isSignedIn: { true },
            fetchTVSuggestions: fake.fetch,
            saveForLater: { item in saved = item; return true },
            toast: { _, level in toastLevel = level }
        )
        m.setMode(.tv); await settle()
        m.setMode(.movie); await settle()

        let movie = m.movieSuggestions.first { $0.tmdbId == 2 }!
        await m.saveMovieSuggestion(movie)

        XCTAssertEqual(saved?.id, "tmdb_2")
        XCTAssertEqual(saved?.mediaType, .movie)
        XCTAssertEqual(toastLevel, .success)
        // Card consumed — spliced out and replaced by a backfill item.
        XCTAssertFalse(m.movieSuggestions.contains { $0.tmdbId == 2 },
                       "a successful save consumes the card (web parity)")
        XCTAssertEqual(m.movieSuggestions.map(\.tmdbId), [1, 3, 100])
        // savedIds still set — dedup guard keeps a second tap from re-firing.
        XCTAssertTrue(m.isSaved("tmdb_2"), "savedIds dedup guard remains after consume")
    }

    /// Saving a show suggestion writes the WHOLE-SHOW item and CONSUMES the card
    /// (web `handleBookmarkSuggestion` calls `consumeSuggestion` first).
    func testSaveShowSuggestionAddsWholeShowItemAndConsumes() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = (1...3).map { suggestion($0) }
        fake.backfillByPage[1] = (100...105).map { suggestion($0) }
        var saved: WatchlistItem?
        let m = RankEntryModel(
            isSignedIn: { true },
            fetchTVSuggestions: fake.fetch,
            saveForLater: { item in saved = item; return true }
        )
        m.setMode(.tv); await settle()

        let picked = m.tvSuggestions.first { $0.tmdbId == 2 }!
        await m.saveShowSuggestion(picked)

        XCTAssertEqual(saved?.id, "tv_2")
        XCTAssertEqual(saved?.mediaType, .tv)
        XCTAssertNil(saved?.seasonNumber, "whole show — no season")
        // Card consumed.
        XCTAssertFalse(m.tvSuggestions.contains { $0.tmdbId == 2 },
                       "a successful show save consumes the card (web parity)")
        XCTAssertTrue(m.isSaved("tv_2"), "savedIds dedup guard remains after consume")
    }

    /// A second save of the same suggestion is a no-op (de-dup via `savedIds`,
    /// the Discover pattern) — `add` fires exactly once.
    func testSaveSuggestionIsIdempotentPerId() async {
        var calls = 0
        let m = RankEntryModel(saveForLater: { _ in calls += 1; return true })
        let movie = RankEntryModel.movieDTO(from: movieSuggestion(1))

        await m.saveMovieSuggestion(movie)
        await m.saveMovieSuggestion(movie)

        XCTAssertEqual(calls, 1, "the optimistic saved-set suppresses the duplicate write")
    }

    /// A failed save reverts the optimistic saved-mark and toasts an error; the
    /// card is NOT consumed (stays in the grid so the user can retry).
    func testFailedSaveRevertsMarkAndCardStaysAndToastsError() async {
        let fake = SuggestionsFake()
        fake.suggestionsByPage[1] = (1...3).map { movieSuggestion($0) }
        fake.backfillByPage[1] = []
        var toastLevel: ToastLevel?
        let m = RankEntryModel(
            isSignedIn: { true },
            fetchTVSuggestions: fake.fetch,
            saveForLater: { _ in false },
            toast: { _, level in toastLevel = level }
        )
        m.setMode(.tv); await settle()
        m.setMode(.movie); await settle()

        let movie = m.movieSuggestions.first { $0.tmdbId == 1 }!
        await m.saveMovieSuggestion(movie)

        XCTAssertEqual(toastLevel, .error)
        XCTAssertFalse(m.isSaved("tmdb_1"), "a failed save reverts the mark so a retry can fire")
        // Card NOT consumed — stays in the grid for the retry.
        XCTAssertTrue(m.movieSuggestions.contains { $0.tmdbId == 1 },
                      "a failed save does not consume the card")
    }
}
