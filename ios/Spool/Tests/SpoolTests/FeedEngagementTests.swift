import XCTest
@testable import Spool

/// Pure engagement contract (reactions + comments), mirroring web's
/// `services/feedService.ts` on `fix/c1-feed-web-blocking`:
///  - aggregate reducer = `getReactionsForEvents` (L469–517): every requested
///    event id gets an entry; counts keyed by the five contract reaction
///    types; unknown types ignored; `myReactions` from rows whose
///    `user_id` == me; comment rows tallied per `event_id`;
///  - toggle-state resolution = `toggleReaction` (L437–467) + the D7
///    decision: 23505 on insert is SUCCESS (`PostgresErrors.isUniqueViolation`);
///  - comment body: trimmed, 1...500 (DB CHECK `length(btrim(body)) BETWEEN
///    1 AND 500`) — iOS throws `CommentError` instead of web's silent
///    `body.slice(0, 500)` (L583) so over-length text is never corrupted;
///  - 1-level nesting = `listFeedComments` (L553–571) mirrored EXACTLY:
///    only top-level ids are read back out of the reply map (L567–568),
///    so replies with an absent parent — and replies-to-replies — are
///    dropped, same as web renders. (Candidate SHARED fix, see
///    `FeedPipelineComments.nest`.)
/// Source: docs/plans/2026-07-08-c1-ios-feed-data-plan.md (Global Constraints + Task 3).
final class FeedEngagementTests: XCTestCase {

    private let me = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let other = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let eventX = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000001")!
    private let eventY = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000002")!

    // MARK: - Helpers

    /// Error whose description contains what we want — `PostgresErrors
    /// .isUniqueViolation` classifies by `String(describing:)`.
    private struct FakeError: Error, CustomStringConvertible {
        let description: String
    }

    private func reaction(_ event: UUID, _ user: UUID, _ type: String) -> EngagementReducer.ReactionRow {
        EngagementReducer.ReactionRow(event_id: event, user_id: user, reaction: type)
    }

    private func comment(
        id: UUID = UUID(),
        event: UUID? = nil,
        user: UUID? = nil,
        body: String = "hi",
        parent: UUID? = nil,
        createdAt: String = "2026-07-07T12:00:00+00:00"
    ) -> FeedComment {
        FeedComment(
            id: id,
            event_id: event ?? eventX,
            user_id: user ?? other,
            body: body,
            parent_comment_id: parent,
            created_at: createdAt
        )
    }

    private static let zeroReactions: [String: Int] = [
        "fire": 0, "agree": 0, "disagree": 0, "want_to_watch": 0, "love": 0,
    ]

    // MARK: - Comment body validation (trim, empty, 500 boundary)

    func testValidatedBodyTrimsSurroundingWhitespace() throws {
        XCTAssertEqual(try FeedPipelineComments.validatedBody("  hello there \n"), "hello there")
    }

    func testEmptyBodyThrowsEmpty() {
        XCTAssertThrowsError(try FeedPipelineComments.validatedBody("")) { error in
            XCTAssertEqual(error as? CommentError, .empty)
        }
    }

    func testWhitespaceOnlyBodyThrowsEmpty() {
        XCTAssertThrowsError(try FeedPipelineComments.validatedBody(" \n\t  ")) { error in
            XCTAssertEqual(error as? CommentError, .empty)
        }
    }

    func testExactly500CharsPasses() throws {
        let body = String(repeating: "a", count: 500)
        XCTAssertEqual(try FeedPipelineComments.validatedBody(body), body)
    }

    func test501CharsThrowsTooLong() {
        let body = String(repeating: "a", count: 501)
        XCTAssertThrowsError(try FeedPipelineComments.validatedBody(body)) { error in
            XCTAssertEqual(error as? CommentError, .tooLong)
        }
    }

    func testLengthIsCheckedAfterTrimming() throws {
        // 500 meaningful chars wrapped in whitespace: trim first, then the
        // boundary — mirrors the DB CHECK `length(btrim(body))`.
        let body = "  " + String(repeating: "b", count: 500) + " \n"
        XCTAssertEqual(try FeedPipelineComments.validatedBody(body), String(repeating: "b", count: 500))
    }

    // MARK: - 1-level nesting

    func testNestAttachesRepliesToParentsPreservingOrder() {
        let p1 = comment(body: "p1", createdAt: "2026-07-07T10:00:00+00:00")
        let p2 = comment(body: "p2", createdAt: "2026-07-07T10:01:00+00:00")
        let r1a = comment(body: "r1a", parent: p1.id, createdAt: "2026-07-07T10:02:00+00:00")
        let r2a = comment(body: "r2a", parent: p2.id, createdAt: "2026-07-07T10:03:00+00:00")
        let r1b = comment(body: "r1b", parent: p1.id, createdAt: "2026-07-07T10:04:00+00:00")

        let nested = FeedPipelineComments.nest([p1, p2, r1a, r2a, r1b])

        XCTAssertEqual(nested.map { $0.0.id }, [p1.id, p2.id])
        XCTAssertEqual(nested[0].1.map(\.id), [r1a.id, r1b.id], "replies keep asc order")
        XCTAssertEqual(nested[1].1.map(\.id), [r2a.id])
    }

    func testNestOrphanedReplyIsDropped() {
        // Parent beyond the 100-row page (or otherwise absent): web's fill
        // pass (feedService.ts L567–568) only reads the reply map for
        // topLevel ids, so the orphan never renders. Mirror the drop —
        // same rows must render the same on both platforms. (Candidate
        // SHARED fix; see the nest doc comment.)
        let p = comment(body: "p", createdAt: "2026-07-07T10:00:00+00:00")
        let orphan = comment(body: "orphan", parent: UUID(), createdAt: "2026-07-07T10:01:00+00:00")
        let later = comment(body: "later", createdAt: "2026-07-07T10:02:00+00:00")

        let nested = FeedPipelineComments.nest([p, orphan, later])

        XCTAssertEqual(nested.map { $0.0.id }, [p.id, later.id],
                       "orphan is dropped, not surfaced")
        XCTAssertTrue(nested.allSatisfy { $0.1.isEmpty })
    }

    func testNestReplyToReplyDropsTheGrandchild() {
        // Web trace for a ← b ← c: b lands in replyMap[a] and renders under
        // a (L558–561, L567–568); c lands in replyMap[b.id], but b is not
        // in topLevel so the fill pass never visits it — b's replies stay
        // the [] they were initialized with (L549) and c is dropped.
        let a = comment(body: "a", createdAt: "2026-07-07T10:00:00+00:00")
        let b = comment(body: "b", parent: a.id, createdAt: "2026-07-07T10:01:00+00:00")
        let c = comment(body: "c", parent: b.id, createdAt: "2026-07-07T10:02:00+00:00")

        let nested = FeedPipelineComments.nest([a, b, c])

        XCTAssertEqual(nested.map { $0.0.id }, [a.id])
        XCTAssertEqual(nested[0].1.map(\.id), [b.id], "b still renders under a")
    }

    func testNestEmptyInputYieldsEmpty() {
        XCTAssertTrue(FeedPipelineComments.nest([]).isEmpty)
    }

    // MARK: - Engagement aggregate reducer

    func testAggregateEmptyEventIDsReturnsEmptyMap() {
        // Web: `if (eventIds.length === 0) return result;` (L474)
        let out = EngagementReducer.aggregate(
            rows: EngagementReducer.Rows(eventIDs: [], reactions: [], commentEventIDs: []),
            myUserID: me
        )
        XCTAssertTrue(out.isEmpty)
    }

    func testAggregateInitializesEveryRequestedEventWithZeroCounts() {
        // Web initializes ALL queried ids before tallying (L492–494) so a
        // card with zero engagement still renders zeroes, not a missing key.
        let out = EngagementReducer.aggregate(
            rows: EngagementReducer.Rows(eventIDs: [eventX, eventY], reactions: [], commentEventIDs: []),
            myUserID: me
        )
        XCTAssertEqual(out[eventX], EngagementCounts(reactions: Self.zeroReactions, comments: 0, myReactions: []))
        XCTAssertEqual(out[eventY], EngagementCounts(reactions: Self.zeroReactions, comments: 0, myReactions: []))
    }

    func testAggregateCountsMultipleReactionTypes() {
        let rows = [
            reaction(eventX, other, "fire"),
            reaction(eventX, me, "fire"),
            reaction(eventX, other, "love"),
            reaction(eventY, other, "agree"),
        ]
        let out = EngagementReducer.aggregate(
            rows: EngagementReducer.Rows(eventIDs: [eventX, eventY], reactions: rows, commentEventIDs: []),
            myUserID: me
        )
        var expectedX = Self.zeroReactions
        expectedX["fire"] = 2
        expectedX["love"] = 1
        XCTAssertEqual(out[eventX]?.reactions, expectedX)
        XCTAssertEqual(out[eventX]?.myReactions, ["fire"])
        var expectedY = Self.zeroReactions
        expectedY["agree"] = 1
        XCTAssertEqual(out[eventY]?.reactions, expectedY)
        XCTAssertEqual(out[eventY]?.myReactions, [])
    }

    func testAggregateBuildsMyReactionsAcrossTypes() {
        // PK is (event_id, user_id, reaction) — one user can hold several
        // different reactions on the same event.
        let rows = [
            reaction(eventX, me, "fire"),
            reaction(eventX, me, "want_to_watch"),
            reaction(eventX, other, "love"),
        ]
        let out = EngagementReducer.aggregate(
            rows: EngagementReducer.Rows(eventIDs: [eventX], reactions: rows, commentEventIDs: []),
            myUserID: me
        )
        XCTAssertEqual(out[eventX]?.myReactions, ["fire", "want_to_watch"])
    }

    func testAggregateIgnoresUnknownReactionTypes() {
        // Web filters through REACTION_TYPES (L501) — a stray legacy 'like'
        // row must not count anywhere, including myReactions.
        let rows = [
            reaction(eventX, me, "like"),
            reaction(eventX, other, "fire"),
        ]
        let out = EngagementReducer.aggregate(
            rows: EngagementReducer.Rows(eventIDs: [eventX], reactions: rows, commentEventIDs: []),
            myUserID: me
        )
        var expected = Self.zeroReactions
        expected["fire"] = 1
        XCTAssertEqual(out[eventX]?.reactions, expected)
        XCTAssertEqual(out[eventX]?.myReactions, [])
    }

    func testAggregateIgnoresRowsForUnrequestedEvents() {
        // Web: `if (!entry) continue;` (L499) — rows outside the queried id
        // set never create entries.
        let strayEvent = UUID()
        let out = EngagementReducer.aggregate(
            rows: EngagementReducer.Rows(eventIDs: [eventX],
                                         reactions: [reaction(strayEvent, other, "fire")],
                                         commentEventIDs: [strayEvent]),
            myUserID: me
        )
        XCTAssertEqual(Array(out.keys), [eventX])
        XCTAssertEqual(out[eventX], EngagementCounts(reactions: Self.zeroReactions, comments: 0, myReactions: []))
    }

    func testAggregateTalliesCommentsPerEvent() {
        let out = EngagementReducer.aggregate(
            rows: EngagementReducer.Rows(eventIDs: [eventX, eventY],
                                         reactions: [],
                                         commentEventIDs: [eventX, eventX, eventY, eventX]),
            myUserID: me
        )
        XCTAssertEqual(out[eventX]?.comments, 3)
        XCTAssertEqual(out[eventY]?.comments, 1)
    }

    func testAggregateNilMyUserIDMeansNoMyReactions() {
        let out = EngagementReducer.aggregate(
            rows: EngagementReducer.Rows(eventIDs: [eventX],
                                         reactions: [reaction(eventX, other, "fire")],
                                         commentEventIDs: []),
            myUserID: nil
        )
        XCTAssertEqual(out[eventX]?.reactions["fire"], 1)
        XCTAssertEqual(out[eventX]?.myReactions, [])
    }

    // MARK: - Toggle-state resolution truth table (incl. 23505-as-success)

    func testToggleInsertSuccessReturnsTrue() throws {
        XCTAssertTrue(try EngagementReducer.resolvedToggleState(currentlyMine: false, writeError: nil))
    }

    func testToggleDeleteSuccessReturnsFalse() throws {
        XCTAssertFalse(try EngagementReducer.resolvedToggleState(currentlyMine: true, writeError: nil))
    }

    func testToggleInsertUniqueViolationIsSuccess() throws {
        // D7: 23505 on insert = the row already exists = the desired end
        // state — report true, don't throw.
        let dup = FakeError(description: #"PostgrestError(code: "23505", message: "duplicate key value violates unique constraint")"#)
        XCTAssertTrue(try EngagementReducer.resolvedToggleState(currentlyMine: false, writeError: dup))
    }

    func testToggleInsertOtherErrorThrows() {
        let boom = FakeError(description: "network timed out")
        XCTAssertThrowsError(
            try EngagementReducer.resolvedToggleState(currentlyMine: false, writeError: boom)
        )
    }

    func testToggleDeleteErrorThrowsEvenIfItLooksLikeUniqueViolation() {
        // The 23505 special case is insert-only; a failed delete is a failed
        // delete, whatever its SQLSTATE claims.
        let weird = FakeError(description: "23505 duplicate key")
        XCTAssertThrowsError(
            try EngagementReducer.resolvedToggleState(currentlyMine: true, writeError: weird)
        )
    }
}
