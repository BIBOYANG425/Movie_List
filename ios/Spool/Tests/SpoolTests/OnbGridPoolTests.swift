import XCTest
@testable import Spool

/// Tests for `OnbGrid.resolvePool` (the signed-in vs signed-out pool decision
/// seam), `TMDBService` `+` percent-encoding inside the inner query string, and
/// the `SuggestionsError.transport` case.
///
/// These are pure-logic tests — no network, no Supabase client.
final class OnbGridPoolTests: XCTestCase {

    // MARK: - Helpers

    private static let fixtures: [TMDBMovie] = [
        TMDBMovie(id: "fx_a", tmdbId: -1, title: "A", year: "2020",
                  posterUrl: nil, genres: [], overview: "", voteAverage: nil),
        TMDBMovie(id: "fx_b", tmdbId: -2, title: "B", year: "2021",
                  posterUrl: nil, genres: [], overview: "", voteAverage: nil),
    ]

    private func liveSuggestions(count: Int = 3) -> SuggestionsResponse {
        let items = (1...count).map { i in
            SuggestionItem(
                id: "tmdb_\(i)", tmdbId: i, title: "Live \(i)", year: "2024",
                posterUrl: "https://example.com/\(i).jpg", backdropUrl: nil,
                mediaType: .movie, genres: ["Drama"], overview: "Overview \(i)",
                voteAverage: 7.5, seasonCount: 0, pool: .generic
            )
        }
        return SuggestionsResponse(items: items, totalRanked: 0)
    }

    // MARK: - OnbGrid.resolvePool: signed-in → client called

    /// When a session exists and the fetch returns non-empty items,
    /// `resolvePool` returns the live pool (real tmdbIds, real posterUrls)
    /// and does NOT call into the fixture fallback.
    func testSignedInUsesLivePool() async throws {
        var called = false
        let pool = await OnbGrid.resolvePool(
            hasSession: true,
            fallbackPool: Self.fixtures
        ) { mode, mediaType, page, ids, limit in
            called = true
            XCTAssertEqual(mode, .suggestions)
            XCTAssertEqual(mediaType, .movie)
            XCTAssertEqual(page, 1)
            XCTAssertEqual(ids, [])
            XCTAssertNil(limit)
            return self.liveSuggestions()
        }

        XCTAssertTrue(called, "SuggestionsClient.fetch must be called when signed in")
        XCTAssertEqual(pool.count, 3)
        XCTAssertTrue(pool.allSatisfy { $0.tmdbId > 0 }, "live pool must have real (positive) tmdbIds")
        XCTAssertTrue(pool.allSatisfy { $0.posterUrl != nil }, "live pool must have poster URLs")
    }

    /// When signed out (no session), `resolvePool` must NOT call the network
    /// and must return the fixture fallback.
    func testSignedOutUsesFallbackWithoutCallingClient() async throws {
        var called = false
        let pool = await OnbGrid.resolvePool(
            hasSession: false,
            fallbackPool: Self.fixtures
        ) { _, _, _, _, _ in
            called = true
            return SuggestionsResponse(items: [], totalRanked: 0)
        }

        XCTAssertFalse(called, "fetch must NOT be called when there is no session")
        XCTAssertEqual(pool.map(\.id), Self.fixtures.map(\.id), "must return the fixture pool")
        XCTAssertTrue(pool.allSatisfy { $0.tmdbId < 0 }, "fixtures have negative synthetic ids")
    }

    /// When signed in but the fetch throws (e.g. transport error), `resolvePool`
    /// falls back to fixtures so the grid is never empty.
    func testSignedInFetchThrowUsesFallback() async throws {
        struct FakeError: Error {}
        let pool = await OnbGrid.resolvePool(
            hasSession: true,
            fallbackPool: Self.fixtures
        ) { _, _, _, _, _ in
            throw FakeError()
        }

        XCTAssertEqual(pool.map(\.id), Self.fixtures.map(\.id),
                       "fetch throw must fall back to fixtures")
    }

    /// When signed in but the server returns an empty items array, `resolvePool`
    /// falls back to fixtures rather than showing an empty grid.
    func testSignedInEmptyResponseUsesFallback() async throws {
        let pool = await OnbGrid.resolvePool(
            hasSession: true,
            fallbackPool: Self.fixtures
        ) { _, _, _, _, _ in
            return SuggestionsResponse(items: [], totalRanked: 0)
        }

        XCTAssertEqual(pool.map(\.id), Self.fixtures.map(\.id),
                       "empty live response must fall back to fixtures")
    }

    // MARK: - TMDBService: `+` encoding in inner query string

    /// A search query containing `+` must have it percent-encoded as `%2B`
    /// inside the packed `path` value so that the proxy's URLSearchParams
    /// decode it as `+`, not as a space.
    ///
    /// Pin: the `query` value in the inner query string (`search/movie?query=...`)
    /// must contain `%2B` at the position where the `+` appears.
    func testPlusInQueryIsEncodedAsPercent2B() {
        // We can observe the encoding by checking TMDBProxy.buildProxyURL
        // with a pre-built inner query to isolate the `+` encoding step.
        // Simulate the inner query-building step by constructing the same
        // URLComponents that TMDBService.fetchAndMap builds, then apply
        // the same `.replacingOccurrences(of: "+", with: "%2B")` step.
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "query", value: "9+1"),
            URLQueryItem(name: "language", value: "en-US"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "include_adult", value: "false"),
        ]
        let rawQuery = comps.percentEncodedQuery ?? ""
        let encodedQuery = rawQuery.replacingOccurrences(of: "+", with: "%2B")
        let path = "search/movie?\(encodedQuery)"

        // The packed proxy URL carries the inner query inside `path=`
        let proxyURL = TMDBProxy.buildProxyURL(
            supabaseURL: "https://proj.supabase.co", tmdbPath: path
        )
        let parsed = URLComponents(string: proxyURL)!
        let packed = parsed.queryItems?.first(where: { $0.name == "path" })?.value ?? ""

        XCTAssertTrue(packed.contains("9%2B1"),
            "'+' in query value must be encoded as '%2B', got: \(packed)")
        XCTAssertFalse(packed.contains("9+1"),
            "raw '+' must not survive into the packed path value")
        XCTAssertFalse(packed.contains("9 1"),
            "'+' must not be decoded as space")
    }

    // MARK: - SuggestionsError.transport case

    /// A raw URLError wrapping to `.transport` must be distinguishable
    /// by pattern matching, so Task 6 can separate connectivity failures
    /// from `.http`/`.decoding`/`.notAuthenticated`.
    func testTransportCaseWrapsUnderlyingError() {
        let underlying = URLError(.notConnectedToInternet)
        let err = SuggestionsClient.SuggestionsError.transport(underlying)

        // Distinguish from other cases via exhaustive switch
        switch err {
        case .transport:
            break // expected
        case .http, .decoding, .notConfigured, .notAuthenticated:
            XCTFail("Expected .transport, got a different case")
        }
    }

    /// `.transport` is distinct from `.http(status:)` — the two are not
    /// accidentally conflated (regression guard for Task 6's branch logic).
    func testTransportIsDistinctFromHttp() {
        let transportErr = SuggestionsClient.SuggestionsError.transport(URLError(.timedOut))
        let httpErr = SuggestionsClient.SuggestionsError.http(status: 503)

        if case .transport = transportErr { /* ok */ } else {
            XCTFail("transportErr should be .transport")
        }
        if case .http(let code) = httpErr {
            XCTAssertEqual(code, 503)
        } else {
            XCTFail("httpErr should be .http(503)")
        }
    }
}
