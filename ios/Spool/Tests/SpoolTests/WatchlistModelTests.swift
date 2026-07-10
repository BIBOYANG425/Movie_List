import XCTest
@testable import Spool

/// Pure-logic pins for the C3 watchlist TAB (Part A, Task 3). Everything here
/// runs with ZERO network: `WatchlistModel`'s IO is injected as closures (same
/// shape as `JournalListModel` / `FeedFeedModel`), so `load`, the media switch,
/// the optimistic `remove`, and the Rank It seam are all exercised with fakes.
///
/// The load-bearing decisions each get a test:
///  1. load success / empty / throw → the right `LoadState` per media type.
///  2. media switch reloads a not-yet-loaded type; cached type keeps state.
///  3. optimistic remove drops immediately, revert-on-error restores + toasts.
///  4. Rank It callback fires with the exact tapped item.
@MainActor
final class WatchlistModelTests: XCTestCase {

    // MARK: fixtures

    private func movie(_ id: String, title: String = "A Movie") -> WatchlistItem {
        WatchlistItem(
            id: id, title: title, year: "2020", posterUrl: "",
            mediaType: .movie, genres: ["Drama"], addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            director: "Someone"
        )
    }

    private func tv(_ id: String, title: String = "A Show") -> WatchlistItem {
        WatchlistItem(
            id: id, title: title, year: "2021", posterUrl: "",
            mediaType: .tv, genres: [], addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            showTmdbId: 1399, seasonNumber: 1
        )
    }

    private func book(_ id: String, title: String = "A Book") -> WatchlistItem {
        WatchlistItem(
            id: id, title: title, year: "2019", posterUrl: "",
            mediaType: .book, genres: [], addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            author: "An Author"
        )
    }

    /// Build a model with sensible no-op defaults; override just the closures a
    /// given test cares about.
    private func makeModel(
        list: @escaping (WatchlistMediaType) async throws -> [WatchlistItem] = { _ in [] },
        remove: @escaping (String, WatchlistMediaType) async throws -> Void = { _, _ in },
        toast: @escaping (String, ToastLevel) -> Void = { _, _ in },
        onRankIt: @escaping (WatchlistItem) -> Void = { _ in }
    ) -> WatchlistModel {
        WatchlistModel(list: list, remove: remove, toast: toast, onRankIt: onRankIt)
    }

    // MARK: - 1. load → LoadState

    func testLoadSuccessPopulatesLoadedState() async {
        let model = makeModel(list: { media in
            XCTAssertEqual(media, .movie)
            return [self.movie("tmdb_1"), self.movie("tmdb_2")]
        })

        await model.loadCurrent()

        XCTAssertEqual(model.selectedMedia, .movie)
        XCTAssertEqual(model.currentState, .loaded([movie("tmdb_1"), movie("tmdb_2")]))
        XCTAssertEqual(model.currentItems.map(\.id), ["tmdb_1", "tmdb_2"])
    }

    func testLoadEmptyRowsBecomesEmptyState() async {
        let model = makeModel(list: { _ in [] })

        await model.loadCurrent()

        XCTAssertEqual(model.currentState, .empty)
        XCTAssertTrue(model.currentItems.isEmpty)
    }

    func testLoadThrowBecomesFailedState() async {
        struct Boom: Error {}
        let model = makeModel(list: { _ in throw Boom() })

        await model.loadCurrent()

        // A thrown read is DISTINCT from empty — feed convention lets the tab
        // show an error state (retry) rather than "your watchlist is empty".
        XCTAssertEqual(model.currentState, .failed)
    }

    func testDefaultMediaIsMovie() {
        let model = makeModel()
        XCTAssertEqual(model.selectedMedia, .movie)
        // Before any load lands the state is .loading, not .empty.
        XCTAssertEqual(model.currentState, .loading)
    }

    // MARK: - 2. media switch

    func testSelectMediaLoadsNotYetLoadedType() async {
        var calls: [WatchlistMediaType] = []
        let model = makeModel(list: { media in
            calls.append(media)
            switch media {
            case .movie: return [self.movie("tmdb_1")]
            case .tv:    return [self.tv("tv_1399_s1")]
            case .book:  return []
            }
        })
        await model.loadCurrent()          // loads movie
        XCTAssertEqual(model.currentItems.map(\.id), ["tmdb_1"])

        await model.select(media: .tv)     // first tv appearance → loads tv

        XCTAssertEqual(model.selectedMedia, .tv)
        XCTAssertEqual(model.currentState, .loaded([tv("tv_1399_s1")]))
        XCTAssertEqual(calls, [.movie, .tv])
    }

    func testSelectAlreadyLoadedMediaKeepsCachedStateNoRefetch() async {
        var calls: [WatchlistMediaType] = []
        let model = makeModel(list: { media in
            calls.append(media)
            return media == .movie ? [self.movie("tmdb_1")] : [self.tv("tv_1")]
        })
        await model.loadCurrent()          // movie
        await model.select(media: .tv)     // tv loads once
        await model.select(media: .movie)  // back to movie — cached, no refetch
        await model.select(media: .tv)     // back to tv — cached, no refetch

        // Each type fetched EXACTLY once despite the back-and-forth.
        XCTAssertEqual(calls, [.movie, .tv])
        XCTAssertEqual(model.selectedMedia, .tv)
        XCTAssertEqual(model.currentItems.map(\.id), ["tv_1"])
    }

    func testSelectSameMediaIsNoOp() async {
        var calls = 0
        let model = makeModel(list: { _ in calls += 1; return [self.movie("tmdb_1")] })
        await model.loadCurrent()          // 1 call
        await model.select(media: .movie)  // same media → no-op

        XCTAssertEqual(calls, 1)
    }

    func testReloadAlwaysRefetchesCurrentMedia() async {
        var calls = 0
        let model = makeModel(list: { _ in calls += 1; return [self.movie("tmdb_\(calls)")] })
        await model.loadCurrent()          // 1
        await model.reload()               // 2 — always refetches

        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.currentItems.map(\.id), ["tmdb_2"])
    }

    // MARK: - 3. optimistic remove + revert

    func testRemoveOptimisticallyDropsRowAndPersists() async {
        var removeArgs: [(String, WatchlistMediaType)] = []
        let model = makeModel(
            list: { _ in [self.movie("tmdb_1"), self.movie("tmdb_2"), self.movie("tmdb_3")] },
            remove: { id, media in removeArgs.append((id, media)) }
        )
        await model.loadCurrent()

        await model.remove(item: movie("tmdb_2"))

        XCTAssertEqual(model.currentItems.map(\.id), ["tmdb_1", "tmdb_3"])
        XCTAssertEqual(removeArgs.count, 1)
        XCTAssertEqual(removeArgs.first?.0, "tmdb_2")
        XCTAssertEqual(removeArgs.first?.1, .movie)
    }

    func testRemoveLastRowTransitionsToEmpty() async {
        let model = makeModel(list: { _ in [self.movie("tmdb_1")] })
        await model.loadCurrent()

        await model.remove(item: movie("tmdb_1"))

        XCTAssertEqual(model.currentState, .empty)
    }

    func testRemoveRevertsRowToOriginalIndexOnThrowAndToasts() async {
        struct Boom: Error {}
        var toasts: [(String, ToastLevel)] = []
        let model = makeModel(
            list: { _ in [self.movie("tmdb_1"), self.movie("tmdb_2", title: "Middle"), self.movie("tmdb_3")] },
            remove: { _, _ in throw Boom() },
            toast: { text, level in toasts.append((text, level)) }
        )
        await model.loadCurrent()

        await model.remove(item: movie("tmdb_2", title: "Middle"))

        // The optimistic drop is reverted — the row snaps back at its original
        // index (1), not appended to the end.
        XCTAssertEqual(model.currentItems.map(\.id), ["tmdb_1", "tmdb_2", "tmdb_3"])
        // And the failure surfaces as an error toast naming the title.
        XCTAssertEqual(toasts.count, 1)
        XCTAssertEqual(toasts.first?.1, .error)
        XCTAssertTrue(toasts.first?.0.contains("Middle") ?? false)
    }

    func testRemoveRevertRestoresFromEmptyState() async {
        struct Boom: Error {}
        let model = makeModel(
            list: { _ in [self.movie("tmdb_1")] },   // single row → removes to .empty
            remove: { _, _ in throw Boom() }
        )
        await model.loadCurrent()

        await model.remove(item: movie("tmdb_1"))

        // The optimistic remove flipped to .empty; the revert must restore the
        // single row back into a .loaded state, not leave it stranded empty.
        XCTAssertEqual(model.currentState, .loaded([movie("tmdb_1")]))
    }

    func testRemoveOnNonLoadedStateIsIgnored() async {
        var removeCalled = false
        let model = makeModel(remove: { _, _ in removeCalled = true })
        // No load — state is .loading. A remove has no list to mutate.

        await model.remove(item: movie("tmdb_1"))

        XCTAssertFalse(removeCalled)
        XCTAssertEqual(model.currentState, .loading)
    }

    // MARK: - 4. Rank It seam

    func testRankItForwardsTheExactItem() {
        var ranked: [WatchlistItem] = []
        let model = makeModel(onRankIt: { ranked.append($0) })

        let item = movie("tmdb_42", title: "Rank Me")
        model.rankIt(item: item)

        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.id, "tmdb_42")
        XCTAssertEqual(ranked.first?.title, "Rank Me")
    }
}
