import Foundation
import Supabase

/// Reads against the `profiles` table. Mirrors the subset of
/// `services/profileService.ts` that iOS screens need today:
///  - `getMyProfile` / `getProfile(id:)` for Profile tab
///  - `getProfilesByIds(_:)` for bulk hydration (friends, followers)
///  - `searchByHandle(_:)` for future "+ add friend" UX
///
/// Returns `nil` (or empty) when `SpoolClient.shared` is nil so callers can
/// fall back to fixtures without a thrown error. Row-level errors throw
/// `RepoError` — caller decides whether to surface a toast.
///
/// Header last reviewed: 2026-04-19
public actor ProfileRepository {

    public static let shared = ProfileRepository()

    public enum RepoError: Error {
        case notConfigured
        case notAuthenticated
    }

    // MARK: reads

    /// Profile for the signed-in user, or nil if no session / no row.
    public func getMyProfile() async throws -> ProfileRow? {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }
        return try await fetchProfile(client: client, id: userID)
    }

    /// Profile for an arbitrary user (their ID must be visible per RLS).
    public func getProfile(id: UUID) async throws -> ProfileRow? {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        return try await fetchProfile(client: client, id: id)
    }

    /// Bulk profile hydration keyed by user ID. Rows the caller lacks
    /// permission to see are simply absent from the result.
    public func getProfilesByIds(_ ids: [UUID]) async throws -> [UUID: ProfileRow] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard !ids.isEmpty else { return [:] }

        let idStrings = ids.map { $0.uuidString }
        let rows: [ProfileRow] = try await client
            .from("profiles")
            .select("id, username, display_name, bio, avatar_url, avatar_path")
            .in("id", values: idStrings)
            .execute()
            .value

        var map: [UUID: ProfileRow] = [:]
        map.reserveCapacity(rows.count)
        for row in rows { map[row.id] = row }
        return map
    }

    // MARK: writes

    /// Update the signed-in user's profile. Only non-nil fields are sent —
    /// pass `nil` to leave a column untouched. Returns the updated row so
    /// callers can refresh their local state without a separate re-fetch.
    ///
    /// RLS enforces `auth.uid() = id` on UPDATE, so there's nothing to check
    /// on the client beyond having a session.
    @discardableResult
    public func updateMyProfile(
        displayName: String? = nil,
        bio: String? = nil,
        avatarUrl: String? = nil
    ) async throws -> ProfileRow {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        // flatMap (not map) because normalizedString returns String? —
        // without flatMap we'd end up with String?? and send the outer
        // Optional unchanged.
        let payload = ProfileUpdatePayload(
            display_name: displayName.flatMap(Self.normalizedString),
            bio: bio.flatMap(Self.normalizedString),
            avatar_url: avatarUrl.flatMap(Self.normalizedString)
        )

        let updated: [ProfileRow] = try await client
            .from("profiles")
            .update(payload)
            .eq("id", value: userID.uuidString)
            .select("id, username, display_name, bio, avatar_url, avatar_path")
            .execute()
            .value

        guard let row = updated.first else {
            // UPDATE returned no rows — almost always an RLS mismatch (the
            // signed-in user isn't who they think they are). Surface as
            // notAuthenticated so the caller can ask them to sign in again.
            throw RepoError.notAuthenticated
        }
        return row
    }

    /// Empty string → nil (so clearing a field writes SQL NULL instead of "").
    /// Leading/trailing whitespace is trimmed.
    private static func normalizedString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Username (or display_name) contains search. Returns up to 12 matches,
    /// excludes the current user. Empty query → []. Mirrors the web
    /// `searchUsers` path but RLS-only (no edge function).
    public func searchByHandle(_ query: String) async throws -> [ProfileRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
        guard !trimmed.isEmpty else { return [] }
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let me = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let rows: [ProfileRow] = try await client
            .from("profiles")
            .select("id, username, display_name, bio, avatar_url, avatar_path")
            .ilike("username", pattern: "%\(trimmed)%")
            .neq("id", value: me.uuidString)
            .limit(12)
            .execute()
            .value
        return rows
    }

    // MARK: private

    private func fetchProfile(client: SupabaseClient, id: UUID) async throws -> ProfileRow? {
        let rows: [ProfileRow] = try await client
            .from("profiles")
            .select("id, username, display_name, bio, avatar_url, avatar_path")
            .eq("id", value: id.uuidString)
            .limit(1)
            .execute()
            .value
        return rows.first
    }
}

// MARK: - DTOs

/// Partial-update payload for the profiles table. Using an `Encodable` struct
/// with optionals lets PostgREST infer `NULL` for unset fields only where the
/// caller explicitly chose nil; untouched fields are omitted entirely via the
/// custom encode(to:). That's the contract we want — "send only what the user
/// changed."
///
/// Why a custom encoder? The default Encodable of a struct with optionals
/// encodes `nil` as a JSON `null`, which Supabase would interpret as "set
/// this column to NULL." We want distinct semantics: omit a field from the
/// JSON entirely to leave it untouched; include it (possibly as null) to
/// write the new value.
private struct ProfileUpdatePayload: Encodable {
    let display_name: String?
    let bio: String?
    let avatar_url: String?

    enum CodingKeys: String, CodingKey {
        case display_name, bio, avatar_url
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let display_name { try c.encode(display_name, forKey: .display_name) }
        if let bio { try c.encode(bio, forKey: .bio) }
        if let avatar_url { try c.encode(avatar_url, forKey: .avatar_url) }
    }
}

/// Mirrors `profiles` row shape used by web's `ProfileRow`. Optional fields
/// are nullable in Postgres; `onboarding_completed` is omitted here because
/// iOS does not consume it today (onboarding state is UserDefaults-only).
public struct ProfileRow: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let username: String
    public let display_name: String?
    public let bio: String?
    public let avatar_url: String?
    public let avatar_path: String?

    /// Convenience: user-visible name, falling back through the hierarchy.
    public var displayedName: String {
        if let d = display_name, !d.isEmpty { return d }
        return username
    }

    /// `@handle` form with exactly one leading `@`, regardless of storage.
    public var handle: String {
        let raw = username
        return raw.hasPrefix("@") ? raw : "@\(raw)"
    }

    /// Split bio on the first newline so UI can render two lines without
    /// layout tricks. An empty bio yields `("", "")`.
    public var bioLines: (first: String, second: String) {
        let text = (bio ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return ("", "") }
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let first = parts.first.map(String.init) ?? ""
        let second = parts.count > 1 ? String(parts[1]) : ""
        return (first, second)
    }
}
