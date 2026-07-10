import XCTest
@testable import Spool

/// RED-first spec for the `suggestions` edge-function client wire types.
///
/// Mirrors the server contract in `supabase/functions/suggestions/index.ts`:
///   request  {mediaType, mode, page, sessionExcludeIds?, poolSlots?, locale?, limit?}
///   response {items: [{id, tmdbId, title, year, posterUrl, backdropUrl,
///             mediaType, genres, overview, voteAverage, seasonCount, pool}],
///             totalRanked}
///
/// These are pure decode/encode tests (no network). They pin:
///  - full response decode incl. every item field,
///  - `pool` decodes to `.unknown(raw)` for a tag the client doesn't recognize
///    (forward-compatibility — a new server pool must never crash the client),
///  - nullable/absent fields (posterUrl, backdropUrl, voteAverage) decode safely,
///  - the request body encodes `sessionExcludeIds` as a JSON array and omits it
///    (and other optionals) when nil.
final class SuggestionsClientTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - Response decode

    func testDecodesFullResponse() throws {
        let json = """
        {
          "items": [
            {
              "id": "tmdb_603",
              "tmdbId": 603,
              "title": "The Matrix",
              "year": "1999",
              "posterUrl": "https://image.tmdb.org/t/p/w500/p.jpg",
              "backdropUrl": "https://image.tmdb.org/t/p/w500/b.jpg",
              "mediaType": "movie",
              "genres": ["Action", "Sci-Fi"],
              "overview": "A hacker learns the truth.",
              "voteAverage": 8.2,
              "seasonCount": 0,
              "pool": "similar"
            }
          ],
          "totalRanked": 7
        }
        """.data(using: .utf8)!

        let resp = try decoder.decode(SuggestionsResponse.self, from: json)
        XCTAssertEqual(resp.totalRanked, 7)
        XCTAssertEqual(resp.items.count, 1)
        let item = resp.items[0]
        XCTAssertEqual(item.id, "tmdb_603")
        XCTAssertEqual(item.tmdbId, 603)
        XCTAssertEqual(item.title, "The Matrix")
        XCTAssertEqual(item.year, "1999")
        XCTAssertEqual(item.posterUrl, "https://image.tmdb.org/t/p/w500/p.jpg")
        XCTAssertEqual(item.backdropUrl, "https://image.tmdb.org/t/p/w500/b.jpg")
        XCTAssertEqual(item.mediaType, .movie)
        XCTAssertEqual(item.genres, ["Action", "Sci-Fi"])
        XCTAssertEqual(item.overview, "A hacker learns the truth.")
        XCTAssertEqual(item.voteAverage, 8.2)
        XCTAssertEqual(item.seasonCount, 0)
        XCTAssertEqual(item.pool, .similar)
    }

    /// A `pool` value the client has never seen must decode to `.unknown(raw)`,
    /// never throw. This keeps old clients forward-compatible with new server
    /// provenance tags.
    func testDecodesUnknownPoolWithoutThrowing() throws {
        let json = """
        {
          "items": [
            {
              "id": "tmdb_1",
              "tmdbId": 1,
              "title": "X",
              "year": "2020",
              "posterUrl": null,
              "backdropUrl": null,
              "mediaType": "tv",
              "genres": [],
              "overview": "",
              "seasonCount": 3,
              "pool": "brand_new_pool_v9"
            }
          ],
          "totalRanked": 0
        }
        """.data(using: .utf8)!

        let resp = try decoder.decode(SuggestionsResponse.self, from: json)
        let item = resp.items[0]
        XCTAssertEqual(item.pool, .unknown("brand_new_pool_v9"))
        XCTAssertNil(item.posterUrl)
        XCTAssertNil(item.backdropUrl)
        XCTAssertNil(item.voteAverage, "absent voteAverage decodes to nil")
        XCTAssertEqual(item.mediaType, .tv)
        XCTAssertEqual(item.seasonCount, 3)
    }

    /// Each known pool tag round-trips to its case.
    func testDecodesEachKnownPool() throws {
        let cases: [(String, SuggestionPool)] = [
            ("similar", .similar), ("taste", .taste), ("trending", .trending),
            ("variety", .variety), ("friend", .friend), ("generic", .generic),
            ("backfill", .backfill), ("new_release", .newRelease),
        ]
        for (raw, expected) in cases {
            let json = """
            {"items":[{"id":"i","tmdbId":1,"title":"t","year":"2000",
            "posterUrl":null,"backdropUrl":null,"mediaType":"movie","genres":[],
            "overview":"","seasonCount":0,"pool":"\(raw)"}],"totalRanked":1}
            """.data(using: .utf8)!
            let resp = try decoder.decode(SuggestionsResponse.self, from: json)
            XCTAssertEqual(resp.items[0].pool, expected, "pool \(raw)")
        }
    }

    /// An absent `pool` decodes to nil (server always sends it, but the client
    /// must not require it).
    func testAbsentPoolDecodesToNil() throws {
        let json = """
        {"items":[{"id":"i","tmdbId":1,"title":"t","year":"2000",
        "posterUrl":null,"backdropUrl":null,"mediaType":"movie","genres":[],
        "overview":"","seasonCount":0}],"totalRanked":1}
        """.data(using: .utf8)!
        let resp = try decoder.decode(SuggestionsResponse.self, from: json)
        XCTAssertNil(resp.items[0].pool)
    }

    // MARK: - Request body encode

    func testRequestBodyEncodesSessionExcludeIdsAsArray() throws {
        let body = SuggestionsRequest(
            mediaType: .movie, mode: .suggestions, page: 2,
            sessionExcludeIds: ["tmdb_1", "tmdb_2"], locale: "en-US", limit: nil
        )
        let data = try JSONEncoder().encode(body)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(obj["mediaType"] as? String, "movie")
        XCTAssertEqual(obj["mode"] as? String, "suggestions")
        XCTAssertEqual(obj["page"] as? Int, 2)
        XCTAssertEqual(obj["locale"] as? String, "en-US")
        XCTAssertEqual(obj["sessionExcludeIds"] as? [String], ["tmdb_1", "tmdb_2"])
        XCTAssertNil(obj["limit"], "nil optionals are omitted")
    }

    func testRequestBodyOmitsEmptyOptionals() throws {
        let body = SuggestionsRequest(
            mediaType: .tv, mode: .backfill, page: 1,
            sessionExcludeIds: nil, locale: nil, limit: nil
        )
        let data = try JSONEncoder().encode(body)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(obj["mediaType"] as? String, "tv")
        XCTAssertEqual(obj["mode"] as? String, "backfill")
        XCTAssertEqual(obj["page"] as? Int, 1)
        XCTAssertNil(obj["sessionExcludeIds"])
        XCTAssertNil(obj["locale"])
        XCTAssertNil(obj["limit"])
    }

    func testRequestBodyEncodesNewReleasesModeAndLimit() throws {
        let body = SuggestionsRequest(
            mediaType: .movie, mode: .newReleases, page: 1,
            sessionExcludeIds: [], locale: "zh-CN", limit: 10
        )
        let data = try JSONEncoder().encode(body)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["mode"] as? String, "new_releases")
        XCTAssertEqual(obj["limit"] as? Int, 10)
        XCTAssertEqual(obj["sessionExcludeIds"] as? [String], [])
    }
}
