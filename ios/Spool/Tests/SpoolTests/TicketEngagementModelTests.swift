import XCTest
@testable import Spool

/// The per-ticket engagement view model — the testable state machine behind
/// `FeedTicketBack` (plan Task 4). All IO is injected as closures mirroring the
/// `FeedRepository` engagement signatures (same style as `FeedPageAssembler`),
/// so every optimistic-update, validation, and failure path is XCTest-covered
/// with zero network.
///
/// Contract pins:
///  - `toggle(reaction:)` is OPTIMISTIC: `myReactions` flips and the count
///    adjusts BEFORE the write closure runs; a throw REVERTS both, in both
///    directions (add→revert-to-absent, remove→revert-to-present).
///  - `addComment(body:)` runs the SAME trim/1...500 validation the repository
///    does (`FeedPipelineComments.validatedBody`) BEFORE any IO: empty /
///    whitespace → `inlineError = "say something"`, >500 → `"keep it under
///    500"`, and the write closure is NEVER called. On a write throw the draft
///    is PRESERVED; on success the new row appends to the thread and the draft
///    clears.
///  - `deleteComment(id:)` removes exactly the matching row (top-level or
///    reply) on success.
///  - `load()` failure sets `loadFailed` (no crash); thread nesting is a
///    straight passthrough to `FeedPipelineComments.nest`.
@MainActor
final class TicketEngagementModelTests: XCTestCase {

    private let event = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000001")!
    private let me = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let other = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private struct FakeError: Error {}

    /// Contract reaction set (EngagementReducer.reactionTypes / phase-5 DB
    /// CHECK): fire, agree, disagree, want_to_watch, love.
    private func counts(
        love: Int = 0, fire: Int = 0, agree: Int = 0, disagree: Int = 0, want: Int = 0,
        comments: Int = 0, mine: Set<String> = []
    ) -> EngagementCounts {
        EngagementCounts(
            reactions: ["fire": fire, "agree": agree, "disagree": disagree,
                        "want_to_watch": want, "love": love],
            comments: comments,
            myReactions: mine
        )
    }

    private func comment(
        id: UUID = UUID(), body: String = "hi", parent: UUID? = nil,
        user: UUID? = nil, createdAt: String = "2026-07-07T12:00:00+00:00"
    ) -> FeedComment {
        FeedComment(id: id, event_id: event, user_id: user ?? other, body: body,
                    parent_comment_id: parent, created_at: createdAt)
    }

    /// Build a model with sensible no-op defaults; each test overrides the
    /// closures it cares about.
    private func makeModel(
        loadCounts: @escaping () async throws -> EngagementCounts = { EngagementCounts(reactions: [:], comments: 0, myReactions: []) },
        loadThread: @escaping () async throws -> [FeedComment] = { [] },
        toggle: @escaping (String, Bool) async throws -> Bool = { _, mine in !mine },
        add: @escaping (String) async throws -> FeedComment = { _ in throw FakeError() },
        delete: @escaping (UUID) async throws -> Void = { _ in }
    ) -> TicketEngagementModel {
        TicketEngagementModel(
            eventID: event,
            loadCounts: loadCounts,
            loadThread: loadThread,
            toggleReaction: toggle,
            addComment: add,
            deleteComment: delete
        )
    }

    // MARK: - load

    func testLoadPopulatesCountsAndNestedThread() async {
        let parent = comment(id: UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!, body: "top")
        let reply = comment(body: "reply", parent: parent.id)
        let model = makeModel(
            loadCounts: { self.counts(love: 3, comments: 2, mine: ["love"]) },
            loadThread: { [parent, reply] }
        )

        await model.load()

        XCTAssertEqual(model.counts?.reactions["love"], 3)
        XCTAssertEqual(model.counts?.myReactions, ["love"])
        XCTAssertFalse(model.loadFailed)
        XCTAssertEqual(model.thread.count, 1)
        XCTAssertEqual(model.thread.first?.0.id, parent.id)
        XCTAssertEqual(model.thread.first?.1.map(\.id), [reply.id])
    }

    func testLoadFailureSetsFlagNotCrash() async {
        let model = makeModel(loadCounts: { throw FakeError() })
        await model.load()
        XCTAssertTrue(model.loadFailed)
        XCTAssertNil(model.counts)
        XCTAssertTrue(model.thread.isEmpty)
    }

    func testLoadThreadFailureSetsFlag() async {
        let model = makeModel(
            loadCounts: { self.counts(love: 1) },
            loadThread: { throw FakeError() }
        )
        await model.load()
        XCTAssertTrue(model.loadFailed)
    }

    func testThreadNestingPassthroughDropsOrphanReply() async {
        // A reply whose parent is absent from the page is dropped — exact
        // FeedPipelineComments.nest passthrough (web parity).
        let orphan = comment(body: "orphan", parent: UUID())
        let top = comment(id: UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!, body: "top")
        let model = makeModel(loadCounts: { self.counts() }, loadThread: { [top, orphan] })
        await model.load()
        XCTAssertEqual(model.thread.count, 1)
        XCTAssertEqual(model.thread.first?.0.id, top.id)
        XCTAssertTrue(model.thread.first?.1.isEmpty ?? false)
    }

    // MARK: - toggle: optimistic add

    func testToggleAddOptimisticThenConfirmed() async {
        var wrote: (String, Bool)?
        let model = makeModel(
            loadCounts: { self.counts(love: 4) },
            toggle: { r, mine in wrote = (r, mine); return !mine }
        )
        await model.load()

        await model.toggle(reaction: "love")

        XCTAssertEqual(wrote?.0, "love")
        XCTAssertEqual(wrote?.1, false)          // closure sees the PRE-toggle mine-state
        XCTAssertTrue(model.counts?.myReactions.contains("love") ?? false)
        XCTAssertEqual(model.counts?.reactions["love"], 5)   // 4 → 5
    }

    func testToggleAddRevertsOnThrow() async {
        let model = makeModel(
            loadCounts: { self.counts(love: 4) },
            toggle: { _, _ in throw FakeError() }
        )
        await model.load()

        await model.toggle(reaction: "love")

        // Reverted: back to not-mine and count 4.
        XCTAssertFalse(model.counts?.myReactions.contains("love") ?? true)
        XCTAssertEqual(model.counts?.reactions["love"], 4)
    }

    // MARK: - toggle: optimistic remove

    func testToggleRemoveOptimisticThenConfirmed() async {
        let model = makeModel(
            loadCounts: { self.counts(love: 4, mine: ["love"]) },
            toggle: { _, mine in !mine }
        )
        await model.load()

        await model.toggle(reaction: "love")

        XCTAssertFalse(model.counts?.myReactions.contains("love") ?? true)
        XCTAssertEqual(model.counts?.reactions["love"], 3)   // 4 → 3
    }

    func testToggleRemoveRevertsOnThrow() async {
        let model = makeModel(
            loadCounts: { self.counts(love: 4, mine: ["love"]) },
            toggle: { _, _ in throw FakeError() }
        )
        await model.load()

        await model.toggle(reaction: "love")

        XCTAssertTrue(model.counts?.myReactions.contains("love") ?? false)
        XCTAssertEqual(model.counts?.reactions["love"], 4)
    }

    // MARK: - count adjustment truth table

    func testToggleNeverDrivesCountNegative() async {
        // Defensive: a stale zero count with mine-state still reverts cleanly
        // and never goes below zero on the optimistic remove.
        let model = makeModel(
            loadCounts: { self.counts(love: 0, mine: ["love"]) },
            toggle: { _, mine in !mine }
        )
        await model.load()
        await model.toggle(reaction: "love")
        XCTAssertEqual(model.counts?.reactions["love"], 0)
        XCTAssertFalse(model.counts?.myReactions.contains("love") ?? true)
    }

    func testToggleOnlyTouchesTheOneReaction() async {
        let model = makeModel(
            loadCounts: { self.counts(love: 2, fire: 5, mine: ["fire"]) },
            toggle: { _, mine in !mine }
        )
        await model.load()
        await model.toggle(reaction: "love")
        XCTAssertEqual(model.counts?.reactions["love"], 3)
        XCTAssertEqual(model.counts?.reactions["fire"], 5)   // untouched
        XCTAssertEqual(model.counts?.myReactions, ["fire", "love"])
    }

    // MARK: - addComment validation (no IO)

    func testAddCommentEmptyDraftSetsInlineErrorNoIO() async {
        var called = false
        let model = makeModel(add: { _ in called = true; return self.comment() })
        model.draft = ""
        await model.addComment()
        XCTAssertEqual(model.inlineError, "say something")
        XCTAssertFalse(called)
        XCTAssertEqual(model.draft, "")   // preserved
    }

    func testAddCommentWhitespaceOnlyDraftSetsInlineErrorNoIO() async {
        var called = false
        let model = makeModel(add: { _ in called = true; return self.comment() })
        model.draft = "   \n  "
        await model.addComment()
        XCTAssertEqual(model.inlineError, "say something")
        XCTAssertFalse(called)
    }

    func testAddCommentTooLongSetsInlineErrorNoIO() async {
        var called = false
        let model = makeModel(add: { _ in called = true; return self.comment() })
        model.draft = String(repeating: "x", count: 501)
        await model.addComment()
        XCTAssertEqual(model.inlineError, "keep it under 500")
        XCTAssertFalse(called)
        XCTAssertEqual(model.draft.count, 501)   // preserved
    }

    func testAddCommentExactly500Passes() async {
        var called = false
        let model = makeModel(add: { body in
            called = true
            return self.comment(body: body)
        })
        model.draft = String(repeating: "x", count: 500)
        await model.addComment()
        XCTAssertTrue(called)
        XCTAssertNil(model.inlineError)
    }

    // MARK: - addComment success / failure

    func testAddCommentSuccessAppendsAndClearsDraft() async {
        let stored = comment(body: "nice pick", user: me)
        let model = makeModel(
            loadCounts: { self.counts() },
            loadThread: { [] },
            add: { _ in stored }
        )
        await model.load()
        model.draft = "nice pick"
        await model.addComment()

        XCTAssertEqual(model.draft, "")
        XCTAssertNil(model.inlineError)
        XCTAssertEqual(model.thread.count, 1)
        XCTAssertEqual(model.thread.first?.0.id, stored.id)
        XCTAssertFalse(model.sending)
    }

    func testAddCommentThrowKeepsDraftAndSetsError() async {
        let model = makeModel(
            loadCounts: { self.counts() },
            loadThread: { [] },
            add: { _ in throw FakeError() }
        )
        await model.load()
        model.draft = "held onto"
        await model.addComment()

        XCTAssertEqual(model.draft, "held onto")   // preserved
        XCTAssertNotNil(model.inlineError)         // some failure message
        XCTAssertTrue(model.thread.isEmpty)
        XCTAssertFalse(model.sending)
    }

    func testAddCommentClearsPreviousInlineErrorOnValidSubmit() async {
        let stored = comment(body: "ok", user: me)
        let model = makeModel(loadCounts: { self.counts() }, add: { _ in stored })
        await model.load()
        // First: empty → error.
        model.draft = ""
        await model.addComment()
        XCTAssertEqual(model.inlineError, "say something")
        // Then: valid → error clears.
        model.draft = "ok"
        await model.addComment()
        XCTAssertNil(model.inlineError)
    }

    // MARK: - deleteComment

    func testDeleteRemovesOwnTopLevelRow() async {
        let mineRow = comment(id: UUID(uuidString: "C0000000-0000-0000-0000-0000000000AA")!, body: "mine", user: me)
        let keep = comment(id: UUID(uuidString: "C0000000-0000-0000-0000-0000000000BB")!, body: "theirs")
        var deleted: UUID?
        let model = makeModel(
            loadCounts: { self.counts(comments: 2) },
            loadThread: { [keep, mineRow] },
            delete: { id in deleted = id }
        )
        await model.load()
        await model.deleteComment(id: mineRow.id)

        XCTAssertEqual(deleted, mineRow.id)
        XCTAssertEqual(model.thread.count, 1)
        XCTAssertEqual(model.thread.first?.0.id, keep.id)
    }

    func testDeleteRemovesOwnReplyRow() async {
        let top = comment(id: UUID(uuidString: "C0000000-0000-0000-0000-0000000000CC")!, body: "top")
        let myReply = comment(id: UUID(uuidString: "C0000000-0000-0000-0000-0000000000DD")!,
                              body: "reply", parent: top.id, user: me)
        let model = makeModel(
            loadCounts: { self.counts(comments: 2) },
            loadThread: { [top, myReply] }
        )
        await model.load()
        XCTAssertEqual(model.thread.first?.1.count, 1)

        await model.deleteComment(id: myReply.id)

        XCTAssertEqual(model.thread.count, 1)
        XCTAssertTrue(model.thread.first?.1.isEmpty ?? false)
    }

    func testDeleteThrowKeepsRow() async {
        let mineRow = comment(id: UUID(uuidString: "C0000000-0000-0000-0000-0000000000EE")!, body: "mine", user: me)
        let model = makeModel(
            loadCounts: { self.counts(comments: 1) },
            loadThread: { [mineRow] },
            delete: { _ in throw FakeError() }
        )
        await model.load()
        await model.deleteComment(id: mineRow.id)
        // Failed delete leaves the row in place (revert / no-op).
        XCTAssertEqual(model.thread.count, 1)
    }
}
