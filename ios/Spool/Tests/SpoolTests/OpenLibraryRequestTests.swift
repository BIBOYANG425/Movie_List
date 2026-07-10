import XCTest
@testable import Spool

/// RED-first spec for the pure OpenLibrary request builder.
///
/// OpenLibrary is KEYLESS and called DIRECTLY (not via the tmdb-proxy, which is
/// TMDB-only by design), so there is no api key to smuggle or strip. Instead the
/// parity facts we pin are: the exact query params (`q` trimmed, `limit=10`,
/// the 10-field `fields` list) mirroring web `searchBooks`; the `User-Agent`
/// header set on the request (OL API policy asks for a contact-identifying UA;
/// a browser CANNOT set User-Agent, so iOS setting it is strictly better
/// citizenship — pinned here so it can never silently regress); and the `+`
/// encoding fix (URLComponents leaves `+` literal; OL decodes it as space under
/// application/x-www-form-urlencoded — force-encode to `%2B`, matching web's
/// `URLSearchParams` behaviour).
final class OpenLibraryRequestTests: XCTestCase {

    // MARK: - query params

    func testBuildRequestTargetsSearchJsonWithExactParams() {
        let req = OpenLibraryService.buildSearchRequest(query: "the hobbit")
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.host, "openlibrary.org")
        XCTAssertEqual(comps.path, "/search.json")

        let items = Dictionary(
            uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) }
        )
        XCTAssertEqual(items["q"], "the hobbit")
        XCTAssertEqual(items["limit"], "10")
        // Exact web field list, comma-joined, order preserved.
        XCTAssertEqual(
            items["fields"] ?? "",
            "key,title,author_name,first_publish_year,number_of_pages_median,cover_i,ratings_average,ratings_count,subject,isbn"
        )
        // Only these three params — no api key, nothing else.
        XCTAssertEqual(Set((comps.queryItems ?? []).map(\.name)), ["q", "limit", "fields"])
    }

    func testBuildRequestTrimsQueryLikeWeb() {
        let req = OpenLibraryService.buildSearchRequest(query: "  dune  ")
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let q = (comps.queryItems ?? []).first(where: { $0.name == "q" })?.value
        XCTAssertEqual(q, "dune", "query is trimmed before it hits the wire")
    }

    // MARK: - User-Agent header (OL policy)

    func testBuildRequestSetsUserAgentHeader() {
        let req = OpenLibraryService.buildSearchRequest(query: "x")
        let ua = req.value(forHTTPHeaderField: "User-Agent")
        XCTAssertEqual(ua, OpenLibraryService.userAgent)
        // The UA must identify the app AND carry a contact URL (OL policy).
        let unwrapped = try? XCTUnwrap(ua)
        XCTAssertTrue(unwrapped?.contains("Spool") ?? false, "UA identifies the app")
        XCTAssertTrue(unwrapped?.contains("http") ?? false, "UA carries a contact URL")
    }

    func testBuildRequestUsesEightSecondTimeout() {
        let req = OpenLibraryService.buildSearchRequest(query: "x")
        XCTAssertEqual(req.timeoutInterval, 8, "web uses an 8s timeout")
    }

    func testBuildRequestIsAGet() {
        let req = OpenLibraryService.buildSearchRequest(query: "x")
        XCTAssertEqual(req.httpMethod, "GET")
    }

    // MARK: - + encoding (parity with web URLSearchParams)

    /// Web's `URLSearchParams` encodes `+` → `%2B`. `URLComponents` leaves `+`
    /// literal, and OpenLibrary's server decodes it as a space under the
    /// `application/x-www-form-urlencoded` convention — so "C++" would arrive as
    /// "C  ". `buildSearchRequest` force-encodes `+` → `%2B` after URLComponents
    /// builds, matching the TMDB service's approach (`buildSearchQuery`).
    func testPlusInQueryIsEncodedAsPercent2B() {
        let req = OpenLibraryService.buildSearchRequest(query: "C++")
        let raw = req.url!.absoluteString
        // The percentEncodedQuery must contain C%2B%2B, not "C++" or "C  ".
        XCTAssertTrue(raw.contains("C%2B%2B"),
            "'+' in query must be encoded as '%2B', got URL: \(raw)")
        XCTAssertFalse(raw.contains("C++"),
            "raw '+' must not survive into the wire URL")
        XCTAssertFalse(raw.contains("C  "),
            "'+' must not be decoded as space in the wire URL")
    }
}
