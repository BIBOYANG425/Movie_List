import Foundation
import Supabase

/// Thin wrapper around `SupabaseClient` that reads config from `Info.plist`.
///
/// Plist keys (both required):
///  - `SUPABASE_URL`: `https://<project>.supabase.co`
///  - `SUPABASE_ANON_KEY`: anon public key (never ship service-role)
///
/// If either key is missing the client is `nil` and the app falls back to
/// fixtures. This lets the UI boot without credentials during design work.
public enum SpoolClient {

    public static let shared: SupabaseClient? = makeClient()

    public static var isConfigured: Bool { shared != nil }

    /// Returns the currently signed-in user's UUID, or nil if there is no session.
    public static func currentUserID() async -> UUID? {
        guard let client = shared else {
            NSLog("[SpoolClient] currentUserID: no client (not configured)")
            return nil
        }
        do {
            let session = try await client.auth.session
            return session.user.id
        } catch {
            NSLog("[SpoolClient] currentUserID: no session (\(error))")
            return nil
        }
    }

    /// Returns the email for the currently signed-in user, or nil if there
    /// is no session. Used by Settings to show which account is active —
    /// the profile table's `display_name` doesn't always match the login email.
    /// Diagnostics mirror `currentUserID` so we see the same "no session"
    /// story from both code paths.
    public static func currentUserEmail() async -> String? {
        guard let client = shared else {
            NSLog("[SpoolClient] currentUserEmail: no client (not configured)")
            return nil
        }
        do {
            let session = try await client.auth.session
            return session.user.email
        } catch {
            NSLog("[SpoolClient] currentUserEmail: no session (\(error))")
            return nil
        }
    }

    private static func makeClient() -> SupabaseClient? {
        let bundle = Bundle.main
        guard
            let urlString = bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let url = URL(string: urlString),
            let key = bundle.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
            !urlString.isEmpty, !key.isEmpty
        else {
            return nil
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }
}
