import Foundation
import Supabase

/// Email + password + Google OAuth auth wrapper on top of `supabase-swift`.
/// Mirrors the behavior of `contexts/AuthContext.tsx` on the web — first tries
/// sign-in; on "invalid credentials" falls through to sign-up. This gives a
/// single "sign in / sign up" button for onboarding.
///
/// Google OAuth uses supabase-swift's built-in `ASWebAuthenticationSession`
/// overload of `signInWithOAuth` — it opens a system-provided Safari sheet,
/// handles the callback back to `com.spool.app://auth/callback`, and returns
/// a fully-hydrated `Session`. `SpoolAppEntry.onOpenURL` also forwards any
/// stray callback URL to `client.auth.handle(_:)` as a belt-and-suspenders
/// path in case the caller relies on a plain deep-link flow.
///
/// Header last reviewed: 2026-04-18
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
        /// Supabase signed up a new user but requires email confirmation
        /// before the session is active — response.session was nil. The
        /// account exists; the user must click the confirmation link.
        case emailNotConfirmed
        /// User closed the OAuth sheet without completing auth. Callers
        /// should treat this as a no-op — don't render an error message.
        case cancelled
        case unknown(String)

        public var userMessage: String {
            switch self {
            case .notConfigured:     return "sign-in is offline. keep exploring."
            case .invalidCredentials:return "wrong password."
            case .weakPassword:      return "password too short."
            case .emailTaken:        return "email already has an account. check your password."
            case .emailNotConfirmed: return "check your email for a confirmation link, then try again."
            case .cancelled:         return ""
            case .network(let msg):  return msg
            case .unknown(let msg):  return msg
            }
        }
    }

    public func signInOrSignUp(email: String, password: String) async -> AuthResult {
        guard let client = SpoolClient.shared else { return .failure(.notConfigured) }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // First attempt: sign in
        do {
            let session = try await client.auth.signIn(email: trimmed, password: password)
            await flushOnboardingQueue()
            return .success(session.user.id)
        } catch {
            // Fall through to sign-up only when the user genuinely doesn't
            // exist. "email not confirmed" means the account IS registered
            // but needs email verification — falling through would fail
            // with "already registered" and hide the real state.
            let msg = "\(error)".lowercased()
            let looksLikeMissingUser =
                msg.contains("invalid login credentials") ||
                msg.contains("user not found")

            if !looksLikeMissingUser {
                return .failure(classify(error))
            }

            // Fall through to sign-up
            do {
                let response = try await client.auth.signUp(email: trimmed, password: password)
                // When email confirmation is required, Supabase returns a
                // user record with session == nil. We can't auto-flush
                // anything without a session, so surface the verification
                // step instead of pretending the flow completed.
                guard response.session != nil else {
                    return .failure(.emailNotConfirmed)
                }
                await flushOnboardingQueue()
                return .success(response.user.id)
            } catch {
                return .failure(classify(error))
            }
        }
    }

    /// Launches the Google OAuth flow via `ASWebAuthenticationSession`. The
    /// call suspends until the user completes (or cancels) the Safari sheet,
    /// at which point supabase-swift extracts the session from the callback
    /// URL and returns it. On success we drain the onboarding queue just like
    /// the email/password path so any stubs ranked in preview mode persist.
    public func signInWithGoogle() async -> AuthResult {
        guard let client = SpoolClient.shared else { return .failure(.notConfigured) }
        do {
            let session = try await client.auth.signInWithOAuth(
                provider: .google,
                redirectTo: URL(string: "com.spool.app://auth/callback")
            )
            await flushOnboardingQueue()
            return .success(session.user.id)
        } catch {
            return .failure(classify(error))
        }
    }

    /// Drain any queued onboarding rankings into `user_rankings`. Errors are
    /// logged but never thrown — a failed flush must not keep the user from
    /// completing sign-in.
    private func flushOnboardingQueue() async {
        do {
            try await OnboardingQueue.flush()
        } catch {
            print("[AuthService] OnboardingQueue.flush failed: \(error)")
        }
    }

    /// Called by `SpoolAppEntry.onOpenURL` after the OAuth callback URL has
    /// already been handed to `client.auth.handle(_:)`. Flushes any queued
    /// onboarding rankings now that a session exists. Safe to call multiple
    /// times — `OnboardingQueue.flush` is idempotent on empty.
    public func flushOnboardingQueueForOAuthCallback() async {
        await flushOnboardingQueue()
    }

    /// Entry point for the SwiftUI `.onOpenURL` modifier at the app root.
    /// Forwards the callback URL to supabase-swift so a session is established,
    /// then flushes the onboarding queue. Defined `nonisolated static` so the
    /// caller doesn't need to hop through the actor or import `Supabase`.
    public nonisolated static func handleOAuthCallback(_ url: URL) {
        guard let client = SpoolClient.shared else { return }
        client.auth.handle(url)
        Task { await AuthService.shared.flushOnboardingQueueForOAuthCallback() }
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
        // OAuth user-cancellation surfaces as an ASWebAuthenticationSession
        // error with Code=1 (canceledLogin). Swallow silently — the user
        // closed the sheet on purpose, nothing broke.
        if m.contains("webauthenticationsession") || m.contains("canceledlogin") {
            return .cancelled
        }
        if m.contains("password") && (m.contains("short") || m.contains("weak")) {
            return .weakPassword
        }
        if m.contains("already registered") || m.contains("already exists") {
            return .emailTaken
        }
        if m.contains("invalid login credentials") {
            return .invalidCredentials
        }
        if m.contains("network") || m.contains("offline") || m.contains("timed out") {
            return .network("couldn't reach the server.")
        }
        return .unknown(String("\(error)".prefix(180)))
    }
}
