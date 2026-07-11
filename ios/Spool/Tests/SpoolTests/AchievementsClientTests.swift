import XCTest
@testable import Spool

/// Spec for the C7-iOS achievements client + catalog (Task 1).
///
/// Pins:
///  - the 16-badge catalog is a VERBATIM port of web
///    `components/social/AchievementsView.tsx` `BADGE_CATALOG` (lines 8-32):
///    16 entries, exact keys, exactly one non-grantable (`early_adopter`), the
///    15 grantable keys equal the RPC's grantable set, category ordering + copy,
///  - `EarnedBadge` decodes the `user_achievements` SELECT projection
///    (`badge_key`, `unlocked_at`) with the snake_case → camelCase mapping,
///  - `grant()` is called via `AchievementMilestones.grantAndEmitMilestones()` in a
///    `Task.detached` at each hook site — errors are swallowed there, never thrown
///    to the primary write path (fire-and-forget post-write contract posture).
final class AchievementsClientTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - Catalog parity (literal pin vs web BADGE_CATALOG)

    func testCatalogHas16Entries() {
        XCTAssertEqual(BadgeCatalog.all.count, 16, "web BADGE_CATALOG has 16 badges")
    }

    func testCatalogKeysMatchWebVerbatim() {
        // Exact key list, in web BADGE_CATALOG order (AchievementsView.tsx:10-31).
        let expected = [
            "first_rank", "rank_10", "rank_25", "rank_50", "rank_100",
            "first_review", "review_10",
            "first_follow", "followers_10", "followers_50", "first_list",
            "genre_5", "genre_10", "s_tier_10", "d_tier_5",
            "early_adopter",
        ]
        XCTAssertEqual(BadgeCatalog.all.map(\.key), expected)
    }

    func testExactlyEarlyAdopterIsNonGrantable() {
        let nonGrantable = BadgeCatalog.all.filter { !$0.grantable }.map(\.key)
        XCTAssertEqual(nonGrantable, ["early_adopter"],
                       "only early_adopter has no RPC rule (15 grantable + 1)")
    }

    func testGrantableKeysAreThe15RpcRuleKeys() {
        // The RPC (20260711_achievements_server_grant.sql) grants exactly these
        // 15 keys — everything in BADGE_CATALOG except early_adopter.
        let expected = Set([
            "first_rank", "rank_10", "rank_25", "rank_50", "rank_100",
            "first_review", "review_10",
            "first_follow", "followers_10", "followers_50", "first_list",
            "genre_5", "genre_10", "s_tier_10", "d_tier_5",
        ])
        XCTAssertEqual(Set(BadgeCatalog.grantableKeys), expected)
        XCTAssertEqual(BadgeCatalog.grantableKeys.count, 15)
    }

    func testCatalogCopyMatchesWebForSampledBadges() {
        // Spot-check name/description/icon/category/requirement against the web
        // source so a copy drift is caught (not just the key set).
        let firstRank = BadgeCatalog.byKey["first_rank"]
        XCTAssertEqual(firstRank?.name, "First Pick")
        XCTAssertEqual(firstRank?.description, "Ranked your first movie")
        XCTAssertEqual(firstRank?.icon, "🎬")
        XCTAssertEqual(firstRank?.category, .milestone)
        XCTAssertEqual(firstRank?.requirement, "1 ranking")

        // The em-dash-bearing D-tier copy is ported verbatim (web line 28).
        let dTier = BadgeCatalog.byKey["d_tier_5"]
        XCTAssertEqual(dTier?.description, "Gave 5 movies D-tier — not everything's great")
        XCTAssertEqual(dTier?.category, .taste)

        let earlyAdopter = BadgeCatalog.byKey["early_adopter"]
        XCTAssertEqual(earlyAdopter?.name, "Early Adopter")
        XCTAssertEqual(earlyAdopter?.category, .special)
        XCTAssertEqual(earlyAdopter?.grantable, false)
    }

    func testCategoryOrderAndGroupingMatchWeb() {
        // CATEGORY_STYLES render order (AchievementsView.tsx:66):
        // milestone → social → taste → special.
        XCTAssertEqual(BadgeCategory.allCases, [.milestone, .social, .taste, .special])
        XCTAssertEqual(BadgeCatalog.inCategory(.milestone).count, 7)
        XCTAssertEqual(BadgeCatalog.inCategory(.social).count, 4)
        XCTAssertEqual(BadgeCatalog.inCategory(.taste).count, 4)
        XCTAssertEqual(BadgeCatalog.inCategory(.special).count, 1)
    }

    func testByKeyLookupCoversEveryEntry() {
        XCTAssertEqual(BadgeCatalog.byKey.count, 16)
        for badge in BadgeCatalog.all {
            XCTAssertEqual(BadgeCatalog.byKey[badge.key]?.key, badge.key)
        }
    }

    // MARK: - EarnedBadge decode (user_achievements SELECT projection)

    func testEarnedBadgeDecodesSnakeCaseProjection() throws {
        let json = """
        [
          { "badge_key": "first_rank", "unlocked_at": "2026-07-01T12:00:00Z" },
          { "badge_key": "rank_10",   "unlocked_at": "2026-07-05T08:30:00+00:00" }
        ]
        """.data(using: .utf8)!

        let rows = try decoder.decode([EarnedBadge].self, from: json)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].badgeKey, "first_rank")
        XCTAssertEqual(rows[0].unlockedAt, "2026-07-01T12:00:00Z")
        XCTAssertEqual(rows[1].badgeKey, "rank_10")
        // Raw ISO string preserved verbatim (no Date round-trip).
        XCTAssertEqual(rows[1].unlockedAt, "2026-07-05T08:30:00+00:00")
    }

    func testEarnedBadgeIsIdentifiableByKey() {
        let badge = EarnedBadge(badgeKey: "s_tier_10", unlockedAt: "2026-07-01T00:00:00Z")
        XCTAssertEqual(badge.id, "s_tier_10")
    }

    func testGrantReturnArrayDecodesAsPlainStrings() throws {
        // The RPC returns text[]; supabase-swift decodes it into [String]. Pin
        // that a JSON string array (the wire shape) decodes to the same list
        // grant() returns.
        let json = "[\"first_rank\", \"first_follow\"]".data(using: .utf8)!
        let granted = try decoder.decode([String].self, from: json)
        XCTAssertEqual(granted, ["first_rank", "first_follow"])
    }

    func testGrantThrowsNotConfiguredWithoutClient() async throws {
        // Only meaningful when the test host is unconfigured (the CI default).
        // Guarded so a locally-configured host doesn't spuriously fail on a
        // network call.
        guard !SpoolClient.isConfigured else {
            throw XCTSkip("SpoolClient configured on this host; skipping unconfigured-path assertion")
        }
        do {
            _ = try await AchievementsClient.grant()
            XCTFail("grant() should throw when the client is not configured")
        } catch AchievementsClient.AchievementsError.notConfigured {
            // Expected.
        } catch {
            XCTFail("grant() threw unexpected error: \(error)")
        }
    }
}
