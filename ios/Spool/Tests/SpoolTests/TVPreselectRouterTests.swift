import XCTest
@testable import Spool

/// C5-iOS Task 6 — the pure TV preselect router (`TVPreselectRouter`), a Swift
/// port of web `resolveTVPreselectRoute` / `healTVPreselect` / `showTmdbIdFromTVId`
/// (`services/watchlistRankHelpers.ts`). The router decides whether a
/// rank-from-watchlist TV bookmark opens the season grid first or drops straight
/// into the ceremony, and derives/heals the real numeric show id from the id when
/// a legacy corrupt row carries `show_tmdb_id = 0`.
///
/// The matrix covers: whole-show → season grid, season → tier, legacy corrupt-id
/// heal (both classes), and the non-TV / malformed passthrough.
final class TVPreselectRouterTests: XCTestCase {

    // MARK: - showTmdbIdFromTVId (id → numeric show id)

    func testShowIdDerivedFromWholeShowId() {
        XCTAssertEqual(TVPreselectRouter.showTmdbIdFromTVId("tv_1399"), 1399)
    }

    func testShowIdDerivedFromSeasonId() {
        XCTAssertEqual(TVPreselectRouter.showTmdbIdFromTVId("tv_1399_s3"), 1399)
    }

    func testShowIdNilForMovieId() {
        XCTAssertNil(TVPreselectRouter.showTmdbIdFromTVId("tmdb_603"))
    }

    func testShowIdNilForBookId() {
        XCTAssertNil(TVPreselectRouter.showTmdbIdFromTVId("ol_OL27448W"))
    }

    func testShowIdNilForMalformedTVIds() {
        XCTAssertNil(TVPreselectRouter.showTmdbIdFromTVId("tv_"))
        XCTAssertNil(TVPreselectRouter.showTmdbIdFromTVId("tv_abc"))
        XCTAssertNil(TVPreselectRouter.showTmdbIdFromTVId("tv_1399_s"))
        XCTAssertNil(TVPreselectRouter.showTmdbIdFromTVId("tv_1399_sx"))
        XCTAssertNil(TVPreselectRouter.showTmdbIdFromTVId("tv_abc_s1"))
    }

    // MARK: - whole-show → season grid

    /// A whole-show bookmark (real showTmdbId, no seasonNumber) opens the grid.
    func testWholeShowWithRealIdRoutesToSeasonGrid() {
        let r = TVPreselectRouter.resolve(
            .init(id: "tv_1399", showTmdbId: 1399, seasonNumber: nil))
        XCTAssertEqual(r?.route, .seasonGrid)
        XCTAssertEqual(r?.showTmdbId, 1399)
    }

    /// seasonNumber == 0 is a whole-show sentinel (web `?? 0` writer) → grid.
    func testWholeShowWithZeroSeasonRoutesToSeasonGrid() {
        let r = TVPreselectRouter.resolve(
            .init(id: "tv_1399", showTmdbId: 1399, seasonNumber: 0))
        XCTAssertEqual(r?.route, .seasonGrid)
        XCTAssertEqual(r?.showTmdbId, 1399)
    }

    // MARK: - season → tier (ceremony direct)

    func testSeasonBookmarkRoutesStraightToTier() {
        let r = TVPreselectRouter.resolve(
            .init(id: "tv_1399_s3", showTmdbId: 1399, seasonNumber: 3))
        XCTAssertEqual(r?.route, .tier)
        XCTAssertEqual(r?.showTmdbId, 1399)
    }

    // MARK: - legacy corrupt-id heal

    /// B1 corrupt row: showTmdbId=0 but a well-formed whole-show id. The old
    /// truthiness check would skip the grid + mint a season-less tv_1399 row;
    /// the router derives 1399 from the id AND still routes to the grid.
    func testCorruptWholeShowIdHealsAndRoutesToSeasonGrid() {
        let r = TVPreselectRouter.resolve(
            .init(id: "tv_1399", showTmdbId: 0, seasonNumber: nil))
        XCTAssertEqual(r?.route, .seasonGrid)
        XCTAssertEqual(r?.showTmdbId, 1399, "derived from the id, not the 0 field")
    }

    /// B1 corrupt season row: showTmdbId=0 but a well-formed season id. Routes
    /// to tier (season already known) with the DERIVED real show id so the
    /// global-score fetch + completion never re-mint corruption.
    func testCorruptSeasonIdHealsShowIdForTierRoute() {
        let r = TVPreselectRouter.resolve(
            .init(id: "tv_1399_s2", showTmdbId: 0, seasonNumber: 2))
        XCTAssertEqual(r?.route, .tier)
        XCTAssertEqual(r?.showTmdbId, 1399, "derived from the season id")
    }

    /// A whole-show preselect whose id is unparseable AND field is 0 has no
    /// resolvable show id → it cannot route to the grid (would mint a 0 row);
    /// falls through to tier with a nil show id (caller guards a nil id).
    func testUnresolvableWholeShowFallsThroughToTier() {
        let r = TVPreselectRouter.resolve(
            .init(id: "tv_bad", showTmdbId: 0, seasonNumber: nil))
        XCTAssertEqual(r?.route, .tier)
        XCTAssertNil(r?.showTmdbId)
    }

    // MARK: - nil / passthrough

    func testNilPreselectResolvesNil() {
        XCTAssertNil(TVPreselectRouter.resolve(nil))
    }

    /// A movie-shaped preselect (no tv id, no show id) is never whole-show.
    func testMovieShapedPreselectRoutesToTier() {
        let r = TVPreselectRouter.resolve(
            .init(id: "tmdb_603", showTmdbId: nil, seasonNumber: nil))
        XCTAssertEqual(r?.route, .tier)
        XCTAssertNil(r?.showTmdbId)
    }

    // MARK: - heal(itemShowTmdbId:route:)

    /// Route derived a real id, item had 0 → heal to the derived id.
    func testHealStampsDerivedIdOntoCorruptItem() {
        let route = TVPreselectRouter.Resolution(route: .tier, showTmdbId: 1399)
        XCTAssertEqual(TVPreselectRouter.heal(itemShowTmdbId: 0, route: route), 1399)
    }

    /// Item already valid, route agrees → returns the valid id (idempotent).
    func testHealNoOpWhenItemAlreadyValid() {
        let route = TVPreselectRouter.Resolution(route: .tier, showTmdbId: 1399)
        XCTAssertEqual(TVPreselectRouter.heal(itemShowTmdbId: 1399, route: route), 1399)
    }

    /// Route produced no id but item has one → keep the item's id.
    func testHealKeepsItemIdWhenRouteHasNone() {
        let route = TVPreselectRouter.Resolution(route: .tier, showTmdbId: nil)
        XCTAssertEqual(TVPreselectRouter.heal(itemShowTmdbId: 1399, route: route), 1399)
    }

    /// Nil route → passthrough of the item's id.
    func testHealPassthroughWhenNoRoute() {
        XCTAssertEqual(TVPreselectRouter.heal(itemShowTmdbId: 42, route: nil), 42)
    }

    // MARK: - rankedSeasonNumbers (season grid disabled-state)

    func testRankedSeasonNumbersParsesThisShowsSeasons() {
        let ids = ["tv_1399_s1", "tv_1399_s3", "tv_1399_s10"]
        XCTAssertEqual(TVPreselectRouter.rankedSeasonNumbers(showTmdbId: 1399, rankedTVIds: ids),
                       [1, 3, 10])
    }

    func testRankedSeasonNumbersIgnoresOtherShowsAndShapes() {
        let ids = ["tv_1399_s1", "tv_9999_s2", "tv_1399", "tmdb_603", "ol_OL1W", "tv_1399_sx"]
        XCTAssertEqual(TVPreselectRouter.rankedSeasonNumbers(showTmdbId: 1399, rankedTVIds: ids),
                       [1], "only well-formed seasons of THIS show count")
    }

    func testRankedSeasonNumbersEmptyWhenNoneRanked() {
        XCTAssertTrue(
            TVPreselectRouter.rankedSeasonNumbers(showTmdbId: 1399, rankedTVIds: [] as [String]).isEmpty)
    }

    /// A show-id prefix collision (tv_13 vs tv_1399) must not leak: 1399's
    /// prefix is `tv_1399_s`, so `tv_13_s5` is not a season of 1399.
    func testRankedSeasonNumbersNoPrefixCollision() {
        let ids = ["tv_13_s5", "tv_1399_s2"]
        XCTAssertEqual(TVPreselectRouter.rankedSeasonNumbers(showTmdbId: 1399, rankedTVIds: ids),
                       [2])
    }
}
