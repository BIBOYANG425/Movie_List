import XCTest
@testable import Spool

/// Pure-logic pins for the C2 journal LIST (plan Task 5). Everything here runs
/// with ZERO network: `JournalListModel`'s IO is injected as closures (same
/// shape as `FeedFeedModel` / `TicketEngagementModel`), so `load`, `search`, and
/// the optimistic `toggleLike` are all exercised with fakes.
///
/// The four load-bearing pure decisions each get a test:
///  1. `applyLikeToggle` — like → +1/liked, unlike → -1 clamped ≥ 0.
///  2. batch liked-state mapping — `load()` sets `likedIDs` from ONE batched
///     `likedEntryIDs` read over the loaded ids (never a per-card probe).
///  3. mood-id → label resolution — `JournalConstants.moodLabel`.
///  4. search-vs-list mode switch — non-empty query → `.search`, empty → `.list`.
@MainActor
final class JournalListModelTests: XCTestCase {

    // Stable ids so we can assert exactly which rows / liked-state landed.
    private let e1 = UUID(uuidString: "11110000-0000-0000-0000-000000000001")!
    private let e2 = UUID(uuidString: "22220000-0000-0000-0000-000000000002")!
    private let e3 = UUID(uuidString: "33330000-0000-0000-0000-000000000003")!
    private let owner = UUID(uuidString: "0FFF0000-0000-0000-0000-0000000000FF")!

    private func row(id: UUID, title: String = "Movie", likeCount: Int = 0) -> JournalRow {
        JournalRow(
            id: id, user_id: owner, tmdb_id: "tmdb_\(title)", title: title,
            poster_url: nil, rating_tier: "A", review_text: "a review",
            contains_spoilers: false, mood_tags: ["moved"], vibe_tags: [],
            favorite_moments: [], standout_performances: [],
            watched_date: "2026-07-01", watched_location: nil, watched_with_user_ids: [],
            watched_platform: nil, is_rewatch: false, rewatch_note: nil,
            personal_takeaway: nil, photo_paths: [], visibility_override: nil,
            like_count: likeCount, created_at: "2026-07-01T00:00:00+00:00"
        )
    }

    private func searchRow(id: UUID, title: String) -> JournalSearchRow {
        JournalSearchRow(
            id: id, user_id: owner, tmdb_id: "tmdb_\(title)", title: title,
            poster_url: nil, rating_tier: "B", review_text: "found",
            contains_spoilers: false, mood_tags: [], vibe_tags: [],
            favorite_moments: [], standout_performances: [],
            watched_date: "2026-06-01", watched_location: nil, watched_with_user_ids: [],
            watched_platform: nil, is_rewatch: false, rewatch_note: nil,
            photo_paths: [], visibility_override: nil,
            like_count: 3, created_at: "2026-06-01T00:00:00+00:00",
            updated_at: "2026-06-02T00:00:00+00:00"
        )
    }

    /// Build a model with sensible no-op defaults; override just the closures a
    /// given test cares about.
    private func makeModel(
        listOwnEntries: @escaping () async throws -> [JournalRow] = { [] },
        likedEntryIDs: @escaping ([UUID]) async throws -> Set<UUID> = { _ in [] },
        search: @escaping (String) async throws -> [JournalSearchRow] = { _ in [] },
        toggleLike: @escaping (UUID, Bool) async throws -> Void = { _, _ in }
    ) -> JournalListModel {
        JournalListModel(
            listOwnEntries: listOwnEntries,
            likedEntryIDs: likedEntryIDs,
            search: search,
            toggleLike: toggleLike
        )
    }

    // MARK: - 1. applyLikeToggle (pure)

    func testApplyLikeToggleLikeAddsOneAndMarksLiked() {
        let (count, liked) = JournalListModel.applyLikeToggle(count: 4, liked: false)
        XCTAssertEqual(count, 5)
        XCTAssertTrue(liked)
    }

    func testApplyLikeToggleUnlikeSubtractsOneAndMarksUnliked() {
        let (count, liked) = JournalListModel.applyLikeToggle(count: 4, liked: true)
        XCTAssertEqual(count, 3)
        XCTAssertFalse(liked)
    }

    func testApplyLikeToggleUnlikeClampsAtZero() {
        // A stale zero-count row unliked must never go negative.
        let (count, liked) = JournalListModel.applyLikeToggle(count: 0, liked: true)
        XCTAssertEqual(count, 0)
        XCTAssertFalse(liked)
    }

    // MARK: - 2. load — batch liked-state (NOT per-card)

    func testLoadPopulatesEntriesAndBatchesLikedStateOverLoadedIDs() async {
        var likedCallArgs: [[UUID]] = []
        let model = makeModel(
            listOwnEntries: { [self.row(id: self.e1, title: "A"),
                               self.row(id: self.e2, title: "B"),
                               self.row(id: self.e3, title: "C")] },
            likedEntryIDs: { ids in
                likedCallArgs.append(ids)
                return [self.e2]   // only e2 is liked
            }
        )

        await model.load()

        XCTAssertEqual(model.entries.map(\.id), [e1, e2, e3])
        XCTAssertEqual(model.likedIDs, [e2])
        XCTAssertFalse(model.loadFailed)
        XCTAssertEqual(model.mode, .list)
        // The liked-state is fetched ONCE, batched over ALL loaded ids — never a
        // per-card call. Exactly one invocation carrying every loaded id.
        XCTAssertEqual(likedCallArgs.count, 1)
        XCTAssertEqual(Set(likedCallArgs.first ?? []), [e1, e2, e3])
    }

    func testLoadCatchesListFailureToEmptyAndFlagsLoadFailed() async {
        struct Boom: Error {}
        let model = makeModel(listOwnEntries: { throw Boom() })

        await model.load()

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.likedIDs.isEmpty)
        XCTAssertTrue(model.loadFailed)
    }

    func testLoadCatchesLikedFailureToEmptyLikesButKeepsEntries() async {
        struct Boom: Error {}
        let model = makeModel(
            listOwnEntries: { [self.row(id: self.e1, title: "A")] },
            likedEntryIDs: { _ in throw Boom() }
        )

        await model.load()

        // Entries still render; a liked-state read hiccup just means no cards
        // start pre-liked (feed convention: reads fail soft to empty).
        XCTAssertEqual(model.entries.map(\.id), [e1])
        XCTAssertTrue(model.likedIDs.isEmpty)
        XCTAssertFalse(model.loadFailed)
    }

    // MARK: - 3. mood-id → label

    func testMoodLabelResolution() {
        XCTAssertEqual(JournalConstants.moodLabel("moved"), "Moved")
        XCTAssertEqual(JournalConstants.moodLabel("heartbroken"), "Heartbroken")
        // Unknown id falls back to itself (never blank).
        XCTAssertEqual(JournalConstants.moodLabel("not_a_mood"), "not_a_mood")
    }

    // MARK: - 4. search-vs-list mode switch

    func testNonEmptyQuerySwitchesToSearchModeWithSearchRows() async {
        let model = makeModel(
            listOwnEntries: { [self.row(id: self.e1, title: "A")] },
            search: { q in
                XCTAssertEqual(q, "portrait")
                return [self.searchRow(id: self.e2, title: "Portrait")]
            }
        )
        await model.load()

        await model.search(query: "portrait")

        XCTAssertEqual(model.mode, .search)
        XCTAssertEqual(model.searchResults.map(\.id), [e2])
    }

    func testEmptyQueryReturnsToListMode() async {
        let model = makeModel(
            listOwnEntries: { [self.row(id: self.e1, title: "A")] },
            search: { _ in [self.searchRow(id: self.e2, title: "Portrait")] }
        )
        await model.load()
        await model.search(query: "portrait")
        XCTAssertEqual(model.mode, .search)

        // Clearing the field drops back to list mode; the list is untouched.
        await model.search(query: "   ")

        XCTAssertEqual(model.mode, .list)
        XCTAssertEqual(model.entries.map(\.id), [e1])
    }

    func testSearchCatchesFailureToEmptyResultsInSearchMode() async {
        struct Boom: Error {}
        let model = makeModel(search: { _ in throw Boom() })

        await model.search(query: "x")

        XCTAssertEqual(model.mode, .search)
        XCTAssertTrue(model.searchResults.isEmpty)
    }

    // MARK: - toggleLike (optimistic + revert)

    func testToggleLikeOptimisticallyLikesAndPersists() async {
        var toggleArgs: [(UUID, Bool)] = []
        let model = makeModel(
            listOwnEntries: { [self.row(id: self.e1, title: "A", likeCount: 2)] },
            toggleLike: { id, liked in toggleArgs.append((id, liked)) }
        )
        await model.load()
        XCTAssertFalse(model.likedIDs.contains(e1))

        await model.toggleLike(entryID: e1)

        XCTAssertTrue(model.likedIDs.contains(e1))
        XCTAssertEqual(model.likeCount(for: e1), 3)
        // The write closure receives the PRE-toggle liked state.
        XCTAssertEqual(toggleArgs.count, 1)
        XCTAssertEqual(toggleArgs.first?.0, e1)
        XCTAssertEqual(toggleArgs.first?.1, false)
    }

    func testToggleLikeRevertsOnThrow() async {
        struct Boom: Error {}
        let model = makeModel(
            listOwnEntries: { [self.row(id: self.e1, title: "A", likeCount: 2)] },
            toggleLike: { _, _ in throw Boom() }
        )
        await model.load()

        await model.toggleLike(entryID: e1)

        // The optimistic apply is reverted — count and liked-state snap back.
        XCTAssertFalse(model.likedIDs.contains(e1))
        XCTAssertEqual(model.likeCount(for: e1), 2)
    }

    func testToggleLikeUnlikeDecrementsAndPersists() async {
        var toggleArgs: [(UUID, Bool)] = []
        let model = makeModel(
            listOwnEntries: { [self.row(id: self.e1, title: "A", likeCount: 5)] },
            likedEntryIDs: { _ in [self.e1] },   // starts liked
            toggleLike: { id, liked in toggleArgs.append((id, liked)) }
        )
        await model.load()
        XCTAssertTrue(model.likedIDs.contains(e1))

        await model.toggleLike(entryID: e1)

        XCTAssertFalse(model.likedIDs.contains(e1))
        XCTAssertEqual(model.likeCount(for: e1), 4)
        XCTAssertEqual(toggleArgs.first?.1, true)   // pre-toggle state = liked
    }
}
