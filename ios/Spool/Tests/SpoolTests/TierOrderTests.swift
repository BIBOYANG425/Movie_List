import XCTest
@testable import Spool

/// Pin for the pure tier-order helpers (`TierOrder.swift`) that back the C4
/// ranking-management ops. Swift port of the web suite
/// `services/__tests__/tierOrder.test.ts` — same cases, same expectations, so
/// the two clients compute identical FULL-MEMBERSHIP arrays for the
/// `set_tier_order` RPC. Pure + total: asserted with ZERO network.
final class TierOrderTests: XCTestCase {

    // MARK: - tierOrderAfterReorder

    func testReorderMovesItemEarlier() {
        XCTAssertEqual(
            TierOrder.tierOrderAfterReorder(["a", "b", "c", "d"], from: 2, to: 0),
            ["c", "a", "b", "d"]
        )
    }

    func testReorderMovesItemLater() {
        XCTAssertEqual(
            TierOrder.tierOrderAfterReorder(["a", "b", "c", "d"], from: 0, to: 2),
            ["b", "c", "a", "d"]
        )
    }

    /// Moving an item to its own index is a no-op (order unchanged) — callers
    /// use this to suppress no-op events (audit B1).
    func testReorderSameIndexIsNoOp() {
        XCTAssertEqual(
            TierOrder.tierOrderAfterReorder(["a", "b", "c"], from: 1, to: 1),
            ["a", "b", "c"]
        )
    }

    func testReorderToLastIndexMovesToEnd() {
        XCTAssertEqual(
            TierOrder.tierOrderAfterReorder(["a", "b", "c"], from: 0, to: 2),
            ["b", "c", "a"]
        )
    }

    func testReorderDoesNotMutateInput() {
        let ids = ["a", "b", "c"]
        _ = TierOrder.tierOrderAfterReorder(ids, from: 0, to: 2)
        XCTAssertEqual(ids, ["a", "b", "c"])
    }

    /// Out-of-range indices return a copy rather than throwing: a `from`
    /// outside range leaves the list untouched; an over-large `to` clamps to
    /// the tail.
    func testReorderOutOfRangeClampsInsteadOfThrowing() {
        XCTAssertEqual(TierOrder.tierOrderAfterReorder(["a", "b"], from: 5, to: 0), ["a", "b"])
        XCTAssertEqual(TierOrder.tierOrderAfterReorder(["a", "b"], from: 0, to: 5), ["b", "a"])
    }

    /// Negative `to` clamps to the head (defensive — no caller should send a
    /// negative index, but the function must stay total).
    func testReorderNegativeToClampsToHead() {
        XCTAssertEqual(
            TierOrder.tierOrderAfterReorder(["a", "b", "c"], from: 2, to: -5),
            ["c", "a", "b"]
        )
    }

    // MARK: - tierOrderAfterRemoval

    func testRemovalRemovesIdPreservingOrder() {
        XCTAssertEqual(TierOrder.tierOrderAfterRemoval(["a", "b", "c"], removedId: "b"), ["a", "c"])
    }

    func testRemovalRemovesFirstId() {
        XCTAssertEqual(TierOrder.tierOrderAfterRemoval(["a", "b", "c"], removedId: "a"), ["b", "c"])
    }

    func testRemovalRemovesLastId() {
        XCTAssertEqual(TierOrder.tierOrderAfterRemoval(["a", "b", "c"], removedId: "c"), ["a", "b"])
    }

    func testRemovalAbsentIdIsNoOpCopy() {
        XCTAssertEqual(TierOrder.tierOrderAfterRemoval(["a", "b"], removedId: "z"), ["a", "b"])
    }

    func testRemovalEmptiesSingleElementList() {
        XCTAssertEqual(TierOrder.tierOrderAfterRemoval(["a"], removedId: "a"), [])
    }

    func testRemovalDoesNotMutateInput() {
        let ids = ["a", "b", "c"]
        _ = TierOrder.tierOrderAfterRemoval(ids, removedId: "b")
        XCTAssertEqual(ids, ["a", "b", "c"])
    }

    // MARK: - ordersAfterCrossTierMove

    func testCrossMoveRemovesFromSourceInsertsIntoTargetAtIndex() {
        let out = TierOrder.ordersAfterCrossTierMove(
            source: ["a", "b", "c"], target: ["x", "y"], movedId: "b", targetIndex: 1
        )
        XCTAssertEqual(out.source, ["a", "c"])
        XCTAssertEqual(out.target, ["x", "b", "y"])
    }

    func testCrossMoveInsertsAtFrontWhenIndexZero() {
        let out = TierOrder.ordersAfterCrossTierMove(
            source: ["a", "b"], target: ["x", "y"], movedId: "a", targetIndex: 0
        )
        XCTAssertEqual(out.source, ["b"])
        XCTAssertEqual(out.target, ["a", "x", "y"])
    }

    func testCrossMoveAppendsWhenIndexIsTargetLength() {
        let out = TierOrder.ordersAfterCrossTierMove(
            source: ["a", "b"], target: ["x", "y"], movedId: "a", targetIndex: 2
        )
        XCTAssertEqual(out.source, ["b"])
        XCTAssertEqual(out.target, ["x", "y", "a"])
    }

    func testCrossMoveClampsOverLargeIndexToAppend() {
        let out = TierOrder.ordersAfterCrossTierMove(
            source: ["a"], target: ["x"], movedId: "a", targetIndex: 99
        )
        XCTAssertEqual(out.target, ["x", "a"])
    }

    func testCrossMoveIntoEmptyTargetTier() {
        let out = TierOrder.ordersAfterCrossTierMove(
            source: ["a", "b"], target: [], movedId: "a", targetIndex: 0
        )
        XCTAssertEqual(out.source, ["b"])
        XCTAssertEqual(out.target, ["a"])
    }

    /// Defensive: `target` passed in should exclude `movedId`, but a stale
    /// snapshot that names it must still yield the id exactly once.
    func testCrossMoveDoesNotDuplicateMovedIdInStaleTarget() {
        let out = TierOrder.ordersAfterCrossTierMove(
            source: ["a", "b"], target: ["a", "x"], movedId: "a", targetIndex: 1
        )
        XCTAssertEqual(out.target.filter { $0 == "a" }.count, 1)
    }

    func testCrossMoveDoesNotMutateInputs() {
        let src = ["a", "b"]
        let tgt = ["x"]
        _ = TierOrder.ordersAfterCrossTierMove(source: src, target: tgt, movedId: "a", targetIndex: 1)
        XCTAssertEqual(src, ["a", "b"])
        XCTAssertEqual(tgt, ["x"])
    }
}
