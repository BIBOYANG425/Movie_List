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
///  5. in-flight guard: a second drop while RPC is in flight is ignored.
///  6. rank renumber: after a confirmed drag `rank` fields match position.
///
/// `RankMoveEmitter.payload` wire shape is pinned separately at the bottom.
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
        // raw insertion index BEFORE removal; from==to means unchanged order
        // because toIndex = destination > fromIndex ? destination-1 : destination
        // → toIndex == fromIndex, which TierOrder resolves as a no-op).
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

    // MARK: - 5. in-flight guard

    func testSecondDropDuringInFlightRPCIsIgnored() async {
        // The RPC suspends until we resume the continuation, giving us a
        // window to fire the second drop while `isReordering` is true.
        var reorderCalls = 0
        var emitCount = 0
        let (stream, continuation) = AsyncStream<Void>.makeStream()

        let model = makeModel(
            items: [item("a", rank: 0), item("b", rank: 1), item("c", rank: 2)],
            reorder: { _, _, _ in
                reorderCalls += 1
                // Block until the test resumes us (simulates in-flight RPC).
                for await _ in stream { break }
            },
            emit: { _ in emitCount += 1 }
        )

        // Start the first drop but don't await it yet.
        let firstTask = Task { await model.moveRow(tier: .A, from: IndexSet(integer: 2), to: 0) }

        // Yield briefly so the first drop enters the RPC and sets isReordering.
        await Task.yield()
        await Task.yield()

        // Second drop while the first RPC is suspended — must be ignored.
        await model.moveRow(tier: .A, from: IndexSet(integer: 0), to: 2)

        // Unblock the first RPC.
        continuation.finish()
        await firstTask.value

        // Only ONE reorder call (the second drop was blocked by the guard).
        XCTAssertEqual(reorderCalls, 1, "second drop during in-flight RPC must be ignored")
        XCTAssertEqual(emitCount, 1, "only the first drop emits")
    }

    // MARK: - 6. rank renumber on confirmed drag

    func testRankRenumberedAfterConfirmedDrag() async {
        let model = makeModel(
            items: [item("a", rank: 0), item("b", rank: 1), item("c", rank: 2)]
        )

        // Move "c" (index 2) to the front (destination 0).
        await model.moveRow(tier: .A, from: IndexSet(integer: 2), to: 0)

        // After persist the ranks must be 0-based contiguous in the new order.
        let rows = model.items(in: .A)
        XCTAssertEqual(rows.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(rows.map(\.rank), [0, 1, 2], "ranks renumbered 0-based after confirmed drag")
    }

    func testRankNotRenumberedOnRevert() async {
        struct Boom: Error {}
        let model = makeModel(
            items: [item("a", rank: 0), item("b", rank: 1), item("c", rank: 2)],
            reorder: { _, _, _ in throw Boom() }
        )

        await model.moveRow(tier: .A, from: IndexSet(integer: 2), to: 0)

        // Reverted to prior order; original ranks preserved.
        let rows = model.items(in: .A)
        XCTAssertEqual(rows.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(rows.map(\.rank), [0, 1, 2])
    }

    // MARK: - menu action fixtures (Task 4)

    /// Build a model wired for the long-press context-menu actions. Records the
    /// cross-tier move call `(tmdbId, fromTier, toTier, atIndex)`, the notes
    /// update `(tmdbId, notes)`, the notes probe result, the delete call
    /// `(tmdbId, tier)`, the re-rank request item, the move/remove emissions,
    /// and toasts.
    private func makeMenuModel(
        items: [RankedItem],
        move: @escaping (String, String, String, String, Int?) async throws -> Void = { _, _, _, _, _ in },
        notesProbe: @escaping (String, String) async throws -> String? = { _, _ in nil },
        saveNotes: @escaping (String, String, String?) async throws -> Void = { _, _, _ in },
        delete: @escaping (String, String, String) async throws -> Void = { _, _, _ in },
        rerank: @escaping (RankedItem) -> Void = { _ in },
        emitMove: @escaping (RankManageModel.MoveEvent) async -> Void = { _ in },
        emitRemove: @escaping (RankManageModel.RemoveEvent) async -> Void = { _ in },
        toast: @escaping (String, ToastLevel) -> Void = { _, _ in }
    ) -> RankManageModel {
        let model = RankManageModel(
            reorder: { _, _, _ in },
            move: move,
            notesProbe: notesProbe,
            saveNotes: saveNotes,
            delete: delete,
            rerank: rerank,
            emit: emitMove,
            emitRemove: emitRemove,
            toast: toast
        )
        model.setItems(items)
        return model
    }

    // MARK: - move to tier

    func testMoveToTierRegroupsOptimisticallyAndCallsMoveOnce() async {
        var moveCalls: [(String, String, String, String, Int?)] = []
        var emitted: [RankManageModel.MoveEvent] = []
        let model = makeMenuModel(
            items: [
                item("a", tier: .A, rank: 0), item("b", tier: .A, rank: 1),
                item("s", tier: .S, rank: 0),
            ],
            move: { media, id, from, to, idx in moveCalls.append((media, id, from, to, idx)) },
            emitMove: { emitted.append($0) }
        )

        await model.moveTo(tier: .S, item: item("a", tier: .A, rank: 0))

        // "a" left A and appended to S's tail; A compacted + renumbered.
        XCTAssertEqual(model.items(in: .A).map(\.id), ["b"])
        XCTAssertEqual(model.items(in: .S).map(\.id), ["s", "a"])
        XCTAssertEqual(model.items(in: .A).map(\.rank), [0])
        XCTAssertEqual(model.items(in: .S).map(\.rank), [0, 1])
        // ONE move call: movie (default), append (atIndex nil) into S from A.
        XCTAssertEqual(moveCalls.count, 1)
        XCTAssertEqual(moveCalls.first?.0, "movie")
        XCTAssertEqual(moveCalls.first?.1, "a")
        XCTAssertEqual(moveCalls.first?.2, "A")
        XCTAssertEqual(moveCalls.first?.3, "S")
        XCTAssertNil(moveCalls.first?.4, "menu move always appends → atIndex nil")
    }

    func testMoveToTierEmitsSingleRankingMoveWithTargetTierAndYear() async {
        var emitted: [RankManageModel.MoveEvent] = []
        let model = makeMenuModel(
            items: [item("a", tier: .A, rank: 0, year: 1994)],
            emitMove: { emitted.append($0) }
        )

        await model.moveTo(tier: .B, item: item("a", tier: .A, rank: 0, year: 1994))

        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.tmdbId, "a")
        XCTAssertEqual(emitted.first?.tier, "B", "emission carries the TARGET tier")
        XCTAssertEqual(emitted.first?.year, "1994")
        XCTAssertNil(emitted.first?.notes, "menu move never carries notes")
    }

    func testMoveToTierRevertsAndToastsOnThrowNoEmission() async {
        struct Boom: Error {}
        var toasts: [(String, ToastLevel)] = []
        var emitCount = 0
        let model = makeMenuModel(
            items: [
                item("a", tier: .A, rank: 0), item("b", tier: .A, rank: 1),
                item("s", tier: .S, rank: 0),
            ],
            move: { _, _, _, _, _ in throw Boom() },
            emitMove: { _ in emitCount += 1 },
            toast: { t, l in toasts.append((t, l)) }
        )

        await model.moveTo(tier: .S, item: item("a", tier: .A, rank: 0))

        // Both tiers reverted to exactly their prior membership.
        XCTAssertEqual(model.items(in: .A).map(\.id), ["a", "b"])
        XCTAssertEqual(model.items(in: .S).map(\.id), ["s"])
        XCTAssertEqual(toasts.count, 1)
        XCTAssertEqual(toasts.first?.1, .error)
        XCTAssertEqual(emitCount, 0, "no emission on a failed move")
    }

    func testMoveToSameTierIsIgnored() async {
        var moveCalls = 0
        let model = makeMenuModel(
            items: [item("a", tier: .A, rank: 0), item("b", tier: .A, rank: 1)],
            move: { _, _, _, _, _ in moveCalls += 1 }
        )

        // Moving to the tier it already lives in is a no-op (the submenu hides
        // the current tier, but guard defensively).
        await model.moveTo(tier: .A, item: item("a", tier: .A, rank: 0))

        XCTAssertEqual(moveCalls, 0)
        XCTAssertEqual(model.items(in: .A).map(\.id), ["a", "b"])
    }

    // MARK: - edit notes (fetch-before-edit)

    func testFetchNotesReturnsSuccessWithProbeResult() async {
        let model = makeMenuModel(
            items: [item("a", rank: 0)],
            notesProbe: { _, id in id == "a" ? "loved the third act" : nil }
        )

        let result = await model.fetchNotes(item: item("a", rank: 0))
        XCTAssertEqual(result, .success("loved the third act"),
                       "sheet seeds from the live row's notes on a successful probe")
    }

    func testFetchNotesSuccessNilWhenColumnEmpty() async {
        let model = makeMenuModel(
            items: [item("a", rank: 0)],
            notesProbe: { _, _ in nil }   // column is empty
        )

        let result = await model.fetchNotes(item: item("a", rank: 0))
        XCTAssertEqual(result, .success(nil),
                       "nil column value is a successful probe — not a failure")
    }

    // RED-first (must fix): probe throws → result is .probeFailed, save blocked
    // for empty draft, toast fired. This is the silent-wipe guard.
    func testFetchNotesReturnsProbeFailedOnThrow() async {
        struct Boom: Error {}
        var toasts: [(String, ToastLevel)] = []
        let model = makeMenuModel(
            items: [item("a", rank: 0)],
            notesProbe: { _, _ in throw Boom() },
            toast: { t, l in toasts.append((t, l)) }
        )

        let result = await model.fetchNotes(item: item("a", rank: 0))

        // Result must be .probeFailed, not .success(nil).
        XCTAssertEqual(result, .probeFailed,
                       "probe throw must return .probeFailed, not degrade silently to nil")
        // A toast must fire so the failure is surfaced even before the sheet renders.
        XCTAssertEqual(toasts.count, 1)
        XCTAssertEqual(toasts.first?.1, .error,
                       "probe failure must toast at error level")
        XCTAssert(toasts.first?.0.contains("couldn't load") == true,
                  "toast message must mention inability to load the note, got: \(toasts.first?.0 ?? "")")
    }

    func testSaveNotesTrimsAndCallsUpdateNoEmission() async {
        var saveCalls: [(String, String?)] = []
        var emitMove = 0
        var emitRemove = 0
        let model = makeMenuModel(
            items: [item("a", rank: 0)],
            saveNotes: { _, id, notes in saveCalls.append((id, notes)) },
            emitMove: { _ in emitMove += 1 },
            emitRemove: { _ in emitRemove += 1 }
        )

        await model.saveNotes(item: item("a", rank: 0), notes: "  a great watch  ")

        XCTAssertEqual(saveCalls.count, 1)
        XCTAssertEqual(saveCalls.first?.0, "a")
        XCTAssertEqual(saveCalls.first?.1, "a great watch", "notes trimmed before persist")
        // A notes edit emits NO activity event (web has no standalone notes-edit
        // writer — notes only ride the ceremony's ranking_add/ranking_move).
        XCTAssertEqual(emitMove, 0)
        XCTAssertEqual(emitRemove, 0)
    }

    func testSaveNotesNormalizesBlankToNil() async {
        var saveCalls: [(String, String?)] = []
        let model = makeMenuModel(
            items: [item("a", rank: 0)],
            saveNotes: { _, id, notes in saveCalls.append((id, notes)) }
        )

        await model.saveNotes(item: item("a", rank: 0), notes: "   ")

        XCTAssertEqual(saveCalls.count, 1)
        XCTAssertNil(saveCalls.first?.1, "whitespace-only notes normalize to nil (clears the column)")
    }

    func testSaveNotesToastsOnThrow() async {
        struct Boom: Error {}
        var toasts: [(String, ToastLevel)] = []
        let model = makeMenuModel(
            items: [item("a", rank: 0)],
            saveNotes: { _, _, _ in throw Boom() },
            toast: { t, l in toasts.append((t, l)) }
        )

        await model.saveNotes(item: item("a", rank: 0), notes: "note")

        XCTAssertEqual(toasts.count, 1)
        XCTAssertEqual(toasts.first?.1, .error)
    }

    // MARK: - re-rank

    func testRequestRerankFiresClosureWithRawItemNoOrigin() async {
        var rerankItems: [RankedItem] = []
        let model = makeMenuModel(
            items: [item("a", tier: .A, rank: 0)],
            rerank: { rerankItems.append($0) }
        )

        model.requestRerank(item: item("a", tier: .A, rank: 0))

        XCTAssertEqual(rerankItems.count, 1)
        XCTAssertEqual(rerankItems.first?.id, "a")
        // The RAW item flows through untouched — no watchlist origin exists here.
        XCTAssertEqual(rerankItems.first?.tier, .A)
    }

    // MARK: - delete (confirm-gated at the view; model takes the confirmed action)

    func testDeleteRemovesOptimisticallyCallsDeleteAndEmitsRemoveOnce() async {
        var deleteCalls: [(String, String)] = []
        var removed: [RankManageModel.RemoveEvent] = []
        let model = makeMenuModel(
            items: [
                item("a", tier: .A, rank: 0), item("b", tier: .A, rank: 1),
                item("c", tier: .A, rank: 2),
            ],
            delete: { _, id, tier in deleteCalls.append((id, tier)) },
            emitRemove: { removed.append($0) }
        )

        await model.delete(item: item("b", tier: .A, rank: 1, year: 1999))

        // "b" gone; A compacted + renumbered.
        XCTAssertEqual(model.items(in: .A).map(\.id), ["a", "c"])
        XCTAssertEqual(model.items(in: .A).map(\.rank), [0, 1])
        // ONE delete call with the tier it lived in.
        XCTAssertEqual(deleteCalls.count, 1)
        XCTAssertEqual(deleteCalls.first?.0, "b")
        XCTAssertEqual(deleteCalls.first?.1, "A")
        // ONE ranking_remove emission with media columns + year.
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.tmdbId, "b")
        XCTAssertEqual(removed.first?.tier, "A")
        XCTAssertEqual(removed.first?.year, "1999")
        XCTAssertNil(removed.first?.notes, "shelf item carries no notes → nil")
    }

    func testDeleteRevertsAndToastsOnThrowNoEmission() async {
        struct Boom: Error {}
        var toasts: [(String, ToastLevel)] = []
        var removeCount = 0
        let model = makeMenuModel(
            items: [
                item("a", tier: .A, rank: 0), item("b", tier: .A, rank: 1),
                item("c", tier: .A, rank: 2),
            ],
            delete: { _, _, _ in throw Boom() },
            emitRemove: { _ in removeCount += 1 },
            toast: { t, l in toasts.append((t, l)) }
        )

        await model.delete(item: item("b", tier: .A, rank: 1))

        // The row is restored to its exact prior position (order + rank).
        XCTAssertEqual(model.items(in: .A).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(model.items(in: .A).map(\.rank), [0, 1, 2])
        XCTAssertEqual(toasts.count, 1)
        XCTAssertEqual(toasts.first?.1, .error)
        XCTAssertEqual(removeCount, 0, "no emission on a failed delete")
    }

    // MARK: - 7. media threading (C5 Task 2 — unpinned from "movie")

    /// The model defaults to the movie vertical so the C4 shelf keeps its
    /// current behaviour when no media is set.
    func testDefaultMediaIsMovie() {
        let model = makeModel(items: [item("a", rank: 0)])
        XCTAssertEqual(model.media, "movie")
    }

    /// A TV-seeded model threads `"tv"` into the reorder RPC (arg 1) instead of
    /// the hardcoded `"movie"` — the read/write for a tv shelf both hit
    /// `tv_rankings`.
    func testReorderThreadsSelectedMediaIntoRPC() async {
        var reorderCalls: [(String, String, [String])] = []
        let model = makeModel(
            items: [item("a", rank: 0), item("b", rank: 1), item("c", rank: 2)],
            reorder: { m, t, ids in reorderCalls.append((m, t, ids)) }
        )
        model.setMedia("tv")

        await model.moveRow(tier: .A, from: IndexSet(integer: 2), to: 0)

        XCTAssertEqual(reorderCalls.count, 1)
        XCTAssertEqual(reorderCalls.first?.0, "tv",
                       "reorder threads the selected media, not a hardcoded movie")
        XCTAssertEqual(reorderCalls.first?.2, ["c", "a", "b"])
    }

    /// A book-seeded model threads `"book"` into the cross-tier move IO.
    func testMoveToTierThreadsSelectedMediaIntoMoveIO() async {
        var moveCalls: [(String, String, String, String, Int?)] = []
        let model = makeMenuModel(
            items: [item("a", tier: .A, rank: 0), item("s", tier: .S, rank: 0)],
            move: { media, id, from, to, idx in moveCalls.append((media, id, from, to, idx)) }
        )
        model.setMedia("book")

        await model.moveTo(tier: .S, item: item("a", tier: .A, rank: 0))

        XCTAssertEqual(moveCalls.count, 1)
        XCTAssertEqual(moveCalls.first?.0, "book", "cross-tier move threads the selected media")
        XCTAssertEqual(moveCalls.first?.1, "a")
        XCTAssertEqual(moveCalls.first?.2, "A")
        XCTAssertEqual(moveCalls.first?.3, "S")
    }

    /// The delete IO threads the selected media so a tv/book delete compacts the
    /// right table.
    func testDeleteThreadsSelectedMediaIntoDeleteIO() async {
        var deleteCalls: [(String, String, String)] = []
        let model = makeMenuModel(
            items: [item("a", tier: .A, rank: 0), item("b", tier: .A, rank: 1)],
            delete: { media, id, tier in deleteCalls.append((media, id, tier)) }
        )
        model.setMedia("tv")

        await model.delete(item: item("b", tier: .A, rank: 1))

        XCTAssertEqual(deleteCalls.count, 1)
        XCTAssertEqual(deleteCalls.first?.0, "tv", "delete threads the selected media")
        XCTAssertEqual(deleteCalls.first?.1, "b")
        XCTAssertEqual(deleteCalls.first?.2, "A")
    }

    /// The notes probe + save IO thread the selected media so the fetch-before-
    /// edit + write hit the tv/book table.
    func testNotesProbeAndSaveThreadSelectedMedia() async {
        var probeMedia: [String] = []
        var saveMedia: [String] = []
        let model = makeMenuModel(
            items: [item("a", rank: 0)],
            notesProbe: { media, _ in probeMedia.append(media); return "existing" },
            saveNotes: { media, _, _ in saveMedia.append(media) }
        )
        model.setMedia("book")

        _ = await model.fetchNotes(item: item("a", rank: 0))
        await model.saveNotes(item: item("a", rank: 0), notes: "great read")

        XCTAssertEqual(probeMedia, ["book"], "notes probe threads the selected media")
        XCTAssertEqual(saveMedia, ["book"], "notes save threads the selected media")
    }

    // MARK: - 8. re-rank menu gating (C5 Task 6 — re-rank flipped ON for tv/book)

    /// Re-rank in the long-press menu is now offered for ALL known verticals: the
    /// media-generic ceremony (T5) lands in C5, so tv/book cards get re-rank and
    /// the completion routes per media. An unknown media string is still gated
    /// off so a malformed shelf never seeds a garbage ceremony.
    func testRerankMenuOfferedForAllKnownMedia() {
        XCTAssertTrue(RankManageModel.showsRerank(forMedia: "movie"),
                      "movie keeps re-rank")
        XCTAssertTrue(RankManageModel.showsRerank(forMedia: "tv"),
                      "tv re-rank is enabled now the ceremony exists (C5-T6)")
        XCTAssertTrue(RankManageModel.showsRerank(forMedia: "book"),
                      "book re-rank is enabled now the ceremony exists (C5-T6)")
        XCTAssertFalse(RankManageModel.showsRerank(forMedia: "podcast"),
                       "an unknown media is still gated off")
    }

    /// `requestRerank` fires the hand-off for a known media…
    func testRequestRerankFiresForKnownMedia() {
        var fired: [String] = []
        let model = makeMenuModel(items: [item("a", rank: 0)])
        model.bindRerank { fired.append($0.id) }
        model.setMedia("tv")
        model.requestRerank(item: item("a", rank: 0))
        XCTAssertEqual(fired, ["a"], "tv re-rank routes through the hand-off")
    }

    /// …and is a no-op for an unknown media (defense-in-depth media guard).
    func testRequestRerankNoOpForUnknownMedia() {
        var fired: [String] = []
        let model = makeMenuModel(items: [item("a", rank: 0)])
        model.bindRerank { fired.append($0.id) }
        model.setMedia("podcast")
        model.requestRerank(item: item("a", rank: 0))
        XCTAssertTrue(fired.isEmpty, "unknown media must not seed the ceremony")
    }

    // MARK: - 9. cross-media race guard (C5 Task 6)

    /// A mutable box so an injected IO closure can switch the SAME model's media
    /// mid-await — the shelf-switched-verticals race we guard against.
    private final class ModelBox { weak var model: RankManageModel? }

    /// A cross-tier move whose RPC is in flight while the shelf switches media
    /// must NOT write its (old-media) result onto the new media's tiers. The
    /// move IO flips `setMedia` mid-op, so the post-await guard skips the
    /// emission (and would skip a revert too).
    func testMoveToTierSkipsEmissionWhenMediaSwitchesMidFlight() async {
        var emitCount = 0
        let box = ModelBox()
        let model = RankManageModel(
            reorder: { _, _, _ in },
            move: { _, _, _, _, _ in box.model?.setMedia("tv") },   // switch mid-await
            notesProbe: { _, _ in nil },
            saveNotes: { _, _, _ in },
            delete: { _, _, _ in },
            rerank: { _ in },
            emit: { _ in emitCount += 1 },
            emitRemove: { _ in },
            toast: { _, _ in }
        )
        box.model = model
        model.setMedia("movie")
        model.setItems([item("a", tier: .A, rank: 0), item("s", tier: .S, rank: 0)])

        await model.moveTo(tier: .S, item: item("a", tier: .A, rank: 0))

        XCTAssertEqual(emitCount, 0,
                       "a move whose media switched mid-flight emits nothing")
        XCTAssertEqual(model.media, "tv", "the switch itself still took effect")
    }

    /// A move that does NOT switch media still emits — the guard only trips on a
    /// real mid-flight switch (control case).
    func testMoveToTierStillEmitsWhenMediaUnchanged() async {
        var emitCount = 0
        let model = makeMenuModel(
            items: [item("a", tier: .A, rank: 0), item("s", tier: .S, rank: 0)],
            emitMove: { _ in emitCount += 1 }
        )
        await model.moveTo(tier: .S, item: item("a", tier: .A, rank: 0))
        XCTAssertEqual(emitCount, 1, "a same-media move emits as normal")
    }

    /// A delete whose media switches mid-flight likewise skips its emission.
    func testDeleteSkipsEmissionWhenMediaSwitchesMidFlight() async {
        var removeEmitCount = 0
        let box = ModelBox()
        let model = RankManageModel(
            reorder: { _, _, _ in },
            move: { _, _, _, _, _ in },
            notesProbe: { _, _ in nil },
            saveNotes: { _, _, _ in },
            delete: { _, _, _ in box.model?.setMedia("tv") },   // switch mid-await
            rerank: { _ in },
            emit: { _ in },
            emitRemove: { _ in removeEmitCount += 1 },
            toast: { _, _ in }
        )
        box.model = model
        model.setMedia("movie")
        model.setItems([item("a", tier: .A, rank: 0), item("b", tier: .A, rank: 1)])

        await model.delete(item: item("b", tier: .A, rank: 1))

        XCTAssertEqual(removeEmitCount, 0,
                       "a delete whose media switched mid-flight emits nothing")
        XCTAssertEqual(model.media, "tv")
    }
}

// MARK: - RankMoveEmitter payload pin

/// Wire-shape contract for `RankMoveEmitter.payload`. Verifies:
///  - `event_type` is exactly `"ranking_move"`
///  - `actor_id` is lowercased UUID string
///  - media columns present (title, tier, posterUrl) and non-media nil columns
///    round-trip as explicit nil (not omitted) via the custom `encode(to:)`
///  - `metadata` contains `year` from the event, no `watched_with_user_ids` key
///  - no `watched_with` key at any level
@MainActor
final class RankMoveEmitterPayloadTests: XCTestCase {

    func testPayloadPinsWireShape() throws {
        let actorID = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        let event = RankManageModel.MoveEvent(
            tmdbId: "tt0111161",
            title: "The Shawshank Redemption",
            tier: "A",
            posterUrl: "https://img/shawshank.jpg",
            year: "1994",
            notes: nil
        )

        let payload = RankMoveEmitter.payload(actorID: actorID, event: event)

        // event_type
        XCTAssertEqual(payload.event_type, "ranking_move")
        // actor_id is lowercased
        XCTAssertEqual(payload.actor_id, "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
        // media columns
        XCTAssertEqual(payload.media_tmdb_id, "tt0111161")
        XCTAssertEqual(payload.media_title, "The Shawshank Redemption")
        XCTAssertEqual(payload.media_tier, "A")
        XCTAssertEqual(payload.media_poster_url, "https://img/shawshank.jpg")
        // metadata carries year, no notes, no watched_with
        XCTAssertEqual(payload.metadata.year, "1994")
        XCTAssertNil(payload.metadata.notes)
        XCTAssertNil(payload.metadata.watchedWithUserIds)
    }

    func testPayloadExplicitNullMediaColumnsEncoded() throws {
        let actorID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let event = RankManageModel.MoveEvent(
            tmdbId: "tt9999",
            title: "No Poster Film",
            tier: "B",
            posterUrl: nil,  // explicit null on wire
            year: nil,
            notes: nil
        )
        let payload = RankMoveEmitter.payload(actorID: actorID, event: event)

        // Encode and verify the JSON contains explicit null for media_poster_url,
        // not a missing key. The custom encode(to:) always writes the key.
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"media_poster_url\":null"),
                      "media_poster_url must be explicit null, got: \(json)")
        XCTAssertFalse(json.contains("watched_with"),
                       "watched_with must never appear in a ranking_move payload")
        // metadata omit-empty: nil year → key absent from metadata JSON
        XCTAssertFalse(json.contains("\"year\""),
                       "nil year must be omitted from metadata by ActivityMetadata")
        XCTAssertFalse(json.contains("\"notes\""),
                       "nil notes must be omitted from metadata by ActivityMetadata")
    }
}

// MARK: - RankRemoveEmitter payload pin

/// Wire-shape contract for `RankRemoveEmitter.payload` (Task 4). Verifies:
///  - `event_type` is exactly `"ranking_remove"`
///  - `actor_id` is lowercased UUID string
///  - media columns present, `media_tier` = the tier removed FROM
///  - `metadata` carries `{notes?, year?}`, NO `watched_with_user_ids`
///  - no `watched_with` key at any level (web omits it for removes)
@MainActor
final class RankRemoveEmitterPayloadTests: XCTestCase {

    func testRemovePayloadPinsWireShape() throws {
        let actorID = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        let event = RankManageModel.RemoveEvent(
            tmdbId: "tt0111161",
            title: "The Shawshank Redemption",
            tier: "S",
            posterUrl: "https://img/shawshank.jpg",
            year: "1994",
            notes: "prison arc is perfect"
        )

        let payload = RankRemoveEmitter.payload(actorID: actorID, event: event)

        XCTAssertEqual(payload.event_type, "ranking_remove")
        XCTAssertEqual(payload.actor_id, "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
        XCTAssertEqual(payload.media_tmdb_id, "tt0111161")
        XCTAssertEqual(payload.media_title, "The Shawshank Redemption")
        XCTAssertEqual(payload.media_tier, "S")
        XCTAssertEqual(payload.media_poster_url, "https://img/shawshank.jpg")
        XCTAssertEqual(payload.metadata.year, "1994")
        XCTAssertEqual(payload.metadata.notes, "prison arc is perfect")
        XCTAssertNil(payload.metadata.watchedWithUserIds)
    }

    func testRemovePayloadOmitsWatchedWithAndEncodesExplicitNullMedia() throws {
        let actorID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let event = RankManageModel.RemoveEvent(
            tmdbId: "tt9999",
            title: "No Poster Film",
            tier: "D",
            posterUrl: nil,
            year: nil,
            notes: nil
        )
        let payload = RankRemoveEmitter.payload(actorID: actorID, event: event)

        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"event_type\":\"ranking_remove\""))
        XCTAssertTrue(json.contains("\"media_poster_url\":null"),
                      "media_poster_url must be explicit null, got: \(json)")
        XCTAssertFalse(json.contains("watched_with"),
                       "watched_with must never appear in a ranking_remove payload")
        XCTAssertFalse(json.contains("\"year\""), "nil year omitted from metadata")
        XCTAssertFalse(json.contains("\"notes\""), "nil notes omitted from metadata")
    }
}
