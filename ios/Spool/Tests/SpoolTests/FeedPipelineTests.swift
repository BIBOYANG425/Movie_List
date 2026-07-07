import XCTest
@testable import Spool

/// Pure feed-pipeline contract, mirroring web's post-#32 `services/feedService.ts`:
///  - cursor `(boosted_ts, id)` echoed VERBATIM off the server row — never
///    recomputed, never re-parsed-and-reformatted (String end-to-end);
///  - mute filtering (user via `actor_id`, media via `media_tmdb_id`);
///  - event-type filter — both mode defaults exclude `ranking_remove`;
///  - milestone throttle: cap 3 per actor per LOCAL calendar day, counted
///    per resume-session in a caller-owned dict (carries across pages,
///    resets with a fresh dict);
///  - score-map key `"<lowercase uuid>:<tmdbId>"` — byte-identical to web's
///    `${userId}:${tmdbId}` (DB uuids are lowercase strings).
/// Source: docs/plans/2026-07-08-c1-ios-feed-data-plan.md (Global Constraints + Task 2).
final class FeedPipelineTests: XCTestCase {

    private let actorA = UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")!
    private let actorB = UUID(uuidString: "BBBBBBBB-5555-6666-7777-888888888888")!

    private func makeRow(
        id: UUID = UUID(),
        actor: UUID,
        type: String,
        tmdbID: String? = nil,
        createdAt: String = "2026-07-07T12:00:00+00:00",
        boostedTs: String = "2026-07-07T12:00:00+00:00"
    ) -> FeedEventRow {
        FeedEventRow(
            id: id,
            actor_id: actor,
            event_type: type,
            media_tmdb_id: tmdbID,
            media_title: nil,
            media_tier: nil,
            media_poster_url: nil,
            metadata: nil,
            created_at: createdAt,
            boosted_ts: boostedTs
        )
    }

    private func calendar(_ tz: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        return cal
    }

    // MARK: - Cursor: verbatim echo, String end-to-end

    func testCursorEchoesServerBoostedTsByteVerbatim() {
        // Postgres µs precision — must survive untouched. Any parse+reformat
        // round trip would truncate to ms and break keyset resume.
        let micro = "2026-07-07T12:34:56.789012+00:00"
        let id = UUID()
        let row = makeRow(id: id, actor: actorA, type: "review", boostedTs: micro)

        let cursor = FeedPipeline.cursor(fromLastConsumed: row)

        XCTAssertEqual(cursor.boostedTs, micro, "boosted_ts must be echoed byte-verbatim")
        XCTAssertEqual(cursor.id, id)
    }

    func testCursorNeverParsesTheTimestamp() {
        // Deliberately NOT a format Foundation would emit: 7 fractional
        // digits and a bare `+00` offset. A verbatim copy preserves it; any
        // re-parse-and-reformat would normalize (or nil out) the string.
        let odd = "2026-07-07 12:34:56.7890123+00"
        let row = makeRow(actor: actorA, type: "ranking_add", boostedTs: odd)

        XCTAssertEqual(FeedPipeline.cursor(fromLastConsumed: row).boostedTs, odd)
    }

    // MARK: - Mutes

    func testApplyMutesDropsMutedUsersRows() {
        let rows = [
            makeRow(actor: actorA, type: "ranking_add"),
            makeRow(actor: actorB, type: "review"),
            makeRow(actor: actorA, type: "milestone"),
        ]
        let kept = FeedPipeline.applyMutes(rows, mutedUsers: [actorA], mutedMedia: [])
        XCTAssertEqual(kept.map(\.actor_id), [actorB])
    }

    func testApplyMutesDropsMutedMediaByTmdbId() {
        let rows = [
            makeRow(actor: actorA, type: "ranking_add", tmdbID: "603"),
            makeRow(actor: actorA, type: "review", tmdbID: "550"),
            makeRow(actor: actorA, type: "milestone", tmdbID: nil), // no media — media mutes can't touch it
        ]
        let kept = FeedPipeline.applyMutes(rows, mutedUsers: [], mutedMedia: ["603"])
        XCTAssertEqual(kept.map(\.media_tmdb_id), ["550", nil])
    }

    func testApplyMutesAppliesBothSetsAndPreservesOrder() {
        let r1 = makeRow(actor: actorA, type: "ranking_add", tmdbID: "1")
        let r2 = makeRow(actor: actorB, type: "ranking_add", tmdbID: "2")
        let r3 = makeRow(actor: actorB, type: "ranking_add", tmdbID: "3")
        let r4 = makeRow(actor: actorB, type: "ranking_add", tmdbID: "4")

        let kept = FeedPipeline.applyMutes([r1, r2, r3, r4],
                                           mutedUsers: [actorA],
                                           mutedMedia: ["3"])
        XCTAssertEqual(kept.map(\.id), [r2.id, r4.id], "order preserved, both mute kinds applied")
    }

    func testApplyMutesWithEmptySetsIsIdentity() {
        let rows = [makeRow(actor: actorA, type: "review", tmdbID: "550")]
        XCTAssertEqual(FeedPipeline.applyMutes(rows, mutedUsers: [], mutedMedia: []), rows)
    }

    // MARK: - Event-type filter

    func testApplyTypeFilterKeepsOnlyAllowedTypes() {
        let rows = [
            makeRow(actor: actorA, type: "ranking_add"),
            makeRow(actor: actorA, type: "ranking_remove"),
            makeRow(actor: actorA, type: "review"),
        ]
        let kept = FeedPipeline.applyTypeFilter(rows, allowed: ["review"])
        XCTAssertEqual(kept.map(\.event_type), ["review"])
    }

    func testDefaultEventTypesMatchWebAllFilterForBothModes() {
        // Web getEventTypesForFilter('all') — same 5-type set in both tabs.
        let expected: Set<String> = ["ranking_add", "ranking_move", "review", "list_create", "milestone"]
        XCTAssertEqual(FeedPipeline.defaultEventTypes(explore: true), expected)
        XCTAssertEqual(FeedPipeline.defaultEventTypes(explore: false), expected)
    }

    func testDefaultEventTypesExcludeRankingRemoveInBothModes() {
        XCTAssertFalse(FeedPipeline.defaultEventTypes(explore: true).contains("ranking_remove"))
        XCTAssertFalse(FeedPipeline.defaultEventTypes(explore: false).contains("ranking_remove"))

        let removal = [makeRow(actor: actorA, type: "ranking_remove")]
        XCTAssertTrue(FeedPipeline.applyTypeFilter(removal, allowed: FeedPipeline.defaultEventTypes(explore: true)).isEmpty)
        XCTAssertTrue(FeedPipeline.applyTypeFilter(removal, allowed: FeedPipeline.defaultEventTypes(explore: false)).isEmpty)
    }

    // MARK: - Milestone throttle (cap 3, per actor, per LOCAL day, session dict)

    func testThrottleCapsAtThreeMilestonesPerActorPerDay() {
        let rows = (0..<5).map { _ in makeRow(actor: actorA, type: "milestone") }
        var counts: [String: Int] = [:]

        let kept = FeedPipeline.throttleMilestones(rows, counts: &counts, calendar: calendar("UTC"))

        XCTAssertEqual(kept.map(\.id), Array(rows.prefix(3)).map(\.id), "first 3 kept, in order")
    }

    func testThrottleIsPerActor() {
        let rows = (0..<3).map { _ in makeRow(actor: actorA, type: "milestone") }
            + (0..<3).map { _ in makeRow(actor: actorB, type: "milestone") }
        var counts: [String: Int] = [:]

        let kept = FeedPipeline.throttleMilestones(rows, counts: &counts, calendar: calendar("UTC"))

        XCTAssertEqual(kept.count, 6, "3-per-actor caps are independent")
    }

    func testThrottleIgnoresNonMilestoneRows() {
        let rows = (0..<4).map { _ in makeRow(actor: actorA, type: "milestone") }
            + [makeRow(actor: actorA, type: "review"), makeRow(actor: actorA, type: "ranking_add")]
        var counts: [String: Int] = [:]

        let kept = FeedPipeline.throttleMilestones(rows, counts: &counts, calendar: calendar("UTC"))

        XCTAssertEqual(kept.map(\.event_type), ["milestone", "milestone", "milestone", "review", "ranking_add"],
                       "non-milestones pass through and never count against the cap")
    }

    func testThrottleBucketsByLocalCalendarDay() {
        // 06:59Z on Jul 7 is Jul 6 in Los Angeles (UTC-7 in July); 08:00Z is Jul 7.
        // µs-precision created_at included on purpose — timestamp parsing must
        // handle Postgres 6-digit fractions.
        let lateNightLA = ["2026-07-07T06:00:00+00:00",
                           "2026-07-07T06:30:00+00:00",
                           "2026-07-07T06:59:59.999999+00:00"]
        let morningLA = ["2026-07-07T08:00:00+00:00",
                         "2026-07-07T09:00:00+00:00"]
        let rows = (lateNightLA + morningLA).map {
            makeRow(actor: actorA, type: "milestone", createdAt: $0)
        }

        var utcCounts: [String: Int] = [:]
        let utcKept = FeedPipeline.throttleMilestones(rows, counts: &utcCounts, calendar: calendar("UTC"))
        XCTAssertEqual(utcKept.count, 3, "UTC: all five share one day — cap bites")

        var laCounts: [String: Int] = [:]
        let laKept = FeedPipeline.throttleMilestones(rows, counts: &laCounts, calendar: calendar("America/Los_Angeles"))
        XCTAssertEqual(laKept.count, 5, "LA: 3 on local Jul 6 + 2 on local Jul 7 — no bucket exceeds the cap")
    }

    func testThrottleLocalDaySplitInTokyo() {
        // 14:30Z is 23:30 Jul 7 in Tokyo (UTC+9); 15:30Z is 00:30 Jul 8.
        let times = ["2026-07-07T14:30:00+00:00", "2026-07-07T14:40:00+00:00",
                     "2026-07-07T14:50:00+00:00", "2026-07-07T15:30:00+00:00"]
        let rows = times.map { makeRow(actor: actorA, type: "milestone", createdAt: $0) }

        var utcCounts: [String: Int] = [:]
        XCTAssertEqual(FeedPipeline.throttleMilestones(rows, counts: &utcCounts, calendar: calendar("UTC")).count,
                       3, "UTC: one day, fourth dropped")

        var tokyoCounts: [String: Int] = [:]
        XCTAssertEqual(FeedPipeline.throttleMilestones(rows, counts: &tokyoCounts, calendar: calendar("Asia/Tokyo")).count,
                       4, "Tokyo: the 15:30Z row lands on the next local day")
    }

    func testThrottleCountsCarryAcrossPagesWithinASession() {
        let page1 = (0..<2).map { _ in makeRow(actor: actorA, type: "milestone") }
        let page2 = (0..<2).map { _ in makeRow(actor: actorA, type: "milestone") }
        var counts: [String: Int] = [:] // one session = one dict, owned by the caller

        let kept1 = FeedPipeline.throttleMilestones(page1, counts: &counts, calendar: calendar("UTC"))
        let kept2 = FeedPipeline.throttleMilestones(page2, counts: &counts, calendar: calendar("UTC"))

        XCTAssertEqual(kept1.count, 2)
        XCTAssertEqual(kept2.count, 1, "session dict carries: 2 + 1 = cap 3, 4th dropped")

        var fresh: [String: Int] = [:] // new resume-session → counter resets
        XCTAssertEqual(FeedPipeline.throttleMilestones(page2, counts: &fresh, calendar: calendar("UTC")).count, 2)
    }

    func testThrottleCountKeyFormatIsActorPipeLocalDay() {
        var counts: [String: Int] = [:]
        let row = makeRow(actor: actorA, type: "milestone", createdAt: "2026-07-07T12:00:00+00:00")

        _ = FeedPipeline.throttleMilestones([row], counts: &counts, calendar: calendar("UTC"))

        XCTAssertEqual(counts, ["aaaaaaaa-1111-2222-3333-444444444444|2026-07-07": 1],
                       "key = lowercase actor uuid | yyyy-MM-dd in the calendar's zone")
    }

    // MARK: - Score-map key (web `${userId}:${tmdbId}` parity)

    func testScoreKeyLowercasesUUIDToMatchWebDBStrings() {
        // Swift's UUID.uuidString is UPPERCASE; DB/web uuid strings are
        // lowercase. The key must canonicalize or lookups silently miss.
        let key = FeedPipeline.scoreKey(userID: actorA, tmdbID: "603")
        XCTAssertEqual(key, "aaaaaaaa-1111-2222-3333-444444444444:603")
    }

    // MARK: - FeedEventRow wire decode (get_feed_page row shape)

    func testFeedEventRowDecodesRPCRowIncludingMetadataAndBoostedTs() throws {
        let json = """
        {
            "id": "0b0b0b0b-0000-0000-0000-000000000001",
            "actor_id": "aaaaaaaa-1111-2222-3333-444444444444",
            "event_type": "ranking_add",
            "target_user_id": null,
            "media_tmdb_id": "603",
            "media_title": "The Matrix",
            "media_tier": "S",
            "media_poster_url": null,
            "metadata": {"notes": "so good", "watched_with_user_ids": ["bbbbbbbb-5555-6666-7777-888888888888"]},
            "created_at": "2026-07-07T10:00:00.123456+00:00",
            "boosted_ts": "2026-07-07T10:00:00.123456+00:00"
        }
        """.data(using: .utf8)!

        let row = try JSONDecoder().decode(FeedEventRow.self, from: json)

        XCTAssertEqual(row.actor_id, actorA)
        XCTAssertEqual(row.event_type, "ranking_add")
        XCTAssertEqual(row.media_tmdb_id, "603")
        XCTAssertEqual(row.created_at, "2026-07-07T10:00:00.123456+00:00", "timestamps stay Strings — no Date decode")
        XCTAssertEqual(row.boosted_ts, "2026-07-07T10:00:00.123456+00:00")
        XCTAssertEqual(row.metadata?["notes"]?.stringValue, "so good")
        XCTAssertEqual(row.metadata?["watched_with_user_ids"]?.arrayValue?.count, 1)
    }
}
