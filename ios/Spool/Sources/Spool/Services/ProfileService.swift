import Foundation
import Supabase

/// Reads from `public.profiles`. Today it only exposes `searchUsers(query:)`
/// used by the onboarding friend-search step, but it's the home for any future
/// profile CRUD that gets ported from `services/profileService.ts`.
///
/// RLS on `profiles` allows `SELECT` for any authenticated user, so a logged-in
/// session is required. Callers should check `SpoolClient.currentUserID()`
/// first — `searchUsers` doesn't enforce it here (the anon key + RLS will
/// return an empty list for unauthenticated callers, which is the right
/// behavior for a preview-mode user who shouldn't see the step anyway).
///
/// Header last reviewed: 2026-04-19
public actor ProfileService {

    public static let shared = ProfileService()

    public enum ProfileError: Error {
        case notConfigured
    }

    /// Row shape matches the columns selected below. `display_name` and the
    /// two avatar fields are nullable because the profile table was originally
    /// migrated from a legacy schema that only had `id/username/avatar_url`.
    public struct ProfileSearchResult: Codable, Sendable, Hashable, Identifiable {
        public let id: UUID
        public let username: String
        public let display_name: String?
        public let avatar_url: String?
        public let avatar_path: String?

        public init(id: UUID, username: String, display_name: String?,
                    avatar_url: String?, avatar_path: String?) {
            self.id = id
            self.username = username
            self.display_name = display_name
            self.avatar_url = avatar_url
            self.avatar_path = avatar_path
        }
    }

    /// Case-insensitive substring match against `username` OR `display_name`,
    /// capped at 12 rows to mirror the web app. Returns `[]` for an empty
    /// query (after trimming) so callers don't have to guard.
    ///
    /// Note: PostgREST's `or` filter takes a comma-joined list of atomic
    /// filters. Commas, parens and `%` in the raw query would break that
    /// grammar, so we strip them before interpolating — same policy the web
    /// app applies via `sanitizeSearchTerm`.
    public func searchUsers(query: String) async throws -> [ProfileSearchResult] {
        guard let client = SpoolClient.shared else { throw ProfileError.notConfigured }

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let safe = Self.sanitize(trimmed)
        guard !safe.isEmpty else { return [] }

        let rows: [ProfileSearchResult] = try await client
            .from("profiles")
            .select("id, username, display_name, avatar_url, avatar_path")
            .or("username.ilike.%\(safe)%,display_name.ilike.%\(safe)%")
            .limit(12)
            .execute()
            .value
        return rows
    }

    /// Strip characters that would break PostgREST's `or(...)` grammar or the
    /// `ilike` wildcard. Mirrors `sanitizeSearchTerm` in the web app.
    private static func sanitize(_ raw: String) -> String {
        let banned: Set<Character> = ["%", "*", ",", "(", ")"]
        return String(raw.filter { !banned.contains($0) })
    }
}
