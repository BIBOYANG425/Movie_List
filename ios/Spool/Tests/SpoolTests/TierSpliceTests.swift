import XCTest
@testable import Spool

/// Pin for the pure tier-splice math that `RankingRepository.insertRanking`
/// uses to compute the target tier's FULL intended membership before handing it
/// to the `set_tier_order` RPC (C4 Task 4 / audit B5).
///
/// The bug this guards against: the old insert wrote a new row at a chosen
/// `rankPosition` WITHOUT renumbering the rest of the tier, so every iOS rank
/// minted a duplicate position. `spliceTierOrder` produces the ordered id list
/// (new id inserted at the clamped index) that the RPC then compacts to a
/// contiguous 0..n-1. Pure + total so the rule is asserted with ZERO network.
final class TierSpliceTests: XCTestCase {

    /// Middle insert: the new id lands at the requested index and everything
    /// after it shifts right.
    func testInsertInMiddle() {
        let out = RankingRepository.spliceTierOrder(["a", "b", "c"], newId: "x", at: 1)
        XCTAssertEqual(out, ["a", "x", "b", "c"])
    }

    /// Index 0: the new id becomes the best-ranked (position 0) row.
    func testInsertAtHead() {
        let out = RankingRepository.spliceTierOrder(["a", "b", "c"], newId: "x", at: 0)
        XCTAssertEqual(out, ["x", "a", "b", "c"])
    }

    /// Exact end index (== count): the new id appends to the tail.
    func testInsertAtEnd() {
        let out = RankingRepository.spliceTierOrder(["a", "b", "c"], newId: "x", at: 3)
        XCTAssertEqual(out, ["a", "b", "c", "x"])
    }

    /// Beyond-end index clamps to the tail — a caller that passes a stale
    /// `rankPosition` larger than the tier can never gap the array.
    func testInsertBeyondEndClamps() {
        let out = RankingRepository.spliceTierOrder(["a", "b", "c"], newId: "x", at: 99)
        XCTAssertEqual(out, ["a", "b", "c", "x"])
    }

    /// Negative index clamps to the head (defensive — no caller should send a
    /// negative rank, but the function must stay total).
    func testNegativeIndexClampsToHead() {
        let out = RankingRepository.spliceTierOrder(["a", "b", "c"], newId: "x", at: -5)
        XCTAssertEqual(out, ["x", "a", "b", "c"])
    }

    /// Empty tier: the new id is the sole member at position 0.
    func testInsertIntoEmptyTier() {
        let out = RankingRepository.spliceTierOrder([], newId: "x", at: 0)
        XCTAssertEqual(out, ["x"])
    }

    /// Empty tier with a non-zero index still clamps to a single-element list.
    func testInsertIntoEmptyTierBeyondZero() {
        let out = RankingRepository.spliceTierOrder([], newId: "x", at: 7)
        XCTAssertEqual(out, ["x"])
    }

    /// Re-rank (id already present): the id MOVES to the spliced position and
    /// does NOT appear twice. Here "b" re-ranks to the head.
    func testReRankMovesExistingIdNoDuplicate() {
        let out = RankingRepository.spliceTierOrder(["a", "b", "c"], newId: "b", at: 0)
        XCTAssertEqual(out, ["b", "a", "c"])
    }

    /// Re-rank to a later slot: removing the id first, THEN clamping/splicing
    /// keeps positions honest (moving "a" to index 2 of the 3-element tier lands
    /// it after "b" and "c").
    func testReRankToLaterSlotNoDuplicate() {
        let out = RankingRepository.spliceTierOrder(["a", "b", "c"], newId: "a", at: 2)
        XCTAssertEqual(out, ["b", "c", "a"])
    }

    /// Re-rank in place: splicing an id back at its own index is a no-op
    /// ordering — no duplicate, no reordering surprise.
    func testReRankInPlaceIsStable() {
        let out = RankingRepository.spliceTierOrder(["a", "b", "c"], newId: "b", at: 1)
        XCTAssertEqual(out, ["a", "b", "c"])
    }

    /// Composite TV ids (`tv_{id}_s{n}`) are opaque strings to the splice — they
    /// pass through byte-for-byte so the RPC can match them as text.
    func testCompositeTvIdsPassThroughVerbatim() {
        let out = RankingRepository.spliceTierOrder(
            ["tv_1_s1", "tv_2_s3"], newId: "tv_9_s2", at: 1
        )
        XCTAssertEqual(out, ["tv_1_s1", "tv_9_s2", "tv_2_s3"])
    }

    // MARK: - reindexWithinTier (same-tier move decision seam)

    /// `moveRanking` degenerates to a same-tier reorder when from == to; the
    /// index is resolved from the id's CURRENT position, then clamped/spliced.
    func testReindexWithinTierMovesToNewSlot() {
        let out = RankingRepository.reindexWithinTier(["a", "b", "c"], movedId: "a", to: 2)
        XCTAssertEqual(out, ["b", "c", "a"])
    }

    /// An id already absent from the tier yields an unchanged copy — the op
    /// never throws on a stale membership snapshot.
    func testReindexWithinTierAbsentIdIsNoOp() {
        let out = RankingRepository.reindexWithinTier(["a", "b"], movedId: "z", to: 0)
        XCTAssertEqual(out, ["a", "b"])
    }

    /// A beyond-end target clamps to the tail (a nil `atIndex` resolves to
    /// count, which must append rather than crash).
    func testReindexWithinTierBeyondEndClampsToTail() {
        let out = RankingRepository.reindexWithinTier(["a", "b", "c"], movedId: "a", to: 99)
        XCTAssertEqual(out, ["b", "c", "a"])
    }

    // MARK: - NotesUpdatePayload (single-column encode seam)

    /// A present note encodes as a JSON string under the `notes` key.
    func testNotesPayloadEncodesString() throws {
        let data = try JSONEncoder().encode(NotesUpdatePayload(notes: "loved it"))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(json, #"{"notes":"loved it"}"#)
    }

    /// A nil note encodes as an EXPLICIT JSON null (never an omitted key) so
    /// the single-column UPDATE CLEARS the column rather than preserving a
    /// stale value (PostgREST treats a missing key as "don't touch").
    func testNotesPayloadEncodesExplicitNullWhenNil() throws {
        let data = try JSONEncoder().encode(NotesUpdatePayload(notes: nil))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(json, #"{"notes":null}"#)
    }
}
