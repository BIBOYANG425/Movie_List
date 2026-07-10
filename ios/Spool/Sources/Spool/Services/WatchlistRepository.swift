import Foundation
import Supabase

/// The three parallel watchlist tables (`watchlist_items`,
/// `tv_watchlist_items`, `book_watchlist_items`) as one actor. Pure CRUD over
/// the binding contract in the C3 web audit §1.1/§1.4; the marshalling seams
/// (row→model, id helpers, whole-show detection, B2 rejection, exclusion-id
/// expansion, add-payload shapes) live in `WatchlistContract`
/// (`WatchlistModels.swift`) and are unit-tested there.
///
/// Reads are ordered `added_at desc` and mapped through `WatchlistContract`,
/// which SKIPS corrupt `show_tmdb_id = 0` TV rows (B2) — those never surface.
/// Writes: `add` UPSERTs on `(user_id, tmdb_id)` (the B3a UPDATE policy landed
/// in C3-web, so merge-duplicates is safe); `remove` DELETEs by
/// `(user_id, tmdb_id)`. The client NEVER sends `added_at` (DB `default now()`).
///
/// Failure posture mirrors the feed convention (see FeedRepository /
/// JournalRepository): reads that back a UI list THROW and let the caller
/// catch to an empty state; `SpoolClient.shared == nil` → `.notConfigured`.
///
/// Header last reviewed: 2026-07-09
public actor WatchlistRepository {

    public static let shared = WatchlistRepository()

    public enum RepoError: Error {
        case notConfigured
        case notAuthenticated
    }

    // MARK: reads — own rows (added_at desc)

    /// The signed-in user's own watchlist for `media`, newest first. Corrupt
    /// TV rows (`show_tmdb_id = 0`, B2) are dropped by the mapper. Throws on
    /// failure so the tab model catches to an empty state (feed convention).
    public func list(media: WatchlistMediaType) async throws -> [WatchlistItem] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }
        return try await fetch(client: client, media: media, userID: userID)
    }

    /// Another user's watchlist for `media`, newest first. `userID` is a
    /// narrowing FILTER, not a trust boundary: RLS decides which rows come
    /// back. All three tables are follower-visible — movie via the
    /// 20260709 migration (Q2 owner adjudication), TV and book from their
    /// original follower SELECT policies. Non-followers get []. Used by
    /// Discover's Twin read (Task 5). Throws on failure (feed convention).
    public func listForUser(userId: UUID, media: WatchlistMediaType) async throws -> [WatchlistItem] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        return try await fetch(client: client, media: media, userID: userId)
    }

    /// Shared read core: `select * where user_id = ? order by added_at desc`,
    /// decoded into the media's row DTO and mapped (dropping B2 rows).
    private func fetch(client: SupabaseClient,
                       media: WatchlistMediaType,
                       userID: UUID) async throws -> [WatchlistItem] {
        let table = WatchlistContract.tableName(for: media)
        do {
            let query = client
                .from(table)
                .select("*")
                .eq("user_id", value: userID.uuidString)
                .order("added_at", ascending: false)

            switch media {
            case .movie:
                let rows: [WatchlistRow] = try await query.execute().value
                return rows.compactMap(WatchlistContract.mapMovieRow)
            case .tv:
                let rows: [TVWatchlistRow] = try await query.execute().value
                return rows.compactMap(WatchlistContract.mapTVRow)
            case .book:
                let rows: [BookWatchlistRow] = try await query.execute().value
                return rows.compactMap(WatchlistContract.mapBookRow)
            }
        } catch {
            NSLog("[WatchlistRepository] list(\(media.rawValue)) failed: \(error)")
            throw error
        }
    }

    // MARK: reads — exclusion sets

    /// Every bookmarked id for the signed-in user in `media`, as an exclusion
    /// Set. For TV, season ids are EXPANDED to also include the show-level id
    /// (`tv_{n}_s{m}` → `+ tv_{n}`) so the TV suggestion engine — which
    /// excludes on show ids — filters a bookmarked season's show too
    /// (audit §1.4). Returns `[]` on failure (this is a filter, not a UI list:
    /// a read hiccup should degrade to "exclude nothing", not blow up the
    /// caller's suggestion fetch).
    public func allBookmarkedIds(media: WatchlistMediaType) async throws -> Set<String> {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let table = WatchlistContract.tableName(for: media)
        do {
            let rows: [IdRow] = try await client
                .from(table)
                .select("tmdb_id")
                .eq("user_id", value: userID.uuidString)
                .execute()
                .value
            let ids = rows.map(\.tmdb_id)
            return media == .tv
                ? WatchlistContract.expandedBookmarkedIds(ids)
                : Set(ids)
        } catch {
            NSLog("[WatchlistRepository] allBookmarkedIds(\(media.rawValue)) failed: \(error)")
            return []
        }
    }

    // MARK: writes

    /// UPSERT `item` into its media's table on `(user_id, tmdb_id)` — a
    /// re-add of an already-bookmarked id updates the row rather than failing
    /// the unique key (the B3a UPDATE policy landed in C3-web; merge-duplicates
    /// is safe). Never writes `added_at` (DB `default now()`). Returns true on
    /// success, false on failure (the web reverts its optimistic prepend and
    /// toasts on error — the caller decides the UI reaction from this bool).
    @discardableResult
    public func add(item: WatchlistItem) async -> Bool {
        guard let client = SpoolClient.shared else {
            NSLog("[WatchlistRepository] add(\(item.mediaType.rawValue) \(item.id)) skipped: client not configured")
            return false
        }
        guard let userID = await SpoolClient.currentUserID() else {
            NSLog("[WatchlistRepository] add(\(item.mediaType.rawValue) \(item.id)) skipped: not authenticated")
            return false
        }

        let table = WatchlistContract.tableName(for: item.mediaType)
        do {
            switch item.mediaType {
            case .movie:
                _ = try await client.from(table)
                    .upsert(WatchlistContract.movieAddPayload(item, userID: userID),
                            onConflict: "user_id,tmdb_id")
                    .execute()
            case .tv:
                _ = try await client.from(table)
                    .upsert(WatchlistContract.tvAddPayload(item, userID: userID),
                            onConflict: "user_id,tmdb_id")
                    .execute()
            case .book:
                _ = try await client.from(table)
                    .upsert(WatchlistContract.bookAddPayload(item, userID: userID),
                            onConflict: "user_id,tmdb_id")
                    .execute()
            }
            return true
        } catch {
            NSLog("[WatchlistRepository] add(\(item.mediaType.rawValue) \(item.id)) failed: \(error)")
            return false
        }
    }

    /// DELETE the signed-in user's row for `tmdbId` in `media`. Owner-only by
    /// RLS; the `eq(user_id)` is belt-and-suspenders. Throws on failure so a
    /// caller that wants to revert an optimistic remove can (web ignores the
    /// error and lets the row reappear on next load — that choice lives in the
    /// caller, not here).
    public func remove(tmdbId: String, media: WatchlistMediaType) async throws {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let table = WatchlistContract.tableName(for: media)
        do {
            _ = try await client
                .from(table)
                .delete()
                .eq("user_id", value: userID.uuidString)
                .eq("tmdb_id", value: tmdbId)
                .execute()
        } catch {
            NSLog("[WatchlistRepository] remove(\(media.rawValue) \(tmdbId)) failed: \(error)")
            throw error
        }
    }
}

// MARK: - Decodable helper rows

/// Projection of a single `tmdb_id` cell — the `allBookmarkedIds` read.
private struct IdRow: Decodable {
    let tmdb_id: String
}
