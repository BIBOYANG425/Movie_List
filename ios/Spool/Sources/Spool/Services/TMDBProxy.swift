import Foundation

/// tmdb-proxy client seam (pure URL builder).
///
/// The iOS bundle no longer holds a TMDB key. Every TMDB request is rewritten to
/// an authenticated GET against the `tmdb-proxy` edge function:
///
///   {SUPABASE_URL}/functions/v1/tmdb-proxy?path=<tmdb path + query, URL-encoded>
///
/// The whole TMDB path *and its query string* are packed into a single `path`
/// param. The proxy splits `path` on the first '?', allowlist-checks the path
/// segment, and re-parses the query against its own safelist (dropping `api_key`,
/// which it injects server-side from the secret store). This is a 1:1 port of
/// web `services/tmdbProxy.ts` `buildProxyUrl` (see the shared test vectors in
/// `services/__tests__/tmdbProxyUrl.test.ts`): pack everything into `path`, NEVER
/// emit sibling query params, and defensively drop any `api_key` a caller left on
/// the path so the secret never touches the wire.
///
/// Pure (no network, no env) so it is unit-testable in isolation —
/// `TMDBProxyURLTests`.
public enum TMDBProxy {

    /// Build the authenticated proxy URL for a bare TMDB path (with optional
    /// query). Mirrors web `buildProxyUrl`.
    ///
    /// - Parameters:
    ///   - supabaseURL: the project URL; a trailing slash is tolerated/stripped.
    ///   - tmdbPath: e.g. `search/movie?query=matrix&page=1` or `/movie/603`.
    ///     A leading slash is preserved inside the `path` value.
    /// - Returns: the full proxy URL string with the packed `path` param.
    public static func buildProxyURL(supabaseURL: String, tmdbPath: String) -> String {
        let base = trimTrailingSlashes(supabaseURL)
        let packed = stripApiKey(tmdbPath)

        // Encode the packed value exactly as a single query param value. `/`
        // becomes %2F (mirrors web URLSearchParams); the rest round-trips.
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "path", value: packed)]
        // `URLComponents.percentEncodedQuery` uses the default query allowed set,
        // which does NOT encode `/`. Web's URLSearchParams DOES encode `/` → %2F,
        // and the shared test vector pins `path=movie%2F603`. Force-encode `/`
        // (and only `/`) on top of the standard query encoding to match byte-for-byte.
        let encodedQuery = (comps.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "/", with: "%2F")

        return "\(base)/functions/v1/tmdb-proxy?\(encodedQuery)"
    }

    /// Strip an `api_key` param from a bare TMDB path+query, if present. The
    /// client must never send it; the proxy injects the real key. Preserves the
    /// rest of the query verbatim (order-preserving). 1:1 with web `stripApiKey`.
    private static func stripApiKey(_ tmdbPath: String) -> String {
        guard let qIdx = tmdbPath.firstIndex(of: "?") else { return tmdbPath }

        let pathPart = String(tmdbPath[tmdbPath.startIndex..<qIdx])
        let queryPart = String(tmdbPath[tmdbPath.index(after: qIdx)...])
        if queryPart.isEmpty { return pathPart }

        let pairs: [String] = queryPart
            .split(separator: "&", omittingEmptySubsequences: false)
            .map(String.init)
        let kept: [String] = pairs.filter { pair in
            if pair.isEmpty { return false }
            let key = pair.split(separator: "=", maxSplits: 1).first.map(String.init)
            return key != "api_key"
        }

        return kept.isEmpty ? pathPart : "\(pathPart)?\(kept.joined(separator: "&"))"
    }

    /// Mirror of web `replace(/\/+$/, '')` — strip one-or-more trailing slashes.
    private static func trimTrailingSlashes(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex, s[s.index(before: end)] == "/" {
            end = s.index(before: end)
        }
        return String(s[s.startIndex..<end])
    }
}
