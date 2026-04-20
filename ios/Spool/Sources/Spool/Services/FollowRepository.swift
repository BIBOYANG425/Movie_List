import Foundation
import Supabase

/// `friend_follows` reads + writes. Mirrors the subset of
/// `services/followService.ts` and `getFollowingProfilesForUser` from
/// `profileService.ts` that iOS screens consume.
///
///  - `getFollowing(userID:)` — profiles this user follows, hydrated
///  - `getFollowers(userID:)` — profiles following this user, hydrated
///  - `follow(targetID:)` / `unfollow(targetID:)`
///  - `getMutualFollowCount(viewerID:targetID:)`
///
/// Writes include the `new_follower` notification insert that the web does
/// in `followUser` — the existing RLS policy on `notifications` handles the
/// permission check; we just fire-and-forget the insert.
///
/// Header last reviewed: 2026-04-19
public actor FollowRepository {

    public static let shared = FollowRepository()

    public enum RepoError: Error {
        case notConfigured
        case notAuthenticated
    }

    // MARK: reads

    /// Profiles the given user follows, newest follow first. Two-step query:
    /// (1) friend_follows rows → following IDs, (2) ProfileRepository for
    /// username/avatar.
    ///
    /// An edge whose target profile can't be hydrated (deleted user, RLS
    /// mismatch) is dropped — we can't render a row without a username. The
    /// logged delta tells us when that happens so a count mismatch between
    /// "what the DB says I follow" and "what we render" doesn't stay silent.
    public func getFollowing(userID: UUID) async throws -> [FollowedProfile] {
        try await hydratedEdges(
            filter: .follower(userID),
            edgeUserID: { $0.following_id }
        )
    }

    /// Profiles that follow the given user, newest follower first.
    public func getFollowers(userID: UUID) async throws -> [FollowedProfile] {
        try await hydratedEdges(
            filter: .following(userID),
            edgeUserID: { $0.follower_id }
        )
    }

    // MARK: follow hydration — shared between getFollowing / getFollowers

    private enum EdgeFilter {
        case follower(UUID)   // edges WHERE follower_id = <uuid>  → the user's followings
        case following(UUID)  // edges WHERE following_id = <uuid> → the user's followers

        var column: String {
            switch self {
            case .follower:   return "follower_id"
            case .following:  return "following_id"
            }
        }
        var value: String {
            switch self {
            case .follower(let id), .following(let id): return id.uuidString
            }
        }
    }

    private func hydratedEdges(filter: EdgeFilter,
                               edgeUserID: (FollowEdgeRow) -> UUID?) async throws -> [FollowedProfile] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        let rows: [FollowEdgeRow] = try await client
            .from("friend_follows")
            .select("follower_id, following_id, created_at")
            .eq(filter.column, value: filter.value)
            .order("created_at", ascending: false)
            .execute()
            .value

        let ids = rows.compactMap(edgeUserID)
        guard !ids.isEmpty else { return [] }
        let profiles = try await ProfileRepository.shared.getProfilesByIds(ids)

        let hydrated: [FollowedProfile] = rows.compactMap { row in
            guard let id = edgeUserID(row), let profile = profiles[id] else { return nil }
            return FollowedProfile(profile: profile, followedAt: row.created_at)
        }
        if hydrated.count != rows.count {
            NSLog("[FollowRepository] dropped \(rows.count - hydrated.count) edge(s) — profile unreadable")
        }
        return hydrated
    }

    /// Users that `viewerID` follows who also follow `targetID`. In other
    /// words, second-degree connections — "friends of mine who also follow
    /// this person." Excludes both participants themselves.
    ///
    /// (This is NOT "users both viewer and target follow"; that would be a
    /// different intersection. If we want that, both selects should project
    /// `following_id`. Keeping the current semantics because FriendsScreen
    /// uses this as a social-proof signal: "N people you follow already
    /// follow them.")
    public func getMutualFollowCount(viewerID: UUID, targetID: UUID) async throws -> Int {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        async let viewerFollowing: [FollowEdgeRow] = client
            .from("friend_follows")
            .select("following_id")
            .eq("follower_id", value: viewerID.uuidString)
            .execute()
            .value
        async let targetFollowers: [FollowEdgeRow] = client
            .from("friend_follows")
            .select("follower_id")
            .eq("following_id", value: targetID.uuidString)
            .execute()
            .value

        let (viewing, followed) = try await (viewerFollowing, targetFollowers)
        let viewerSet = Set(viewing.compactMap { $0.following_id })
        let targetSet = Set(followed.compactMap { $0.follower_id })
        let mutual = viewerSet.intersection(targetSet)
            .subtracting([viewerID, targetID])
        return mutual.count
    }

    // MARK: writes

    /// Follow `targetID` as the signed-in user, plus a best-effort
    /// `new_follower` notification insert.
    ///
    /// **Duplicate handling is explicit now:** we only treat the Postgres
    /// `unique_violation` error (code 23505) as "already following, no-op,
    /// return false without a notification". Any other error (network,
    /// RLS rejection, timeout) is re-thrown so transient failures don't
    /// get silently swallowed as "already following".
    @discardableResult
    public func follow(targetID: UUID) async throws -> Bool {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let me = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let payload = FollowInsertPayload(follower_id: me, following_id: targetID)
        do {
            _ = try await client.from("friend_follows").insert(payload).execute()
        } catch {
            if Self.isUniqueViolation(error) {
                // Already following this user — idempotent no-op; skip the
                // notification so we don't spam them on every re-tap.
                NSLog("[FollowRepository] follow: already follows (ignored)")
                return false
            }
            // Genuine failure: let the caller see it and decide whether to
            // retry or toast. Don't masquerade as "already following".
            NSLog("[FollowRepository] follow FAILED: \(error)")
            throw error
        }

        // New edge — notify.
        let notif = NotificationInsertPayload(
            user_id: targetID,
            type: "new_follower",
            title: "started following you",
            actor_id: me,
            reference_id: me.uuidString
        )
        do {
            _ = try await client.from("notifications").insert(notif).execute()
        } catch {
            // Notification is best-effort — don't fail the follow just
            // because the notification insert hiccupped.
            NSLog("[FollowRepository] follow notification insert failed: \(error)")
        }
        return true
    }

    /// Detect Postgres unique_violation (SQLSTATE 23505) surfaced through
    /// PostgREST. Supabase-swift exposes the error code via a couple of
    /// different shapes depending on the call site; string-matching the
    /// rendered description is a deliberate fallback for the cases where
    /// the typed Error doesn't carry a code we can pattern-match on.
    private static func isUniqueViolation(_ error: Error) -> Bool {
        let s = "\(error)"
        return s.contains("23505")
            || s.lowercased().contains("duplicate key")
            || s.lowercased().contains("unique constraint")
    }

    @discardableResult
    public func unfollow(targetID: UUID) async throws -> Bool {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let me = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        do {
            _ = try await client
                .from("friend_follows")
                .delete()
                .eq("follower_id", value: me.uuidString)
                .eq("following_id", value: targetID.uuidString)
                .execute()
            return true
        } catch {
            print("[FollowRepository] unfollow failed: \(error)")
            return false
        }
    }
}

// MARK: - DTOs

/// One row from `friend_follows`. Both id fields are optional because the
/// select can project only one of them depending on the query shape.
private struct FollowEdgeRow: Codable, Sendable {
    let follower_id: UUID?
    let following_id: UUID?
    let created_at: String?
}

private struct FollowInsertPayload: Encodable {
    let follower_id: UUID
    let following_id: UUID
}

private struct NotificationInsertPayload: Encodable {
    let user_id: UUID
    let type: String
    let title: String
    let actor_id: UUID
    let reference_id: String
}

/// A hydrated follow edge — the profile, plus when the follow happened.
public struct FollowedProfile: Sendable, Hashable, Identifiable {
    public let profile: ProfileRow
    public let followedAt: String?

    public var id: UUID { profile.id }
}
