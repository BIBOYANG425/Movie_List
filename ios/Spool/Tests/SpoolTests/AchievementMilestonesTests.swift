import XCTest
@testable import Spool

/// Pins for the C7-iOS post-write achievement hook's milestone-feed emitter
/// (`AchievementMilestones`). The grant call itself is fire-and-forget IO; these
/// tests assert the PURE seams with ZERO network:
///
///  - the milestone `activity_events` payload SHAPE matches web 1:1
///    (`event_type: 'milestone'`, metadata `{ badgeKey, badgeIcon,
///    milestoneDescription }`, NO media columns) — web `feedService.logMilestoneEvent`
///    (`services/feedService.ts:730-738`);
///  - the milestone copy map is the VERBATIM web `BADGE_MILESTONE_COPY`
///    (`services/achievementService.ts:17-33`) — the contract's pinned copy
///    source, DISTINCT from `BadgeCatalog`;
///  - one payload per NEW key, order preserved, empty return → zero payloads
///    (iOS MUST NOT emit for a key the user already held — the loop iterates only
///    the RPC's returned NEW keys), and the unknown-key fallback matches web.
final class AchievementMilestonesTests: XCTestCase {

    private let actor = UUID(uuidString: "0FFF0000-0000-0000-0000-0000000000AA")!

    private func decode(_ payload: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Payload shape (web parity)

    func testMilestonePayloadShapeMirrorsWeb() throws {
        let payload = AchievementMilestones.milestoneEventPayload(actorID: actor, key: "rank_100")
        let json = try decode(payload)

        // Exactly three top-level keys — NO media columns (web writes none).
        XCTAssertEqual(Set(json.keys), ["actor_id", "event_type", "metadata"])
        XCTAssertEqual(json["actor_id"] as? String, actor.uuidString.lowercased())
        XCTAssertEqual(json["event_type"] as? String, "milestone")

        let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
        // Exactly the three metadata keys the feed card reads — no extras.
        XCTAssertEqual(Set(metadata.keys), ["badgeKey", "badgeIcon", "milestoneDescription"])
        XCTAssertEqual(metadata["badgeKey"] as? String, "rank_100")
        XCTAssertEqual(metadata["badgeIcon"] as? String, "👑")
        XCTAssertEqual(metadata["milestoneDescription"] as? String, "Ranked 100 movies")
    }

    /// UUIDs are lowercased on the wire (Swift UUIDs uppercase; web is lower).
    func testActorIDLowercasedOnWire() throws {
        let json = try decode(AchievementMilestones.milestoneEventPayload(actorID: actor, key: "first_rank"))
        let actorID = try XCTUnwrap(json["actor_id"] as? String)
        XCTAssertEqual(actorID, actorID.lowercased())
    }

    // MARK: - Copy map (verbatim BADGE_MILESTONE_COPY)

    /// The map covers exactly the 15 grantable keys — `early_adopter` (no RPC
    /// rule) never appears in a grant return, so it has no milestone copy (web
    /// parity: web's BADGE_MILESTONE_COPY also omits it).
    func testMilestoneCopyCoversTheFifteenGrantableKeys() {
        XCTAssertEqual(Set(AchievementMilestones.milestoneCopy.keys),
                       Set(BadgeCatalog.grantableKeys))
        XCTAssertNil(AchievementMilestones.milestoneCopy["early_adopter"])
    }

    /// Spot-check the copy is the VERBATIM web map — icons/descriptions that
    /// DIFFER from `BadgeCatalog` (proving the correct source was ported).
    func testMilestoneCopyIsVerbatimWebNotBadgeCatalog() {
        // web BADGE_MILESTONE_COPY.rank_10 = 🎯 "Ranked 10 movies";
        // BadgeCatalog.rank_10 icon = 🎞️ (different) — the feed uses the former.
        let rank10 = AchievementMilestones.copy(for: "rank_10")
        XCTAssertEqual(rank10.icon, "🎯")
        XCTAssertEqual(rank10.description, "Ranked 10 movies")
        XCTAssertNotEqual(rank10.icon, BadgeCatalog.byKey["rank_10"]?.icon)

        // s_tier_10: web 💎 "10 movies in S tier"; catalog icon 👑 (different).
        let sTier = AchievementMilestones.copy(for: "s_tier_10")
        XCTAssertEqual(sTier.icon, "💎")
        XCTAssertEqual(sTier.description, "10 movies in S tier")
    }

    /// Unknown key → web's `{ icon: '🏅', description: 'Unlocked: <key>' }`
    /// fallback (a newer server badge this build doesn't map still emits).
    func testUnknownKeyFallbackMatchesWeb() throws {
        let fallback = AchievementMilestones.copy(for: "future_badge")
        XCTAssertEqual(fallback.icon, "🏅")
        XCTAssertEqual(fallback.description, "Unlocked: future_badge")

        let json = try decode(
            AchievementMilestones.milestoneEventPayload(actorID: actor, key: "future_badge")
        )
        let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["badgeIcon"] as? String, "🏅")
        XCTAssertEqual(metadata["milestoneDescription"] as? String, "Unlocked: future_badge")
    }

    // MARK: - One event per NEW key (the milestone loop's decision seam)

    /// One payload per NEW key, order preserved — the milestone fan-out.
    func testMilestonePayloads_onePerNewKey_orderPreserved() {
        let payloads = AchievementMilestones.milestonePayloads(
            actorID: actor, newKeys: ["first_rank", "rank_10", "rank_25"]
        )
        XCTAssertEqual(payloads.map { $0.metadata.badgeKey },
                       ["first_rank", "rank_10", "rank_25"])
        XCTAssertTrue(payloads.allSatisfy { $0.event_type == "milestone" })
    }

    /// EMPTY return → ZERO payloads. The RPC returns only NEWLY granted keys, so
    /// a call that granted nothing (all badges already held) emits no milestone —
    /// the "never emit for an already-held badge" contract rule.
    func testMilestonePayloads_emptyReturn_emitsNothing() {
        XCTAssertTrue(AchievementMilestones.milestonePayloads(actorID: actor, newKeys: []).isEmpty)
    }
}
