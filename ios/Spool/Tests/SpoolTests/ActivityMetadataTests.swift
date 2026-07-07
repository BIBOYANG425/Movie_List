import XCTest
@testable import Spool

/// Contract: `activity_events.metadata` for `ranking_add` carries
/// `{ notes?, year?, watched_with_user_ids? }` — each key OMITTED entirely
/// when nil/empty (never null-valued, never empty-string/empty-array), and
/// the object is `{}` when there is nothing to send.
/// Source: shared-payloads contract quote in
/// docs/plans/2026-07-08-c1-ios-feed-data-plan.md (Global Constraints + Task 1).
final class ActivityMetadataTests: XCTestCase {

    private let uidA = UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")!
    private let uidB = UUID(uuidString: "BBBBBBBB-5555-6666-7777-888888888888")!

    private func jsonObject(_ metadata: ActivityMetadata) throws -> [String: Any] {
        let data = try JSONEncoder().encode(metadata)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: full metadata → exact snake_case key set

    func testFullMetadataEncodesExactContractKeySet() throws {
        let m = ActivityMetadata(notes: "so good", year: "1999", watchedWithUserIds: [uidA])
        let obj = try jsonObject(m)
        XCTAssertEqual(Set(obj.keys), ["notes", "year", "watched_with_user_ids"],
                       "contract keys only, snake_case")
        XCTAssertEqual(obj["notes"] as? String, "so good")
        XCTAssertEqual(obj["year"] as? String, "1999")
    }

    // MARK: falsy members → keys ABSENT (never null, never "" / [])

    func testAllNilEncodesEmptyObject() throws {
        let obj = try jsonObject(ActivityMetadata(notes: nil, year: nil, watchedWithUserIds: nil))
        XCTAssertTrue(obj.isEmpty, "all-nil metadata must encode {}, got \(obj)")
    }

    func testEmptyValuesEncodeEmptyObject() throws {
        let obj = try jsonObject(ActivityMetadata(notes: "", year: "", watchedWithUserIds: []))
        XCTAssertTrue(obj.isEmpty,
                      "empty string / empty array must OMIT keys entirely, got \(obj)")
    }

    func testMixedFalsyMembersOmitOnlyThoseKeys() throws {
        let obj = try jsonObject(ActivityMetadata(notes: "", year: "2024", watchedWithUserIds: nil))
        XCTAssertEqual(Set(obj.keys), ["year"], "only the truthy member survives")
        XCTAssertEqual(obj["year"] as? String, "2024")
    }

    // MARK: whitespace-only is KEPT — omission is web truthiness, not trimming

    func testWhitespaceOnlyNotesAreKeptVerbatim() throws {
        // Web gates the key on JS truthiness ("  " is truthy) and never
        // trims, so a whitespace-only note ships as-is. iOS's isEmpty check
        // mirrors that boundary exactly: only "" drops the key.
        let obj = try jsonObject(ActivityMetadata(notes: "  ", year: nil, watchedWithUserIds: nil))
        XCTAssertEqual(Set(obj.keys), ["notes"], "\"  \" is truthy — key must survive")
        XCTAssertEqual(obj["notes"] as? String, "  ", "value must be untrimmed")
    }

    // MARK: uuid array → lowercase strings (web parity; Swift's UUID uppercases)

    func testWatchedWithEncodesLowercaseUUIDStrings() throws {
        let obj = try jsonObject(ActivityMetadata(notes: nil, year: nil,
                                                  watchedWithUserIds: [uidA, uidB]))
        let ids = try XCTUnwrap(obj["watched_with_user_ids"] as? [String],
                                "watched_with_user_ids must be a string array")
        XCTAssertEqual(ids, [
            "aaaaaaaa-1111-2222-3333-444444444444",
            "bbbbbbbb-5555-6666-7777-888888888888",
        ], "uuid strings must be lowercase and order-preserving")
    }
}
