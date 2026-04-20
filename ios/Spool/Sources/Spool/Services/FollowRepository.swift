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
    /// username/avatar. This matches the web implementation and keeps RLS
    /// enforcement in Postgres (no client-side permission checks).
    public func getFollowing(userID: UUID) async throws -> [FollowedProfile] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        let rows: [FollowEdgeRow] = try await client
            .from("friend_follows")
            .select("follower_id, following_id, created_at")
            .eq("follower_id", value: userID.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value

        let ids = rows.compactMap { $0.following_id }
        guard !ids.isEmpty else { return [] }
        let profiles = try await ProfileRepository.shared.getProfilesByIds(ids)

        return rows.compactMap { row -> FollowedProfile? in
            guard let targetID = row.following_id,
                  let profile = profiles[targetID] else { return nil }
            return FollowedProfile(profile: profile, followedAt: row.created_at)
        }
    }

    /// Profiles that follow the given user, newest follower first.
    public func getFollowers(userID: UUID) async throws -> [FollowedProfile] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        let rows: [FollowEdgeRow] = try await client
            .from("friend_follows")
            .select("follower_id, following_id, created_at")
            .eq("following_id", value: userID.uuidString)
            .order("created_at", ascending: false)
            .execute()
            .value

        let ids = rows.compactMap { $0.follower_id }
        guard !ids.isEmpty else { return [] }
        let profiles = try await ProfileRepository.shared.getProfilesByIds(ids)

        return rows.compactMap { row -> FollowedProfile? in
            guard let actorID = row.follower_id,
                  let profile = profiles[actorID] else { return nil }
            return FollowedProfile(profile: profile, followedAt: row.created_at)
        }
    }

    /// Users who both `viewerID` and `targetID` follow, excluding the two
    /// participants themselves. Two selects (viewer's following,
    /// target's followers) — RLS already scopes both.
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

    /// Follow `targetID` as the signed-in user, plus fire-and-forget
    /// notification insert. Matches the web `followUser` flow — a failed
    /// notification insert does not fail the follow.
    @discardableResult
    public func follow(targetID: UUID) async throws -> Bool {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let me = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let payload = FollowInsertPayload(follower_id: me, following_id: targetID)
        do {
            _ = try await client.from("friend_follows").insert(payload).execute()
        } catch {
            print("[FollowRepository] follow failed: \(error)")
            return false
        }

        // Best-effort follower notification. Already-follows may collide on
        // the unique constraint above and skip this path — that's fine.
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
            print("[FollowRepository] follow notification insert failed: \(error)")
        }
        return true
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
