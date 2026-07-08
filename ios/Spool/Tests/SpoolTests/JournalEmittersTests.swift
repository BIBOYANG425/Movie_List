import XCTest
@testable import Spool

/// Pure-payload pins for the C2 journal side-effect emitters (plan Task 6). The
/// `JournalDraftModel` owns the GATE logic (tested in `JournalDraftModelTests`);
/// `JournalEmitters` binds the emitted inputs to the REAL `activity_events` /
/// `notifications` insert wire shapes. These tests assert the encoded JSON
/// matches web 1:1 with ZERO network — the builders are pure.
///
/// Wire references:
///  - `review` activity event: `services/feedService.ts:664-693`
///    (`logReviewActivityEvent`) — `event_type: 'review'`, the four `media_*`
///    columns, `metadata: { reviewBody, containsSpoilers }`. Mirrors
///    `RankingRepository`'s `activity_events` insert.
///  - `journal_tag` notification: `services/journalService.ts:268-279`, one row
///    per friend, `body` = first 100 chars of review. Mirrors
///    `FollowRepository`'s `NotificationInsertPayload`.
final class JournalEmittersTests: XCTestCase {

    private let actor = UUID(uuidString: "0FFF0000-0000-0000-0000-0000000000FF")!
    private let friend = UUID(uuidString: "11110000-0000-0000-0000-000000000001")!
    private let entry = UUID(uuidString: "22220000-0000-0000-0000-000000000002")!

    private func decode(_ payload: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - review activity event

    func testReviewEventPayloadShapeMirrorsWeb() throws {
        let input = JournalDraftModel.ReviewEventInput(
            tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg",
            tier: "S", body: "a machine dreamt of us.", containsSpoilers: true
        )
        let payload = JournalEmitters.reviewEventPayload(actorID: actor, input: input)
        let json = try decode(payload)

        XCTAssertEqual(json["actor_id"] as? String, actor.uuidString.lowercased())
        XCTAssertEqual(json["event_type"] as? String, "review")
        XCTAssertEqual(json["media_tmdb_id"] as? String, "603")
        XCTAssertEqual(json["media_title"] as? String, "The Matrix")
        XCTAssertEqual(json["media_tier"] as? String, "S")
        XCTAssertEqual(json["media_poster_url"] as? String, "/p.jpg")

        let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["reviewBody"] as? String, "a machine dreamt of us.")
        XCTAssertEqual(metadata["containsSpoilers"] as? Bool, true)
        // Exactly the two metadata keys — no extras.
        XCTAssertEqual(Set(metadata.keys), ["reviewBody", "containsSpoilers"])
    }

    func testReviewEventPayloadEncodesNilMediaColumnsAsExplicitNull() throws {
        let input = JournalDraftModel.ReviewEventInput(
            tmdbId: "1", title: "Untitled", posterUrl: nil,
            tier: nil, body: "b", containsSpoilers: false
        )
        let data = try JSONEncoder().encode(JournalEmitters.reviewEventPayload(actorID: actor, input: input))
        let raw = String(data: data, encoding: .utf8) ?? ""
        // `media_tier` / `media_poster_url` nullable here (web `tier ?? null`).
        XCTAssertTrue(raw.contains("\"media_tier\":null"), raw)
        XCTAssertTrue(raw.contains("\"media_poster_url\":null"), raw)
    }

    // MARK: - journal_tag notification

    func testJournalTagNotificationPayloadShapeMirrorsWeb() throws {
        let input = JournalDraftModel.JournalTagInput(
            friendID: friend, actorID: actor,
            title: "watched The Matrix with you",
            body: "a machine dreamt of us.", referenceID: entry
        )
        let payload = JournalEmitters.journalTagPayload(input: input)
        let json = try decode(payload)

        XCTAssertEqual(json["user_id"] as? String, friend.uuidString.lowercased())
        XCTAssertEqual(json["type"] as? String, "journal_tag")
        XCTAssertEqual(json["title"] as? String, "watched The Matrix with you")
        XCTAssertEqual(json["body"] as? String, "a machine dreamt of us.")
        XCTAssertEqual(json["actor_id"] as? String, actor.uuidString.lowercased())
        // reference_id is the journal entry id (deep-link target).
        XCTAssertEqual(json["reference_id"] as? String, entry.uuidString.lowercased())
    }

    func testJournalTagNotificationOmitsBodyWhenNil() throws {
        // Web: `body: data.reviewText ? … : undefined` → key omitted, not null.
        let input = JournalDraftModel.JournalTagInput(
            friendID: friend, actorID: actor,
            title: "watched X with you", body: nil, referenceID: entry
        )
        let json = try decode(JournalEmitters.journalTagPayload(input: input))
        XCTAssertNil(json["body"])
        XCTAssertFalse(json.keys.contains("body"))
    }
}
