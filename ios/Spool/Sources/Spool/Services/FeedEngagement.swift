import Foundation

/// Pure engagement half of the C1 feed contract — reactions + comments,
/// the Swift mirror of the "Reactions"/"Comments" sections of web's
/// `services/feedService.ts` (branch `fix/c1-feed-web-blocking`). Lives in
/// its own file (not FeedPipeline.swift) because engagement is a separate
/// table family (`activity_reactions`/`activity_comments`) with its own
/// reducer, validation, and nesting — FeedPipeline stays the page-stream
/// pipeline (cursor/mutes/filter/throttle), matching web's own section
/// boundaries. No network, no clocks: everything here is a pure function,
/// XCTest-covered in FeedEngagementTests.
///
/// Contract source: docs/plans/2026-07-08-c1-ios-feed-data-plan.md
/// (Global Constraints + Task 3), quoting docs/contracts/shared-payloads.md
/// on branch fix/c1-feed-web-blocking @ e57850c.

// MARK: - Engagement counts

/// Per-event engagement snapshot for one feed card:
/// `reactions` always carries EXACTLY the five contract types (zeroed when
/// absent — web's `emptyReactionCounts()`); `myReactions` is the set of
/// types the signed-in viewer holds on the event (PK is
/// `(event_id, user_id, reaction)`, so several per user are legal).
public struct EngagementCounts: Sendable, Equatable {
    public let reactions: [String: Int]
    public let comments: Int
    public let myReactions: Set<String>

    public init(reactions: [String: Int], comments: Int, myReactions: Set<String>) {
        self.reactions = reactions
        self.comments = comments
        self.myReactions = myReactions
    }
}

// MARK: - Reducer (aggregate + toggle resolution)

/// Pure reducers behind `FeedRepository`'s engagement calls — extracted so
/// the row math is testable without a network.
public enum EngagementReducer {

    /// The five contract reaction types (phase-5 CHECK constraint; web's
    /// `REACTION_TYPES`). Anything else — e.g. a stray legacy `like` row —
    /// is ignored by the reducer, exactly like web's
    /// `REACTION_TYPES.includes(reaction)` guard.
    public static let reactionTypes: Set<String> = [
        "fire", "agree", "disagree", "want_to_watch", "love",
    ]

    /// One `activity_reactions` row as the batch query selects it
    /// (`event_id, user_id, reaction`). snake_case = wire format.
    public struct ReactionRow: Codable, Sendable, Hashable {
        public let event_id: UUID
        public let user_id: UUID
        public let reaction: String

        public init(event_id: UUID, user_id: UUID, reaction: String) {
            self.event_id = event_id
            self.user_id = user_id
            self.reaction = reaction
        }
    }

    /// Raw inputs to one aggregate pass: the page's event-id set plus the
    /// two batch query results (`activity_reactions` rows; one element of
    /// `commentEventIDs` per `activity_comments` row — the comment query
    /// selects only `event_id`, mirroring web).
    public struct Rows: Sendable {
        public let eventIDs: [UUID]
        public let reactions: [ReactionRow]
        public let commentEventIDs: [UUID]

        public init(eventIDs: [UUID], reactions: [ReactionRow], commentEventIDs: [UUID]) {
            self.eventIDs = eventIDs
            self.reactions = reactions
            self.commentEventIDs = commentEventIDs
        }
    }

    private static var zeroCounts: [String: Int] {
        reactionTypes.reduce(into: [:]) { $0[$1] = 0 }
    }

    /// Web's `getReactionsForEvents` tally, minus the I/O: EVERY id in
    /// `rows.eventIDs` gets an entry (zeroed when untouched — a card with
    /// no engagement renders zeroes, not a missing key); rows for events
    /// outside the id set are dropped; unknown reaction types are dropped;
    /// `myReactions` collects the viewer's own types (`myUserID` nil — no
    /// session — means the set stays empty).
    public static func aggregate(rows: Rows, myUserID: UUID?) -> [UUID: EngagementCounts] {
        guard !rows.eventIDs.isEmpty else { return [:] }

        // Mutable working state per event id.
        var reactionCounts: [UUID: [String: Int]] = [:]
        var commentCounts: [UUID: Int] = [:]
        var mine: [UUID: Set<String>] = [:]
        for id in rows.eventIDs {
            reactionCounts[id] = zeroCounts
            commentCounts[id] = 0
            mine[id] = []
        }

        for row in rows.reactions {
            guard reactionCounts[row.event_id] != nil else { continue }
            guard reactionTypes.contains(row.reaction) else { continue }
            reactionCounts[row.event_id]![row.reaction, default: 0] += 1
            if row.user_id == myUserID {
                mine[row.event_id]!.insert(row.reaction)
            }
        }

        for eventID in rows.commentEventIDs {
            guard commentCounts[eventID] != nil else { continue }
            commentCounts[eventID]! += 1
        }

        var result: [UUID: EngagementCounts] = [:]
        result.reserveCapacity(rows.eventIDs.count)
        for id in rows.eventIDs {
            result[id] = EngagementCounts(reactions: reactionCounts[id]!,
                                          comments: commentCounts[id]!,
                                          myReactions: mine[id]!)
        }
        return result
    }

    /// Resolve `toggleReaction`'s post-write state from the write outcome.
    /// Truth table (pinned in FeedEngagementTests):
    ///   insert ok            → true   (reaction now mine)
    ///   insert 23505         → true   (D7: row already exists = desired
    ///                                  end state, `PostgresErrors
    ///                                  .isUniqueViolation`)
    ///   insert other error   → throws
    ///   delete ok            → false  (reaction no longer mine)
    ///   delete ANY error     → throws (the 23505 special case is
    ///                                  insert-only)
    public static func resolvedToggleState(currentlyMine: Bool, writeError: Error?) throws -> Bool {
        if let writeError {
            if !currentlyMine && PostgresErrors.isUniqueViolation(writeError) {
                return true
            }
            throw writeError
        }
        return !currentlyMine
    }
}

// MARK: - Comments

/// `addComment` validation failures — thrown BEFORE any I/O.
public enum CommentError: Error, Equatable {
    case empty
    case tooLong
}

/// One `activity_comments` row. snake_case = wire format; columns verified
/// against `supabase_phase2_activity_patch.sql` (base table) +
/// `supabase_phase5_social_feed.sql` (`parent_comment_id`). `created_at`
/// stays a String, same policy as `FeedEventRow`.
public struct FeedComment: Codable, Sendable, Hashable {
    public let id: UUID
    public let event_id: UUID
    public let user_id: UUID
    public let body: String
    public let parent_comment_id: UUID?
    public let created_at: String

    public init(id: UUID, event_id: UUID, user_id: UUID, body: String,
                parent_comment_id: UUID?, created_at: String) {
        self.id = id
        self.event_id = event_id
        self.user_id = user_id
        self.body = body
        self.parent_comment_id = parent_comment_id
        self.created_at = created_at
    }
}

public enum FeedPipelineComments {

    /// Contract max body length AFTER trimming — the DB CHECK is
    /// `length(btrim(body)) BETWEEN 1 AND 500`.
    public static let maxBodyLength = 500

    /// Trim, then enforce 1...500. Throws `CommentError.empty` /
    /// `.tooLong` — a deliberate divergence from web's silent
    /// `body.slice(0, 500)`: iOS refuses over-length text instead of
    /// corrupting it, and the thrown error is what the composer UI needs
    /// anyway. Returns the trimmed body that goes on the wire.
    public static func validatedBody(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CommentError.empty }
        guard trimmed.count <= maxBodyLength else { throw CommentError.tooLong }
        return trimmed
    }

    /// 1-level reply nesting over one asc-ordered `comments(for:)` page —
    /// an exact mirror of web's `listFeedComments` render pass
    /// (feedService.ts L553–571 on fix/c1-feed-web-blocking): comments with
    /// `parent_comment_id == nil` are the top-level threads; every other
    /// comment goes into a parent-keyed reply map, and the fill pass
    /// (web L567–568) reads that map ONLY for top-level ids. Consequences,
    /// mirrored precisely so the same rows render the same on both
    /// platforms:
    ///  - a reply whose parent is absent from the page (e.g. beyond the
    ///    100-row limit) is DROPPED;
    ///  - a reply-to-a-reply is dropped too: its parent renders as a
    ///    reply, is never visited by web's fill loop, so its `replies`
    ///    stay the `[]` they were initialized with (web L549) and the
    ///    grandchild never surfaces.
    ///
    /// ⚠️ Candidate SHARED fix (both platforms in one cycle — ledger
    /// item): the drop is arguably a bug — a reply whose parent is missing
    /// from the fetched page silently vanishes. Until web and iOS change
    /// together, web is the reference and iOS mirrors the drop.
    public static func nest(_ flat: [FeedComment]) -> [(FeedComment, [FeedComment])] {
        var topLevel: [FeedComment] = []
        var replies: [UUID: [FeedComment]] = [:]  // web's replyMap — keyed by parent id, unconditionally
        for comment in flat {
            if let parent = comment.parent_comment_id {
                replies[parent, default: []].append(comment)
            } else {
                topLevel.append(comment)
            }
        }
        // Web L567–568: only top-level ids are read back out of the map;
        // entries keyed by absent or reply-level parents are dropped here.
        return topLevel.map { ($0, replies[$0.id] ?? []) }
    }
}
