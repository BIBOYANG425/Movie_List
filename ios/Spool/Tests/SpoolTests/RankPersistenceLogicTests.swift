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
}
