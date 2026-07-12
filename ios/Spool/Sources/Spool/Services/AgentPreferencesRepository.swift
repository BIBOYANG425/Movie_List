import Foundation
import Supabase

/// Reads and writes `public.agent_preferences` — the user's control over Chris's
/// "daily reel" (a short morning movie-industry newsletter in Chris's voice).
///
/// The table is a direct own-row table under RLS (no RPC): the authenticated
/// client upserts on `user_id`, exactly like `ProfileRepository.updateVisibility`.
/// `timezone` is stamped from the device (`TimeZone.current.identifier`) on every
/// save so Chris delivers at the user's local hour. Reads happen when the sheet
/// opens in its linked state.
///
/// Returns `nil` when there is no client / no session so callers fall back to the
/// contract defaults (daily @ 9). Write failures throw `RepoError` so the caller
/// can toast and revert its optimistic state.
///
/// Header last reviewed: 2026-07-12
public actor AgentPreferencesRepository {

    public static let shared = AgentPreferencesRepository()

    public enum RepoError: Error {
        case notConfigured
        case notAuthenticated
    }

    // MARK: read

    /// The signed-in user's digest preferences, or `nil` when there's no client /
    /// no session / no row yet. A missing row is NOT an error: a user who never
    /// touched the control has no row, and the caller applies the defaults.
    public func load() async -> DigestPreferences? {
        guard let client = SpoolClient.shared else { return nil }
        guard let userID = await SpoolClient.currentUserID() else { return nil }
        do {
            let rows: [DigestPreferencesRow] = try await client
                .from("agent_preferences")
                .select("trade_digest_cadence, digest_hour, timezone")
                .eq("user_id", value: userID.uuidString)
                .limit(1)
                .execute()
                .value
            return rows.first.map { DigestPreferences(row: $0) }
        } catch {
            NSLog("[AgentPreferencesRepository] load failed: \(error)")
            return nil
        }
    }

    // MARK: write

    /// Upsert the caller's cadence + delivery hour. `timezone` is stamped from the
    /// device on every save (per spec) so the stored hour is always interpreted in
    /// the user's current zone. RLS re-enforces `auth.uid() = user_id`; an empty
    /// result means the row didn't land (almost always an RLS mismatch) → surfaced
    /// as `.notAuthenticated`.
    public func save(cadence: DigestCadence, hour: Int) async throws {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let payload = DigestPreferencesUpsertPayload(
            user_id: userID.uuidString,
            trade_digest_cadence: cadence.rawValue,
            digest_hour: DigestPreferences.clampHour(hour),
            timezone: TimeZone.current.identifier,
            updated_at: ISO8601DateFormatter().string(from: Date())
        )

        let written: [DigestPreferencesRow] = try await client
            .from("agent_preferences")
            .upsert(payload, onConflict: "user_id")
            .select("trade_digest_cadence, digest_hour, timezone")
            .execute()
            .value

        guard written.first != nil else {
            throw RepoError.notAuthenticated
        }
    }
}

// MARK: - DTOs

/// Row shape read back from `agent_preferences`.
struct DigestPreferencesRow: Decodable, Sendable {
    let trade_digest_cadence: String
    let digest_hour: Int
    let timezone: String
}

/// Upsert body. `user_id` is required for the ON CONFLICT target; `updated_at` is
/// stamped client-side so the row's freshness reflects the save, matching the web
/// `updateMyProfile` idiom.
private struct DigestPreferencesUpsertPayload: Encodable {
    let user_id: String
    let trade_digest_cadence: String
    let digest_hour: Int
    let timezone: String
    let updated_at: String
}
