import XCTest
@testable import Spool

/// Pins for the STAGE-A quick-entry write (plan Task 6). Every rank ceremony —
/// even a plain "post to feed" with no "write more" — must produce a real
/// `journal_entries` row from the ceremony's moods + one-liner (audit stage-a:
/// today the ceremony only writes to `user_rankings.notes`; this ADDS the
/// journal row without removing that). The pure draft builder is tested here so
/// the resulting upsert payload is deterministic with ZERO network.
final class JournalQuickEntryTests: XCTestCase {

    func testQuickDraftFoldsLineIntoReviewAndCarriesMoods() {
        let draft = JournalQuickEntry.draft(
            tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg",
            line: "a machine dreamt of us.", moods: ["thrilled", "amazed"]
        )
        XCTAssertEqual(draft.tmdbId, "603")
        XCTAssertEqual(draft.title, "The Matrix")
        XCTAssertEqual(draft.posterUrl, "/p.jpg")
        // The one-liner folds into review_text (there is NO separate one-liner
        // column — plan note).
        XCTAssertEqual(draft.reviewText, "a machine dreamt of us.")
        XCTAssertEqual(draft.moodTags, ["thrilled", "amazed"])
        // Everything else stays a blank default — a quick entry is minimal.
        XCTAssertTrue(draft.vibeTags.isEmpty)
        XCTAssertTrue(draft.favoriteMoments.isEmpty)
        XCTAssertTrue(draft.watchedWithUserIds.isEmpty)
        XCTAssertNil(draft.visibilityOverride)
        XCTAssertFalse(draft.watchedDate.isEmpty)   // local yyyy-MM-dd default
    }

    func testQuickDraftEmptyLineYieldsEmptyReview() {
        let draft = JournalQuickEntry.draft(
            tmdbId: "1", title: "X", posterUrl: nil, line: "", moods: []
        )
        XCTAssertEqual(draft.reviewText, "")
        // An empty review coerces to null in the upsert payload — verify via the
        // contract so a quick entry with no line still writes a valid row.
        let payload = JournalEntryContract.upsertPayload(
            userID: UUID(), ratingTier: "B", from: draft
        )
        XCTAssertNil(payload.review_text)
        XCTAssertEqual(payload.tmdb_id, "1")
    }

    func testQuickDraftWatchedDateIsLocalNotGMT() {
        // Reuses the stubs local-date helper (never a GMT formatter) — the
        // quick entry's watched_date must match the same "today" the stub uses.
        let draft = JournalQuickEntry.draft(
            tmdbId: "1", title: "X", posterUrl: nil, line: "l", moods: []
        )
        XCTAssertEqual(draft.watchedDate, StubWriteContract.localDateString())
    }
}
