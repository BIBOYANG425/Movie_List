import Foundation
import Supabase

/// Email + password auth wrapper on top of `supabase-swift`.
/// Mirrors the behavior of `contexts/AuthContext.tsx` on the web — first tries
/// sign-in; on "invalid credentials" falls through to sign-up. This gives a
/// single "sign in / sign up" button for onboarding.
///
/// OAuth (Google etc.) is not wired here yet — it needs URL scheme + an
/// `ASWebAuthenticationSession` handoff; will be a follow-up.
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
        case unknown(String)

        public var userMessage: String {
            switch self {
            case .notConfigured:     return "sign-in is offline. keep exploring."
            case .invalidCredentials:return "wrong password."
            case .weakPassword:      return "password too short."
            case .emailTaken:        return "email already has an account. check your password."
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
            // If the error is "user doesn't exist" fall through to sign-up.
            // Supabase surfaces these as AuthError with specific messages/codes.
            let msg = "\(error)".lowercased()
            let looksLikeMissingUser =
                msg.contains("invalid login credentials") ||
                msg.contains("user not found") ||
                msg.contains("email not confirmed")

            if !looksLikeMissingUser {
                return .failure(classify(error))
            }

            // Fall through to sign-up
            do {
                let response = try await client.auth.signUp(email: trimmed, password: password)
                await flushOnboardingQueue()
                return .success(response.user.id)
            } catch {
                return .failure(classify(error))
            }
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

    public func signOut() async {
        guard let client = SpoolClient.shared else { return }
        try? await client.auth.signOut()
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
