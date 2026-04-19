import Foundation
import Supabase

/// Writes to `public.friend_follows`. Column names match the web app and the
/// `supabase_schema.sql` migration: `follower_id` (the user doing the
/// following) and `following_id` (the target). RLS only allows `INSERT` when
/// `auth.uid() = follower_id`, so a Supabase session is required.
///
/// The web app follows up each insert with a `notifications` row; we skip that
/// here for now — the onboarding friend-search step is the only caller today
/// and the notification flow can be added alongside a proper notifications
/// surface.
///
/// Header last reviewed: 2026-04-18
public actor FollowService {

    public static let shared = FollowService()

    public enum FollowError: Error {
        case notConfigured
        case notAuthenticated
    }

    public func followUser(_ userID: UUID) async throws {
        guard let client = SpoolClient.shared else { throw FollowError.notConfigured }
        guard let me = await SpoolClient.currentUserID() else { throw FollowError.notAuthenticated }

        let payload = FollowPayload(follower_id: me, following_id: userID)
        _ = try await client.from("friend_follows").insert(payload).execute()
    }

    private struct FollowPayload: Encodable {
        let follower_id: UUID
        let following_id: UUID
    }
}
