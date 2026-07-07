import Foundation
import Supabase

/// Network half of the C1 feed data layer: the two feed RPCs plus the
/// engagement tables (`activity_reactions` / `activity_comments`) and the
/// `feed_mutes` CRUD.
///
///  - `fetchPage(mode:cursor:pageSize:)` — `get_feed_page` keyset pagination
///  - `rankingScores(pairs:)` — `get_feed_ranking_scores` batch score lookup
///  - `engagement(for:)` — batched reaction/comment counts per page
///  - `toggleReaction` / `comments(for:)` / `addComment` / `deleteComment`
///  - `mutes()` / `muteUser` / `unmuteUser` / `muteMedia` / `unmuteMedia`
///
/// ⚠️ THE TWO RPCs ARE NOT CALLABLE IN PROD YET: they ship with web PR #32's
/// migrations (`20260707_feed_page_rpc.sql`,
/// `20260707_feed_ranking_scores_rpc.sql`). Until #32 merges and those
/// migrations are applied, `fetchPage`/`rankingScores` fail server-side.
/// (The engagement tables exist since phase 2/5, but their event ids come
/// from `fetchPage`, so the whole surface goes live together.) Unit tests
/// therefore cover the pure layer only (FeedPipeline / FeedEngagement);
/// this actor's paths are exercised against a real backend once #32 lands.
///
/// All client-side feed logic lives in pure helpers — this actor only moves
/// bytes: mutes/type filter/throttle/cursor in `FeedPipeline`, the
/// engagement reducer, comment validation, and reply nesting in
/// `FeedEngagement.swift`. Follows the existing repository pattern: actor +
/// `SpoolClient.shared` guard, `[FeedRepository]`-prefixed logs, errors
/// rethrown to callers (`fetchPage` propagates the RPC's raise-classified
/// errors, e.g. 22023 for bad mode/cursor/page_size, so bugs fail loud
/// instead of rendering an empty feed).
public actor FeedRepository {

    public static let shared = FeedRepository()

    public enum RepoError: Error {
        case notConfigured
        case notAuthenticated
    }

    // MARK: - get_feed_page

    /// Fetch one raw keyset page of the boosted feed stream.
    ///
    /// Cursor contract (see FeedCursor): pass nil for the first page — both
    /// `cursor_rank` and `cursor_id` go up as EXPLICIT JSON nulls (the
    /// 4-parameter function has no argument defaults, so the keys must be
    /// present; `AnyJSON.null` encodes `encodeNil()`). Next pages echo the
    /// last consumed row's server-returned `(boosted_ts, id)` verbatim.
    /// `pageSize` is forwarded untouched; the RPC raises 22023 outside 1...100.
    public func fetchPage(mode: FeedMode,
                          cursor: FeedCursor?,
                          pageSize: Int = 20) async throws -> [FeedEventRow] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        let params: [String: AnyJSON] = [
            "mode": .string(mode.rawValue),
            "cursor_rank": cursor.map { .string($0.boostedTs) } ?? .null,
            "cursor_id": cursor.map { .string($0.id.uuidString.lowercased()) } ?? .null,
            "page_size": .integer(pageSize),
        ]

        do {
            return try await client
                .rpc("get_feed_page", params: params)
                .execute()
                .value
        } catch {
            NSLog("[FeedRepository] fetchPage(\(mode.rawValue)) failed: \(error)")
            throw error
        }
    }

    // MARK: - get_feed_ranking_scores

    /// Batch live-score lookup for ranking/review cards. One round trip for
    /// the whole page. Returns a map keyed `"<lowercase uuid>:<tmdbId>"`
    /// (`FeedPipeline.scoreKey` — web's `${userId}:${tmdbId}`); a pair with
    /// no visible ranking returns no row, so a missing key means "no score,
    /// hide the badge". Pairs are deduped before the call (web parity).
    public func rankingScores(pairs: [(userID: UUID, tmdbID: String)]) async throws -> [String: Double] {
        guard !pairs.isEmpty else { return [:] }
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        var seen = Set<String>()
        var rpcPairs: [ScorePairPayload] = []
        for pair in pairs {
            let key = FeedPipeline.scoreKey(userID: pair.userID, tmdbID: pair.tmdbID)
            guard seen.insert(key).inserted else { continue }
            // Lowercase uuid strings on the wire — same bytes web sends.
            rpcPairs.append(ScorePairPayload(user_id: pair.userID.uuidString.lowercased(),
                                             tmdb_id: pair.tmdbID))
        }

        do {
            let rows: [ScoreRow] = try await client
                .rpc("get_feed_ranking_scores", params: ScoresParams(pairs: rpcPairs))
                .execute()
                .value
            var map: [String: Double] = [:]
            map.reserveCapacity(rows.count)
            for row in rows {
                map[FeedPipeline.scoreKey(userID: row.user_id, tmdbID: row.tmdb_id)] = row.score
            }
            return map
        } catch {
            NSLog("[FeedRepository] rankingScores failed: \(error)")
            throw error
        }
    }
}

// MARK: - Engagement: reactions + comments (web feedService.ts sections
// "Reactions"/"Comments" on fix/c1-feed-web-blocking)

extension FeedRepository {

    // MARK: engagement batch

    /// Batched engagement lookup for one rendered page — web's
    /// `getReactionsForEvents`: two concurrent queries over the page's id
    /// set (`activity_reactions` → `event_id, user_id, reaction`;
    /// `activity_comments` → `event_id` only), reduced by the pure
    /// `EngagementReducer.aggregate`. Every requested id gets an entry;
    /// no session just means `myReactions` stays empty (reads don't
    /// require auth).
    public func engagement(for eventIDs: [UUID]) async throws -> [UUID: EngagementCounts] {
        guard !eventIDs.isEmpty else { return [:] }
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        let idStrings = eventIDs.map { $0.uuidString.lowercased() }
        do {
            async let reactionRows: [EngagementReducer.ReactionRow] = client
                .from("activity_reactions")
                .select("event_id, user_id, reaction")
                .in("event_id", values: idStrings)
                .execute()
                .value
            async let commentRows: [CommentEventRow] = client
                .from("activity_comments")
                .select("event_id")
                .in("event_id", values: idStrings)
                .execute()
                .value

            let (reactions, comments) = try await (reactionRows, commentRows)
            let me = await SpoolClient.currentUserID()
            return EngagementReducer.aggregate(
                rows: EngagementReducer.Rows(eventIDs: eventIDs,
                                             reactions: reactions,
                                             commentEventIDs: comments.map(\.event_id)),
                myUserID: me
            )
        } catch {
            NSLog("[FeedRepository] engagement batch failed: \(error)")
            throw error
        }
    }

    // MARK: reactions

    /// Toggle the signed-in user's `reaction` on an event and return the
    /// new state (true = reaction is now mine). `currentlyMine == false` →
    /// INSERT own row; `true` → DELETE own row (PK triple
    /// `(event_id, user_id, reaction)`). Outcome resolution — including
    /// D7's "23505 on insert = success" — is the pure
    /// `EngagementReducer.resolvedToggleState`; any other error throws.
    public func toggleReaction(eventID: UUID, reaction: String, currentlyMine: Bool) async throws -> Bool {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let me = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        var writeError: Error?
        do {
            if currentlyMine {
                _ = try await client
                    .from("activity_reactions")
                    .delete()
                    .eq("event_id", value: eventID.uuidString.lowercased())
                    .eq("user_id", value: me.uuidString.lowercased())
                    .eq("reaction", value: reaction)
                    .execute()
            } else {
                let payload = ReactionWritePayload(event_id: eventID, user_id: me, reaction: reaction)
                _ = try await client
                    .from("activity_reactions")
                    .insert(payload)
                    .execute()
            }
        } catch {
            writeError = error
        }

        do {
            return try EngagementReducer.resolvedToggleState(currentlyMine: currentlyMine,
                                                             writeError: writeError)
        } catch {
            NSLog("[FeedRepository] toggleReaction(\(reaction)) failed: \(error)")
            throw error
        }
    }

    // MARK: comments

    /// Flat comment page for one event — web's `listFeedComments` query:
    /// ascending `created_at`, limit 100. Returns the FLAT list; reply
    /// nesting is the caller's pure `FeedPipelineComments.nest` pass.
    public func comments(for eventID: UUID) async throws -> [FeedComment] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        do {
            return try await client
                .from("activity_comments")
                .select("id, event_id, user_id, body, parent_comment_id, created_at")
                .eq("event_id", value: eventID.uuidString.lowercased())
                .order("created_at", ascending: true)
                .limit(100)
                .execute()
                .value
        } catch {
            NSLog("[FeedRepository] comments(for:) failed: \(error)")
            throw error
        }
    }

    /// Insert a comment (optionally a 1-level reply) and return the stored
    /// row. Body is trimmed and validated FIRST — `CommentError.empty` /
    /// `.tooLong` throw before any I/O (the DB CHECK
    /// `length(btrim(body)) BETWEEN 1 AND 500` would reject them anyway;
    /// web silently `slice(0, 500)`s instead — iOS refuses rather than
    /// corrupts). `parent_comment_id` is omitted from the payload when nil,
    /// same as web's conditional key.
    public func addComment(eventID: UUID, body: String, parentID: UUID?) async throws -> FeedComment {
        let trimmed = try FeedPipelineComments.validatedBody(body)
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let me = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let payload = CommentInsertPayload(event_id: eventID,
                                           user_id: me,
                                           body: trimmed,
                                           parent_comment_id: parentID)
        do {
            return try await client
                .from("activity_comments")
                .insert(payload)
                .select()
                .single()
                .execute()
                .value
        } catch {
            NSLog("[FeedRepository] addComment failed: \(error)")
            throw error
        }
    }

    /// Delete OWN comment only — the `user_id` filter scopes the delete to
    /// the signed-in user client-side (web parity) on top of RLS; deleting
    /// someone else's comment id is a silent no-op, not an error.
    public func deleteComment(id: UUID) async throws {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let me = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        do {
            _ = try await client
                .from("activity_comments")
                .delete()
                .eq("id", value: id.uuidString.lowercased())
                .eq("user_id", value: me.uuidString.lowercased())
                .execute()
        } catch {
            NSLog("[FeedRepository] deleteComment failed: \(error)")
            throw error
        }
    }
}

// MARK: - Mutes (web feedService.ts section "Mutes" on
// fix/c1-feed-web-blocking, L611–658; table: phase-5 migration
// `feed_mutes(user_id, mute_type ∈ {'user','movie'}, target_id text,
// UNIQUE(user_id, mute_type, target_id))`)

/// One `feed_mutes` row as the read selects it (`mute_type, target_id`).
/// `target_id` is TEXT for both kinds: a lowercase uuid string for user
/// mutes, a tmdb id for movie mutes.
public struct FeedMuteRow: Codable, Sendable, Hashable {
    public let mute_type: String
    public let target_id: String

    public init(mute_type: String, target_id: String) {
        self.mute_type = mute_type
        self.target_id = target_id
    }
}

/// Pure mute helpers — the set-building reducer `FeedPipeline.applyMutes`
/// consumes, plus the insert payload builder. Extracted so both are
/// testable without a network (NotificationTests).
public enum FeedMutes {

    /// Split raw rows into the two mute sets — web `getFeedCards` L231–232:
    /// `mutes.filter(m => m.muteType === 'user'/'movie').map(m => m.targetId)`.
    /// Unknown `mute_type`s fall through both filters there and are dropped
    /// here too; a user `target_id` that isn't a parseable uuid can never
    /// match an `actor_id`, so it is dropped rather than crash the feed.
    public static func sets(from rows: [FeedMuteRow]) -> (users: Set<UUID>, media: Set<String>) {
        var users = Set<UUID>()
        var media = Set<String>()
        for row in rows {
            switch row.mute_type {
            case "user":
                if let id = UUID(uuidString: row.target_id) { users.insert(id) }
            case "movie":
                media.insert(row.target_id)
            default:
                continue
            }
        }
        return (users: users, media: media)
    }

    /// `feed_mutes` insert for a user mute — web `addMute` L636–640:
    /// exactly `{user_id, mute_type, target_id}` (`id`/`created_at` are
    /// server-side). The target uuid goes up lowercase so it compares
    /// equal to Postgres's text form of `actor_id`.
    public static func insertPayload(userID: UUID, mutingUser target: UUID) -> MuteInsertPayload {
        MuteInsertPayload(user_id: userID.uuidString.lowercased(),
                          mute_type: "user",
                          target_id: target.uuidString.lowercased())
    }

    /// `feed_mutes` insert for a movie mute (same shape, tmdb id target).
    public static func insertPayload(userID: UUID, mutingMedia tmdbID: String) -> MuteInsertPayload {
        MuteInsertPayload(user_id: userID.uuidString.lowercased(),
                          mute_type: "movie",
                          target_id: tmdbID)
    }
}

/// The exact `feed_mutes` insert column set. Built only via
/// `FeedMutes.insertPayload` so the two mute kinds can't drift.
public struct MuteInsertPayload: Encodable, Sendable, Equatable {
    public let user_id: String
    public let mute_type: String
    public let target_id: String
}

extension FeedRepository {

    /// The signed-in user's mute sets, ready for `FeedPipeline.applyMutes`
    /// — web `getMutes` (L613–629) + the set split (L231–232) in one call.
    /// The explicit `user_id` filter mirrors web on top of the
    /// own-rows-only RLS. No session → empty sets (an anonymous feed has
    /// nothing muted); read errors rethrow after logging.
    public func mutes() async throws -> (users: Set<UUID>, media: Set<String>) {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let me = await SpoolClient.currentUserID() else {
            NSLog("[FeedRepository] mutes: no session — empty")
            return (users: [], media: [])
        }

        do {
            let rows: [FeedMuteRow] = try await client
                .from("feed_mutes")
                .select("mute_type, target_id")
                .eq("user_id", value: me.uuidString.lowercased())
                .execute()
                .value
            return FeedMutes.sets(from: rows)
        } catch {
            NSLog("[FeedRepository] mutes failed: \(error)")
            throw error
        }
    }

    /// Mute a user's activity. Duplicate handling mirrors web `addMute`
    /// (L636–647): web has NO conflict special-case — any insert error,
    /// including the UNIQUE-triple 23505, is a logged failure there
    /// (`return false`), so here it throws like every other write error.
    /// (Contrast `toggleReaction`, where the contract explicitly makes
    /// 23505 a success.)
    public func muteUser(_ id: UUID) async throws {
        try await insertMute { FeedMutes.insertPayload(userID: $0, mutingUser: id) }
    }

    /// Unmute a user. iOS deletes by the UNIQUE triple `(user_id,
    /// mute_type, target_id)` instead of web's row id (`removeMute`,
    /// L648–658) because the plan's interface takes the target, not a
    /// mute-row id — the UNIQUE constraint makes the two exactly
    /// equivalent. Deleting a mute that doesn't exist is a no-op.
    public func unmuteUser(_ id: UUID) async throws {
        try await deleteMute(type: "user", targetID: id.uuidString.lowercased())
    }

    /// Mute a movie/show by tmdb id. Same duplicate semantics as
    /// `muteUser`.
    public func muteMedia(_ tmdbID: String) async throws {
        try await insertMute { FeedMutes.insertPayload(userID: $0, mutingMedia: tmdbID) }
    }

    /// Unmute a movie/show. Same by-target delete as `unmuteUser`.
    public func unmuteMedia(_ tmdbID: String) async throws {
        try await deleteMute(type: "movie", targetID: tmdbID)
    }

    // MARK: mute plumbing

    private func insertMute(_ payload: (UUID) -> MuteInsertPayload) async throws {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let me = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        do {
            _ = try await client
                .from("feed_mutes")
                .insert(payload(me))
                .execute()
        } catch {
            NSLog("[FeedRepository] mute insert failed: \(error)")
            throw error
        }
    }

    private func deleteMute(type: String, targetID: String) async throws {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let me = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        do {
            _ = try await client
                .from("feed_mutes")
                .delete()
                .eq("user_id", value: me.uuidString.lowercased())
                .eq("mute_type", value: type)
                .eq("target_id", value: targetID)
                .execute()
        } catch {
            NSLog("[FeedRepository] unmute failed: \(error)")
            throw error
        }
    }
}

// MARK: - Wire payloads (snake_case = wire format)

private struct ScoresParams: Encodable {
    let pairs: [ScorePairPayload]
}

private struct ScorePairPayload: Encodable {
    let user_id: String
    let tmdb_id: String
}

/// One `get_feed_ranking_scores` result row.
private struct ScoreRow: Decodable {
    let user_id: UUID
    let tmdb_id: String
    let score: Double
}

/// `activity_reactions` insert — the PK triple, nothing else
/// (`created_at` is server-defaulted).
private struct ReactionWritePayload: Encodable {
    let event_id: UUID
    let user_id: UUID
    let reaction: String
}

/// `activity_comments` insert. `parent_comment_id` is optional so the
/// synthesized encoder OMITS the key when nil (web only sets the key for
/// replies); `id`/`created_at` are server-generated.
private struct CommentInsertPayload: Encodable {
    let event_id: UUID
    let user_id: UUID
    let body: String
    let parent_comment_id: UUID?
}

/// Comment-count probe row — the batch query selects `event_id` only.
private struct CommentEventRow: Decodable {
    let event_id: UUID
}
