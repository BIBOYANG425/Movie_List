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
        guard let client = shared else { return nil }
        do {
            let session = try await client.auth.session
            return session.user.id
        } catch {
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
