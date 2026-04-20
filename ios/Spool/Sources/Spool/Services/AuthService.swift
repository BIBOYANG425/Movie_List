import Foundation
import Supabase
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

/// Email + password auth wrapper on top of `supabase-swift`.
///
/// **Why this isn't "signIn-or-signUp" anymore:** Supabase returns the same
/// generic "invalid login credentials" error for both wrong password AND
/// missing user (security policy — they don't want you to be able to enumerate
/// accounts). An auto-fallthrough to `signUp` on that error ends up silently
/// creating phantom unconfirmed accounts whenever someone mistypes their
/// password. The correct surface is an explicit `signIn` call and a separate
/// `signUp` call. Callers decide which intent to act on.
///
/// OAuth (Google etc.) is not wired here yet — it needs URL scheme + an
/// `ASWebAuthenticationSession` handoff; will be a follow-up.
///
/// Header last reviewed: 2026-04-19
public actor AuthService {

    public static let shared = AuthService()

    public enum AuthResult {
        case success(UUID)
        case failure(AuthError)
    }

    public enum AuthError: Error, Sendable {
        case notConfigured
        case network(String)
        case invalidCredentials
        case weakPassword
        case emailTaken
        case emailNotConfirmed
        /// ASWebAuthenticationSession was dismissed by the user without
        /// completing auth. Callers should treat this as a silent no-op —
        /// no toast, no error state. `userMessage` returns an empty string.
        case cancelled
        case unknown(String)

        public var userMessage: String {
            switch self {
            case .notConfigured:      return "sign-in is offline. keep exploring."
            case .invalidCredentials: return "wrong email or password."
            case .weakPassword:       return "password too short."
            case .emailTaken:         return "email already has an account. try signing in instead."
            case .emailNotConfirmed:  return "check your email — confirm the link we sent, then try again."
            case .cancelled:          return ""
            case .network(let msg):   return msg
            case .unknown(let msg):   return msg
            }
        }
    }

    /// Sign an existing user in. Does NOT fall through to signUp on failure —
    /// a wrong password returns `.invalidCredentials`, full stop. Callers that
    /// want to create a new account should call `signUp` explicitly.
    public func signIn(email: String, password: String) async -> AuthResult {
        guard let client = SpoolClient.shared else { return .failure(.notConfigured) }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        do {
            let session = try await client.auth.signIn(email: trimmed, password: password)
            NSLog("[AuthService] signIn OK: user=\(session.user.id.uuidString)")
            await flushOnboardingQueue()
            return .success(session.user.id)
        } catch {
            NSLog("[AuthService] signIn FAIL: \(error)")
            return .failure(classify(error))
        }
    }

    /// Create a new account. Returns `.success` when Supabase returns a
    /// session; if the project requires email confirmation, no session is
    /// issued and this returns `.failure(.emailNotConfirmed)` — the user
    /// needs to click the link in their inbox.
    public func signUp(email: String, password: String) async -> AuthResult {
        guard let client = SpoolClient.shared else { return .failure(.notConfigured) }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        do {
            let response = try await client.auth.signUp(email: trimmed, password: password)
            NSLog("[AuthService] signUp OK: user=\(response.user.id.uuidString) session=\(response.session != nil)")
            // signUp can return a user with no session when email confirmation
            // is enabled on the project. Treat that as "check your email".
            if response.session == nil {
                return .failure(.emailNotConfirmed)
            }
            await flushOnboardingQueue()
            return .success(response.user.id)
        } catch {
            NSLog("[AuthService] signUp FAIL: \(error)")
            return .failure(classify(error))
        }
    }

    /// Back-compat shim. Existing call sites that still expect the old
    /// "try sign-in then sign-up" affordance are routed through the safer
    /// path: sign-in only. A failed login no longer silently creates a new
    /// account. New-account flow should use `signUp` directly.
    @available(*, deprecated, message: "Use signIn or signUp explicitly — this alias only calls signIn.")
    public func signInOrSignUp(email: String, password: String) async -> AuthResult {
        await signIn(email: email, password: password)
    }

    // MARK: OAuth — Google

    /// The callback URL that Supabase redirects back to after Google auth
    /// completes. The scheme (`spool`) is registered in `Info.plist` via
    /// `CFBundleURLTypes`. The Supabase project must have this URL in its
    /// allowed redirects: Dashboard → Authentication → URL Configuration.
    public static let oauthRedirectURL = URL(string: "spool://auth-callback")!

    /// Sign in via Google using Supabase-hosted OAuth. Presents an
    /// `ASWebAuthenticationSession` so the user authenticates with Google in
    /// a system-managed web sheet; the session comes back with tokens and
    /// the SDK stores them in the keychain like the email/password flow.
    ///
    /// Requires:
    /// - `spool://` URL scheme in Info.plist
    /// - `spool://auth-callback` allowlisted in the Supabase project
    /// - Google provider enabled + Client ID/Secret configured in the
    ///   Supabase dashboard (the web app already uses this)
    #if canImport(AuthenticationServices)
    public func signInWithGoogle() async -> AuthResult {
        guard let client = SpoolClient.shared else { return .failure(.notConfigured) }
        do {
            let session = try await client.auth.signInWithOAuth(
                provider: .google,
                redirectTo: Self.oauthRedirectURL,
                scopes: "email profile"
            ) { authSession in
                // Prefer an ephemeral session so Safari cookies aren't reused
                // across accounts — matches how the web app treats OAuth.
                authSession.prefersEphemeralWebBrowserSession = true
            }
            NSLog("[AuthService] signInWithGoogle OK: user=\(session.user.id.uuidString)")
            await flushOnboardingQueue()
            return .success(session.user.id)
        } catch {
            NSLog("[AuthService] signInWithGoogle FAIL: \(error)")
            return .failure(classify(error))
        }
    }
    #else
    public func signInWithGoogle() async -> AuthResult {
        .failure(.notConfigured)
    }
    #endif

    // MARK: lifecycle

    /// Drain any queued onboarding rankings into `user_rankings`. Errors are
    /// logged but never thrown — a failed flush must not keep the user from
    /// completing sign-in.
    private func flushOnboardingQueue() async {
        do {
            try await OnboardingQueue.flush()
        } catch {
            NSLog("[AuthService] OnboardingQueue.flush failed: \(error)")
        }
    }

    public func signOut() async {
        guard let client = SpoolClient.shared else { return }
        try? await client.auth.signOut()
        // Without this, a user who signs out keeps `spool.preview_mode == false`
        // and the next rank attempt falls into the "signed in" branch of
        // `RankH2HScreen.persistRanking`, silently failing with no banner to
        // warn them. Flip the flag so the preview-mode banner + queue behavior
        // kicks back in until they sign in again.
        await MainActor.run {
            UserDefaults.standard.set(true, forKey: "spool.preview_mode")
        }
    }

    public func currentUserID() async -> UUID? {
        await SpoolClient.currentUserID()
    }

    // MARK: classify

    private func classify(_ error: Error) -> AuthError {
        let m = "\(error)".lowercased()
        if m.contains("password") && (m.contains("short") || m.contains("weak")) {
            return .weakPassword
        }
        if m.contains("already registered") || m.contains("already exists") || m.contains("user already") {
            return .emailTaken
        }
        if m.contains("email not confirmed") || m.contains("not confirmed") {
            return .emailNotConfirmed
        }
        if m.contains("invalid login credentials") || m.contains("invalid credentials") {
            return .invalidCredentials
        }
        // ASWebAuthenticationSession user-cancel surfaces as a specific code;
        // return a distinct .cancelled so callers can suppress UI entirely
        // (showing an error toast when the user deliberately backed out is
        // noise).
        if m.contains("canceledlogin") || m.contains("cancelled") || m.contains("user cancel") {
            return .cancelled
        }
        if m.contains("network") || m.contains("offline") || m.contains("timed out") {
            return .network("couldn't reach the server.")
        }
        return .unknown(String("\(error)".prefix(180)))
    }
}
