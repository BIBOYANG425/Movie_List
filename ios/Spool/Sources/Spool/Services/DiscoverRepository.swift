import Foundation
import Supabase

/// Reads for the social Discover screen (C3-iOS Part A, Task 5): friends'
/// recommendations and trending-among-friends. Supabase-only, TMDB-free —
/// mirrors web `DiscoverView`'s two data sources (`components/social/
/// DiscoverView.tsx`), which call `getFriendRecommendations` /
/// `getTrendingAmongFriends` in `services/tasteService.ts`.
///
/// Both entry points run under the SIGNED-IN USER'S own client, so RLS
/// enforces follow visibility exactly as web does — no service role, no RPC.
/// The reads are thin; all aggregation/sort/exclusion/capping is the pure
/// `DiscoverAggregation` core (`DiscoverModels.swift`, unit-tested).
///
/// Query shape (ported from tasteService):
///  - `friendRecommendations`: 4 reads — (1) `friend_follows` → following ids,
///    (2) the viewer's own ranked ids + (via WatchlistRepository) watchlisted
///    ids for the exclusion set, (3) friends' S/A `user_rankings`, (4)
///    `profiles` for the ≤3 chips (`tasteService.ts:216-278`).
///  - `trendingAmongFriends`: 3 reads — follows, friends' `user_rankings` with
///    `updated_at >= now()-Nd`, and `profiles` (`tasteService.ts:321-373`).
///
/// PRESERVED web quirks (documented, not fixed here):
///  - exclusion is a verbatim `tmdb_id` string compare (B1) — a bare-numeric
///    friend ranking won't match a `tmdb_`-prefixed exclusion,
///  - trending recency keys on `updated_at`, which whole-tier ceremony inserts
///    bump, so stale rankings can "trend" (D13). We do NOT invent a different
///    recency source.
///
/// Failure posture mirrors the feed convention (FeedRepository / WatchlistRepo
/// list): reads that back a UI list THROW and let the model catch to an empty/
/// error state; `SpoolClient.shared == nil` → `.notConfigured`, no session →
/// `.notAuthenticated`.
///
/// Header last reviewed: 2026-07-09
public actor DiscoverRepository {

    public static let shared = DiscoverRepository()

    public enum RepoError: Error {
        case notConfigured
        case notAuthenticated
    }

    // MARK: - Friend recommendations

    /// Friends' S/A `user_rankings` aggregated per movie, excluding the
    /// viewer's own ranked ∪ watchlisted ids, sorted friendCount DESC then avg
    /// tier (S best), capped at `limit`. Ports `getFriendRecommendations`
    /// (`tasteService.ts:211-311`).
    public func friendRecommendations(limit: Int = 20) async throws -> [FriendRecommendation] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        // 1. Following ids (`tasteService.ts:216-221`).
        let friendIDs = try await followingIDs(client: client, viewerID: userID)
        guard !friendIDs.isEmpty else { return [] }

        // 2. Viewer's own ranked + watchlisted ids for the exclusion set
        //    (`tasteService.ts:224-231`). The watchlist read goes through
        //    WatchlistRepository so the canonical bookmarked-id set (and its
        //    own read hardening) is shared with the rest of C3.
        async let rankedIDs: [FollowFollowingIDRow] = client
            .from("user_rankings")
            .select("tmdb_id")
            .eq("user_id", value: userID.uuidString)
            .execute()
            .value
        async let watchlistIDs: Set<String> = WatchlistRepository.shared
            .allBookmarkedIds(media: .movie)

        // 3. Friends' S/A rankings (`tasteService.ts:234-238`).
        async let friendRankingRows: [FriendRankingRow] = client
            .from("user_rankings")
            .select("tmdb_id, title, poster_url, year, genres, tier, user_id")
            .in("user_id", values: friendIDs.map(\.uuidString))
            .in("tier", values: ["S", "A"])
            .execute()
            .value

        let (rankedRows, bookmarked, friendRows) =
            try await (rankedIDs, watchlistIDs, friendRankingRows)

        guard !friendRows.isEmpty else { return [] }

        var excluded = bookmarked
        for r in rankedRows { excluded.insert(r.tmdb_id) }

        // 4. Profiles for the distinct rankers (`tasteService.ts:271-278`).
        let rankerIDs = Array(Set(friendRows.map(\.user_id)))
        let profiles = try await fetchProfiles(client: client, ids: rankerIDs)

        return DiscoverAggregation.friendRecommendations(
            rows: friendRows.map(Self.toRankingRow),
            excludedIds: excluded,
            profiles: profiles.map(Self.toProfileRow),
            limit: limit,
            avatarURL: Self.avatarURL
        )
    }

    // MARK: - Trending among friends

    /// Friends' `user_rankings` updated within the last `days`, kept when ≥2
    /// distinct friends ranked the movie, sorted rankerCount DESC then avg
    /// tier, numbered + capped at `limit`. Ports `getTrendingAmongFriends`
    /// (`tasteService.ts:316-398`). Recency keys on `updated_at` (D13 quirk).
    public func trendingAmongFriends(limit: Int = 15, days: Int = 30) async throws -> [TrendingMovie] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let friendIDs = try await followingIDs(client: client, viewerID: userID)
        guard !friendIDs.isEmpty else { return [] }

        // `now - days` as an ISO-8601 cutoff (web `new Date(Date.now() -
        // days*86_400_000).toISOString()`, `tasteService.ts:328`).
        let cutoff = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-Double(days) * 86_400)
        )

        let recentRows: [FriendRankingRow] = try await client
            .from("user_rankings")
            .select("tmdb_id, title, poster_url, year, genres, tier, user_id")
            .in("user_id", values: friendIDs.map(\.uuidString))
            .gte("updated_at", value: cutoff)
            .execute()
            .value

        guard !recentRows.isEmpty else { return [] }

        let rankerIDs = Array(Set(recentRows.map(\.user_id)))
        let profiles = try await fetchProfiles(client: client, ids: rankerIDs)

        return DiscoverAggregation.trendingAmongFriends(
            rows: recentRows.map(Self.toRankingRow),
            profiles: profiles.map(Self.toProfileRow),
            limit: limit,
            avatarURL: Self.avatarURL
        )
    }

    // MARK: - Follow probe (empty-state disambiguation)

    /// True when the signed-in viewer follows at least one person. Cheap single
    /// read over the follow edge (no profile hydration) — the Discover model
    /// uses it to tell "no friends yet" apart from "friends, nothing new" when
    /// both sections come back empty. Fails soft to `true` (assume connected)
    /// so a transient read blip never mislabels a well-connected user.
    public func hasFollows() async -> Bool {
        guard let client = SpoolClient.shared,
              let userID = await SpoolClient.currentUserID() else { return true }
        do {
            let rows = try await followingIDs(client: client, viewerID: userID)
            return !rows.isEmpty
        } catch {
            NSLog("[DiscoverRepository] hasFollows read failed: \(error)")
            return true
        }
    }

    // MARK: - Shared reads

    /// The viewer's following ids (`friend_follows.following_id where
    /// follower_id = viewer`). Same edge read FollowRepository / tasteService
    /// use.
    private func followingIDs(client: SupabaseClient, viewerID: UUID) async throws -> [UUID] {
        let rows: [FollowFollowRow] = try await client
            .from("friend_follows")
            .select("following_id")
            .eq("follower_id", value: viewerID.uuidString)
            .execute()
            .value
        return rows.map(\.following_id)
    }

    /// `profiles.id, username, avatar_path` for the given rankers. Empty ids →
    /// no query (web skips the `.in()` on an empty set implicitly).
    private func fetchProfiles(client: SupabaseClient, ids: [UUID]) async throws -> [ProfileChipRow] {
        guard !ids.isEmpty else { return [] }
        return try await client
            .from("profiles")
            .select("id, username, avatar_path")
            .in("id", values: ids.map(\.uuidString))
            .execute()
            .value
    }

    // MARK: - Mapping

    private static func toRankingRow(_ r: FriendRankingRow) -> DiscoverRankingRow {
        DiscoverRankingRow(
            tmdbId: r.tmdb_id, title: r.title, posterUrl: r.poster_url,
            year: r.year, genres: r.genres ?? [], tier: r.tier, userId: r.user_id
        )
    }

    private static func toProfileRow(_ p: ProfileChipRow) -> DiscoverProfileRow {
        DiscoverProfileRow(id: p.id, username: p.username ?? "", avatarPath: p.avatar_path)
    }

    /// Build a loadable avatar URL for a chip via the same storage/dicebear
    /// fallback the feed uses (`FeedCards.avatarURL`). Web hand-builds the
    /// storage URL and leaves it "" with no `avatar_path`; iOS carries the full
    /// chain so a chip always renders something.
    private static func avatarURL(_ p: DiscoverProfileRow) -> String {
        FeedCards.avatarURL(avatarUrl: nil, avatarPath: p.avatarPath, username: p.username)
    }
}

// MARK: - Decodable rows

/// A friend `user_rankings` row for Discover (matches the web select).
private struct FriendRankingRow: Decodable, Sendable {
    let tmdb_id: String
    let title: String
    let poster_url: String?
    let year: String?
    let genres: [String]?
    let tier: String
    let user_id: UUID
}

/// `friend_follows.following_id` projection.
private struct FollowFollowRow: Decodable, Sendable {
    let following_id: UUID
}

/// A single `tmdb_id` cell (the viewer's own-ranked read).
private struct FollowFollowingIDRow: Decodable, Sendable {
    let tmdb_id: String
}

/// `profiles.id, username, avatar_path` for building chips.
private struct ProfileChipRow: Decodable, Sendable {
    let id: UUID
    let username: String?
    let avatar_path: String?
}
