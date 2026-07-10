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

    // MARK: - Re-rank merge flow (C3 Part B Task 0 — the wipe fix)

    private let uid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private struct ProbeThrew: Error {}

    /// A recorder for the injected merge-flow IO — captures what `writeMerging`
    /// probed and upserted with zero network.
    private final class Recorder: @unchecked Sendable {
        var probeCount = 0
        var upsertPayloads: [JournalUpsertPayload] = []
    }

    private func richRow() -> JournalRow {
        JournalRow(
            id: UUID(uuidString: "22222222-0000-0000-0000-000000000002")!,
            user_id: uid, tmdb_id: "603", title: "The Matrix",
            poster_url: "/p.jpg", rating_tier: "loved",
            review_text: "a machine dreamt of us.", contains_spoilers: true,
            mood_tags: ["nostalgic"], vibe_tags: ["late_night"],
            favorite_moments: ["the lobby", "red pill"],
            standout_performances: [
                StandoutPerformance(personId: 6384, name: "Keanu Reeves", character: "Neo"),
            ],
            watched_date: "2026-06-01", watched_location: "home",
            watched_with_user_ids: [], watched_platform: "netflix",
            is_rewatch: true, rewatch_note: "still holds up",
            personal_takeaway: "choose your reality", photo_paths: ["u/603/0.jpg"],
            visibility_override: "public", like_count: 3,
            created_at: "2026-06-01T00:00:00+00:00"
        )
    }

    private func echo(_ payload: JournalUpsertPayload) -> JournalRow {
        JournalRow(
            id: UUID(), user_id: payload.user_id, tmdb_id: payload.tmdb_id,
            title: payload.title, poster_url: payload.poster_url,
            rating_tier: payload.rating_tier, review_text: payload.review_text,
            contains_spoilers: payload.contains_spoilers, mood_tags: payload.mood_tags,
            vibe_tags: payload.vibe_tags, favorite_moments: payload.favorite_moments,
            standout_performances: payload.standout_performances,
            watched_date: payload.watched_date, watched_location: payload.watched_location,
            watched_with_user_ids: payload.watched_with_user_ids,
            watched_platform: payload.watched_platform, is_rewatch: payload.is_rewatch,
            rewatch_note: payload.rewatch_note, personal_takeaway: payload.personal_takeaway,
            photo_paths: payload.photo_paths, visibility_override: payload.visibility_override,
            like_count: 0, created_at: ""
        )
    }

    /// `.moved` + new moods/line + an existing rich row → probed MERGE: the
    /// upsert preserves every rich field and folds in only the new moods + line,
    /// keeping the existing watched_date. Never a blank full-replace.
    func testMergeFlowMovedWithExistingRowPreservesRichFields() async {
        let rec = Recorder()
        await JournalQuickEntry.writeMerging(
            userID: uid, tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg",
            line: "second time hits harder.", moods: ["thrilled"], ratingTier: "loved",
            probe: { _ in rec.probeCount += 1; return self.richRow() },
            upsert: { p in rec.upsertPayloads.append(p); return self.echo(p) }
        )
        XCTAssertEqual(rec.probeCount, 1)
        XCTAssertEqual(rec.upsertPayloads.count, 1)
        let p = rec.upsertPayloads[0]
        XCTAssertEqual(p.review_text, "second time hits harder.")
        XCTAssertEqual(p.mood_tags, ["thrilled"])
        XCTAssertEqual(p.personal_takeaway, "choose your reality")
        XCTAssertEqual(p.photo_paths, ["u/603/0.jpg"])
        XCTAssertEqual(p.favorite_moments, ["the lobby", "red pill"])
        XCTAssertEqual(p.visibility_override, "public")
        XCTAssertEqual(p.watched_date, "2026-06-01")   // existing date kept
    }

    /// `.moved` + new input but NO existing row (probe returns nil) → a plain
    /// quick-write full-replace (nothing to merge, nothing to wipe).
    func testMergeFlowMovedWithNoExistingRowQuickWrites() async {
        let rec = Recorder()
        await JournalQuickEntry.writeMerging(
            userID: uid, tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg",
            line: "fresh line.", moods: ["thrilled"], ratingTier: "loved",
            probe: { _ in rec.probeCount += 1; return nil },
            upsert: { p in rec.upsertPayloads.append(p); return self.echo(p) }
        )
        XCTAssertEqual(rec.probeCount, 1)
        XCTAssertEqual(rec.upsertPayloads.count, 1)
        let p = rec.upsertPayloads[0]
        XCTAssertEqual(p.review_text, "fresh line.")
        XCTAssertEqual(p.mood_tags, ["thrilled"])
        XCTAssertNil(p.personal_takeaway)   // brand-new quick draft, nothing rich
    }

    /// PROBE FAILURE on the merge path → skip the write ENTIRELY (never a blind
    /// full-replace) + log loudly. The wipe-guard posture: a read hiccup must NOT
    /// let a near-blank draft clobber the rich row.
    func testMergeFlowProbeThrowSkipsWriteEntirely() async {
        let rec = Recorder()
        await JournalQuickEntry.writeMerging(
            userID: uid, tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg",
            line: "line.", moods: ["thrilled"], ratingTier: "loved",
            probe: { _ in rec.probeCount += 1; throw ProbeThrew() },
            upsert: { p in rec.upsertPayloads.append(p); return self.echo(p) }
        )
        XCTAssertEqual(rec.probeCount, 1)
        XCTAssertTrue(rec.upsertPayloads.isEmpty, "probe failure must NOT upsert")
    }

    // MARK: - Whitespace trim gates (code review round 1)

    /// A whitespace-only line in a fresh quick draft must store "" in reviewText,
    /// which nilIfEmpty coerces to nil — never "   " in review_text.
    func testFreshDraftWhitespaceLineYieldsNilReviewText() {
        let draft = JournalQuickEntry.draft(
            tmdbId: "603", title: "The Matrix", posterUrl: nil,
            line: "   ", moods: []
        )
        XCTAssertEqual(draft.reviewText, "", "trimmed whitespace → empty string in draft")
        let payload = JournalEntryContract.upsertPayload(
            userID: UUID(), ratingTier: nil, from: draft
        )
        XCTAssertNil(payload.review_text,
                     "empty reviewText must coerce to nil in the upsert payload")
    }

    /// On the merge path, a whitespace-only newLine must NOT overwrite the
    /// existing rich review_text — the merge gate trims before checking isEmpty.
    func testMergePath_WhitespaceLinePreservesExistingReviewText() async {
        let rec = Recorder()
        await JournalQuickEntry.writeMerging(
            userID: uid, tmdbId: "603", title: "The Matrix", posterUrl: "/p.jpg",
            line: "   ", moods: ["moved"], ratingTier: "loved",
            probe: { _ in rec.probeCount += 1; return self.richRow() },
            upsert: { p in rec.upsertPayloads.append(p); return self.echo(p) }
        )
        XCTAssertEqual(rec.upsertPayloads.count, 1)
        XCTAssertEqual(
            rec.upsertPayloads[0].review_text,
            "a machine dreamt of us.",
            "whitespace-only newLine must NOT overwrite the existing rich review_text")
    }
}
