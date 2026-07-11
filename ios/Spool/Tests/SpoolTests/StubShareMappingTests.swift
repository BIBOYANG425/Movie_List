import XCTest
@testable import Spool

/// Guards the StubShareScreen real-data fix (design-check Defect 6): the share
/// card / exported image used to burn in demo constants ("cried on the 6 train.",
/// moods ["tender","devastating"], "APR · 18 · 2026", "#0127", director
/// "celine song", handle "@yurui"). These tests pin the pure StubRow → StubShare
/// mapping and the shared date/number formatters so those literals can never
/// creep back in.
final class StubShareMappingTests: XCTestCase {

    private func row(
        title: String = "Past Lives",
        tier: String = "S",
        watchedDate: String = "2026-04-18",
        moods: [String] = ["quiet", "aching"],
        line: String? = "still thinking about it.",
        poster: String? = "/pl.jpg"
    ) -> StubRow {
        StubRow(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            user_id: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!,
            media_type: "movie",
            tmdb_id: "tmdb_1",
            title: title,
            poster_path: poster,
            tier: tier,
            watched_date: watchedDate,
            mood_tags: moods,
            stub_line: line,
            palette: [],
            template_id: "classic"
        )
    }

    // MARK: - StubFormat (extracted from StubsScreen)

    func testAdmitDateFormatsISOToStampShape() {
        XCTAssertEqual(StubFormat.admitDate("2026-04-18"), "APR · 18 · 2026")
        XCTAssertEqual(StubFormat.admitDate("2025-12-03"), "DEC · 03 · 2025")
    }

    func testAdmitDateDegradesOnMalformedInput() {
        // Not a 3-part date → uppercased echo, never a placeholder date.
        XCTAssertEqual(StubFormat.admitDate("garbage"), "GARBAGE")
    }

    func testStubNumberZeroPads() {
        XCTAssertEqual(StubFormat.stubNumber(42), "#0042")
        XCTAssertEqual(StubFormat.stubNumber(0), "#0000")
        XCTAssertEqual(StubFormat.stubNumber(-5), "#0000")   // clamps negatives
        XCTAssertEqual(StubFormat.stubNumber(1234), "#1234")
    }

    // MARK: - StubShare.from(row:) — the REAL-DATA path

    func testFromRowUsesRealFieldsNotDemoConstants() {
        let share = StubShare.from(row: row(), stubCount: 42, handle: "@bobby")

        // Every field is the row's own data, NOT the old demo literals.
        XCTAssertEqual(share.title, "Past Lives")
        XCTAssertEqual(share.tier, .S)
        XCTAssertEqual(share.line, "still thinking about it.")
        XCTAssertNotEqual(share.line, "cried on the 6 train.")
        XCTAssertEqual(share.moods, ["quiet", "aching"])
        XCTAssertNotEqual(share.moods, ["tender", "devastating"])
        XCTAssertEqual(share.date, "APR · 18 · 2026")   // formatted from watched_date
        XCTAssertEqual(share.stubNo, "#0042")           // from the real count, not "#0127"
        XCTAssertEqual(share.year, 2026)                // parsed, not hardcoded 2023
        XCTAssertEqual(share.posterUrl, "/pl.jpg")
        XCTAssertEqual(share.handle, "@bobby")
        XCTAssertNotEqual(share.handle, "@yurui")
        // No director source on a stub row → the app's "—" placeholder, never
        // the demo "celine song".
        XCTAssertEqual(share.director, "—")
        XCTAssertNotEqual(share.director.lowercased(), "celine song")
    }

    func testFromRowEmptyLineRendersEmptyNotDemo() {
        // A stub with no review line maps to "", so the card omits the quote
        // block — it must not fall back to the demo line.
        let share = StubShare.from(row: row(line: nil), stubCount: 1, handle: "@x")
        XCTAssertEqual(share.line, "")
    }

    func testFromRowMovieCarriesRealYearAndPoster() {
        let share = StubShare.from(row: row(watchedDate: "2019-06-01"), stubCount: 3, handle: "@x")
        XCTAssertEqual(share.movie.title, "Past Lives")
        XCTAssertEqual(share.movie.year, 2019)
        XCTAssertEqual(share.movie.posterUrl, "/pl.jpg")
        XCTAssertNotEqual(share.movie.year, 2023)   // not the demo year
    }

    // MARK: - StubShare.from(day:) — the fixture / preview-mode path

    func testFromDayLeavesLineAndMoodsEmpty() {
        // A WatchedDay carries no line/moods (dropped in rowToDay); the share
        // must render them empty, not invent demo values.
        let day = WatchedDay(day: 18, tier: .S, title: "Past Lives", year: 2026, month: 4)
        let share = StubShare.from(day: day, stubCount: 127, handle: "@yurui")
        XCTAssertEqual(share.line, "")
        XCTAssertEqual(share.moods, [])
        XCTAssertEqual(share.date, "APR · 18 · 2026")
        XCTAssertEqual(share.stubNo, "#0127")
        XCTAssertEqual(share.title, "Past Lives")
    }

    func testFromDayWithoutDateFallsBackToDayLabel() {
        // Fixture rows without year/month get a day-only label, never a
        // misleading full date.
        let day = WatchedDay(day: 8, tier: .A, title: "Drive My Car")
        let share = StubShare.from(day: day, stubCount: 0, handle: "@x")
        XCTAssertEqual(share.date, "DAY · 08")
    }

    // MARK: - StubsScreen.indexRowsByDay — the tap → row recovery seam

    func testIndexRowsByDayKeysByDayOfMonth() {
        let rows = [
            row(title: "A", tier: "B", watchedDate: "2026-04-02"),
            row(title: "B", tier: "S", watchedDate: "2026-04-18")
        ]
        let byDay = StubsScreen.indexRowsByDay(rows)
        XCTAssertEqual(byDay[2]?.title, "A")
        XCTAssertEqual(byDay[18]?.title, "B")
        XCTAssertNil(byDay[9])
    }

    func testIndexRowsByDayKeepsHigherTierOnCollision() {
        // Two stubs on the same day → the calendar cell shows the best tier, so
        // the shared row must be that same higher-tier stub.
        let rows = [
            row(title: "low", tier: "C", watchedDate: "2026-04-10"),
            row(title: "high", tier: "S", watchedDate: "2026-04-10")
        ]
        let byDay = StubsScreen.indexRowsByDay(rows)
        XCTAssertEqual(byDay[10]?.title, "high")
    }
}
