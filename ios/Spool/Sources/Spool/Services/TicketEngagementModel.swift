import Foundation
import SwiftUI

/// Per-ticket engagement state — the observable that drives `FeedTicketBack`
/// (the flipped side of a feed ticket: reaction stamps, comment thread,
/// composer). One instance per event id.
///
/// `ObservableObject`, NOT `@Observable`: the package's platform floor is
/// iOS 16 / macOS 13 (Package.swift), and the Observation macro requires
/// iOS 17 / macOS 14. `ToastCenter` is the codebase precedent — same
/// `@MainActor final class … ObservableObject` + `@Published` shape.
///
/// ALL IO is injected as closures mirroring the `FeedRepository` engagement
/// signatures (same style as `FeedPageAssembler`'s typealias closures), so the
/// optimistic-update, validation, and failure paths are XCTest-covered with no
/// network (`TicketEngagementModelTests`). Task 5 binds the closures to
/// `FeedRepository.engagement`/`comments`/`toggleReaction`/`addComment`/
/// `deleteComment`.
///
/// State machine contract (pinned in the tests):
///  - `toggle(reaction:)` is OPTIMISTIC — `myReactions` flips and the count
///    adjusts BEFORE the write; a throw reverts BOTH, in either direction.
///  - `addComment()` runs the repository's OWN trim/1...500 validation
///    (`FeedPipelineComments.validatedBody`) BEFORE any IO, mapping the two
///    `CommentError`s to lowercase inline copy; the write closure never runs
///    for an invalid draft. On a write throw the draft is preserved; on
///    success the row appends and the draft clears.
///  - `deleteComment(id:)` removes exactly the matching row (top-level or
///    reply) on success; a throw leaves the thread untouched.
///  - `load()` failure sets `loadFailed` (empty state, never a crash); thread
///    nesting is a straight `FeedPipelineComments.nest` passthrough.
///
/// Contract: docs/plans/2026-07-08-c1-ios-feed-ui-plan.md (Task 4), spec
/// docs/plans/2026-07-08-c1-ios-feed-ui-design.md §2.
@MainActor
public final class TicketEngagementModel: ObservableObject {

    // MARK: Injected IO (mirrors FeedRepository engagement signatures)

    /// `FeedRepository.engagement(for:)` narrowed to this event's counts.
    public typealias LoadCounts = () async throws -> EngagementCounts
    /// `FeedRepository.comments(for:)` — the FLAT asc page (nesting is ours).
    public typealias LoadThread = () async throws -> [FeedComment]
    /// `FeedRepository.toggleReaction(eventID:reaction:currentlyMine:)` bound to
    /// this event — takes `(reaction, currentlyMine)`, returns the new state.
    public typealias ToggleReaction = (String, Bool) async throws -> Bool
    /// `FeedRepository.addComment(eventID:body:parentID:)` bound to this event's
    /// top level — takes the raw body, returns the stored row.
    public typealias AddComment = (String) async throws -> FeedComment
    /// `FeedRepository.deleteComment(id:)`.
    public typealias DeleteComment = (UUID) async throws -> Void

    // MARK: Published state

    /// Reaction + comment counts snapshot; nil until `load()` succeeds.
    @Published public private(set) var counts: EngagementCounts?
    /// 1-level nested thread: each top-level comment with its replies.
    @Published public private(set) var thread: [(FeedComment, [FeedComment])] = []
    /// Composer text — two-way bound to the TextField.
    @Published public var draft: String = ""
    /// Inline composer error (validation or send failure); lowercase voice.
    @Published public private(set) var inlineError: String?
    /// A send is in flight — disables the send button.
    @Published public private(set) var sending: Bool = false
    /// The initial load failed; the back shows an empty/error state.
    @Published public private(set) var loadFailed: Bool = false

    // MARK: Stored

    public let eventID: UUID
    private let loadCounts: LoadCounts
    private let loadThread: LoadThread
    private let toggleReaction: ToggleReaction
    private let addCommentIO: AddComment
    private let deleteCommentIO: DeleteComment

    public init(eventID: UUID,
                loadCounts: @escaping LoadCounts,
                loadThread: @escaping LoadThread,
                toggleReaction: @escaping ToggleReaction,
                addComment: @escaping AddComment,
                deleteComment: @escaping DeleteComment) {
        self.eventID = eventID
        self.loadCounts = loadCounts
        self.loadThread = loadThread
        self.toggleReaction = toggleReaction
        self.addCommentIO = addComment
        self.deleteCommentIO = deleteComment
    }

    // MARK: - Load

    /// Fetch counts + thread. Either failure flips `loadFailed` and leaves the
    /// state empty — a blank back beats a crashed one (plan Task 4). Success
    /// clears the flag so a retry can recover.
    public func load() async {
        do {
            let (loaded, flat) = try await loadBoth()
            counts = loaded
            thread = FeedPipelineComments.nest(flat)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    /// Both reads concurrently; either throw fails the load.
    private func loadBoth() async throws -> (EngagementCounts, [FeedComment]) {
        async let countsTask = loadCounts()
        async let threadTask = loadThread()
        return try await (countsTask, threadTask)
    }

    // MARK: - Reactions (optimistic)

    /// Toggle one reaction stamp. The UI updates FIRST (flip `myReactions`,
    /// bump the count ±1), then the write runs; on throw we revert both so the
    /// stamp snaps back. The write closure receives the PRE-toggle mine-state
    /// (what the repository needs to decide insert vs delete), and its returned
    /// state is authoritative — a `23505`-as-success passthrough (already
    /// resolved in the repository) simply confirms the optimistic add.
    public func toggle(reaction: String) async {
        // Re-entrancy guard (Task 5): a stamp button double-tap must not fire
        // two overlapping writes — the second would race the first's revert.
        // `sending` gates both the composer send and the stamp toggles so
        // only one engagement write is ever in flight per ticket.
        guard !sending else { return }
        guard let before = counts else { return }
        let wasMine = before.myReactions.contains(reaction)

        // Optimistic apply.
        counts = Self.applyToggle(before, reaction: reaction, nowMine: !wasMine)

        sending = true
        defer { sending = false }
        do {
            let confirmed = try await toggleReaction(reaction, wasMine)
            // Reconcile if the server's truth differs from the optimistic
            // guess (defensive; normally confirmed == !wasMine).
            if let current = counts, current.myReactions.contains(reaction) != confirmed {
                counts = Self.applyToggle(current, reaction: reaction, nowMine: confirmed)
            }
        } catch {
            // Revert to the pre-toggle snapshot.
            counts = before
        }
    }

    /// Pure count/mine adjustment for one reaction. `nowMine` true → +1 and
    /// insert; false → -1 (floored at zero) and remove. Only the one key
    /// moves; the other four are untouched.
    static func applyToggle(_ c: EngagementCounts, reaction: String, nowMine: Bool) -> EngagementCounts {
        var reactions = c.reactions
        var mine = c.myReactions
        let current = reactions[reaction] ?? 0
        if nowMine {
            reactions[reaction] = current + 1
            mine.insert(reaction)
        } else {
            reactions[reaction] = max(0, current - 1)
            mine.remove(reaction)
        }
        return EngagementCounts(reactions: reactions, comments: c.comments, myReactions: mine)
    }

    // MARK: - Comments

    /// Validate the draft with the repository's OWN rule, then send. Empty /
    /// whitespace and >500 map to inline copy and NEVER hit the write closure
    /// (mirrors `FeedRepository.addComment`, which throws the same
    /// `CommentError` before any IO). On success the stored row appends to the
    /// thread and the draft clears; on a send failure the draft is preserved so
    /// the user can retry.
    public func addComment() async {
        // Re-entrancy guard (Task 5): once wired to the send button a double-
        // tap is genuine; a second send while the first is in flight would
        // post the draft twice and clear it out from under the retry. One
        // send per ticket at a time — `sending` also gates reaction toggles.
        guard !sending else { return }
        inlineError = nil

        // Local validation FIRST — same trim/1...500 the repository enforces.
        let body: String
        do {
            body = try FeedPipelineComments.validatedBody(draft)
        } catch let error as CommentError {
            inlineError = Self.message(for: error)
            return
        } catch {
            inlineError = Self.genericSendFailure
            return
        }

        sending = true
        defer { sending = false }
        do {
            let stored = try await addCommentIO(body)
            appendToThread(stored)
            draft = ""
        } catch {
            inlineError = Self.genericSendFailure   // draft PRESERVED
        }
    }

    /// Delete OWN comment. On success drop it from the thread (top-level row or
    /// a reply); a throw leaves the thread as-is.
    public func deleteComment(id: UUID) async {
        do {
            try await deleteCommentIO(id)
            removeFromThread(id)
        } catch {
            // No-op on failure — the row stays visible.
        }
    }

    // MARK: - Thread mutation (local, structure-preserving)

    /// Append a newly stored comment. A top-level comment starts a new thread
    /// row; a reply slots under its parent when that parent is on the page
    /// (matching `FeedPipelineComments.nest`'s drop-if-parent-absent rule).
    private func appendToThread(_ comment: FeedComment) {
        if let parent = comment.parent_comment_id {
            guard let idx = thread.firstIndex(where: { $0.0.id == parent }) else { return }
            thread[idx].1.append(comment)
        } else {
            thread.append((comment, []))
        }
        bumpCommentCount(by: 1)
    }

    /// Remove a comment by id from wherever it lives (top level or a reply).
    private func removeFromThread(_ id: UUID) {
        if let idx = thread.firstIndex(where: { $0.0.id == id }) {
            thread.remove(at: idx)
            bumpCommentCount(by: -1)
            return
        }
        for i in thread.indices {
            if let replyIdx = thread[i].1.firstIndex(where: { $0.id == id }) {
                thread[i].1.remove(at: replyIdx)
                bumpCommentCount(by: -1)
                return
            }
        }
    }

    /// Keep the comment tally in step with local thread edits (floored at 0).
    private func bumpCommentCount(by delta: Int) {
        guard let c = counts else { return }
        counts = EngagementCounts(reactions: c.reactions,
                                  comments: max(0, c.comments + delta),
                                  myReactions: c.myReactions)
    }

    // MARK: - Copy

    static let genericSendFailure = "couldn't post — try again"

    /// Lowercase composer copy for the two validation errors (spec §2 voice).
    static func message(for error: CommentError) -> String {
        switch error {
        case .empty:   return "say something"
        case .tooLong: return "keep it under 500"
        }
    }
}
