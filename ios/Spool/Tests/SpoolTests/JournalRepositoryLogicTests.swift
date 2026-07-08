import XCTest
import Supabase
@testable import Spool

/// Pure tests for the `JournalRepository` marshalling seams — the bits that
/// don't touch the network. Mirrors the web `journalService.ts` seams
/// (`buildSearchRpcArgs`, `buildLikeInsertPayload`, `getLikedEntryIds`'s
/// reducer) and the 23-column shared search-row shape (audit B5: no
/// `personal_takeaway`, no `search_vector`).
final class JournalRepositoryLogicTests: XCTestCase {

    private let uid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let target = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
    private let entryA = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private let entryB = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
    private let entryC = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!

    // MARK: searchRpcArgs — { search_query, target_user_id }

    /// Web `buildSearchRpcArgs(targetUserId, query) → { search_query: query,
    /// target_user_id: targetUserId }`. Exactly two keys, lowercase uuid on
    /// the wire (web parity — Swift's UUID uppercases).
    func testSearchRpcArgsShape() throws {
        let args = JournalRepoLogic.searchRpcArgs(query: "matrix", targetUserID: target)

        XCTAssertEqual(Set(args.keys), ["search_query", "target_user_id"])
        XCTAssertEqual(args["search_query"], .string("matrix"))
        XCTAssertEqual(args["target_user_id"], .string(target.uuidString.lowercased()))
    }

    /// An empty query is forwarded verbatim (the RPC, not the client, decides
    /// what an empty plainto_tsquery returns).
    func testSearchRpcArgsEmptyQueryPassthrough() {
        let args = JournalRepoLogic.searchRpcArgs(query: "", targetUserID: target)
        XCTAssertEqual(args["search_query"], .string(""))
    }

    // MARK: likeInsertPayload — { entry_id, user_id }

    /// Web `buildLikeInsertPayload(entryId, userId) → { entry_id, user_id }`
    /// against `journal_entry_likes(entry_id, user_id)`. Lowercase uuids.
    func testLikeInsertPayloadShape() throws {
        let payload = JournalRepoLogic.likeInsertPayload(entryID: entryA, userID: uid)

        let data = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(Set(obj.keys), ["entry_id", "user_id"])
        XCTAssertEqual(obj["entry_id"] as? String, entryA.uuidString.lowercased())
        XCTAssertEqual(obj["user_id"] as? String, uid.uuidString.lowercased())
    }

    // MARK: likedSet reducer — [LikeRow] → Set<UUID>

    /// Web `getLikedEntryIds` reduces the fetched `entry_id` column into a Set
    /// for O(1) card lookup.
    func testLikedSetReduces() {
        let rows = [
            JournalRepoLogic.LikeRow(entry_id: entryA),
            JournalRepoLogic.LikeRow(entry_id: entryC),
        ]
        XCTAssertEqual(JournalRepoLogic.likedSet(from: rows), [entryA, entryC])
    }

    func testLikedSetEmpty() {
        XCTAssertEqual(JournalRepoLogic.likedSet(from: []), Set<UUID>())
    }

    func testLikedSetDedupes() {
        let rows = [
            JournalRepoLogic.LikeRow(entry_id: entryA),
            JournalRepoLogic.LikeRow(entry_id: entryA),
            JournalRepoLogic.LikeRow(entry_id: entryB),
        ]
        XCTAssertEqual(JournalRepoLogic.likedSet(from: rows), [entryA, entryB])
    }

    // MARK: JournalSearchRow — 23 cols, NO personal_takeaway, NO search_vector

    /// The shared search-row DTO decodes the RPC's 23-column table. Decoding a
    /// full row that ALSO carries `personal_takeaway`/`search_vector` must
    /// succeed (extra keys ignored) and the type must expose neither field —
    /// a cross-user read can never surface the owner-only takeaway.
    func testSearchRowDecodesAndOmitsTakeaway() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-0000000000AA",
            "user_id": "00000000-0000-0000-0000-000000000001",
            "tmdb_id": "603",
            "title": "The Matrix",
            "poster_url": "https://img/matrix.jpg",
            "rating_tier": "S",
            "review_text": "a machine dream",
            "contains_spoilers": true,
            "mood_tags": ["thrilled"],
            "vibe_tags": ["late_night"],
            "favorite_moments": ["the lobby"],
            "standout_performances": [{"personId": 6384, "name": "Keanu Reeves", "character": "Neo"}],
            "watched_date": "2026-07-06",
            "watched_location": "home",
            "watched_with_user_ids": ["00000000-0000-0000-0000-0000000000BB"],
            "watched_platform": "netflix",
            "is_rewatch": false,
            "rewatch_note": "still holds up",
            "photo_paths": ["u/603/0.jpg"],
            "visibility_override": "public",
            "like_count": 3,
            "created_at": "2026-07-06T00:00:00Z",
            "updated_at": "2026-07-06T01:00:00Z",
            "personal_takeaway": "SHOULD NOT SURFACE",
            "search_vector": "'machine':1"
        }
        """.data(using: .utf8)!

        let row = try JSONDecoder().decode(JournalSearchRow.self, from: json)
        XCTAssertEqual(row.id, entryA)
        XCTAssertEqual(row.title, "The Matrix")
        XCTAssertEqual(row.like_count, 3)
        XCTAssertEqual(row.updated_at, "2026-07-06T01:00:00Z")

        // The DTO must carry exactly the 23 shared columns — no takeaway, no
        // search_vector. Re-encoding proves the fields the type owns.
        let reencoded = try JSONEncoder().encode(row)
        let keys = Set((try JSONSerialization.jsonObject(with: reencoded) as! [String: Any]).keys)
        XCTAssertFalse(keys.contains("personal_takeaway"),
                       "JournalSearchRow must not carry personal_takeaway (owner-only, audit B5)")
        XCTAssertFalse(keys.contains("search_vector"))
        XCTAssertEqual(keys, JournalRepositoryLogicTests.expectedSearchRowKeys)
    }

    /// The exact 23 columns of the search RPC return table (contract's
    /// JOURNAL_ENTRY_SHARED_COLUMN_LIST).
    static let expectedSearchRowKeys: Set<String> = [
        "id", "user_id", "tmdb_id", "title", "poster_url", "rating_tier",
        "review_text", "contains_spoilers", "mood_tags", "vibe_tags",
        "favorite_moments", "standout_performances", "watched_date",
        "watched_location", "watched_with_user_ids", "watched_platform",
        "is_rewatch", "rewatch_note", "photo_paths", "visibility_override",
        "like_count", "created_at", "updated_at",
    ]
}
