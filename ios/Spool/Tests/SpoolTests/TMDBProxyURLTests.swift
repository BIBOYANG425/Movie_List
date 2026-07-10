import XCTest
@testable import Spool

/// RED-first spec for the pure client-side tmdb-proxy URL builder.
///
/// The iOS bundle no longer holds a TMDB key. Every TMDB request is rewritten to
/// an authenticated GET against the tmdb-proxy edge function:
///   {SUPABASE_URL}/functions/v1/tmdb-proxy?path=<encoded tmdb path+query>.
///
/// `TMDBProxy.buildProxyURL` owns exactly one job, mirroring web's
/// `services/tmdbProxy.ts` `buildProxyUrl` (see
/// `services/__tests__/tmdbProxyUrl.test.ts`): take a bare TMDB path (with its
/// own query string, minus api_key) and produce the proxy URL with the whole
/// thing packed into a single, correctly-encoded `path` param. It must NOT
/// smuggle the embedded query as sibling params (the proxy re-parses `path`).
final class TMDBProxyURLTests: XCTestCase {

    private let base = "https://proj.supabase.co"

    /// Case 1 (web): packs a bare path into a single ?path= param.
    func testPacksBarePathIntoSinglePathParam() {
        let url = TMDBProxy.buildProxyURL(supabaseURL: base, tmdbPath: "movie/603")
        XCTAssertEqual(
            url,
            "https://proj.supabase.co/functions/v1/tmdb-proxy?path=movie%2F603"
        )
    }

    /// Case 2 (web): keeps the embedded query inside the path value, not as
    /// siblings — the proxy URL has exactly ONE query param, `path`.
    func testKeepsEmbeddedQueryInsidePathValue() {
        let str = TMDBProxy.buildProxyURL(
            supabaseURL: base, tmdbPath: "search/movie?query=matrix&page=1"
        )
        let parsed = URLComponents(string: str)!
        XCTAssertEqual(parsed.path, "/functions/v1/tmdb-proxy")
        let names = (parsed.queryItems ?? []).map(\.name)
        XCTAssertEqual(names, ["path"], "only `path` may be a top-level param")
        // The decoded value the proxy reads back is byte-identical to what we sent.
        XCTAssertEqual(
            parsed.queryItems?.first(where: { $0.name == "path" })?.value,
            "search/movie?query=matrix&page=1"
        )
    }

    /// Case 3 (web): round-trips special characters (spaces, `&`, non-ASCII)
    /// through the path param without corrupting the value.
    func testRoundTripsSpecialCharacters() {
        let str = TMDBProxy.buildProxyURL(
            supabaseURL: base, tmdbPath: "search/movie?query=amélie & co&page=2"
        )
        let parsed = URLComponents(string: str)!
        XCTAssertEqual(
            parsed.queryItems?.first(where: { $0.name == "path" })?.value,
            "search/movie?query=amélie & co&page=2"
        )
    }

    /// Case 4 (web): tolerates a leading slash on the tmdb path (preserved
    /// inside the `path` value; the proxy strips at most one leading slash).
    func testToleratesLeadingSlash() {
        let str = TMDBProxy.buildProxyURL(
            supabaseURL: base, tmdbPath: "/movie/603?append_to_response=credits"
        )
        let parsed = URLComponents(string: str)!
        XCTAssertEqual(
            parsed.queryItems?.first(where: { $0.name == "path" })?.value,
            "/movie/603?append_to_response=credits"
        )
    }

    /// Case 5 (web): strips a trailing slash from the supabase base url before
    /// joining, so the path segment is never doubled.
    func testStripsTrailingSlashFromBase() {
        let url = TMDBProxy.buildProxyURL(
            supabaseURL: "https://proj.supabase.co/", tmdbPath: "movie/603"
        )
        XCTAssertEqual(
            url,
            "https://proj.supabase.co/functions/v1/tmdb-proxy?path=movie%2F603"
        )
    }

    /// Case 6 (web): defense in depth — never forwards an api_key a caller
    /// accidentally left on the path. The secret must not reach the wire even
    /// though the proxy also strips it server-side.
    func testNeverForwardsApiKeyLeftOnPath() {
        let str = TMDBProxy.buildProxyURL(
            supabaseURL: base, tmdbPath: "movie/603?api_key=LEAK&language=en-US"
        )
        let parsed = URLComponents(string: str)!
        let packed = parsed.queryItems?.first(where: { $0.name == "path" })?.value ?? ""
        XCTAssertFalse(packed.contains("api_key"), "api_key must be dropped")
        XCTAssertFalse(packed.contains("LEAK"))
        XCTAssertTrue(packed.contains("language=en-US"), "other params preserved")
    }
}
