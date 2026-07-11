import XCTest
@testable import Spool

/// RED-first spec for the C3 Part B Discover engine grid + New Releases sections
/// and the card actions (save-for-later, rank-it) on `DiscoverModel`
/// (`DiscoverScreen.swift`). Everything runs with ZERO network — the engine /
/// new-releases loads and the save closure are injected as fakes (the same
/// idiom as `WatchlistModelTests` / `FeedFeedModelTests`).
///
/// The load-bearing decisions each get a test:
///  1. provenance chip copy — every pool + unknown maps to the right EN string
///     (twin of web `discoverChips.ts` + `i18n/en.ts`).
///  2. engine section choreography: load → ready(12-capped) / empty(no-auth) /
///     error(http/transport); Refresh advances the page and whole-set swaps.
///  3. new-releases choreography: load → ready(≤10) / empty / error + retry.
///  4. card actions: save-for-later calls `add` with the right item (movie
///     media) + toasts; rank-it fires the closure with the RAW mapped movie.
@MainActor
final class DiscoverEngineModelTests: XCTestCase {

    // MARK: fixtures

    private func item(_ n: Int, pool: SuggestionPool? = .taste, title: String = "M") -> SuggestionItem {
        SuggestionItem(
            id: "tmdb_\(n)", tmdbId: n, title: "\(title)\(n)", year: "2020",
            posterUrl: "https://img/\(n).jpg", backdropUrl: nil, mediaType: .movie,
            genres: ["Drama", "Sci-Fi"], overview: "o", voteAverage: 7.0,
            seasonCount: 0, pool: pool
        )
    }

    private func items(_ count: Int, pool: SuggestionPool? = .taste) -> [SuggestionItem] {
        (1...count).map { item($0, pool: pool) }
    }

    /// A model with no-op defaults; override just the closure a test cares about.
    private func makeModel(
        loadRecs: @escaping DiscoverModel.LoadRecs = { [] },
        loadTrending: @escaping DiscoverModel.LoadTrending = { [] },
        hasFriends: @escaping DiscoverModel.HasFriends = { true },
        loadEngine: @escaping DiscoverModel.LoadSuggestions = { _, _ in [] },
        loadNewReleases: @escaping DiscoverModel.LoadSuggestions = { _, _ in [] },
        save: @escaping DiscoverModel.SaveForLater = { _ in true },
        toast: @escaping DiscoverModel.Toast = { _, _ in }
    ) -> DiscoverModel {
        DiscoverModel(
            loadRecs: loadRecs, loadTrending: loadTrending, hasFriends: hasFriends,
            loadEngine: loadEngine, loadNewReleases: loadNewReleases,
            save: save, toast: toast
        )
    }

    // MARK: - 1. provenance chip copy (twin of web discoverChips + en.ts)

    func testChipCopyForEveryKnownPool() {
        // Now wired through L10n reusing the web discover.chip.* keys (C6-iOS
        // Task 3); assert against the resolved value so the test is locale-safe.
        let cases: [(SuggestionPool, String)] = [
            (.friend, L10n.t("discover.chip.friend")),
            (.taste, L10n.t("discover.chip.taste")),
            (.similar, L10n.t("discover.chip.similar")),
            (.trending, L10n.t("discover.chip.trending")),
            (.variety, L10n.t("discover.chip.variety")),
            (.generic, L10n.t("discover.chip.generic")),
            (.newRelease, L10n.t("discover.chip.new_release")),
        ]
        for (pool, copy) in cases {
            XCTAssertEqual(DiscoverCardCopy.chipCopy(for: pool), copy, "pool \(pool.rawValue)")
        }
    }

    /// `backfill` has no distinct story and any unknown/nil pool must fall back
    /// to the safe "popular" chip (discover.chip.generic) — never a raw enum or
    /// blank (web parity).
    func testChipCopyFallsBackToPopular() {
        XCTAssertEqual(DiscoverCardCopy.chipCopy(for: .backfill), L10n.t("discover.chip.generic"))
        XCTAssertEqual(DiscoverCardCopy.chipCopy(for: .unknown("brand_new_v9")), L10n.t("discover.chip.generic"))
        XCTAssertEqual(DiscoverCardCopy.chipCopy(for: nil), L10n.t("discover.chip.generic"))
    }

    // MARK: - 2. engine section choreography

    func testEngineLoadReadyCapsAtTwelve() async {
        let model = makeModel(loadEngine: { mode, page in
            XCTAssertEqual(mode, .suggestions)
            XCTAssertEqual(page, 1)
            return self.items(20)
        })

        await model.loadEngineIfNeeded()

        guard case .ready(let items) = model.engineState else {
            return XCTFail("expected .ready, got \(model.engineState)")
        }
        XCTAssertEqual(items.count, 12, "engine grid caps at 12")
    }

    func testEngineNotAuthenticatedBecomesEmpty() async {
        let model = makeModel(loadEngine: { _, _ in throw SuggestionsClient.SuggestionsError.notAuthenticated })
        await model.loadEngineIfNeeded()
        // The screen is auth-gated; a signed-out engine is empty, not an error.
        XCTAssertEqual(model.engineState, .empty)
    }

    func testEngineHttpErrorBecomesError() async {
        let model = makeModel(loadEngine: { _, _ in throw SuggestionsClient.SuggestionsError.http(status: 502) })
        await model.loadEngineIfNeeded()
        XCTAssertEqual(model.engineState, .error)
    }

    func testEngineTransportErrorBecomesError() async {
        struct Net: Error {}
        let model = makeModel(loadEngine: { _, _ in throw SuggestionsClient.SuggestionsError.transport(Net()) })
        await model.loadEngineIfNeeded()
        XCTAssertEqual(model.engineState, .error)
    }

    func testEngineEmptyResultBecomesEmpty() async {
        let model = makeModel(loadEngine: { _, _ in [] })
        await model.loadEngineIfNeeded()
        XCTAssertEqual(model.engineState, .empty)
    }

    /// Refresh advances the page (web parity: Refresh = page+1) and whole-set
    /// swaps the grid (no append).
    func testRefreshEngineAdvancesPageAndSwaps() async {
        var pages: [Int] = []
        let model = makeModel(loadEngine: { _, page in
            pages.append(page)
            return page == 1 ? [self.item(1)] : [self.item(2), self.item(3)]
        })

        await model.loadEngineIfNeeded()
        XCTAssertEqual(model.engineItems.map(\.id), ["tmdb_1"])

        await model.refreshEngine()

        XCTAssertEqual(pages, [1, 2], "refresh requests page 2")
        XCTAssertEqual(model.engineItems.map(\.id), ["tmdb_2", "tmdb_3"],
                       "whole-set swap, not append")
    }

    /// `loadEngineIfNeeded` is idempotent — a second call after a ready load
    /// does not re-request (web loads once per mount; Refresh is the re-fetch).
    func testLoadEngineIfNeededIsIdempotent() async {
        var calls = 0
        let model = makeModel(loadEngine: { _, _ in calls += 1; return [self.item(1)] })
        await model.loadEngineIfNeeded()
        await model.loadEngineIfNeeded()
        XCTAssertEqual(calls, 1)
    }

    // MARK: - 3. new-releases choreography

    func testNewReleasesLoadReadyCapsAtTen() async {
        let model = makeModel(loadNewReleases: { mode, page in
            XCTAssertEqual(mode, .newReleases)
            XCTAssertEqual(page, 1)
            return self.items(15)
        })
        await model.loadNewReleasesIfNeeded()
        guard case .ready(let items) = model.newReleasesState else {
            return XCTFail("expected .ready, got \(model.newReleasesState)")
        }
        XCTAssertEqual(items.count, 10, "new releases cap at 10")
    }

    func testNewReleasesNotAuthenticatedBecomesEmpty() async {
        let model = makeModel(loadNewReleases: { _, _ in throw SuggestionsClient.SuggestionsError.notAuthenticated })
        await model.loadNewReleasesIfNeeded()
        XCTAssertEqual(model.newReleasesState, .empty)
    }

    func testNewReleasesHttpErrorBecomesErrorThenRetryRecovers() async {
        var attempt = 0
        let model = makeModel(loadNewReleases: { _, _ in
            attempt += 1
            if attempt == 1 { throw SuggestionsClient.SuggestionsError.http(status: 429) }
            return [self.item(1)]
        })
        await model.loadNewReleasesIfNeeded()
        XCTAssertEqual(model.newReleasesState, .error)

        await model.retryNewReleases()
        guard case .ready(let items) = model.newReleasesState else {
            return XCTFail("retry should recover to .ready")
        }
        XCTAssertEqual(items.map(\.id), ["tmdb_1"])
    }

    // MARK: - 4. card actions

    func testSaveForLaterCallsAddWithMovieItemAndToasts() async {
        var savedItem: WatchlistItem?
        var toasted: String?
        let model = makeModel(
            save: { item in savedItem = item; return true },
            toast: { text, _ in toasted = text }
        )

        let suggestion = item(603, title: "The Matrix ")
        await model.saveForLater(suggestion)

        XCTAssertEqual(savedItem?.id, "tmdb_603", "adds under the tmdb_-prefixed id")
        XCTAssertEqual(savedItem?.mediaType, .movie)
        XCTAssertEqual(savedItem?.title, "The Matrix 603")
        XCTAssertEqual(savedItem?.genres, ["Drama", "Sci-Fi"])
        XCTAssertNotNil(toasted, "a confirmation toast fires")
    }

    func testSaveForLaterFailureToastsError() async {
        var level: ToastLevel?
        let model = makeModel(save: { _ in false }, toast: { _, l in level = l })
        await model.saveForLater(item(1))
        XCTAssertEqual(level, .error, "a failed save surfaces an error toast")
    }

    /// Saving the same item twice only calls `add` once — an optimistic
    /// "already saved" set suppresses the duplicate write (owned/bookmarked
    /// items are excluded server-side for the grid; the client de-dups taps).
    func testSaveForLaterIsIdempotentPerItem() async {
        var calls = 0
        let model = makeModel(save: { _ in calls += 1; return true })
        await model.saveForLater(item(1))
        await model.saveForLater(item(1))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(model.isSaved("tmdb_1"))
    }

    /// Rank-it maps the RAW suggestion to a `Movie` and fires the injected
    /// closure — no watchlist origin (a discover rank must never delete a
    /// bookmark; mirrors `rerankFromShelf`).
    func testRankItFiresClosureWithMappedRawMovie() async {
        var ranked: Movie?
        let model = makeModel()
        model.bindRankIt { ranked = $0 }

        model.rankIt(item(27205, title: "Inception "))

        XCTAssertEqual(ranked?.id, "tmdb_27205")
        XCTAssertEqual(ranked?.title, "Inception 27205")
        XCTAssertEqual(ranked?.year, 2020)
        XCTAssertEqual(ranked?.genres, ["Drama", "Sci-Fi"])
        XCTAssertEqual(ranked?.posterUrl, "https://img/27205.jpg")
        XCTAssertEqual(ranked?.voteAverage, 7.0, "engine vote_average rides along")
    }

    // MARK: - live owned-display filter (C7-iOS Task 4)

    /// Ranking a grid item this session drops it LIVE from the engine grid: the
    /// engine already excludes server-owned items, but a mid-session rank was in
    /// the already-fetched page — `visibleEngineItems` re-filters it out
    /// (web `isAlreadyOwned` render-time parity). The raw `engineItems` still
    /// holds it (the fetched page is untouched).
    func testRankingItemDropsItLiveFromEngineGrid() async {
        let model = makeModel(loadEngine: { _, _ in self.items(4) })
        model.bindRankIt { _ in }
        await model.loadEngineIfNeeded()

        XCTAssertEqual(model.visibleEngineItems.count, 4, "all four visible before")

        model.rankIt(self.item(2))   // rank tmdb_2

        XCTAssertFalse(model.visibleEngineItems.map(\.id).contains("tmdb_2"),
                       "a ranked item vanishes from the visible grid immediately")
        XCTAssertEqual(model.visibleEngineItems.count, 3)
        XCTAssertEqual(model.engineItems.count, 4,
                       "the raw fetched page is untouched — only the display filters")
    }

    /// Saving a grid item this session likewise drops it live from the grid
    /// (web folds session bookmarks into `allExcludedIds`).
    func testSavingItemDropsItLiveFromEngineGrid() async {
        let model = makeModel(loadEngine: { _, _ in self.items(3) }, save: { _ in true })
        await model.loadEngineIfNeeded()
        XCTAssertEqual(model.visibleEngineItems.count, 3)

        await model.saveForLater(self.item(1))   // save tmdb_1

        XCTAssertFalse(model.visibleEngineItems.map(\.id).contains("tmdb_1"),
                       "a saved item vanishes from the visible grid immediately")
        XCTAssertEqual(model.visibleEngineItems.count, 2)
    }

    /// The New Releases row shares the same session-scoped display filter.
    func testRankingItemDropsItLiveFromNewReleases() async {
        let model = makeModel(loadNewReleases: { _, _ in self.items(3) })
        model.bindRankIt { _ in }
        await model.loadNewReleasesIfNeeded()
        XCTAssertEqual(model.visibleNewReleasesItems.count, 3)

        model.rankIt(self.item(2))

        XCTAssertFalse(model.visibleNewReleasesItems.map(\.id).contains("tmdb_2"),
                       "a ranked item vanishes from New Releases too")
        XCTAssertEqual(model.visibleNewReleasesItems.count, 2)
    }

    /// A failed save reverts the optimistic saved-mark, so the item stays in the
    /// visible grid (the filter follows `savedIds`, which the revert clears).
    func testFailedSaveKeepsItemInVisibleGrid() async {
        let model = makeModel(loadEngine: { _, _ in self.items(2) }, save: { _ in false })
        await model.loadEngineIfNeeded()

        await model.saveForLater(self.item(1))

        XCTAssertTrue(model.visibleEngineItems.map(\.id).contains("tmdb_1"),
                      "a failed save reverts the mark, so the card stays visible")
        XCTAssertEqual(model.visibleEngineItems.count, 2)
    }

    // MARK: - 5. card actions on the SOCIAL sections (Part A cards)

    private func rec(_ tmdb: String, title: String = "Rec") -> FriendRecommendation {
        FriendRecommendation(
            tmdbId: tmdb, title: title, posterUrl: "p.jpg", year: "2019",
            genres: ["Drama"], avgTier: "A", avgTierNumeric: 4.0,
            friendCount: 2, topTier: "S", friends: []
        )
    }

    private func trending(_ tmdb: String, title: String = "Trend") -> TrendingMovie {
        TrendingMovie(
            rank: 1, tmdbId: tmdb, title: title, posterUrl: "p.jpg", year: "2023",
            genres: ["Sci-Fi"], rankerCount: 3, avgTier: "B", avgTierNumeric: 3.0,
            recentRankers: []
        )
    }

    func testSaveForLaterOnFriendRecCallsAdd() async {
        var saved: WatchlistItem?
        let model = makeModel(save: { item in saved = item; return true })
        await model.saveForLater(rec("tmdb_500", title: "Fight Club"))
        XCTAssertEqual(saved?.id, "tmdb_500")
        XCTAssertEqual(saved?.mediaType, .movie)
        XCTAssertEqual(saved?.title, "Fight Club")
    }

    func testSaveForLaterOnTrendingCallsAdd() async {
        var saved: WatchlistItem?
        let model = makeModel(save: { item in saved = item; return true })
        await model.saveForLater(trending("tmdb_680", title: "Pulp Fiction"))
        XCTAssertEqual(saved?.id, "tmdb_680")
        XCTAssertEqual(saved?.mediaType, .movie)
    }

    func testRankItOnFriendRecFiresClosure() async {
        var ranked: Movie?
        let model = makeModel()
        model.bindRankIt { ranked = $0 }
        model.rankIt(rec("tmdb_155", title: "The Dark Knight"))
        XCTAssertEqual(ranked?.id, "tmdb_155")
        XCTAssertEqual(ranked?.title, "The Dark Knight")
        XCTAssertEqual(ranked?.year, 2019)
    }

    func testRankItOnTrendingFiresClosure() async {
        var ranked: Movie?
        let model = makeModel()
        model.bindRankIt { ranked = $0 }
        model.rankIt(trending("tmdb_13", title: "Forrest Gump"))
        XCTAssertEqual(ranked?.id, "tmdb_13")
        XCTAssertEqual(ranked?.title, "Forrest Gump")
    }

    // MARK: - 6. section independence (engine loads regardless of social state)

    /// The engine + New Releases sections are auth-gated independently of the
    /// social sections — a no-friends viewer still gets engine suggestions.
    func testEngineLoadsIndependentlyOfSocialState() async {
        let model = makeModel(
            loadRecs: { [] }, loadTrending: { [] }, hasFriends: { false },
            loadEngine: { _, _ in self.items(3) }
        )
        await model.reload()
        await model.loadEngineIfNeeded()
        XCTAssertEqual(model.state, .noFriends, "social is empty → no-friends")
        XCTAssertEqual(model.engineItems.count, 3, "engine still loaded")
    }

    // MARK: - 7. wire-401 → empty (Important 1)

    /// A wire HTTP 401 must land `.empty`, NOT `.error`. Retry would 401 again,
    /// so the error banner + retry affordance is wrong here — web maps wire
    /// 401 → empty at this seam. (Distinct from `notAuthenticated`, which is a
    /// pre-network client-side throw; 401 is the server's wire response.)
    func testEngineHttp401BecomesEmpty() async {
        let model = makeModel(loadEngine: { _, _ in
            throw SuggestionsClient.SuggestionsError.http(status: 401)
        })
        await model.loadEngineIfNeeded()
        XCTAssertEqual(model.engineState, .empty,
                       "wire HTTP 401 must be empty, not error — retry would 401 again")
    }

    // MARK: - 8. social card id normalization (Important 2 — B1 seam)

    /// Bare-numeric ids from legacy `user_rankings.tmdb_id` rows must be
    /// prefix-normalized to `tmdb_N` at the social-card mapper seam.
    func testNormalizeTmdbIdBareDigits() {
        XCTAssertEqual(DiscoverCardCopy.normalizeTmdbId("27205"), "tmdb_27205")
        XCTAssertEqual(DiscoverCardCopy.normalizeTmdbId("1"), "tmdb_1")
        XCTAssertEqual(DiscoverCardCopy.normalizeTmdbId("0"), "tmdb_0")
    }

    /// Already-prefixed ids must pass through unchanged.
    func testNormalizeTmdbIdAlreadyPrefixed() {
        XCTAssertEqual(DiscoverCardCopy.normalizeTmdbId("tmdb_27205"), "tmdb_27205")
        XCTAssertEqual(DiscoverCardCopy.normalizeTmdbId("tv_1399"), "tv_1399")
    }

    /// A bare-numeric `FriendRecommendation.tmdbId` (B1 legacy row) must produce
    /// a prefixed `WatchlistItem.id` at the mapper seam.
    func testWatchlistItemFromBareIdRecNormalizes() {
        let r = rec("27205", title: "Inception")
        let item = DiscoverCardCopy.watchlistItem(from: r)
        XCTAssertEqual(item.id, "tmdb_27205",
                       "bare-numeric tmdbId must be normalized at the watchlist-item seam")
    }

    /// A bare-numeric `TrendingMovie.tmdbId` (B1 legacy row) must produce a
    /// prefixed `WatchlistItem.id` at the mapper seam.
    func testWatchlistItemFromBareTrendingIdNormalizes() {
        let t = trending("872585", title: "Oppenheimer")
        let item = DiscoverCardCopy.watchlistItem(from: t)
        XCTAssertEqual(item.id, "tmdb_872585",
                       "bare-numeric tmdbId must be normalized at the watchlist-item seam")
    }

    /// Rank-it on a bare-id rec maps through the same normalizer, so the
    /// `Movie.id` that enters the rank ceremony is prefixed.
    func testRankItOnBareIdRecNormalizesMovieId() {
        var ranked: Movie?
        let model = makeModel()
        model.bindRankIt { ranked = $0 }
        model.rankIt(rec("496243", title: "Parasite"))
        XCTAssertEqual(ranked?.id, "tmdb_496243",
                       "bare-numeric id must be normalized before reaching the rank ceremony")
    }
}
