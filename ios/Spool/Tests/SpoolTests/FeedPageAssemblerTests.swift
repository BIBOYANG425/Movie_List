import XCTest
@testable import Spool

/// `FeedPageAssembler` — the contract refill loop, pure-orchestrated over
/// injected IO closures (no network anywhere in this file). Mirrors web's
/// `getFeedCards` loop in `services/feedService.ts` (post-#32):
///  - ≤ `maxRPCPages` raw fetches per `assemblePage` call (web L212-213);
///  - stage order type-filter → mutes → throttle, throttle LAST
///    (web L307-320: eventTypes → mutes → milestone throttle);
///  - throttle counts dict lives for ONE assemblePage call, shared across
///    the refill pages consumed inside it (web L275-280);
///  - cursor advances over EVERY consumed raw row — kept or dropped — and
///    the returned cursor is the last RAW row consumed, never rewound to
///    the last kept card (web L306 `cursor = rowCursor`);
///  - `hasMore` = last raw page row count == pageSize (web L293-294);
///  - reads fail soft: first-page fetchPage throw → empty/hasMore-false;
///    later refill throw → kept-so-far (web L288-292 `break`, exhausted
///    stays false); mutes/profiles/scores throws degrade (web getMutes
///    L619-622 returns [], Promise.all members fail soft in-service).
/// Contract: docs/plans/2026-07-08-c1-ios-feed-ui-plan.md (Global
/// Constraints + Task 2), sourced from the C1-iOS Part-B caller contract in
/// docs/plans/2026-07-07-ios-parity-ledger.md.
final class FeedPageAssemblerTests: XCTestCase {

    private let actorA = UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")!
    private let actorB = UUID(uuidString: "BBBBBBBB-5555-6666-7777-888888888888")!

    private let allTypes = FeedPipeline.defaultEventTypes(explore: false)

    private enum Boom: Error { case boom }

    private func makeRow(
        id: UUID = UUID(),
        actor: UUID,
        type: String = "ranking_add",
        tmdbID: String? = nil,
        createdAt: String = "2026-07-07T12:00:00+00:00",
        boostedTs: String? = nil
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
            // Distinct per-row ordering keys by default so cursor asserts
            // can't pass by collision.
            boosted_ts: boostedTs ?? "2026-07-07T12:00:00.\(String(format: "%06d", abs(id.hashValue % 1_000_000)))+00:00"
        )
    }

    private func makeProfile(id: UUID, username: String,
                             avatarUrl: String? = nil,
                             avatarPath: String? = nil) -> ProfileRow {
        ProfileRow(id: id, username: username, display_name: nil, bio: nil,
                   avatar_url: avatarUrl, avatar_path: avatarPath)
    }

    /// Scripted fetchPage over a fixed page list; records every call's
    /// (mode, cursor, pageSize). A `.failure` page throws.
    private final class PageScript {
        var pages: [Result<[FeedEventRow], Error>]
        private(set) var calls: [(mode: FeedMode, cursor: FeedCursor?, pageSize: Int)] = []

        init(_ pages: [Result<[FeedEventRow], Error>]) { self.pages = pages }
        convenience init(pages: [[FeedEventRow]]) { self.init(pages.map { .success($0) }) }

        func fetch(mode: FeedMode, cursor: FeedCursor?, pageSize: Int) throws -> [FeedEventRow] {
            calls.append((mode, cursor, pageSize))
            guard calls.count <= pages.count else { return [] } // past the script = stream end
            return try pages[calls.count - 1].get()
        }
    }

    private func makeAssembler(
        pageSize: Int = 20,
        maxRPCPages: Int = 10,
        script: PageScript,
        mutes: @escaping () async throws -> (users: Set<UUID>, media: Set<String>) = { ([], []) },
        profiles: @escaping ([UUID]) async throws -> [UUID: ProfileRow] = { _ in [:] },
        scores: @escaping ([(userID: UUID, tmdbID: String)]) async throws -> [String: Double] = { _ in [:] }
    ) -> FeedPageAssembler {
        FeedPageAssembler(
            fetchPage: { mode, cursor, size in try script.fetch(mode: mode, cursor: cursor, pageSize: size) },
            fetchMutes: mutes,
            fetchProfiles: profiles,
            fetchScores: scores,
            config: FeedAssemblerConfig(pageSize: pageSize, maxRPCPages: maxRPCPages)
        )
    }

    // MARK: - Refill loop: fill across raw pages, cursor over every raw row

    func testRefillsAcrossThreeRawPagesUntilFull() async {
        // pageSize 4. Filters (mutes) shorten pages 1 and 2; page 3 tops up.
        let k1 = makeRow(actor: actorA), k2 = makeRow(actor: actorA)
        let k3 = makeRow(actor: actorA), k4 = makeRow(actor: actorA)
        let x1 = makeRow(actor: actorB), x2 = makeRow(actor: actorB)
        let x3 = makeRow(actor: actorB), x4 = makeRow(actor: actorB), x5 = makeRow(actor: actorB)
        let tail1 = makeRow(actor: actorA), tail2 = makeRow(actor: actorA), tail3 = makeRow(actor: actorA)

        let script = PageScript(pages: [
            [k1, x1, k2, x2],          // kept 2; last RAW row is a dropped one
            [x3, x4, x5, k3],          // kept 3
            [k4, tail1, tail2, tail3], // k4 fills the page; tail is NOT consumed
        ])
        let assembler = makeAssembler(pageSize: 4, script: script,
                                      mutes: { ([self.actorB], []) })

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertEqual(result.cards.map(\.id), [k1, k2, k3, k4].map(\.id))
        XCTAssertEqual(script.calls.count, 3)
        XCTAssertTrue(result.hasMore, "last raw page was full-length")
        // Refill cursors advance over dropped rows too:
        XCTAssertNil(script.calls[0].cursor, "first fetch starts from the input cursor")
        XCTAssertEqual(script.calls[1].cursor, FeedPipeline.cursor(fromLastConsumed: x2),
                       "page-2 cursor = page 1's last RAW row (a mute-dropped one)")
        XCTAssertEqual(script.calls[2].cursor, FeedPipeline.cursor(fromLastConsumed: k3))
        // The returned cursor stops at the last CONSUMED row — the row that
        // filled the page — leaving the unconsumed tail for the next call.
        XCTAssertEqual(result.cursor, FeedPipeline.cursor(fromLastConsumed: k4))
    }

    func testPassesModeInputCursorAndPageSizeThrough() async {
        let input = FeedCursor(boostedTs: "2026-07-01T00:00:00.123456+00:00", id: UUID())
        let script = PageScript(pages: [[makeRow(actor: actorA)]])
        let assembler = makeAssembler(pageSize: 7, script: script)

        _ = await assembler.assemblePage(mode: .explore, after: input, allowedTypes: allTypes)

        XCTAssertEqual(script.calls.count, 1)
        XCTAssertEqual(script.calls[0].mode, .explore)
        XCTAssertEqual(script.calls[0].cursor, input)
        XCTAssertEqual(script.calls[0].pageSize, 7)
    }

    // MARK: - hasMore truth table (raw page count == pageSize)

    func testHasMoreFalseOnShortRawPage() async {
        let r1 = makeRow(actor: actorA), r2 = makeRow(actor: actorA)
        let script = PageScript(pages: [[r1, r2]]) // 2 < pageSize 4 → stream end
        let assembler = makeAssembler(pageSize: 4, script: script)

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertEqual(result.cards.map(\.id), [r1.id, r2.id])
        XCTAssertFalse(result.hasMore)
        XCTAssertEqual(script.calls.count, 1, "short page ends the loop — no refill")
        XCTAssertEqual(result.cursor, FeedPipeline.cursor(fromLastConsumed: r2))
    }

    func testHasMoreTrueWhenLastRawPageExactlyFullEvenIfStreamEnds() async {
        // Raw count == pageSize says "maybe more" even when the next fetch
        // would come back empty — web L293-294 judges the CURRENT page only.
        let rows = (0..<4).map { _ in makeRow(actor: actorA) }
        let script = PageScript(pages: [rows])
        let assembler = makeAssembler(pageSize: 4, script: script)

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertEqual(result.cards.count, 4)
        XCTAssertTrue(result.hasMore)
    }

    func testEmptyFirstPageYieldsEmptyResultHasMoreFalseInputCursorEchoed() async {
        var profileCalls = 0
        var scoreCalls = 0
        let script = PageScript(pages: [[]])
        let assembler = makeAssembler(
            pageSize: 4, script: script,
            profiles: { _ in profileCalls += 1; return [:] },
            scores: { _ in scoreCalls += 1; return [:] }
        )

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertTrue(result.cards.isEmpty)
        XCTAssertFalse(result.hasMore)
        XCTAssertNil(result.cursor, "nothing consumed — input cursor (nil) unchanged")
        XCTAssertEqual(profileCalls, 0, "no kept cards → no hydration IO")
        XCTAssertEqual(scoreCalls, 0)
    }

    // MARK: - RPC page cap

    func testStopsAtMaxRPCPagesUnderNarrowFilter() async {
        // Every raw page is full but the type filter keeps nothing: the loop
        // must stop at exactly maxRPCPages fetches (web L212-213/282).
        var pages: [[FeedEventRow]] = []
        for _ in 0..<15 { pages.append((0..<4).map { _ in makeRow(actor: actorA, type: "ranking_add") }) }
        var profileCalls = 0
        let script = PageScript(pages: pages)
        let assembler = makeAssembler(pageSize: 4, maxRPCPages: 10, script: script,
                                      profiles: { _ in profileCalls += 1; return [:] })

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: ["review"])

        XCTAssertEqual(script.calls.count, 10, "hard cap on raw fetches per call")
        XCTAssertTrue(result.cards.isEmpty)
        XCTAssertTrue(result.hasMore, "cap ≠ stream end — the last raw page was full")
        XCTAssertEqual(result.cursor, FeedPipeline.cursor(fromLastConsumed: pages[9].last!),
                       "cursor sits after page 10's last raw row so the next call continues")
        XCTAssertEqual(profileCalls, 0)
    }

    // MARK: - Cursor over dropped rows

    func testMuteDroppedTrailingRowStillAdvancesReturnedCursor() async {
        // The last raw row is dropped by mutes: the returned cursor must be
        // THAT row's, not the last kept card's — otherwise the next call
        // re-fetches and re-drops it forever (web L306: consumed = advanced).
        let k1 = makeRow(actor: actorA), k2 = makeRow(actor: actorA)
        let dropped = makeRow(actor: actorB)
        let script = PageScript(pages: [[k1, k2, dropped]]) // short page
        let assembler = makeAssembler(pageSize: 4, script: script,
                                      mutes: { ([self.actorB], []) })

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertEqual(result.cards.map(\.id), [k1.id, k2.id])
        XCTAssertEqual(result.cursor, FeedPipeline.cursor(fromLastConsumed: dropped))
    }

    func testMediaMuteDropsRowsToo() async {
        let kept = makeRow(actor: actorA, tmdbID: "safe")
        let dropped = makeRow(actor: actorA, tmdbID: "muted-movie")
        let script = PageScript(pages: [[kept, dropped]])
        let assembler = makeAssembler(pageSize: 4, script: script,
                                      mutes: { ([], ["muted-movie"]) })

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertEqual(result.cards.map(\.id), [kept.id])
    }

    // MARK: - Milestone throttle: per-call dict, throttle LAST

    func testThrottleCapSharedAcrossRefillPagesWithinOneCall() async {
        // 4 same-UTC-date milestones on page 1 (cap 3 keeps 3), 4 more on
        // page 2 — ALL dropped because the SAME counts dict carried over.
        let day = "2026-07-07"
        let page1 = (0..<4).map { _ in makeRow(actor: actorA, type: "milestone", createdAt: "\(day)T08:00:00+00:00") }
        let page2 = (0..<4).map { _ in makeRow(actor: actorB, type: "milestone", createdAt: "\(day)T09:00:00+00:00") }
        let script = PageScript(pages: [page1, page2, []])
        let assembler = makeAssembler(pageSize: 4, script: script)

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertEqual(result.cards.map(\.id), page1.prefix(3).map(\.id),
                       "cap 3/day GLOBAL across actors, carried across refills")
        XCTAssertEqual(script.calls.count, 3)
        XCTAssertFalse(result.hasMore)
    }

    func testThrottleCountsResetOnEveryAssemblePageCall() async {
        // Same assembler, two calls: each call gets a fresh dict (web resets
        // per getFeedCards call — carrying it across calls over-throttles).
        let day = "2026-07-07"
        func milestonePage() -> [FeedEventRow] {
            (0..<4).map { _ in makeRow(actor: actorA, type: "milestone", createdAt: "\(day)T08:00:00+00:00") }
        }
        let script = PageScript(pages: [milestonePage(), milestonePage()])
        let assembler = makeAssembler(pageSize: 5, script: script) // 4 < 5 → short → one page per call

        let first = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)
        let second = await assembler.assemblePage(mode: .friends, after: first.cursor, allowedTypes: allTypes)

        XCTAssertEqual(first.cards.count, 3)
        XCTAssertEqual(second.cards.count, 3, "a carried-over dict would keep 0 here")
    }

    func testThrottleRunsLastSoMutedMilestonesNeverConsumeBudget() async {
        // Stage order type-filter → mutes → throttle: a milestone dropped by
        // mutes must not eat the daily cap. If the throttle ran first, the
        // muted row would burn budget and only 2 of the 4 clean ones survive.
        let day = "2026-07-07"
        let mutedMilestone = makeRow(actor: actorB, type: "milestone", createdAt: "\(day)T07:00:00+00:00")
        let clean = (0..<4).map { _ in makeRow(actor: actorA, type: "milestone", createdAt: "\(day)T08:00:00+00:00") }
        let script = PageScript(pages: [[mutedMilestone] + clean])
        let assembler = makeAssembler(pageSize: 20, script: script,
                                      mutes: { ([self.actorB], []) })

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertEqual(result.cards.map(\.id), clean.prefix(3).map(\.id))
    }

    // MARK: - Fetch failures

    func testFirstPageFetchThrowYieldsEmptyResultHasMoreFalse() async {
        let input = FeedCursor(boostedTs: "2026-07-01T00:00:00+00:00", id: UUID())
        var profileCalls = 0
        let script = PageScript([.failure(Boom.boom)])
        let assembler = makeAssembler(pageSize: 4, script: script,
                                      profiles: { _ in profileCalls += 1; return [:] })

        let result = await assembler.assemblePage(mode: .friends, after: input, allowedTypes: allTypes)

        XCTAssertTrue(result.cards.isEmpty)
        XCTAssertFalse(result.hasMore)
        XCTAssertEqual(result.cursor, input, "nothing consumed — input cursor echoed back")
        XCTAssertEqual(profileCalls, 0)
    }

    func testLaterRefillThrowReturnsKeptSoFar() async {
        // Page 1 is full but filters leave 3 < pageSize; the refill fetch
        // throws. Keep what we have; the error is NOT end-of-stream, so
        // hasMore stays true (web L288-292 breaks without exhausted=true).
        let k1 = makeRow(actor: actorA), k2 = makeRow(actor: actorA)
        let x1 = makeRow(actor: actorB)
        let k3 = makeRow(actor: actorA)
        let script = PageScript([.success([k1, k2, x1, k3]), .failure(Boom.boom)])
        let assembler = makeAssembler(
            pageSize: 4, script: script,
            mutes: { ([self.actorB], []) },
            profiles: { ids in [self.actorA: self.makeProfile(id: self.actorA, username: "amy")] }
        )

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertEqual(result.cards.map(\.id), [k1.id, k2.id, k3.id])
        XCTAssertTrue(result.hasMore)
        XCTAssertEqual(result.cursor, FeedPipeline.cursor(fromLastConsumed: k3))
        XCTAssertEqual(result.cards.map(\.actorUsername), ["amy", "amy", "amy"],
                       "kept-so-far cards still get hydrated")
    }

    func testMutesFetchThrowDegradesToNoMutes() async {
        // Web getMutes fails soft to [] (feedService.ts L619-622): a mutes
        // read failure must not blank the feed — rows just go unfiltered.
        let r1 = makeRow(actor: actorA), r2 = makeRow(actor: actorB)
        var muteCalls = 0
        let script = PageScript(pages: [[r1, r2]])
        let assembler = makeAssembler(pageSize: 4, script: script,
                                      mutes: { muteCalls += 1; throw Boom.boom })

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertEqual(result.cards.map(\.id), [r1.id, r2.id])
        XCTAssertEqual(muteCalls, 1, "mutes are fetched exactly once per assemblePage call")
    }

    // MARK: - Profile hydration

    func testProfileHydrationFillsUsernameAndAvatarViaFeedCardsChain() async {
        let rowA = makeRow(actor: actorA)
        let rowB = makeRow(actor: actorB)
        let rowA2 = makeRow(actor: actorA)
        var requestedIDs: [[UUID]] = []
        let script = PageScript(pages: [[rowA, rowB, rowA2]])
        let assembler = makeAssembler(
            pageSize: 4, script: script,
            profiles: { ids in
                requestedIDs.append(ids)
                return [
                    self.actorA: self.makeProfile(id: self.actorA, username: "amy",
                                                  avatarUrl: "https://cdn.example/amy.png"),
                    self.actorB: self.makeProfile(id: self.actorB, username: "ben"),
                ]
            }
        )

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertEqual(result.cards.map(\.actorUsername), ["amy", "ben", "amy"])
        XCTAssertEqual(result.cards[0].actorAvatarURL, "https://cdn.example/amy.png")
        // Chain output, not a hand-rolled URL: ben has no avatar fields, so
        // the assembler must produce exactly what FeedCards.avatarURL does.
        XCTAssertEqual(result.cards[1].actorAvatarURL,
                       FeedCards.avatarURL(avatarUrl: nil, avatarPath: nil, username: "ben"))
        XCTAssertEqual(requestedIDs.count, 1, "one batched profile fetch per call")
        XCTAssertEqual(requestedIDs[0], [actorA, actorB], "unique actor ids, first-seen order")
    }

    func testProfileFetchThrowLeavesUsernameAndAvatarNil() async {
        // Documented choice: hydration FAILURE leaves actorUsername nil AND
        // actorAvatarURL nil — no dicebear-for-unknown-user. The dicebear
        // step is a per-profile fallback for a FETCHED profile without
        // avatar fields, not a mask for a failed read. Views render their
        // own placeholder for nil. (Web renders 'unknown' + undefined
        // avatar here; iOS keeps both nil so the UI can tell "profile has
        // no avatar" from "profile never loaded".)
        let row = makeRow(actor: actorA)
        let script = PageScript(pages: [[row]])
        let assembler = makeAssembler(pageSize: 4, script: script,
                                      profiles: { _ in throw Boom.boom })

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertEqual(result.cards.count, 1)
        XCTAssertNil(result.cards[0].actorUsername)
        XCTAssertNil(result.cards[0].actorAvatarURL, "must NOT fall back to a dicebear URL")
    }

    func testActorMissingFromProfileMapStaysNilNil() async {
        // A successful fetch that simply lacks the actor (deleted account)
        // degrades identically to a failed fetch for that card.
        let rowA = makeRow(actor: actorA), rowB = makeRow(actor: actorB)
        let script = PageScript(pages: [[rowA, rowB]])
        let assembler = makeAssembler(
            pageSize: 4, script: script,
            profiles: { _ in [self.actorA: self.makeProfile(id: self.actorA, username: "amy")] }
        )

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertEqual(result.cards[0].actorUsername, "amy")
        XCTAssertNil(result.cards[1].actorUsername)
        XCTAssertNil(result.cards[1].actorAvatarURL)
    }

    // MARK: - Score hydration

    func testScoreHydrationLooksUpLowercaseUidColonTmdbKey() async {
        let ranking = makeRow(actor: actorA, type: "ranking_add", tmdbID: "m1")
        let review = makeRow(actor: actorB, type: "review", tmdbID: "m2")
        let list = makeRow(actor: actorA, type: "list_create", tmdbID: "m3")
        let milestone = makeRow(actor: actorA, type: "milestone")
        var requestedPairs: [[(userID: UUID, tmdbID: String)]] = []
        let script = PageScript(pages: [[ranking, review, list, milestone]])
        let assembler = makeAssembler(
            pageSize: 4, script: script,
            scores: { pairs in
                requestedPairs.append(pairs)
                // Literal lowercase keys — the exact wire format. Swift's
                // UUID.uuidString uppercases; a non-canonicalized lookup
                // would miss every one of these.
                return [
                    "aaaaaaaa-1111-2222-3333-444444444444:m1": 9.4,
                    "bbbbbbbb-5555-6666-7777-888888888888:m2": 7.1,
                    "aaaaaaaa-1111-2222-3333-444444444444:m3": 5.0, // never requested, never applied
                ]
            }
        )

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertEqual(result.cards[0].score, 9.4)
        XCTAssertEqual(result.cards[1].score, 7.1)
        XCTAssertNil(result.cards[2].score, "list cards never carry a score")
        XCTAssertNil(result.cards[3].score)
        XCTAssertEqual(requestedPairs.count, 1)
        XCTAssertEqual(requestedPairs[0].map(\.tmdbID), ["m1", "m2"],
                       "collection rule: ranking/review with tmdb id only")
    }

    func testScoresFetchThrowLeavesScoresNilButProfilesStillHydrate() async {
        let ranking = makeRow(actor: actorA, type: "ranking_add", tmdbID: "m1")
        let script = PageScript(pages: [[ranking]])
        let assembler = makeAssembler(
            pageSize: 4, script: script,
            profiles: { _ in [self.actorA: self.makeProfile(id: self.actorA, username: "amy")] },
            scores: { _ in throw Boom.boom }
        )

        let result = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertEqual(result.cards.count, 1)
        XCTAssertNil(result.cards[0].score, "a missing score hides the badge, never errors")
        XCTAssertEqual(result.cards[0].actorUsername, "amy", "degradations are independent")
    }

    func testNoEligibleScorePairsSkipsTheScoresFetch() async {
        let list = makeRow(actor: actorA, type: "list_create", tmdbID: "m3")
        let milestone = makeRow(actor: actorA, type: "milestone")
        var scoreCalls = 0
        let script = PageScript(pages: [[list, milestone]])
        let assembler = makeAssembler(pageSize: 4, script: script,
                                      scores: { _ in scoreCalls += 1; return [:] })

        _ = await assembler.assemblePage(mode: .friends, after: nil, allowedTypes: allTypes)

        XCTAssertEqual(scoreCalls, 0, "no pairs → no RPC")
    }
}
