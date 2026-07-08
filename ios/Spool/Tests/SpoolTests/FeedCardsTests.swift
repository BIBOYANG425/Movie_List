import XCTest
import Supabase
@testable import Spool

/// Pure FeedCard layer, mirroring web's `services/feedService.ts` card
/// mapping (post-#32) and `utils/relativeDate.ts`:
///  - kind coercion: `toFeedCardType` (feedService.ts L105–111) with the
///    unknown-type fallback `?? 'ranking'` (feedService.ts L375);
///  - tier guard: `toTier` — S–D whitelist, anything else nil
///    (feedService.ts L112–115);
///  - avatar chain: `avatar_url` → storage public URL from `avatar_path` →
///    dicebear (feedService.ts L57–59; storage URL string format per
///    notificationService.ts L52:
///    `${SUPABASE_URL}/storage/v1/object/public/avatars/${avatar_path}`);
///  - score-pair rule: ranking/review cards with `media_tmdb_id` only
///    (feedService.ts L358–361);
///  - relative time buckets: utils/relativeDate.ts L13–21, used by every
///    web feed card (components/feed/FeedRankingCard.tsx L9, L75).
/// Source of truth: docs/plans/2026-07-08-c1-ios-feed-ui-plan.md Task 1.
final class FeedCardsTests: XCTestCase {

    private let actorA = UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")!
    private let actorB = UUID(uuidString: "BBBBBBBB-5555-6666-7777-888888888888")!

    private func makeRow(
        id: UUID = UUID(),
        actor: UUID = UUID(),
        type: String = "ranking_add",
        tmdbID: String? = nil,
        title: String? = nil,
        tier: String? = nil,
        posterURL: String? = nil,
        metadata: JSONObject? = nil,
        createdAt: String = "2026-07-07T12:00:00+00:00",
        boostedTs: String = "2026-07-07T12:00:00+00:00"
    ) -> FeedEventRow {
        FeedEventRow(
            id: id,
            actor_id: actor,
            event_type: type,
            media_tmdb_id: tmdbID,
            media_title: title,
            media_tier: tier,
            media_poster_url: posterURL,
            metadata: metadata,
            created_at: createdAt,
            boosted_ts: boostedTs
        )
    }

    private func makeCard(kind: FeedCardKind = .ranking,
                          actor: UUID = UUID(),
                          tmdbID: String? = nil) -> FeedCard {
        var card = FeedCards.card(from: makeRow(actor: actor, tmdbID: tmdbID))
        // Force the kind independently of event-type coercion so the
        // score-pair truth table isolates the kind axis.
        card = FeedCard(
            id: card.id, kind: kind, actorID: card.actorID,
            eventType: card.eventType, mediaTmdbID: card.mediaTmdbID,
            title: card.title, tier: card.tier, posterURL: card.posterURL,
            metadata: card.metadata, createdAt: card.createdAt,
            boostedTs: card.boostedTs
        )
        return card
    }

    // MARK: - Kind coercion (web toFeedCardType, feedService.ts L105–111 + L375)

    func testKindCoercionTable() {
        // The 6 event types the system emits (FeedPipeline.defaultEventTypes
        // + ranking_remove) plus a garbage unknown. Web maps via
        // toFeedCardType (feedService.ts L105–111) and coerces null to
        // 'ranking' at the card-build site (feedService.ts L375:
        // `toFeedCardType(row.event_type) ?? 'ranking'`).
        let expectations: [(String, FeedCardKind)] = [
            ("ranking_add", .ranking),
            ("ranking_move", .ranking),
            ("review", .review),
            ("milestone", .milestone),
            ("list_create", .list),
            ("ranking_remove", .ranking),   // unknown to the map → coerced
            ("journal_entry_v9", .ranking), // future/unknown type → coerced
        ]
        for (eventType, expected) in expectations {
            let card = FeedCards.card(from: makeRow(type: eventType))
            XCTAssertEqual(card.kind, expected,
                           "\(eventType) must map to .\(expected.rawValue)")
        }
    }

    func testCardMappingCopiesRowFieldsVerbatimAndLeavesHydrationNil() {
        let id = UUID()
        let meta: JSONObject = ["containsSpoilers": .bool(true), "notes": .string("so good")]
        let row = makeRow(
            id: id, actor: actorA, type: "review", tmdbID: "603",
            title: "The Matrix", tier: "S", posterURL: "https://img.example/p.jpg",
            metadata: meta,
            createdAt: "2026-07-07T09:30:00.123456+00:00",
            boostedTs: "2026-07-07T11:30:00.123456+00:00"
        )
        let card = FeedCards.card(from: row)
        XCTAssertEqual(card.id, id)
        XCTAssertEqual(card.kind, .review)
        XCTAssertEqual(card.actorID, actorA)
        XCTAssertEqual(card.eventType, "review", "raw event_type preserved for menus/analytics")
        XCTAssertEqual(card.mediaTmdbID, "603")
        XCTAssertEqual(card.title, "The Matrix")
        XCTAssertEqual(card.tier, .S)
        XCTAssertEqual(card.posterURL, "https://img.example/p.jpg")
        XCTAssertEqual(card.metadata, meta)
        XCTAssertEqual(card.createdAt, "2026-07-07T09:30:00.123456+00:00",
                       "timestamptz stays a verbatim String (FeedPipeline cursor rule)")
        XCTAssertEqual(card.boostedTs, "2026-07-07T11:30:00.123456+00:00")
        XCTAssertNil(card.actorUsername, "hydration is the assembler's job")
        XCTAssertNil(card.actorAvatarURL)
        XCTAssertNil(card.score)
    }

    // MARK: - Tier guard (web toTier, feedService.ts L112–115)

    func testTierGuardMapsSThroughDAndRejectsEverythingElse() {
        // Web: `if (value && ['S','A','B','C','D'].includes(value)) return value`
        // (feedService.ts L112–115) — exact, case-sensitive membership.
        let valid: [(String, Tier)] = [("S", .S), ("A", .A), ("B", .B), ("C", .C), ("D", .D)]
        for (raw, tier) in valid {
            XCTAssertEqual(FeedCards.card(from: makeRow(tier: raw)).tier, tier)
        }
        for raw in ["X", "", "s", "F", "SS", " S"] {
            XCTAssertNil(FeedCards.card(from: makeRow(tier: raw)).tier,
                         "'\(raw)' is outside S–D and must guard to nil, not crash")
        }
        XCTAssertNil(FeedCards.card(from: makeRow(tier: nil)).tier)
    }

    // MARK: - Avatar chain (feedService.ts L57–59; notificationService.ts L52)

    // Web chain (feedService.ts L57–59):
    //   avatarUrl: row.avatar_url ?? (row.avatar_path
    //     ? supabase.storage.from('avatars').getPublicUrl(row.avatar_path).data.publicUrl
    //     : `https://api.dicebear.com/8.x/thumbs/svg?seed=${encodeURIComponent(row.username)}`)
    // getPublicUrl renders `${SUPABASE_URL}/storage/v1/object/public/avatars/<path>`
    // — the exact string web also hand-builds in notificationService.ts L52.
    // No Swift builder exists yet (grep `avatar_path` in Sources: raw fields
    // only; NotificationRepository L101 explicitly leaves URL-building to
    // the UI layer), so this mirrors the web builder.
    // iOS hardening per plan Task 1: step 1 requires a NON-EMPTY url
    // (whitespace-only falls through), unlike web's nullish `??`.

    private let base = "https://abc.supabase.co"

    func testAvatarChainStep1UsesNonEmptyAvatarUrl() {
        XCTAssertEqual(
            FeedCards.avatarURL(avatarUrl: "https://cdn.example/me.png",
                                avatarPath: "u/1.png", username: "bob",
                                supabaseURL: base),
            "https://cdn.example/me.png"
        )
        // Leading/trailing whitespace is trimmed, not treated as content.
        XCTAssertEqual(
            FeedCards.avatarURL(avatarUrl: "  https://cdn.example/me.png ",
                                avatarPath: nil, username: "bob",
                                supabaseURL: base),
            "https://cdn.example/me.png"
        )
    }

    func testAvatarChainStep2BuildsStoragePublicURLFromPath() {
        // Format per notificationService.ts L52:
        // `${SUPABASE_URL}/storage/v1/object/public/avatars/${avatar_path}`
        XCTAssertEqual(
            FeedCards.avatarURL(avatarUrl: nil, avatarPath: "u/1.png",
                                username: "bob", supabaseURL: base),
            "https://abc.supabase.co/storage/v1/object/public/avatars/u/1.png"
        )
        // Whitespace-only avatar_url falls through to the path step.
        XCTAssertEqual(
            FeedCards.avatarURL(avatarUrl: "   ", avatarPath: "u/1.png",
                                username: "bob", supabaseURL: base),
            "https://abc.supabase.co/storage/v1/object/public/avatars/u/1.png"
        )
        // Trailing slash on the configured base must not double up.
        XCTAssertEqual(
            FeedCards.avatarURL(avatarUrl: nil, avatarPath: "u/1.png",
                                username: "bob", supabaseURL: base + "/"),
            "https://abc.supabase.co/storage/v1/object/public/avatars/u/1.png"
        )
    }

    func testAvatarChainStep3DicebearMirrorsWebFormat() {
        // Exact web format (feedService.ts L59), NOT the 7.x/initials/png
        // guess in the plan prose — the plan's own instruction is "verify
        // the exact web format in services/feedService.ts and mirror".
        XCTAssertEqual(
            FeedCards.avatarURL(avatarUrl: nil, avatarPath: nil,
                                username: "bob", supabaseURL: base),
            "https://api.dicebear.com/8.x/thumbs/svg?seed=bob"
        )
        // Seed is encodeURIComponent'd (feedService.ts L59): space → %20,
        // + → %2B, @ → %40; JS-unreserved marks -_.!~*'() stay literal.
        XCTAssertEqual(
            FeedCards.avatarURL(avatarUrl: nil, avatarPath: nil,
                                username: "bob smith+1@x", supabaseURL: base),
            "https://api.dicebear.com/8.x/thumbs/svg?seed=bob%20smith%2B1%40x"
        )
        XCTAssertEqual(
            FeedCards.avatarURL(avatarUrl: nil, avatarPath: nil,
                                username: "a-_.!~*'()z", supabaseURL: base),
            "https://api.dicebear.com/8.x/thumbs/svg?seed=a-_.!~*'()z"
        )
        // nil username → empty seed (still a loadable dicebear URL).
        XCTAssertEqual(
            FeedCards.avatarURL(avatarUrl: nil, avatarPath: nil,
                                username: nil, supabaseURL: base),
            "https://api.dicebear.com/8.x/thumbs/svg?seed="
        )
    }

    func testAvatarChainWithoutConfiguredBaseSkipsStorageStep() {
        // Fixture/preview mode: no SUPABASE_URL → the path step can't build
        // a real URL, so the chain degrades to dicebear instead of emitting
        // a relative garbage string.
        XCTAssertEqual(
            FeedCards.avatarURL(avatarUrl: nil, avatarPath: "u/1.png",
                                username: "bob", supabaseURL: nil),
            "https://api.dicebear.com/8.x/thumbs/svg?seed=bob"
        )
        // Whitespace-only path is no path.
        XCTAssertEqual(
            FeedCards.avatarURL(avatarUrl: nil, avatarPath: "  ",
                                username: "bob", supabaseURL: base),
            "https://api.dicebear.com/8.x/thumbs/svg?seed=bob"
        )
    }

    // MARK: - Score pairs (feedService.ts L358–361)

    // Web collects `{ userId: row.actor_id, tmdbId: row.media_tmdb_id }`
    // only when `(ct === 'ranking' || ct === 'review') && row.media_tmdb_id`
    // (feedService.ts L358–361). Per plan Task 1 the iOS rule is keyed on
    // the coerced kind (kind × mediaTmdbID truth table); the only delta vs
    // web is that a coerced-unknown ranking card with a tmdb id yields one
    // extra RPC pair, which the security-invoker RPC answers with no row —
    // score stays nil either way. Dedupe is NOT this layer's job: web
    // dedupes inside getRankingScores (feedService.ts L82–90) and iOS
    // inside FeedRepository.rankingScores.
    func testScorePairsKindByTmdbIDTruthTable() {
        let rankingWith = makeCard(kind: .ranking, actor: actorA, tmdbID: "603")
        let reviewWith = makeCard(kind: .review, actor: actorB, tmdbID: "604")
        let rankingWithout = makeCard(kind: .ranking, actor: actorA, tmdbID: nil)
        let reviewWithout = makeCard(kind: .review, actor: actorB, tmdbID: nil)
        let listWith = makeCard(kind: .list, actor: actorA, tmdbID: "605")
        let milestoneWith = makeCard(kind: .milestone, actor: actorB, tmdbID: "606")

        let pairs = FeedCards.scorePairs(for: [
            rankingWith, reviewWith, rankingWithout,
            reviewWithout, listWith, milestoneWith,
        ])

        XCTAssertEqual(pairs.count, 2, "only ranking/review with a tmdb id qualify")
        XCTAssertEqual(pairs[0].userID, actorA)
        XCTAssertEqual(pairs[0].tmdbID, "603")
        XCTAssertEqual(pairs[1].userID, actorB)
        XCTAssertEqual(pairs[1].tmdbID, "604")
    }

    func testScorePairsPreservesOrderAndDuplicates() {
        let a = makeCard(kind: .ranking, actor: actorA, tmdbID: "603")
        let b = makeCard(kind: .ranking, actor: actorA, tmdbID: "603")
        let pairs = FeedCards.scorePairs(for: [a, b])
        XCTAssertEqual(pairs.count, 2, "dedupe lives in the repository, not here")
    }

    func testScorePairsEmptyInput() {
        XCTAssertTrue(FeedCards.scorePairs(for: []).isEmpty)
    }

    // MARK: - Relative time (utils/relativeDate.ts L13–21)

    // Web buckets (utils/relativeDate.ts L13–21, rendered by every feed
    // card via relativeDate — components/feed/FeedRankingCard.tsx L9, L75):
    //   mins = floor(diff/60000); mins < 1        → 'just now'   (en.ts L86)
    //   mins < 60                                  → '{n}m ago'   (en.ts L87)
    //   hrs = floor(mins/60); hrs < 24             → '{n}h ago'   (en.ts L88)
    //   days = floor(hrs/24); days < 7             → '{n}d ago'   (en.ts L89)
    //   else → toLocaleDateString(month:'short', day:'numeric')
    // iOS renders the compact stub form ('now', '2m', '2h', '3d', 'jun 28')
    // per plan Task 1 + the spec's `ADMIT ONE · @HANDLE · 2H` header — the
    // BUCKET BOUNDARIES are the web-exact part.
    // Parse failure mirrors web's catch (relativeDate.ts L22–23):
    // `return iso || t('feed.justNow')` — echo the raw string; empty → now.

    private let utc = TimeZone(identifier: "UTC")!

    private func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else {
            XCTFail("bad test fixture: \(iso)")
            return Date(timeIntervalSince1970: 0)
        }
        return d
    }

    func testRelativeTimeBucketBoundaries() {
        let now = at("2026-07-06T12:00:00Z")
        let cases: [(String, String)] = [
            ("2026-07-06T12:00:00+00:00", "now"),    // 0s → mins 0 < 1
            ("2026-07-06T11:59:01+00:00", "now"),    // 59s → mins 0
            ("2026-07-06T11:59:00+00:00", "1m"),     // 60s → mins 1
            ("2026-07-06T11:01:00+00:00", "59m"),    // 59min → last minute bucket
            ("2026-07-06T11:00:00+00:00", "1h"),     // 60min → hrs 1
            ("2026-07-05T12:00:01+00:00", "23h"),    // 23:59:59 → hrs 23
            ("2026-07-05T12:00:00+00:00", "1d"),     // 24h → days 1
            ("2026-06-29T12:00:01+00:00", "6d"),     // 6d 23:59:59 → days 6
        ]
        for (createdAt, expected) in cases {
            XCTAssertEqual(
                FeedCards.relativeTime(from: createdAt, now: now, timeZone: utc),
                expected, "createdAt \(createdAt)"
            )
        }
    }

    func testRelativeTimeSevenDaysCutsOverToShortDate() {
        // Web: days >= 7 → toLocaleDateString(month:'short', day:'numeric')
        // (relativeDate.ts L21). iOS renders it lowercase-mono per app copy
        // voice ('jun 28'), in the viewer's time zone like web (UTC here
        // for determinism).
        let now = at("2026-07-06T12:00:00Z")
        XCTAssertEqual(
            FeedCards.relativeTime(from: "2026-06-29T12:00:00+00:00",
                                   now: now, timeZone: utc),
            "jun 29", "exactly 7 days → date form"
        )
        XCTAssertEqual(
            FeedCards.relativeTime(from: "2026-06-28T08:00:00+00:00",
                                   now: now, timeZone: utc),
            "jun 28"
        )
    }

    func testRelativeTimeAcceptsPostgresMicrosecondPrecision() {
        // get_feed_page timestamps carry Postgres µs precision
        // (FeedPipeline cursor doc); parsing must not choke on 6 fraction
        // digits nor require them.
        let now = at("2026-07-06T12:00:00Z")
        // 1h 59m 59.876544s — web's Math.floor chain gives hrs 1, so the
        // fractional part must both parse AND floor like web.
        XCTAssertEqual(
            FeedCards.relativeTime(from: "2026-07-06T10:00:00.123456+00:00",
                                   now: now, timeZone: utc),
            "1h"
        )
        XCTAssertEqual(
            FeedCards.relativeTime(from: "2026-07-06T10:00:00Z",
                                   now: now, timeZone: utc),
            "2h"
        )
    }

    func testRelativeTimeFutureTimestampClampsToNow() {
        // Web: negative diff → floor gives mins < 1 → 'just now'.
        let now = at("2026-07-06T12:00:00Z")
        XCTAssertEqual(
            FeedCards.relativeTime(from: "2026-07-06T12:05:00+00:00",
                                   now: now, timeZone: utc),
            "now"
        )
    }

    func testRelativeTimeUnparseableEchoesRawAndEmptyIsNow() {
        // Mirrors web's catch (relativeDate.ts L22–23): return iso || justNow.
        let now = at("2026-07-06T12:00:00Z")
        XCTAssertEqual(
            FeedCards.relativeTime(from: "not-a-date", now: now, timeZone: utc),
            "not-a-date"
        )
        XCTAssertEqual(
            FeedCards.relativeTime(from: "", now: now, timeZone: utc),
            "now"
        )
    }

    func testRelativeTimePublicOverloadUsesCurrentZone() {
        // The public 2-arg form (plan's exact signature) delegates to the
        // seam with TimeZone.current; sub-7-day buckets are zone-agnostic.
        let now = at("2026-07-06T12:00:00Z")
        XCTAssertEqual(
            FeedCards.relativeTime(from: "2026-07-06T09:00:00+00:00", now: now),
            "3h"
        )
    }
}
