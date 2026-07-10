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

    // MARK: - RankingPayload.notes omit-on-nil (re-rank preservation seam)
    //
    // WHY THIS MATTERS: `RankingPayload` uses synthesized Encodable, so
    // `notes: String?` goes through `encodeIfPresent`. A nil notes value OMITS
    // the key entirely. PostgREST interprets a missing key as "don't touch
    // this column", so a menu re-rank that passes `notes: nil` PRESERVES the
    // user's existing `user_rankings.notes` value on the server. This is the
    // ONLY thing stopping context-menu re-ranks from silently wiping notes that
    // were written via the "edit notes" sheet. Pinned here so a refactor that
    // adds a custom `encode(to:)` can't accidentally regress the omission.

    /// The MOVIE payload body with `notes: nil` → the JSON must NOT contain a
    /// `"notes"` key. PostgREST omit-key semantics preserve the existing column
    /// on re-rank. (Post-C5 the payload is per-media; the movie body is the
    /// unchanged historical shape, so this pin is byte-identical to before.)
    func testRankingPayloadNilNotesOmitsKey() throws {
        let payload = MoviePayloadBody(
            user_id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            tmdb_id: "tt1234", title: "Some Film", year: nil, poster_url: nil,
            type: "movie", genres: [], director: nil, tier: "A",
            rank_position: 0, notes: nil
        )
        let data = try JSONEncoder().encode(payload)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("\"notes\""),
                       "nil notes must OMIT the key so PostgREST preserves the existing column on re-rank; got: \(json)")
    }

    /// The MOVIE payload body with a non-nil `notes` → the JSON MUST contain the
    /// key so an intentional notes write reaches the server.
    func testRankingPayloadPresentNotesIncludesKey() throws {
        let payload = MoviePayloadBody(
            user_id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            tmdb_id: "tt1234", title: "Some Film", year: "2000", poster_url: nil,
            type: "movie", genres: [], director: nil, tier: "A",
            rank_position: 1, notes: "a tight second act"
        )
        let data = try JSONEncoder().encode(payload)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"notes\":\"a tight second act\""),
                      "present notes must encode the key so the write reaches the server; got: \(json)")
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

    // MARK: - CeremonyEmission (fresh-vs-re-rank emission decision seam)
    //
    // The ledgered C4 deviation: an iOS ceremony re-rank emitted `ranking_add`
    // and only spliced the target tier. The corrected contract
    // (docs/contracts/shared-payloads.md `## user_rankings ordering`) requires
    // a SINGLE `ranking_move` on a re-rank (metadata `{notes?, year?}`, never
    // watched-with) and `ranking_add` only on a genuine fresh insert. These
    // pin the pure decision seam that `insertRanking` drives off its pre-read.

    private static let uidW = UUID(uuidString: "CCCCCCCC-1111-2222-3333-444444444444")!

    private func emissionMetadataObject(_ decision: CeremonyEmission.Decision) throws -> [String: Any] {
        let data = try JSONEncoder().encode(decision.metadata)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// FRESH insert (no prior row) → `ranking_add`, and watched-with is CARRIED
    /// (add sites keep it, per the contract).
    func testFreshInsertEmitsRankingAddKeepingWatchedWith() throws {
        let decision = CeremonyEmission.decide(
            outcome: .inserted, notes: "great", year: "2001",
            watchedWithUserIds: [Self.uidW]
        )
        XCTAssertEqual(decision.eventType, "ranking_add")
        let obj = try emissionMetadataObject(decision)
        XCTAssertEqual(Set(obj.keys), ["notes", "year", "watched_with_user_ids"],
                       "a fresh add carries all three metadata keys")
    }

    /// RE-RANK (prior row existed) → a SINGLE `ranking_move`, metadata is
    /// `{notes?, year?}` only, and watched-with is STRIPPED even when the caller
    /// passed some (the move sites never carry it — contract line ~75).
    func testReRankEmitsRankingMoveStrippingWatchedWith() throws {
        let decision = CeremonyEmission.decide(
            outcome: .moved(fromTier: "A"), notes: "even better", year: "2001",
            watchedWithUserIds: [Self.uidW]
        )
        XCTAssertEqual(decision.eventType, "ranking_move",
                       "a re-rank is a MOVE, never a fresh add")
        let obj = try emissionMetadataObject(decision)
        XCTAssertEqual(Set(obj.keys), ["notes", "year"],
                       "ranking_move metadata is {notes?, year?} — watched-with stripped")
        XCTAssertNil(obj["watched_with_user_ids"],
                     "watched_with_user_ids must NEVER appear on a move")
    }

    /// Same-tier vs cross-tier re-rank both emit `ranking_move` — the source
    /// tier differs only in whether the compaction call fires, not the event.
    func testSameTierReRankStillEmitsRankingMove() {
        let sameTier = CeremonyEmission.decide(
            outcome: .moved(fromTier: "S"), notes: nil, year: nil, watchedWithUserIds: nil
        )
        XCTAssertEqual(sameTier.eventType, "ranking_move")
    }

    /// A re-rank with no notes/year encodes an EMPTY metadata object (the
    /// omit-empty rule still applies to a move) — never a stray watched-with.
    func testReRankWithNoMetadataEncodesEmptyObject() throws {
        let decision = CeremonyEmission.decide(
            outcome: .moved(fromTier: "B"), notes: nil, year: nil,
            watchedWithUserIds: [Self.uidW]
        )
        let obj = try emissionMetadataObject(decision)
        XCTAssertTrue(obj.isEmpty,
                      "no notes/year and stripped watched-with → {} , got \(obj)")
    }

    // MARK: - InsertOutcome mapping (pre-read → outcome the caller observes)

    /// The pre-read maps a nil prior tier to `.inserted` and a present prior
    /// tier to `.moved(fromTier:)` — the exact expression `insertRanking` uses
    /// to turn the DB pre-read into the outcome + emission driver.
    func testInsertOutcomeMapsNilPriorTierToInserted() {
        let existingTier: String? = nil
        let outcome = existingTier.map(RankingRepository.InsertOutcome.moved) ?? .inserted
        XCTAssertEqual(outcome, .inserted)
    }

    func testInsertOutcomeMapsPresentPriorTierToMoved() {
        let existingTier: String? = "A"
        let outcome = existingTier.map(RankingRepository.InsertOutcome.moved) ?? .inserted
        XCTAssertEqual(outcome, .moved(fromTier: "A"))
    }

    // MARK: - source-tier compaction math (cross-tier re-rank leaves no gap)

    /// A cross-tier re-rank compacts the SOURCE tier via
    /// `TierOrder.tierOrderAfterRemoval` — the departed id is dropped and the
    /// survivors keep order (the RPC then renumbers them 0..k-1). This is the
    /// membership-minus-id array `insertRanking` step 5 sends for the source.
    func testSourceTierCompactionDropsDepartedId() {
        let sourceMembership = ["a", "x", "b", "c"]   // "x" is re-ranking away
        let compacted = TierOrder.tierOrderAfterRemoval(sourceMembership, removedId: "x")
        XCTAssertEqual(compacted, ["a", "b", "c"],
                       "source tier keeps survivors in order, minus the moved id")
    }
}
