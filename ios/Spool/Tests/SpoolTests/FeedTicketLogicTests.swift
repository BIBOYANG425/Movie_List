import XCTest
import Supabase
@testable import Spool

/// Pure presentation helpers behind `FeedTicket` — the parts that can diverge
/// from web live here (tested), the SwiftUI shell stays a thin renderer.
///
/// Web parity anchors (verified against main):
///  - stamp score format: `card.mediaScore.toFixed(1)`
///    (components/feed/FeedRankingCard.tsx L92, FeedReviewCard.tsx L98) —
///    one decimal, trailing zero KEPT (`9.0`, not `9`). We mirror toFixed(1).
///  - review body / spoilers metadata keys: `reviewBody`, `containsSpoilers`
///    (services/feedService.ts L409–411).
///  - list metadata keys: `listTitle`, `listItemCount` (feedService.ts L417–420);
///    count row wording `{count} movies` — ALWAYS plural, row hidden when the
///    count is absent (FeedListCard.tsx L92–94).
///  - milestone metadata keys: `badgeIcon`, `milestoneDescription`
///    (feedService.ts L413–415).
///  - ranking notes: `metadata["notes"]` per plan Task 3 (governs; the web
///    ranking card carries it in metadata even though its DOM doesn't surface it).
///  - header line: `ADMIT ONE · @HANDLE · <relativeTime>` mono caps, spec §1;
///    missing username collapses the handle segment (`ADMIT ONE · 2H`).
final class FeedTicketLogicTests: XCTestCase {

    // MARK: variant selection

    func testVariantMapsEachKind() {
        XCTAssertEqual(FeedTicketPresenter.variant(for: .ranking), .ranking)
        XCTAssertEqual(FeedTicketPresenter.variant(for: .review), .review)
        XCTAssertEqual(FeedTicketPresenter.variant(for: .list), .list)
        XCTAssertEqual(FeedTicketPresenter.variant(for: .milestone), .milestone)
    }

    // MARK: stamp text — score composition + fallback

    func testStampTextWithScoreOneDecimal() {
        XCTAssertEqual(FeedTicketPresenter.stampText(tier: .S, score: 9.4), "S · 9.4")
    }

    func testStampTextKeepsTrailingZeroLikeToFixed1() {
        // Web toFixed(1) renders 9.0, not 9 — mirror it.
        XCTAssertEqual(FeedTicketPresenter.stampText(tier: .A, score: 9.0), "A · 9.0")
    }

    func testStampTextRoundsToOneDecimal() {
        // toFixed(1) rounds: 8.75 → "8.8", 8.74 → "8.7".
        XCTAssertEqual(FeedTicketPresenter.stampText(tier: .B, score: 8.75), "B · 8.8")
        XCTAssertEqual(FeedTicketPresenter.stampText(tier: .B, score: 8.74), "B · 8.7")
    }

    func testStampTextNoScoreIsTierOnly() {
        XCTAssertEqual(FeedTicketPresenter.stampText(tier: .S, score: nil), "S")
    }

    // MARK: spoiler flag

    func testSpoilerFlagTrue() {
        let meta: JSONObject = ["containsSpoilers": .bool(true)]
        XCTAssertTrue(FeedTicketPresenter.spoilerFlag(from: meta))
    }

    func testSpoilerFlagFalseWhenAbsentOrFalseOrNil() {
        XCTAssertFalse(FeedTicketPresenter.spoilerFlag(from: nil))
        XCTAssertFalse(FeedTicketPresenter.spoilerFlag(from: ["containsSpoilers": .bool(false)]))
        XCTAssertFalse(FeedTicketPresenter.spoilerFlag(from: ["reviewBody": .string("x")]))
    }

    func testSpoilerFlagWrongTypedValueIsFalseNoCrash() {
        // A string-typed "true" (or a 1) is NOT a spoiler flag — strict bool
        // only, no shield, no crash.
        XCTAssertFalse(FeedTicketPresenter.spoilerFlag(from: ["containsSpoilers": .string("true")]))
        XCTAssertFalse(FeedTicketPresenter.spoilerFlag(from: ["containsSpoilers": .integer(1)]))
    }

    // MARK: notes line (ranking)

    func testNotesLinePresent() {
        XCTAssertEqual(FeedTicketPresenter.notesLine(from: ["notes": .string("cried on the 6 train")]),
                       "cried on the 6 train")
    }

    func testNotesLineTrimsAndDropsEmpty() {
        XCTAssertNil(FeedTicketPresenter.notesLine(from: ["notes": .string("   ")]))
        XCTAssertNil(FeedTicketPresenter.notesLine(from: nil))
        XCTAssertNil(FeedTicketPresenter.notesLine(from: ["other": .string("x")]))
        XCTAssertEqual(FeedTicketPresenter.notesLine(from: ["notes": .string("  hi  ")]), "hi")
    }

    // MARK: review body

    func testReviewBodyPresentAndTrimmed() {
        XCTAssertEqual(FeedTicketPresenter.reviewBody(from: ["reviewBody": .string("  loved it  ")]),
                       "loved it")
    }

    func testReviewBodyMissingIsNil() {
        XCTAssertNil(FeedTicketPresenter.reviewBody(from: nil))
        XCTAssertNil(FeedTicketPresenter.reviewBody(from: ["reviewBody": .string("  ")]))
        XCTAssertNil(FeedTicketPresenter.reviewBody(from: ["notes": .string("x")]))
    }

    // MARK: list summary

    func testListSummaryTitleAndCount() {
        let meta: JSONObject = ["listTitle": .string("summer watchlist"), "listItemCount": .integer(7)]
        let s = FeedTicketPresenter.listSummary(from: meta)
        XCTAssertEqual(s.title, "summer watchlist")
        XCTAssertEqual(s.count, 7)
    }

    func testListSummaryDefaultsTitleAndNilCount() {
        // Missing title → fallback "untitled list"; missing count → nil (the
        // view hides the row, like web's `card.listItemCount != null &&` gate,
        // FeedListCard.tsx L92).
        let s = FeedTicketPresenter.listSummary(from: nil)
        XCTAssertEqual(s.title, "untitled list")
        XCTAssertNil(s.count)
    }

    func testListSummaryCountAcceptsDoubleEncodedInt() {
        // PostgREST can hand a whole number back as a JSON double; coerce it.
        let s = FeedTicketPresenter.listSummary(from: ["listItemCount": .double(4)])
        XCTAssertEqual(s.count, 4)
    }

    func testListSummaryMalformedCountIsNilNotCrash() {
        // Int(exactly:) guards — out-of-range, NaN, wrong-typed, and
        // non-integral doubles all degrade to nil (row hidden), never trap.
        XCTAssertNil(FeedTicketPresenter.listSummary(from: ["listItemCount": .double(1e300)]).count)
        XCTAssertNil(FeedTicketPresenter.listSummary(from: ["listItemCount": .double(.nan)]).count)
        XCTAssertNil(FeedTicketPresenter.listSummary(from: ["listItemCount": .string("7")]).count)
        XCTAssertNil(FeedTicketPresenter.listSummary(from: ["listItemCount": .double(4.5)]).count)
    }

    func testListCountLineMirrorsWebWording() {
        // Web: `{card.listItemCount} movies` — ALWAYS plural, even for 1
        // (FeedListCard.tsx L94); nil count → nil (row hidden, L92).
        XCTAssertEqual(FeedTicketPresenter.listCountLine(count: 12), "12 movies")
        XCTAssertEqual(FeedTicketPresenter.listCountLine(count: 1), "1 movies")
        XCTAssertEqual(FeedTicketPresenter.listCountLine(count: 0), "0 movies")
        XCTAssertNil(FeedTicketPresenter.listCountLine(count: nil))
    }

    // MARK: milestone summary

    func testMilestoneSummaryIconAndDescription() {
        let meta: JSONObject = ["badgeIcon": .string("🏆"),
                                "milestoneDescription": .string("100 films ranked")]
        let s = FeedTicketPresenter.milestoneSummary(from: meta)
        XCTAssertEqual(s.icon, "🏆")
        XCTAssertEqual(s.description, "100 films ranked")
    }

    func testMilestoneSummaryDefaultsIconAndDescription() {
        let s = FeedTicketPresenter.milestoneSummary(from: nil)
        XCTAssertEqual(s.icon, "🎖") // fallback badge glyph
        XCTAssertNil(s.description)
    }

    // MARK: header line

    func testAdmitLineWithUsernameUppercased() {
        XCTAssertEqual(FeedTicketPresenter.admitLine(username: "yurui", relativeTime: "2h"),
                       "ADMIT ONE · @YURUI · 2H")
    }

    func testAdmitLineMissingUsernameCollapsesHandle() {
        XCTAssertEqual(FeedTicketPresenter.admitLine(username: nil, relativeTime: "2h"),
                       "ADMIT ONE · 2H")
        XCTAssertEqual(FeedTicketPresenter.admitLine(username: "  ", relativeTime: "3d"),
                       "ADMIT ONE · 3D")
    }

    func testAdmitLineDoesNotDoubleAtSign() {
        // Username may already carry a leading @; don't render @@.
        XCTAssertEqual(FeedTicketPresenter.admitLine(username: "@yurui", relativeTime: "now"),
                       "ADMIT ONE · @YURUI · NOW")
    }

    // MARK: context-menu labels

    func testMenuLabelComposesHandle() {
        XCTAssertEqual(FeedTicketPresenter.menuLabel(action: "mute", username: "yurui", fallback: "user"),
                       "mute @yurui")
        XCTAssertEqual(FeedTicketPresenter.menuLabel(action: "open", username: "yurui", fallback: "profile"),
                       "open @yurui")
    }

    func testMenuLabelDedupsAtSign() {
        // Same @ dedup as admitLine — never render @@.
        XCTAssertEqual(FeedTicketPresenter.menuLabel(action: "mute", username: "@yurui", fallback: "user"),
                       "mute @yurui")
    }

    func testMenuLabelMissingUsernameUsesFallback() {
        XCTAssertEqual(FeedTicketPresenter.menuLabel(action: "mute", username: nil, fallback: "user"),
                       "mute user")
        XCTAssertEqual(FeedTicketPresenter.menuLabel(action: "open", username: "  ", fallback: "profile"),
                       "open profile")
    }

    // MARK: avatar accessibility label

    func testAvatarLabelComposesHandle() {
        XCTAssertEqual(FeedTicketPresenter.avatarAccessibilityLabel(username: "yurui"),
                       "avatar of @yurui")
    }

    func testAvatarLabelDedupsAtSign() {
        // Same @ dedup as admitLine/menuLabel — never render @@.
        XCTAssertEqual(FeedTicketPresenter.avatarAccessibilityLabel(username: "@yurui"),
                       "avatar of @yurui")
    }

    func testAvatarLabelMissingUsernameFallsBack() {
        XCTAssertEqual(FeedTicketPresenter.avatarAccessibilityLabel(username: nil), "avatar")
        XCTAssertEqual(FeedTicketPresenter.avatarAccessibilityLabel(username: "  "), "avatar")
    }

    // MARK: display title

    func testDisplayTitlePassesThroughAndFallsBack() {
        XCTAssertEqual(FeedTicketPresenter.displayTitle("Past Lives"), "Past Lives")
        XCTAssertEqual(FeedTicketPresenter.displayTitle(nil), "untitled")
        XCTAssertEqual(FeedTicketPresenter.displayTitle("   "), "untitled")
        XCTAssertEqual(FeedTicketPresenter.displayTitle("  Dune  "), "Dune")
    }

    // MARK: stamp accessibility label

    func testStampAccessibilityLabel() {
        XCTAssertEqual(FeedTicketPresenter.stampAccessibilityLabel(tier: .S, score: 9.4),
                       "tier S, score 9.4")
        XCTAssertEqual(FeedTicketPresenter.stampAccessibilityLabel(tier: .S, score: nil),
                       "tier S")
    }

    // MARK: flip hinge — face switch + shadow (pure)

    func testHingeFrontShowsBelow90AndSwitchesAt90Exactly() {
        XCTAssertTrue(FeedTicketFlipHinge.frontShowing(at: 0))
        XCTAssertTrue(FeedTicketFlipHinge.frontShowing(at: 89.99))
        // The switch happens AT the hinge, not after it.
        XCTAssertFalse(FeedTicketFlipHinge.frontShowing(at: 90))
        XCTAssertFalse(FeedTicketFlipHinge.frontShowing(at: 90.01))
        XCTAssertFalse(FeedTicketFlipHinge.frontShowing(at: 180))
    }

    func testHingeShadowPeaksAtMidFlipAndRestsAtEndpoints() {
        // 0.08 at rest on either face, peaking 0.30 at the 90° hinge.
        XCTAssertEqual(FeedTicketFlipHinge.shadowOpacity(at: 0), 0.08, accuracy: 0.0001)
        XCTAssertEqual(FeedTicketFlipHinge.shadowOpacity(at: 180), 0.08, accuracy: 0.0001)
        XCTAssertEqual(FeedTicketFlipHinge.shadowOpacity(at: 90), 0.30, accuracy: 0.0001)
        // Monotonic rise into the hinge.
        XCTAssertLessThan(FeedTicketFlipHinge.shadowOpacity(at: 30),
                          FeedTicketFlipHinge.shadowOpacity(at: 60))
    }
}
