import XCTest
@testable import Spool

/// Pure aggregation tests for the social Discover screen (C3-iOS Part A,
/// Task 5) — the network-free `DiscoverAggregation` core. Mirrors web
/// `getFriendRecommendations` (`services/tasteService.ts:211-311`) and
/// `getTrendingAmongFriends` (`:316-398`) per the C3 audit §1.2.
///
/// Coverage per the brief:
///  - friend-rec aggregation: per-movie friendCount / avgTier / topTier,
///    viewer own-id exclusion (ranked ∪ watchlisted), sort (friendCount DESC
///    then avg tier S-best), tie cases,
///  - trending: distinct-ranker ≥2 threshold, sort + rank numbering,
///  - profile capping at 3 chips.
final class DiscoverContractTests: XCTestCase {

    // Deterministic UUIDs for rankers.
    private func u(_ n: Int) -> UUID {
        UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000\(String(format: "%02d", n))")!
    }

    private func row(_ tmdb: String, _ tier: String, _ user: Int,
                     title: String = "Movie", year: String? = "2000",
                     genres: [String] = ["Drama"], poster: String? = "p.jpg") -> DiscoverRankingRow {
        DiscoverRankingRow(tmdbId: tmdb, title: title, posterUrl: poster,
                           year: year, genres: genres, tier: tier, userId: u(user))
    }

    private func profile(_ user: Int, _ name: String, avatar: String? = nil) -> DiscoverProfileRow {
        DiscoverProfileRow(id: u(user), username: name, avatarPath: avatar)
    }

    /// Deterministic avatar builder for tests: "avatar://<username>".
    private func testAvatar(_ p: DiscoverProfileRow) -> String { "avatar://\(p.username)" }

    // MARK: - Tier helpers

    func testTierLabelRoundsAndClamps() {
        XCTAssertEqual(discoverTierLabel(5.0), "S")
        XCTAssertEqual(discoverTierLabel(4.4), "A")   // rounds to 4
        XCTAssertEqual(discoverTierLabel(4.5), "S")   // rounds to 5
        XCTAssertEqual(discoverTierLabel(1.0), "D")
        XCTAssertEqual(discoverTierLabel(0.2), "D")   // clamped to 1
        XCTAssertEqual(discoverTierLabel(9.9), "S")   // clamped to 5
    }

    // MARK: - Friend recommendations: aggregation

    /// Two friends both ranking the same movie → one card, friendCount 2,
    /// avgTier from the mean, topTier from the max.
    func testFriendRecsAggregatesPerMovie() {
        let rows = [
            row("tmdb_1", "S", 1),   // weight 5
            row("tmdb_1", "A", 2),   // weight 4
        ]
        let recs = DiscoverAggregation.friendRecommendations(
            rows: rows, excludedIds: [], profiles: [profile(1, "mei"), profile(2, "theo")],
            limit: 20, avatarURL: testAvatar
        )
        XCTAssertEqual(recs.count, 1)
        let card = recs[0]
        XCTAssertEqual(card.tmdbId, "tmdb_1")
        XCTAssertEqual(card.friendCount, 2)
        XCTAssertEqual(card.avgTierNumeric, 4.5)   // (5+4)/2
        XCTAssertEqual(card.avgTier, "S")          // 4.5 rounds to 5
        XCTAssertEqual(card.topTier, "S")          // best of {S, A} is S
    }

    /// topTier is the BEST (highest weight) tier any friend gave — S beats A.
    func testFriendRecsTopTierIsBest() {
        let rows = [row("tmdb_1", "S", 1), row("tmdb_1", "A", 2)]
        let recs = DiscoverAggregation.friendRecommendations(
            rows: rows, excludedIds: [], profiles: [], limit: 20, avatarURL: testAvatar
        )
        XCTAssertEqual(recs[0].topTier, "S")
    }

    /// A single friend's duplicate rows for the same movie do not double-count
    /// the friend — friendCount is DISTINCT rankers.
    func testFriendRecsDistinctFriendCount() {
        let rows = [
            row("tmdb_1", "S", 1),
            row("tmdb_1", "A", 1),   // same user, second row
            row("tmdb_1", "S", 2),
        ]
        let recs = DiscoverAggregation.friendRecommendations(
            rows: rows, excludedIds: [], profiles: [], limit: 20, avatarURL: testAvatar
        )
        XCTAssertEqual(recs[0].friendCount, 2)         // users 1 and 2
        XCTAssertEqual(recs[0].avgTierNumeric, 4.7)    // (5+4+5)/3 = 4.666 → 4.7
    }

    // MARK: - Friend recommendations: exclusion

    /// Movies whose id is in the viewer's owned set (ranked ∪ watchlisted) are
    /// excluded entirely (`tasteService.ts:253`).
    func testFriendRecsExcludesViewerOwnedIds() {
        let rows = [
            row("tmdb_1", "S", 1),
            row("tmdb_2", "S", 1),   // viewer already ranked this
            row("tmdb_3", "A", 2),   // viewer watchlisted this
        ]
        let recs = DiscoverAggregation.friendRecommendations(
            rows: rows, excludedIds: ["tmdb_2", "tmdb_3"], profiles: [], limit: 20, avatarURL: testAvatar
        )
        XCTAssertEqual(recs.map(\.tmdbId), ["tmdb_1"])
    }

    /// Exclusion is a canonical exact-string compare on the `tmdb_` id — a
    /// bare-numeric id does NOT match a `tmdb_`-prefixed exclusion (B1 quirk
    /// preserved: the compare is verbatim, not normalized here).
    func testFriendRecsExclusionIsVerbatimStringCompare() {
        let rows = [row("603", "S", 1)]                       // bare id ranking
        let recs = DiscoverAggregation.friendRecommendations(
            rows: rows, excludedIds: ["tmdb_603"], profiles: [], limit: 20, avatarURL: testAvatar
        )
        XCTAssertEqual(recs.count, 1, "bare id does not match tmdb_ exclusion (B1)")
    }

    // MARK: - Friend recommendations: sort + ties

    /// Sort is friendCount DESC first: a 3-friend movie outranks a 2-friend
    /// movie even when the latter has a higher average tier.
    func testFriendRecsSortsByFriendCountFirst() {
        let rows = [
            // tmdb_hi: 2 friends, both S → avg 5.0
            row("tmdb_hi", "S", 1), row("tmdb_hi", "S", 2),
            // tmdb_pop: 3 friends, all B → avg 3.0
            row("tmdb_pop", "B", 3), row("tmdb_pop", "B", 4), row("tmdb_pop", "B", 5),
        ]
        let recs = DiscoverAggregation.friendRecommendations(
            rows: rows, excludedIds: [], profiles: [], limit: 20, avatarURL: testAvatar
        )
        XCTAssertEqual(recs.map(\.tmdbId), ["tmdb_pop", "tmdb_hi"])
    }

    /// Tie on friendCount → higher average tier wins (S best).
    func testFriendRecsTieBreaksOnAvgTier() {
        let rows = [
            row("tmdb_lo", "B", 1), row("tmdb_lo", "B", 2),   // 2 friends, avg 3.0
            row("tmdb_hi", "S", 3), row("tmdb_hi", "A", 4),   // 2 friends, avg 4.5
        ]
        let recs = DiscoverAggregation.friendRecommendations(
            rows: rows, excludedIds: [], profiles: [], limit: 20, avatarURL: testAvatar
        )
        XCTAssertEqual(recs.map(\.tmdbId), ["tmdb_hi", "tmdb_lo"])
    }

    /// Full tie (same friendCount AND same avg tier) keeps first-seen order —
    /// a stable sort, matching JS `Array.sort` stability.
    func testFriendRecsFullTieKeepsFirstSeenOrder() {
        let rows = [
            row("tmdb_first", "S", 1), row("tmdb_first", "S", 2),
            row("tmdb_second", "S", 3), row("tmdb_second", "S", 4),
        ]
        let recs = DiscoverAggregation.friendRecommendations(
            rows: rows, excludedIds: [], profiles: [], limit: 20, avatarURL: testAvatar
        )
        XCTAssertEqual(recs.map(\.tmdbId), ["tmdb_first", "tmdb_second"])
    }

    /// `limit` caps the result count after sorting.
    func testFriendRecsRespectsLimit() {
        let rows = [
            row("tmdb_a", "S", 1), row("tmdb_a", "S", 2), row("tmdb_a", "S", 3),  // 3 friends
            row("tmdb_b", "S", 1), row("tmdb_b", "S", 2),                          // 2 friends
            row("tmdb_c", "S", 1),                                                 // 1 friend
        ]
        let recs = DiscoverAggregation.friendRecommendations(
            rows: rows, excludedIds: [], profiles: [], limit: 2, avatarURL: testAvatar
        )
        XCTAssertEqual(recs.map(\.tmdbId), ["tmdb_a", "tmdb_b"])
    }

    // MARK: - Friend recommendations: profile capping

    /// A card carries at most 3 friend chips even when more friends ranked it,
    /// in first-seen order, mapped through the injected avatar builder.
    func testFriendRecsCapsChipsAtThree() {
        let rows = [
            row("tmdb_1", "S", 1), row("tmdb_1", "S", 2),
            row("tmdb_1", "S", 3), row("tmdb_1", "S", 4), row("tmdb_1", "S", 5),
        ]
        let profiles = [profile(1, "a"), profile(2, "b"), profile(3, "c"),
                        profile(4, "d"), profile(5, "e")]
        let recs = DiscoverAggregation.friendRecommendations(
            rows: rows, excludedIds: [], profiles: profiles, limit: 20, avatarURL: testAvatar
        )
        XCTAssertEqual(recs[0].friendCount, 5, "count reflects ALL rankers")
        XCTAssertEqual(recs[0].friends.count, 3, "but only 3 chips render")
        XCTAssertEqual(recs[0].friends.map(\.username), ["a", "b", "c"])
        XCTAssertEqual(recs[0].friends.map(\.avatarUrl),
                       ["avatar://a", "avatar://b", "avatar://c"])
    }

    /// A ranker with no matching profile row still yields a chip (empty
    /// username, avatar built from an empty profile) — no crash, no drop.
    func testFriendRecsMissingProfileYieldsChip() {
        let rows = [row("tmdb_1", "S", 1), row("tmdb_1", "S", 2)]
        let recs = DiscoverAggregation.friendRecommendations(
            rows: rows, excludedIds: [], profiles: [profile(1, "known")],
            limit: 20, avatarURL: testAvatar
        )
        XCTAssertEqual(recs[0].friends.count, 2)
        XCTAssertEqual(recs[0].friends[0].username, "known")
        XCTAssertEqual(recs[0].friends[1].username, "")
    }

    /// topGenres shows only the first two genres (audit §1.2 card field).
    func testFriendRecsTopGenresCapsAtTwo() {
        let rows = [row("tmdb_1", "S", 1, genres: ["Action", "Sci-Fi", "Thriller"])]
        let recs = DiscoverAggregation.friendRecommendations(
            rows: rows, excludedIds: [], profiles: [], limit: 20, avatarURL: testAvatar
        )
        XCTAssertEqual(recs[0].topGenres, ["Action", "Sci-Fi"])
    }

    // MARK: - Trending: distinct-ranker threshold

    /// A movie ranked by only ONE friend never trends — the ≥2-distinct-ranker
    /// threshold (`tasteService.ts:377`).
    func testTrendingDropsSingleRankerMovies() {
        let rows = [
            row("tmdb_solo", "S", 1),                          // 1 ranker → dropped
            row("tmdb_duo", "S", 2), row("tmdb_duo", "A", 3),  // 2 rankers → kept
        ]
        let trending = DiscoverAggregation.trendingAmongFriends(
            rows: rows, profiles: [], limit: 15, avatarURL: testAvatar
        )
        XCTAssertEqual(trending.map(\.tmdbId), ["tmdb_duo"])
        XCTAssertEqual(trending[0].rankerCount, 2)
    }

    /// The SAME friend ranking a movie twice does not reach the threshold —
    /// rankerCount is distinct users, not row count.
    func testTrendingThresholdCountsDistinctRankers() {
        let rows = [row("tmdb_1", "S", 1), row("tmdb_1", "A", 1)]  // same user twice
        let trending = DiscoverAggregation.trendingAmongFriends(
            rows: rows, profiles: [], limit: 15, avatarURL: testAvatar
        )
        XCTAssertTrue(trending.isEmpty, "one distinct ranker never trends")
    }

    // MARK: - Trending: sort + rank numbering

    /// Trending sorts by rankerCount DESC and assigns 1-based ranks.
    func testTrendingSortsByRankerCountAndNumbers() {
        let rows = [
            // tmdb_two: 2 rankers
            row("tmdb_two", "S", 1), row("tmdb_two", "S", 2),
            // tmdb_three: 3 rankers
            row("tmdb_three", "B", 3), row("tmdb_three", "B", 4), row("tmdb_three", "B", 5),
        ]
        let trending = DiscoverAggregation.trendingAmongFriends(
            rows: rows, profiles: [], limit: 15, avatarURL: testAvatar
        )
        XCTAssertEqual(trending.map(\.tmdbId), ["tmdb_three", "tmdb_two"])
        XCTAssertEqual(trending.map(\.rank), [1, 2])
    }

    /// Tie on rankerCount → higher avg tier wins.
    func testTrendingTieBreaksOnAvgTier() {
        let rows = [
            row("tmdb_lo", "C", 1), row("tmdb_lo", "C", 2),   // avg 2.0
            row("tmdb_hi", "S", 3), row("tmdb_hi", "S", 4),   // avg 5.0
        ]
        let trending = DiscoverAggregation.trendingAmongFriends(
            rows: rows, profiles: [], limit: 15, avatarURL: testAvatar
        )
        XCTAssertEqual(trending.map(\.tmdbId), ["tmdb_hi", "tmdb_lo"])
        XCTAssertEqual(trending.map(\.rank), [1, 2])
    }

    /// Trending caps ranker chips at 3 and respects limit.
    func testTrendingCapsChipsAndLimit() {
        let rows = [
            row("tmdb_1", "S", 1), row("tmdb_1", "S", 2), row("tmdb_1", "S", 3), row("tmdb_1", "S", 4),
            row("tmdb_2", "S", 1), row("tmdb_2", "S", 2), row("tmdb_2", "S", 3),
            row("tmdb_3", "S", 1), row("tmdb_3", "S", 2),
        ]
        let profiles = [profile(1, "a"), profile(2, "b"), profile(3, "c"), profile(4, "d")]
        let trending = DiscoverAggregation.trendingAmongFriends(
            rows: rows, profiles: profiles, limit: 2, avatarURL: testAvatar
        )
        XCTAssertEqual(trending.count, 2)
        XCTAssertEqual(trending[0].recentRankers.count, 3, "chips capped at 3")
        XCTAssertEqual(trending[0].recentRankers.map(\.username), ["a", "b", "c"])
    }

    // MARK: - Empty inputs

    func testEmptyInputsYieldEmptyResults() {
        XCTAssertTrue(DiscoverAggregation.friendRecommendations(
            rows: [], excludedIds: [], profiles: [], limit: 20, avatarURL: testAvatar).isEmpty)
        XCTAssertTrue(DiscoverAggregation.trendingAmongFriends(
            rows: [], profiles: [], limit: 15, avatarURL: testAvatar).isEmpty)
    }

    // MARK: - Card copy (pure formatting)

    func testMetaLineJoinsYearAndUpperGenres() {
        XCTAssertEqual(DiscoverCardCopy.metaLine(year: "2010", genres: ["Action", "Sci-Fi"]),
                       "2010 · ACTION · SCI-FI")
    }

    func testMetaLineOmitsBlankYear() {
        XCTAssertEqual(DiscoverCardCopy.metaLine(year: "", genres: ["Drama"]), "DRAMA")
        XCTAssertEqual(DiscoverCardCopy.metaLine(year: nil, genres: ["Drama"]), "DRAMA")
    }

    func testFriendCountLineSingularPlural() {
        XCTAssertEqual(DiscoverCardCopy.friendCountLine(1, avgTier: "S"), "1 friend · avg S")
        XCTAssertEqual(DiscoverCardCopy.friendCountLine(3, avgTier: "A"), "3 friends · avg A")
    }

    func testRankerCountLine() {
        XCTAssertEqual(DiscoverCardCopy.rankerCountLine(4, avgTier: "B"), "4 ranked · avg B")
    }
}

// MARK: - Model load choreography (no network — injected closures)

@MainActor
final class DiscoverModelTests: XCTestCase {

    private func rec(_ id: String) -> FriendRecommendation {
        FriendRecommendation(tmdbId: id, title: "t", posterUrl: nil, year: nil, genres: [],
                             avgTier: "A", avgTierNumeric: 4.0, friendCount: 1, topTier: "A", friends: [])
    }
    private func trend(_ id: String) -> TrendingMovie {
        TrendingMovie(rank: 1, tmdbId: id, title: "t", posterUrl: nil, year: nil, genres: [],
                      rankerCount: 2, avgTier: "A", avgTierNumeric: 4.0, recentRankers: [])
    }

    /// A successful load with content lands `.loaded` with both sections.
    func testLoadedStateCarriesBothSections() async {
        let model = DiscoverModel(
            loadRecs: { [self.rec("tmdb_1")] },
            loadTrending: { [self.trend("tmdb_2")] },
            hasFriends: { true }
        )
        await model.reload()
        guard case .loaded(let recs, let trending) = model.state else {
            return XCTFail("expected .loaded, got \(model.state)")
        }
        XCTAssertEqual(recs.map(\.tmdbId), ["tmdb_1"])
        XCTAssertEqual(trending.map(\.tmdbId), ["tmdb_2"])
    }

    /// Both sections empty AND no follows → `.noFriends` (nudge to follow).
    func testEmptyWithNoFollowsIsNoFriends() async {
        let model = DiscoverModel(loadRecs: { [] }, loadTrending: { [] }, hasFriends: { false })
        await model.reload()
        XCTAssertEqual(model.state, .noFriends)
    }

    /// Both sections empty BUT the viewer follows people → `.loaded([], [])`
    /// (the quiet "nothing new" state, NOT the no-friends nudge).
    func testEmptyWithFollowsIsLoadedEmpty() async {
        let model = DiscoverModel(loadRecs: { [] }, loadTrending: { [] }, hasFriends: { true })
        await model.reload()
        XCTAssertEqual(model.state, .loaded([], []))
    }

    /// A thrown read lands `.failed` (feed convention — distinct from empty).
    func testThrownReadIsFailed() async {
        struct Boom: Error {}
        let model = DiscoverModel(loadRecs: { throw Boom() }, loadTrending: { [] }, hasFriends: { true })
        await model.reload()
        XCTAssertEqual(model.state, .failed)
    }

    /// `loadIfNeeded` loads once; a second call is a no-op (keeps loaded state).
    func testLoadIfNeededLoadsOnce() async {
        var calls = 0
        let model = DiscoverModel(
            loadRecs: { calls += 1; return [] },
            loadTrending: { [] },
            hasFriends: { true }
        )
        await model.loadIfNeeded()
        await model.loadIfNeeded()
        XCTAssertEqual(calls, 1)
    }
}
