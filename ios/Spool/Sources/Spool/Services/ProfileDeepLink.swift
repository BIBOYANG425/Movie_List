import Foundation

/// Pure URL-routing seam for inbound deep links (C7-iOS Task 5). Classifies a
/// URL the OS hands the app — from the `spool://` custom scheme OR a real
/// universal link on `rankspool.com` — into one of three routes without any
/// I/O, so the whole predicate is test-enforced (`ProfileDeepLinkTests`).
///
/// Two public entry surfaces, one shape:
///  * `spool://u/{username}` (custom scheme)
///  * `https://rankspool.com/u/{username}` and the `www.` variant (universal link)
/// both resolve to `.profile(username)`. The username is the FIRST path
/// component after `/u/`; anything deeper (`/u/bob/extra`) is rejected so a
/// stray segment can't smuggle a bogus handle through.
///
/// The OAuth callback (`spool://auth-callback`) is classified as `.authCallback`
/// and returned UNTOUCHED so the caller can early-out and let the existing
/// Supabase/ASWebAuthenticationSession machinery own that URL. This parser never
/// consumes or rewrites the auth callback — it only recognises it so the profile
/// branch can't accidentally treat `auth-callback` as a username.
///
/// Everything else (other hosts, other schemes, other paths, empty username,
/// garbage) is `.unhandled`. The caller ignores `.unhandled` — no toast, no
/// navigation — because the OS may route unrelated URLs here.
///
/// Owner binding: the universal-link host allowlist (`rankspool.com`,
/// `www.rankspool.com`) mirrors the AASA `applinks` served at
/// `https://rankspool.com/.well-known/apple-app-site-association` and the
/// `associated-domains` entitlement. Keep the three in sync.
///
/// Header last reviewed: 2026-07-10
public enum ProfileDeepLink {

    /// The routing outcome for an inbound URL.
    public enum Route: Equatable, Sendable {
        /// A public-profile link resolved to this bare username (no leading `@`,
        /// percent-decoded). The caller resolves it to a profile row.
        case profile(username: String)
        /// The OAuth callback (`spool://auth-callback`) — recognised so the
        /// caller leaves it to the existing auth machinery, never handled here.
        case authCallback
        /// Not a link this app routes. The caller ignores it.
        case unhandled
    }

    /// Custom scheme the app registers (`CFBundleURLSchemes`).
    static let customScheme = "spool"

    /// Hosts whose `https` links are claimed as universal links. Mirrors the
    /// AASA `applinks` + the `associated-domains` entitlement.
    static let universalLinkHosts: Set<String> = ["rankspool.com", "www.rankspool.com"]

    /// The auth-callback host under the `spool://` scheme (`spool://auth-callback`).
    static let authCallbackHost = "auth-callback"

    /// The path prefix that precedes a public-profile username (`/u/{username}`).
    static let profilePathComponent = "u"

    /// Classify `url` into a route. Pure — no session, no network.
    public static func route(for url: URL) -> Route {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .unhandled
        }
        let scheme = components.scheme?.lowercased()

        // ── Custom scheme: spool://…
        if scheme == customScheme {
            // OAuth callback — recognise and hand back untouched.
            if components.host?.lowercased() == authCallbackHost {
                return .authCallback
            }
            // spool://u/{username}: the host is `u`, the username is the single
            // path segment. (URLComponents parses spool://u/bob as host="u",
            // path="/bob".)
            if components.host?.lowercased() == profilePathComponent {
                return profileRoute(fromPathSegments: pathSegments(components.path))
            }
            return .unhandled
        }

        // ── Universal link: https://[www.]rankspool.com/u/{username}
        if scheme == "https", let host = components.host?.lowercased(),
           universalLinkHosts.contains(host) {
            var segments = pathSegments(components.path)
            guard segments.first == profilePathComponent else { return .unhandled }
            segments.removeFirst()
            return profileRoute(fromPathSegments: segments)
        }

        return .unhandled
    }

    // MARK: - private

    /// Split a path into non-empty, percent-decoded segments.
    private static func pathSegments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map {
            String($0).removingPercentEncoding ?? String($0)
        }
    }

    /// A profile route iff there is EXACTLY ONE non-empty username segment.
    /// Zero segments (bare `/u/`), or a deeper path (`/u/bob/extra`), is rejected.
    private static func profileRoute(fromPathSegments segments: [String]) -> Route {
        guard segments.count == 1 else { return .unhandled }
        let username = segments[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return .unhandled }
        // Strip a single leading `@` so both `/u/bob` and `/u/@bob` normalise
        // to the bare storage handle the profiles table keys on.
        let normalized = username.hasPrefix("@") ? String(username.dropFirst()) : username
        guard !normalized.isEmpty else { return .unhandled }
        return .profile(username: normalized)
    }
}
