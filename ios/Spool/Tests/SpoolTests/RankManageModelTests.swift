import XCTest
@testable import Spool

/// Pure-logic pins for the C4 edit-mode drag-to-reorder model
/// (`RankManageModel`, management-UI Task 3). Everything here runs with ZERO
/// network: the model's IO is injected as closures (same shape as
/// `WatchlistModel` / `JournalListModel`), so the edit-mode toggle, the
/// in-tier move, the no-op suppression, the full-membership reorder write, the
/// single `ranking_move` emission, and the revert-on-throw are all exercised
/// with fakes.
///
/// The load-bearing decisions each get a test:
///  1. edit-mode toggle flips `isEditing`.
///  2. a NO-OP drop (same position) → NO reorder call, NO emission.
///  3. a CHANGED drop → `reorderIO` called ONCE with the tier's FULL new
///     membership (via `TierOrder`) + emission fires ONCE.
///  4. a reorder throw → the tier's order REVERTS to the exact prior order,
///     an error toast fires, and NO emission fires.
@MainActor
final class RankManageModelTests: XCTestCase {

    // MARK: fixtures

    private func item(_ id: String, tier: Tier = .A, rank: Int, year: Int? = 2020) -> RankedItem {
        RankedItem(
            id: id, title: "Movie \(id)", year: year, director: "Someone",
            genres: ["Drama"], tier: tier, rank: rank, posterUrl: "http://p/\(id).jpg"
        )
    }

    /// Build a model seeded with `items`, overriding just the closures a given
    /// test cares about. `reorderIO` records `(media, tier, ids)`; `emitIO`
    /// records the emitted events; `toast` records `(text, level)`.
    private func makeModel(
        items: [RankedItem],
        reorder: @escaping (String, String, [String]) async throws -> Void = { _, _, _ in },
        emit: @escaping (RankManageModel.MoveEvent) async -> Void = { _ in },
        toast: @escaping (String, ToastLevel) -> Void = { _, _ in }
    ) -> RankManageModel {
        let model = RankManageModel(reorder: reorder, emit: emit, toast: toast)
        model.setItems(items)
        return model
    }

    // MARK: - 1. edit-mode toggle

    func testToggleEditingFlipsState() {
        let model = makeModel(items: [item("a", rank: 0), item("b", rank: 1)])
        XCTAssertFalse(model.isEditing)

        model.toggleEditing()
        XCTAssertTrue(model.isEditing)

        model.toggleEditing()
        XCTAssertFalse(model.isEditing)
    }

    func testSetItemsGroupsByTierBestFirst() {
        let model = makeModel(items: [
            item("a", tier: .A, rank: 1),
            item("b", tier: .A, rank: 0),
            item("s", tier: .S, rank: 0),
        ])
        // Grouped by tier, each section sorted by rank ascending (best first).
        XCTAssertEqual(model.items(in: .A).map(\.id), ["b", "a"])
        XCTAssertEqual(model.items(in: .S).map(\.id), ["s"])
        XCTAssertEqual(model.items(in: .B).map(\.id), [])
    }

    // MARK: - 2. no-op drop

    func testNoOpDropDoesNothing() async {
        var reorderCalls: [(String, String, [String])] = []
        var emitCount = 0
        let model = makeModel(
            items: [item("a", rank: 0), item("b", rank: 1), item("c", rank: 2)],
            reorder: { m, t, ids in reorderCalls.append((m, t, ids)) },
            emit: { _ in emitCount += 1 }
        )

        // A move of index 1 to index 1 is a no-op (SwiftUI .onMove passes the
        // destination AFTER removal; from==to means unchanged order).
        await model.moveRow(tier: .A, from: IndexSet(integer: 1), to: 1)

        XCTAssertTrue(reorderCalls.isEmpty, "no-op drop must not hit the RPC")
        XCTAssertEqual(emitCount, 0, "no-op drop must not emit")
        XCTAssertEqual(model.items(in: .A).map(\.id), ["a", "b", "c"])
    }

    func testNoOpDropWhenDestinationEqualsSourcePlusOne() async {
        // SwiftUI passes `to == from + 1` when the row is dropped back in place
        // (destination is computed BEFORE removal); this must also be a no-op.
        var reorderCalls = 0
        var emitCount = 0
        let model = makeModel(
            items: [item("a", rank: 0), item("b", rank: 1), item("c", rank: 2)],
            reorder: { _, _, _ in reorderCalls += 1 },
            emit: { _ in emitCount += 1 }
        )

        await model.moveRow(tier: .A, from: IndexSet(integer: 1), to: 2)

        XCTAssertEqual(reorderCalls, 0)
        XCTAssertEqual(emitCount, 0)
        XCTAssertEqual(model.items(in: .A).map(\.id), ["a", "b", "c"])
    }

    // MARK: - 3. changed drop → full membership + single emission

    func testChangedDropCallsReorderWithFullMembershipAndEmitsOnce() async {
        var reorderCalls: [(String, String, [String])] = []
        var emitted: [RankManageModel.MoveEvent] = []
        let model = makeModel(
            items: [item("a", rank: 0), item("b", rank: 1), item("c", rank: 2)],
            reorder: { m, t, ids in reorderCalls.append((m, t, ids)) },
            emit: { emitted.append($0) }
        )

        // Move "c" (index 2) to the front (destination 0).
        await model.moveRow(tier: .A, from: IndexSet(integer: 2), to: 0)

        // Optimistic order applied.
        XCTAssertEqual(model.items(in: .A).map(\.id), ["c", "a", "b"])
        // ONE reorder call, movies, tier A, the tier's FULL new membership.
        XCTAssertEqual(reorderCalls.count, 1)
        XCTAssertEqual(reorderCalls.first?.0, "movie")
        XCTAssertEqual(reorderCalls.first?.1, "A")
        XCTAssertEqual(reorderCalls.first?.2, ["c", "a", "b"])
        // ONE emission for the moved item.
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.tmdbId, "c")
        XCTAssertEqual(emitted.first?.tier, "A")
        XCTAssertEqual(emitted.first?.year, "2020")
    }

    func testChangedDropLaterInTierUsesTierOrderSemantics() async {
        var reorderIds: [String] = []
        let model = makeModel(
            items: [item("a", rank: 0), item("b", rank: 1), item("c", rank: 2), item("d", rank: 3)],
            reorder: { _, _, ids in reorderIds = ids }
        )

        // Move "a" (0) toward the end: SwiftUI destination 3 (before removal).
        await model.moveRow(tier: .A, from: IndexSet(integer: 0), to: 3)

        // Matches TierOrder.tierOrderAfterReorder(from:0,to:2) → a lands before d.
        XCTAssertEqual(reorderIds, ["b", "c", "a", "d"])
        XCTAssertEqual(model.items(in: .A).map(\.id), ["b", "c", "a", "d"])
    }

    func testEmissionCarriesMovedItemMediaColumns() async {
        var emitted: [RankManageModel.MoveEvent] = []
        let model = makeModel(
            items: [
                item("a", rank: 0, year: 1999),
                item("b", rank: 1, year: nil),
            ],
            emit: { emitted.append($0) }
        )

        await model.moveRow(tier: .A, from: IndexSet(integer: 1), to: 0)

        XCTAssertEqual(emitted.count, 1)
        let ev = emitted.first
        XCTAssertEqual(ev?.tmdbId, "b")
        XCTAssertEqual(ev?.title, "Movie b")
        XCTAssertEqual(ev?.tier, "A")
        XCTAssertEqual(ev?.posterUrl, "http://p/b.jpg")
        // year nil on the moved item → nil on the event (metadata omits it).
        XCTAssertNil(ev?.year)
        // notes is never carried by a drag reorder (RankedItem has none).
        XCTAssertNil(ev?.notes)
    }

    // MARK: - 4. reorder throw → revert + toast, no emission

    func testReorderThrowRevertsToExactPriorOrderAndToasts() async {
        struct Boom: Error {}
        var toasts: [(String, ToastLevel)] = []
        var emitCount = 0
        let model = makeModel(
            items: [item("a", rank: 0), item("b", rank: 1), item("c", rank: 2)],
            reorder: { _, _, _ in throw Boom() },
            emit: { _ in emitCount += 1 },
            toast: { text, level in toasts.append((text, level)) }
        )

        await model.moveRow(tier: .A, from: IndexSet(integer: 2), to: 0)

        // The optimistic order is REVERTED to the exact prior order.
        XCTAssertEqual(model.items(in: .A).map(\.id), ["a", "b", "c"])
        // An error toast fired.
        XCTAssertEqual(toasts.count, 1)
        XCTAssertEqual(toasts.first?.1, .error)
        // NO emission on a failed write.
        XCTAssertEqual(emitCount, 0)
    }

    func testReorderThrowRevertsOnlyTheAffectedTier() async {
        struct Boom: Error {}
        let model = makeModel(
            items: [
                item("s1", tier: .S, rank: 0),
                item("a", tier: .A, rank: 0), item("b", tier: .A, rank: 1),
            ],
            reorder: { _, _, _ in throw Boom() }
        )

        await model.moveRow(tier: .A, from: IndexSet(integer: 1), to: 0)

        // A tier untouched by the failed move keeps its order.
        XCTAssertEqual(model.items(in: .S).map(\.id), ["s1"])
        XCTAssertEqual(model.items(in: .A).map(\.id), ["a", "b"])
    }

    // MARK: - edge cases

    func testMoveOnUnknownOrEmptyTierIsIgnored() async {
        var reorderCalls = 0
        let model = makeModel(
            items: [item("a", rank: 0)],
            reorder: { _, _, _ in reorderCalls += 1 }
        )

        // Tier B has no rows — a move there has no list to mutate.
        await model.moveRow(tier: .B, from: IndexSet(integer: 0), to: 1)

        XCTAssertEqual(reorderCalls, 0)
    }
}
