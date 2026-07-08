import Foundation
import Supabase

/// `journal_entries` + `journal_entry_likes` I/O — the pure-CRUD half of the
/// C2 journal. Mirrors the read/write seams of web `services/journalService.ts`
/// against the binding contract in `docs/contracts/shared-payloads.md`.
///
/// Split by who may read `personal_takeaway`:
///  - `getOwnEntry` / `listOwnEntries` / `upsert` are OWNER-scoped and use
///    `select('*')` (or the returned row) — the ONLY paths that retain the
///    owner-only `personal_takeaway`. `JournalRow` carries it.
///  - `search` goes through the `search_journal_entries` SECURITY INVOKER RPC,
///    which returns a 23-column table (NO `personal_takeaway`, NO
///    `search_vector`). It decodes into `JournalSearchRow`, which has no
///    takeaway field by construction — a cross-user read can never surface it.
///
/// This actor is PURE CRUD. The upsert side effects (the `review` activity
/// event and the per-friend `journal_tag` notification) live in the Task 4
/// MODEL, not here — the repo builds/returns rows, the model orchestrates.
///
/// Reads the UI renders empty (`listOwnEntries`, `search`, `likedEntryIDs`)
/// THROW on failure and let the model catch to an empty state — the feed
/// convention (see FeedRepository). `SpoolClient.shared == nil` → `.notConfigured`.
///
/// Header last reviewed: 2026-07-07
public actor JournalRepository {

    public static let shared = JournalRepository()

    public enum RepoError: Error {
        case notConfigured
        case notAuthenticated
    }

    // MARK: reads — owner-scoped (retain personal_takeaway)

    /// The owner's FULL row for `tmdbId` (`select('*')`) — the probe-before-edit
    /// source. Web `getJournalEntry` (the only `select('*')` path). Returns nil
    /// when the owner has no entry for this movie yet. Decodes into an array +
    /// `.first` rather than `.single()` so a 0-row result is a clean nil, not a
    /// thrown "expected one row" error (web uses `.maybeSingle()`).
    public func getOwnEntry(tmdbId: String) async throws -> JournalRow? {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let rows: [JournalRow] = try await client
            .from("journal_entries")
            .select("*")
            .eq("user_id", value: userID.uuidString)
            .eq("tmdb_id", value: tmdbId)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// The owner's own entries, newest first. Throws on failure so the list
    /// model catches to an empty state (feed convention).
    public func listOwnEntries(limit: Int = 50) async throws -> [JournalRow] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        do {
            let rows: [JournalRow] = try await client
                .from("journal_entries")
                .select("*")
                .eq("user_id", value: userID.uuidString)
                .order("created_at", ascending: false)
                .limit(limit)
                .execute()
                .value
            return rows
        } catch {
            NSLog("[JournalRepository] listOwnEntries failed: \(error)")
            throw error
        }
    }

    /// `user_rankings.tier` for `(current user, tmdbId)` — null if the item
    /// isn't ranked. The upsert path resolves this at save time; `rating_tier`
    /// is NEVER taken from the form. 0-or-1 row, so array + `.first`.
    public func ratingTier(tmdbId: String) async throws -> String? {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let rows: [TierRow] = try await client
            .from("user_rankings")
            .select("tier")
            .eq("user_id", value: userID.uuidString)
            .eq("tmdb_id", value: tmdbId)
            .limit(1)
            .execute()
            .value
        return rows.first?.tier
    }

    // MARK: writes

    /// Full-replace upsert of the 20 client columns (`onConflict:
    /// user_id,tmdb_id`), returning the freshly written row. The caller passes
    /// a fully-built `JournalUpsertPayload` — `rating_tier` already resolved via
    /// `ratingTier(...)` and the payload assembled by `JournalEntryContract`
    /// (Task 4's model does the lookup-then-build). Any omitted field wipes it,
    /// so the payload always encodes all 20 (explicit null for optionals).
    @discardableResult
    public func upsert(_ payload: JournalUpsertPayload) async throws -> JournalRow {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        do {
            let row: JournalRow = try await client
                .from("journal_entries")
                .upsert(payload, onConflict: "user_id,tmdb_id")
                .select("*")
                .single()
                .execute()
                .value
            return row
        } catch {
            NSLog("[JournalRepository] upsert failed: \(error)")
            throw error
        }
    }

    /// Delete the current user's entry for `tmdbId`. Owner-only by RLS; the
    /// `eq(user_id)` is belt-and-suspenders so the delete can only ever touch
    /// the caller's own row.
    public func deleteEntry(tmdbId: String) async throws {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        do {
            _ = try await client
                .from("journal_entries")
                .delete()
                .eq("user_id", value: userID.uuidString)
                .eq("tmdb_id", value: tmdbId)
                .execute()
        } catch {
            NSLog("[JournalRepository] deleteEntry failed: \(error)")
            throw error
        }
    }

    // MARK: search — cross-user RPC (23 cols, NO personal_takeaway)

    /// `search_journal_entries(search_query, target_user_id)` — the SECURITY
    /// INVOKER RPC. `targetUserID` is a narrowing FILTER, never a trust
    /// boundary: the caller's RLS decides which rows come back. Returns the
    /// 23-column shared shape (no `personal_takeaway`, no `search_vector`).
    /// Throws on failure so the model catches to empty (feed convention).
    public func search(_ query: String, targetUserID: UUID) async throws -> [JournalSearchRow] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        do {
            let rows: [JournalSearchRow] = try await client
                .rpc("search_journal_entries",
                     params: JournalRepoLogic.searchRpcArgs(query: query, targetUserID: targetUserID))
                .execute()
                .value
            return rows
        } catch {
            NSLog("[JournalRepository] search failed: \(error)")
            throw error
        }
    }

    // MARK: likes

    /// Toggle the current user's like on `entryID`.
    ///
    /// Like = INSERT `{entry_id, user_id}` `ON CONFLICT DO NOTHING`
    /// (`upsert(onConflict:ignoreDuplicates:true)`): idempotent, and a repeat
    /// like cannot inflate the trigger-maintained `like_count`. A 23505 that
    /// still slips through is treated as SUCCESS (already liked) rather than
    /// an error — same tolerance as `FollowRepository.follow`. Unlike = DELETE
    /// own row (always allowed — a like can be withdrawn unconditionally).
    ///
    /// NEVER calls the dropped increment/decrement RPCs and NEVER writes
    /// `like_count` (trigger-owned).
    public func toggleLike(entryID: UUID, currentlyLiked: Bool) async throws {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        if currentlyLiked {
            // Withdraw the like.
            do {
                _ = try await client
                    .from("journal_entry_likes")
                    .delete()
                    .eq("entry_id", value: entryID.uuidString)
                    .eq("user_id", value: userID.uuidString)
                    .execute()
            } catch {
                NSLog("[JournalRepository] unlike failed: \(error)")
                throw error
            }
        } else {
            // Add the like: INSERT ... ON CONFLICT DO NOTHING.
            let payload = JournalRepoLogic.likeInsertPayload(entryID: entryID, userID: userID)
            do {
                _ = try await client
                    .from("journal_entry_likes")
                    .upsert(payload, onConflict: "entry_id,user_id", ignoreDuplicates: true)
                    .execute()
            } catch {
                if PostgresErrors.isUniqueViolation(error) {
                    // Already liked — idempotent no-op. The trigger derives the
                    // count from rows, so nothing to reconcile.
                    NSLog("[JournalRepository] like: already liked (ignored)")
                    return
                }
                NSLog("[JournalRepository] like failed: \(error)")
                throw error
            }
        }
    }

    /// Batch initial liked-state for the current viewer over `entryIDs` — the
    /// ids this viewer has liked. Cards MUST NOT default to "not liked"
    /// (historical double-increment drift); the list loads this once for the
    /// whole page. Throws on failure so the model catches to empty.
    public func likedEntryIDs(_ entryIDs: [UUID]) async throws -> Set<UUID> {
        guard !entryIDs.isEmpty else { return [] }
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        do {
            let rows: [JournalRepoLogic.LikeRow] = try await client
                .from("journal_entry_likes")
                .select("entry_id")
                .eq("user_id", value: userID.uuidString)
                .in("entry_id", values: entryIDs.map { $0.uuidString })
                .execute()
                .value
            return JournalRepoLogic.likedSet(from: rows)
        } catch {
            NSLog("[JournalRepository] likedEntryIDs failed: \(error)")
            throw error
        }
    }
}

// MARK: - Pure marshalling seams (tested — JournalRepositoryLogicTests)

/// The network-free bits of `JournalRepository`: the search-RPC arg builder,
/// the like-insert payload builder, and the liked-set reducer. Extracted so
/// the wire shapes are unit-tested without a live client — the network paths
/// are covered by build + these pure tests. Mirrors web `buildSearchRpcArgs`,
/// `buildLikeInsertPayload`, and `getLikedEntryIds`'s reduction.
public enum JournalRepoLogic {

    /// `{ search_query, target_user_id }` for `search_journal_entries`. Web
    /// `buildSearchRpcArgs(targetUserId, query)` returns exactly these two
    /// keys. Lowercase uuid on the wire (web parity; Swift's UUID uppercases).
    public static func searchRpcArgs(query: String, targetUserID: UUID) -> [String: AnyJSON] {
        [
            "search_query": .string(query),
            "target_user_id": .string(targetUserID.uuidString.lowercased()),
        ]
    }

    /// `{ entry_id, user_id }` for a `journal_entry_likes` insert. Web
    /// `buildLikeInsertPayload(entryId, userId)`. Lowercase uuids on the wire.
    public static func likeInsertPayload(entryID: UUID, userID: UUID) -> LikeInsertPayload {
        LikeInsertPayload(entry_id: entryID.uuidString.lowercased(),
                          user_id: userID.uuidString.lowercased())
    }

    /// Reduce fetched `entry_id` rows to a Set for O(1) card lookup. Web
    /// `getLikedEntryIds` does `new Set(rows.map(r => r.entry_id))`.
    public static func likedSet(from rows: [LikeRow]) -> Set<UUID> {
        Set(rows.map { $0.entry_id })
    }

    /// Insert payload for `journal_entry_likes` (snake_case columns).
    public struct LikeInsertPayload: Encodable, Equatable {
        public let entry_id: String
        public let user_id: String
    }

    /// One `journal_entry_likes` row projected to just `entry_id` — the shape
    /// `likedEntryIDs` selects and `likedSet` reduces.
    public struct LikeRow: Codable, Sendable, Hashable {
        public let entry_id: UUID
    }
}

// MARK: - DTOs

/// One `user_rankings` row projected to just `tier` (the `ratingTier` lookup).
private struct TierRow: Codable, Sendable {
    let tier: String?
}

/// The 23-column shared search-row DTO — the return shape of the
/// `search_journal_entries` RPC and every cross-user read
/// (`JOURNAL_ENTRY_SHARED_COLUMN_LIST`). Deliberately has NO
/// `personal_takeaway` and NO `search_vector` field: the owner-only takeaway
/// is unrepresentable here, so no cross-user read can surface it (audit B5).
/// Unlike `JournalRow` it carries `updated_at` (the RPC returns it) but NEVER
/// the takeaway. Extra keys in the payload are ignored on decode.
public struct JournalSearchRow: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let user_id: UUID
    public let tmdb_id: String
    public let title: String
    public let poster_url: String?
    public let rating_tier: String?
    public let review_text: String?
    public let contains_spoilers: Bool
    public let mood_tags: [String]?
    public let vibe_tags: [String]?
    public let favorite_moments: [String]?
    public let standout_performances: [StandoutPerformance]?
    public let watched_date: String?
    public let watched_location: String?
    public let watched_with_user_ids: [UUID]?
    public let watched_platform: String?
    public let is_rewatch: Bool
    public let rewatch_note: String?
    public let photo_paths: [String]?
    public let visibility_override: String?
    public let like_count: Int
    public let created_at: String
    public let updated_at: String

    public init(
        id: UUID, user_id: UUID, tmdb_id: String, title: String,
        poster_url: String?, rating_tier: String?, review_text: String?,
        contains_spoilers: Bool, mood_tags: [String]?, vibe_tags: [String]?,
        favorite_moments: [String]?, standout_performances: [StandoutPerformance]?,
        watched_date: String?, watched_location: String?, watched_with_user_ids: [UUID]?,
        watched_platform: String?, is_rewatch: Bool, rewatch_note: String?,
        photo_paths: [String]?, visibility_override: String?,
        like_count: Int, created_at: String, updated_at: String
    ) {
        self.id = id
        self.user_id = user_id
        self.tmdb_id = tmdb_id
        self.title = title
        self.poster_url = poster_url
        self.rating_tier = rating_tier
        self.review_text = review_text
        self.contains_spoilers = contains_spoilers
        self.mood_tags = mood_tags
        self.vibe_tags = vibe_tags
        self.favorite_moments = favorite_moments
        self.standout_performances = standout_performances
        self.watched_date = watched_date
        self.watched_location = watched_location
        self.watched_with_user_ids = watched_with_user_ids
        self.watched_platform = watched_platform
        self.is_rewatch = is_rewatch
        self.rewatch_note = rewatch_note
        self.photo_paths = photo_paths
        self.visibility_override = visibility_override
        self.like_count = like_count
        self.created_at = created_at
        self.updated_at = updated_at
    }
}
