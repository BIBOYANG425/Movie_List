import XCTest
@testable import Spool

/// Pin for the ceremony's stage-a quick-write ↔ "write more" MUTUAL EXCLUSION
/// (follow-up to plan Task 6). `RankPersistence.save` fires the stage-a
/// `JournalQuickEntry` upsert on a PLAIN finish but MUST skip it on the "write
/// more" finish, where the composer's explicit full-replace save is the
/// authoritative journal write. Running both would double-write / race on the
/// same `(user_id, tmdb_id)` key. The gate is pure so the rule is asserted with
/// ZERO network.
final class RankPersistenceLogicTests: XCTestCase {

    /// PLAIN finish ("post to feed", no composer): the flag defaults to `true`
    /// and the quick-write fires — every plain rank still produces a journal row
    /// (audit stage-a holds).
    func testPlainFinishWritesQuickEntry() {
        XCTAssertTrue(RankPersistence.shouldWriteQuickEntry(writeJournalQuickEntry: true))
    }

    /// "WRITE MORE" finish: the flag is `false` and the quick-write is SKIPPED —
    /// the composer owns the journal write on this path, so the two are mutually
    /// exclusive (no double-write, no race, composer probe deterministically
    /// finds nil and seeds from moods+line).
    func testWriteMoreFinishSkipsQuickEntry() {
        XCTAssertFalse(RankPersistence.shouldWriteQuickEntry(writeJournalQuickEntry: false))
    }

    // MARK: - Re-rank wipe guard (C3 Part B Task 0)

    /// The full decision seam folds `writeJournalQuickEntry`, the insert outcome,
    /// and whether the ceremony captured any moods/one-liner into one of three
    /// outcomes: `.skip`, `.quickWrite` (fresh full-replace), or `.probedMerge`
    /// (re-rank preserving the existing rich row). These pins fix the truth table
    /// so a re-rank can NEVER blind-replace a rich entry.

    /// "WRITE MORE" always wins: the composer owns the write, so the quick-write
    /// path is skipped regardless of outcome or input.
    func testWriteMoreSkipsEverything() {
        XCTAssertEqual(
            RankPersistence.quickEntryDecision(
                writeJournalQuickEntry: false, outcome: .inserted, hasInput: true),
            .skip)
        XCTAssertEqual(
            RankPersistence.quickEntryDecision(
                writeJournalQuickEntry: false, outcome: .moved(fromTier: "B"), hasInput: true),
            .skip)
    }

    /// A FRESH rank (`.inserted`) is unchanged — plain full-replace quick-write,
    /// input or not (an empty quick row still guarantees the audit stage-a row).
    func testFreshInsertAlwaysQuickWrites() {
        XCTAssertEqual(
            RankPersistence.quickEntryDecision(
                writeJournalQuickEntry: true, outcome: .inserted, hasInput: true),
            .quickWrite)
        XCTAssertEqual(
            RankPersistence.quickEntryDecision(
                writeJournalQuickEntry: true, outcome: .inserted, hasInput: false),
            .quickWrite)
    }

    /// A RE-RANK (`.moved`) with NO new moods and NO one-liner writes NOTHING —
    /// there is nothing to merge, and a blank full-replace would wipe the existing
    /// rich entry. This is the core wipe guard.
    func testReRankNoInputSkips() {
        XCTAssertEqual(
            RankPersistence.quickEntryDecision(
                writeJournalQuickEntry: true, outcome: .moved(fromTier: "B"), hasInput: false),
            .skip)
    }

    /// A RE-RANK (`.moved`) WITH new moods/one-liner takes the probed-merge path:
    /// fetch the full owner row and merge only the new fields onto it (never a
    /// blind full-replace of a near-blank quick draft).
    func testReRankWithInputMerges() {
        XCTAssertEqual(
            RankPersistence.quickEntryDecision(
                writeJournalQuickEntry: true, outcome: .moved(fromTier: "B"), hasInput: true),
            .probedMerge)
    }

    /// `hasInput` is true when EITHER moods or the one-liner is present.
    func testHasCeremonyInputIsMoodsOrLine() {
        XCTAssertTrue(RankPersistence.hasCeremonyInput(moods: ["thrilled"], line: ""))
        XCTAssertTrue(RankPersistence.hasCeremonyInput(moods: [], line: "a line"))
        XCTAssertTrue(RankPersistence.hasCeremonyInput(moods: ["x"], line: "y"))
        XCTAssertFalse(RankPersistence.hasCeremonyInput(moods: [], line: ""))
    }

    // MARK: - Ceremony defaults fix + whitespace gate (code review round 1)

    /// PIN: the OLD demo defaults ["tender", "devastating"] / "cried on the 6
    /// train." would have fired a `.probedMerge` on a re-rank — a tap-through
    /// with no user input would overwrite real mood_tags + review_text with demo
    /// junk. This asserts the FIXED empty defaults produce `.skip` on `.moved` so
    /// the wipe guard is actually reachable on a tap-through.
    func testEmptyDefaultsYieldSkipOnMoved_OldDefaultsWouldHaveMerged() {
        // Old behavior (would fire .probedMerge — the bug):
        XCTAssertEqual(
            RankPersistence.quickEntryDecision(
                writeJournalQuickEntry: true,
                outcome: .moved(fromTier: "B"),
                hasInput: RankPersistence.hasCeremonyInput(
                    moods: ["tender", "devastating"], line: "cried on the 6 train.")),
            .probedMerge,
            "sanity: old defaults counted as input and would have fired merge")
        // New behavior (fixed empty defaults → .skip — the wipe guard is reachable):
        XCTAssertEqual(
            RankPersistence.quickEntryDecision(
                writeJournalQuickEntry: true,
                outcome: .moved(fromTier: "B"),
                hasInput: RankPersistence.hasCeremonyInput(moods: [], line: "")),
            .skip,
            "empty defaults must produce .skip on .moved so the wipe guard fires")
    }

    /// Whitespace-only line counts as NO input — `"   "` must not pass the gate.
    func testWhitespaceOnlyLineCountsAsNoInput() {
        XCTAssertFalse(RankPersistence.hasCeremonyInput(moods: [], line: "   "))
        XCTAssertFalse(RankPersistence.hasCeremonyInput(moods: [], line: "\n\t"))
        // Whitespace + empty moods → .skip on .moved (wipe guard fires)
        XCTAssertEqual(
            RankPersistence.quickEntryDecision(
                writeJournalQuickEntry: true,
                outcome: .moved(fromTier: "A"),
                hasInput: RankPersistence.hasCeremonyInput(moods: [], line: "   ")),
            .skip)
    }
}
