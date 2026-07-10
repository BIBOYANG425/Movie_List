import XCTest
@testable import Spool

/// Pure presentation-logic pins for `JournalComposer` (plan Task 6). The
/// composer view itself is verified by build + previews; the network-free
/// decisions it leans on — favorite-moment add/remove clamped at
/// `JOURNAL_MAX_MOMENTS`, standout-performance minting (`personId` by index,
/// mirroring web's AI path), photo-extension normalization, and the
/// visibility-picker label mapping — are unit-tested here with ZERO UIKit.
final class JournalComposerLogicTests: XCTestCase {

    // MARK: - favorite moments (max 5, add blank / remove by index)

    func testAddMomentAppendsBlankUpToMax() {
        var moments = ["a", "b"]
        moments = JournalComposerLogic.addMoment(moments)
        XCTAssertEqual(moments, ["a", "b", ""])
    }

    func testAddMomentClampsAtMax() {
        let full = ["1", "2", "3", "4", "5"]   // JOURNAL_MAX_MOMENTS = 5
        XCTAssertEqual(full.count, JournalConstants.journalMaxMoments)
        let after = JournalComposerLogic.addMoment(full)
        XCTAssertEqual(after, full, "a 6th moment must not be added")
    }

    func testRemoveMomentByIndex() {
        let after = JournalComposerLogic.removeMoment(["a", "b", "c"], at: 1)
        XCTAssertEqual(after, ["a", "c"])
    }

    func testRemoveMomentOutOfRangeIsNoOp() {
        let after = JournalComposerLogic.removeMoment(["a"], at: 9)
        XCTAssertEqual(after, ["a"])
    }

    // MARK: - standout performances (personId by index, mirroring web)

    func testAddPerformanceMintsPersonIdByIndex() {
        var perfs: [StandoutPerformance] = []
        perfs = JournalComposerLogic.addPerformance(perfs, name: "Tony Leung", character: "Chow")
        perfs = JournalComposerLogic.addPerformance(perfs, name: "Maggie Cheung", character: nil)
        XCTAssertEqual(perfs.count, 2)
        XCTAssertEqual(perfs[0].personId, 0)
        XCTAssertEqual(perfs[0].name, "Tony Leung")
        XCTAssertEqual(perfs[0].character, "Chow")
        XCTAssertEqual(perfs[1].personId, 1)
        XCTAssertEqual(perfs[1].name, "Maggie Cheung")
        XCTAssertNil(perfs[1].character)
    }

    func testAddPerformanceIgnoresBlankName() {
        let perfs = JournalComposerLogic.addPerformance([], name: "   ", character: "x")
        XCTAssertTrue(perfs.isEmpty)
    }

    func testAddPerformanceTrimsCharacterToNilWhenBlank() {
        let perfs = JournalComposerLogic.addPerformance([], name: "Actor", character: "   ")
        XCTAssertEqual(perfs.count, 1)
        XCTAssertNil(perfs[0].character)
    }

    func testRemovePerformanceByIndex() {
        let perfs = [
            StandoutPerformance(personId: 0, name: "A", character: nil),
            StandoutPerformance(personId: 1, name: "B", character: nil),
        ]
        let after = JournalComposerLogic.removePerformance(perfs, at: 0)
        XCTAssertEqual(after.map(\.name), ["B"])
    }

    // MARK: - photo extension normalization

    func testPhotoExtensionLowercasesAndStripsDot() {
        XCTAssertEqual(JournalComposerLogic.photoExtension(fromIdentifier: "public.jpeg"), "jpeg")
        XCTAssertEqual(JournalComposerLogic.photoExtension(fromIdentifier: "public.png"), "png")
        XCTAssertEqual(JournalComposerLogic.photoExtension(fromIdentifier: "public.heic"), "heic")
    }

    func testPhotoExtensionDefaultsToJpgForUnknown() {
        XCTAssertEqual(JournalComposerLogic.photoExtension(fromIdentifier: nil), "jpg")
        XCTAssertEqual(JournalComposerLogic.photoExtension(fromIdentifier: "com.weird.type"), "jpg")
    }

    // MARK: - visibility picker options

    func testVisibilityOptionsIncludeDefaultThenThreeChoices() {
        // Order: default (nil override) first, then public / friends / private.
        let opts = JournalComposerLogic.visibilityOptions
        XCTAssertEqual(opts.count, 4)
        XCTAssertNil(opts[0].value)                     // default = nil override
        XCTAssertEqual(opts[1].value, .pub)
        XCTAssertEqual(opts[2].value, .friends)
        XCTAssertEqual(opts[3].value, .priv)
    }

    func testVisibilityLabelForValue() {
        // Wired through L10n reusing web journal.vis* keys (C6-iOS Task 3);
        // assert against the resolved value so the test is locale-safe.
        XCTAssertEqual(JournalComposerLogic.visibilityLabel(nil), L10n.t("journal.visDefault"))
        XCTAssertEqual(JournalComposerLogic.visibilityLabel(.pub), L10n.t("journal.visPublic"))
        XCTAssertEqual(JournalComposerLogic.visibilityLabel(.friends), L10n.t("journal.visFriends"))
        XCTAssertEqual(JournalComposerLogic.visibilityLabel(.priv), L10n.t("journal.visPrivate"))
    }
}
