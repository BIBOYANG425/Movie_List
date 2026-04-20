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

    /// Update the signed-in user's profile using three-state patch semantics:
    ///   - `nil`            → leave the column untouched (omitted from JSON)
    ///   - `""` (or whitespace) → clear the column (encoded as JSON `null` → SQL NULL)
    ///   - non-empty string → set the column to that value
    ///
    /// Returns the freshly-read row so callers can refresh their local state
    /// without an extra round-trip. RLS enforces `auth.uid() = id` on UPDATE.
    @discardableResult
    public func updateMyProfile(
        displayName: String? = nil,
        bio: String? = nil,
        avatarUrl: String? = nil
    ) async throws -> ProfileRow {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        // Trim whitespace but preserve the empty-string signal — the encoder
        // below turns `""` into JSON null so the column is cleared, while
        // `nil` means "don't touch this column at all."
        let payload = ProfileUpdatePayload(
            display_name: displayName.map(Self.trim),
            bio: bio.map(Self.trim),
            avatar_url: avatarUrl.map(Self.trim)
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

    /// Whitespace trim only. Unlike the previous `normalizedString`, this
    /// does NOT collapse `""` to `nil` — the distinction matters to the
    /// three-state patch above.
    private static func trim(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Username-contains search (case-insensitive). Returns up to 12 matches,
    /// excludes the current user. Empty query → []. Mirrors the web
    /// `searchUsers` username path — display-name matching is intentionally
    /// NOT included here yet (the web edge function does it server-side with
    /// ranked scoring; running an `.or(...)` on both columns client-side
    /// spikes latency without matching the ranking logic).
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

/// Partial-update payload for the profiles table. Three encoding outcomes
/// per field:
///   - field is `nil`   → key omitted from JSON      → column untouched
///   - field is `""`    → key present, value is null → column cleared to NULL
///   - field is `"foo"` → key present, value is "foo" → column set to "foo"
///
/// Default synthesized Encodable would emit `null` for `nil`, collapsing the
/// first two cases. The custom `encode(to:)` below distinguishes them by
/// checking for the empty string before the non-empty branch.
private struct ProfileUpdatePayload: Encodable {
    let display_name: String?
    let bio: String?
    let avatar_url: String?

    enum CodingKeys: String, CodingKey {
        case display_name, bio, avatar_url
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try Self.encodeField(display_name, forKey: .display_name, into: &c)
        try Self.encodeField(bio, forKey: .bio, into: &c)
        try Self.encodeField(avatar_url, forKey: .avatar_url, into: &c)
    }

    /// Three-state encoder: nil→omit, ""→encodeNil, non-empty→encode.
    private static func encodeField(_ value: String?, forKey key: CodingKeys,
                                    into container: inout KeyedEncodingContainer<CodingKeys>) throws {
        guard let value else { return } // untouched
        if value.isEmpty {
            try container.encodeNil(forKey: key)     // clear to NULL
        } else {
            try container.encode(value, forKey: key) // set
        }
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
