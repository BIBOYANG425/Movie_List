import XCTest
@testable import Spool

/// Pure notification + mute contract, mirroring web on
/// `fix/c1-feed-web-blocking`:
///  - `NotificationKind.orFallback` — contract: "unknown types render with
///    the `new_follower` fallback" (plan Global Constraints, notifications
///    bullet); the six known types map 1:1;
///  - mark-read id-picking = `NotificationBell.tsx` L83
///    (`data.filter((n) => !n.isRead).map((n) => n.id)`): bulk-mark EXACTLY
///    the fetched unread ids — read rows are never re-marked;
///  - actor join = `notificationService.ts` `getNotifications` (L25–57):
///    actor ids deduped (L34), profiles batch-selected
///    `id, username, avatar_path` (L38), avatar comes from `avatar_path`
///    ONLY (L52) — iOS carries the raw PATH (URL building is a UI concern,
///    and there is deliberately NO `avatar_url` fallback chain);
///  - mute set-building = `feedService.ts` `getFeedCards` L231–232
///    (`mutes.filter(m => m.muteType === 'user'/'movie').map(m => m.targetId)`)
///    over `feed_mutes` rows (phase-5 migration: `mute_type` ∈
///    {'user','movie'}, `target_id` text, UNIQUE(user_id, mute_type,
///    target_id));
///  - mute insert payload = `feedService.ts` `addMute` L636–640: exactly
///    `{user_id, mute_type, target_id}` (`id`/`created_at` server-side).
/// Source: docs/plans/2026-07-08-c1-ios-feed-data-plan.md (Global
/// Constraints + Task 4).
final class NotificationTests: XCTestCase {

    private let me = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let alice = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let bob = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    // MARK: - Helpers

    private func row(_ id: String,
                     type: String = "new_follower",
                     actor: UUID? = nil,
                     isRead: Bool = false) -> NotificationRow {
        NotificationRow(id: UUID(uuidString: "DDDDDDDD-0000-0000-0000-0000000000\(id)")!,
                        user_id: me,
                        type: type,
                        title: "started following you",
                        body: nil,
                        actor_id: actor,
                        reference_id: actor?.uuidString.lowercased(),
                        is_read: isRead,
                        created_at: "2026-07-07T10:00:00.123456+00:00")
    }

    private func mute(_ type: String, _ target: String) -> FeedMuteRow {
        FeedMuteRow(mute_type: type, target_id: target)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - NotificationKind.orFallback

    func testOrFallbackMapsAllSixKnownTypes() {
        XCTAssertEqual(NotificationKind.orFallback("new_follower"), .newFollower)
        XCTAssertEqual(NotificationKind.orFallback("review_like"), .reviewLike)
        XCTAssertEqual(NotificationKind.orFallback("list_like"), .listLike)
        XCTAssertEqual(NotificationKind.orFallback("badge_unlock"), .badgeUnlock)
        XCTAssertEqual(NotificationKind.orFallback("ranking_comment"), .rankingComment)
        XCTAssertEqual(NotificationKind.orFallback("journal_tag"), .journalTag)
        // The enum IS the six-type contract list — a seventh case would
        // silently skip the fallback test above.
        XCTAssertEqual(NotificationKind.allCases.count, 6)
    }

    func testOrFallbackUnknownTypesFallBackToNewFollower() {
        XCTAssertEqual(NotificationKind.orFallback("party_invite"), .newFollower)
        XCTAssertEqual(NotificationKind.orFallback(""), .newFollower)
        // Raw types are exact strings on the wire — no case folding.
        XCTAssertEqual(NotificationKind.orFallback("Review_Like"), .newFollower)
    }

    func testItemKindUsesFallbackButPreservesRawType() {
        let items = NotificationAssembler.items(from: [row("01", type: "future_thing")],
                                                actors: [])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].type, "future_thing") // raw survives for debugging
        XCTAssertEqual(items[0].kind, .newFollower)   // renders as fallback
    }

    // MARK: - Mark-read id-picking (bell L83: only fetched AND unread)

    func testUnreadIDsPicksOnlyUnreadPreservingOrder() {
        let items = NotificationAssembler.items(
            from: [row("01", isRead: false),
                   row("02", isRead: true),
                   row("03", isRead: false)],
            actors: [])
        XCTAssertEqual(NotificationAssembler.unreadIDs(from: items),
                       [items[0].id, items[2].id])
    }

    func testUnreadIDsEmptyWhenAllReadOrNoRows() {
        let allRead = NotificationAssembler.items(
            from: [row("01", isRead: true), row("02", isRead: true)],
            actors: [])
        XCTAssertEqual(NotificationAssembler.unreadIDs(from: allRead), [])
        XCTAssertEqual(NotificationAssembler.unreadIDs(from: []), [])
    }

    // MARK: - Actor batch-join (web getNotifications L34–56)

    func testActorIDsDedupedSkippingNilPreservingFirstSeenOrder() {
        let rows = [row("01", actor: alice),
                    row("02", actor: nil),
                    row("03", actor: bob),
                    row("04", actor: alice)]
        XCTAssertEqual(NotificationAssembler.actorIDs(from: rows), [alice, bob])
        XCTAssertEqual(NotificationAssembler.actorIDs(from: [row("01")]), [])
    }

    func testItemsJoinActorProfilesByID() {
        let rows = [row("01", actor: alice, isRead: true),
                    row("02", actor: bob),
                    row("03", actor: nil)]
        let actors = [NotificationActorRow(id: alice, username: "alice", avatar_path: "ab/alice.jpg")]
        let items = NotificationAssembler.items(from: rows, actors: actors)

        XCTAssertEqual(items.map(\.id), rows.map(\.id)) // row order preserved

        // Matched actor: both fields hydrate.
        XCTAssertEqual(items[0].actorUsername, "alice")
        XCTAssertEqual(items[0].actorAvatarPath, "ab/alice.jpg")
        // Actor id present but profile missing from the batch (deleted
        // user): fields stay nil, row still renders.
        XCTAssertEqual(items[1].actorID, bob)
        XCTAssertNil(items[1].actorUsername)
        XCTAssertNil(items[1].actorAvatarPath)
        // No actor at all.
        XCTAssertNil(items[2].actorID)
        XCTAssertNil(items[2].actorUsername)

        // Row fields carried verbatim.
        XCTAssertEqual(items[0].title, "started following you")
        XCTAssertTrue(items[0].isRead)
        XCTAssertFalse(items[1].isRead)
        XCTAssertEqual(items[0].createdAt, "2026-07-07T10:00:00.123456+00:00")
        XCTAssertEqual(items[0].referenceID, alice.uuidString.lowercased())
    }

    func testItemsAvatarIsRawPathFromAvatarPathOnly() {
        // avatar_path nil → nil; NO fallback to anything else (the actor
        // row deliberately has no avatar_url member to fall back to).
        let actors = [NotificationActorRow(id: alice, username: "alice", avatar_path: nil)]
        let items = NotificationAssembler.items(from: [row("01", actor: alice)], actors: actors)
        XCTAssertEqual(items[0].actorUsername, "alice")
        XCTAssertNil(items[0].actorAvatarPath)

        // And when present it is the raw storage PATH, never a built URL.
        let withPath = NotificationAssembler.items(
            from: [row("02", actor: alice)],
            actors: [NotificationActorRow(id: alice, username: "alice", avatar_path: "ab/alice.jpg")])
        XCTAssertEqual(withPath[0].actorAvatarPath, "ab/alice.jpg")
        XCTAssertFalse(withPath[0].actorAvatarPath!.contains("://"))
    }

    // MARK: - Mute set-building (web getFeedCards L231–232)

    func testMuteSetsSplitUserAndMovieRows() {
        let sets = FeedMutes.sets(from: [
            mute("user", alice.uuidString.lowercased()),
            mute("movie", "603"),
            mute("user", bob.uuidString.lowercased()),
            mute("movie", "27205"),
        ])
        XCTAssertEqual(sets.users, [alice, bob])
        XCTAssertEqual(sets.media, ["603", "27205"])
    }

    func testMuteSetsIgnoreUnknownTypeAndUnparseableUserID() {
        let sets = FeedMutes.sets(from: [
            mute("user", "not-a-uuid"),   // defensive drop — cannot match an actor_id
            mute("channel", "whatever"),  // unknown mute_type: web's exact-string filters skip it too
            mute("movie", "603"),
        ])
        XCTAssertTrue(sets.users.isEmpty)
        XCTAssertEqual(sets.media, ["603"])
    }

    func testMuteSetsDedupeAndUUIDCaseInsensitive() {
        let sets = FeedMutes.sets(from: [
            mute("user", alice.uuidString.lowercased()),
            mute("user", alice.uuidString), // uppercase form of the same id
            mute("movie", "603"),
            mute("movie", "603"),
        ])
        XCTAssertEqual(sets.users, [alice])
        XCTAssertEqual(sets.media, ["603"])
        XCTAssertEqual(FeedMutes.sets(from: []).users, [])
        XCTAssertEqual(FeedMutes.sets(from: []).media, [])
    }

    // MARK: - Mute insert payload (web addMute L636–640)

    func testMuteInsertPayloadWireFormat() throws {
        let user = try jsonObject(FeedMutes.insertPayload(userID: me, mutingUser: alice))
        XCTAssertEqual(Set(user.keys), ["user_id", "mute_type", "target_id"])
        XCTAssertEqual(user["user_id"] as? String, me.uuidString.lowercased())
        XCTAssertEqual(user["mute_type"] as? String, "user")
        // target_id is TEXT in feed_mutes; user targets go up as the
        // lowercase uuid string so they compare equal to `actor_id::text`.
        XCTAssertEqual(user["target_id"] as? String, alice.uuidString.lowercased())

        let movie = try jsonObject(FeedMutes.insertPayload(userID: me, mutingMedia: "603"))
        XCTAssertEqual(Set(movie.keys), ["user_id", "mute_type", "target_id"])
        XCTAssertEqual(movie["mute_type"] as? String, "movie")
        XCTAssertEqual(movie["target_id"] as? String, "603")
    }
}
