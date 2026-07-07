import XCTest
@testable import Spool

final class StubWriteContractTests: XCTestCase {

    private let uid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private var movie: Movie {
        Movie(id: "603", title: "The Matrix", year: 1999, director: "Lana Wachowski",
              posterUrl: "https://image.tmdb.org/t/p/w500/matrix.jpg")
    }
    // 2026-07-07T02:00:00Z == 2026-07-06 19:00 in America/Los_Angeles (PDT)
    private let eveningUTC = Date(timeIntervalSince1970: 1_783_389_600)

    private func calendar(_ tzID: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tzID)!
        return c
    }

    private func jsonKeys<T: Encodable>(_ payload: T) throws -> Set<String> {
        let data = try JSONEncoder().encode(payload)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return Set(obj.keys)
    }

    // MARK: local date — pinned to a named timezone so a GMT regression
    // fails deterministically regardless of the runner's timezone.

    func testLocalDateStringUsesLocalCalendarDay() {
        let la = StubWriteContract.localDateString(from: eveningUTC, calendar: calendar("America/Los_Angeles"))
        XCTAssertEqual(la, "2026-07-06", "evening UTC must land on the LA calendar day")
        let utc = StubWriteContract.localDateString(from: eveningUTC, calendar: calendar("UTC"))
        XCTAssertEqual(utc, "2026-07-07")
    }

    // MARK: template id

    func testTemplateIDGoldOnlyForSTier() {
        XCTAssertEqual(StubWriteContract.templateID(for: .S), "s_tier_gold")
        for tier in [Tier.A, .B, .C, .D] {
            XCTAssertEqual(StubWriteContract.templateID(for: tier), "default", "\(tier)")
        }
    }

    // MARK: insert payload — exact key set per audit §1.1 + PR #30

    func testInsertPayloadKeySetAndValues() throws {
        let p = StubWriteContract.insertPayload(
            userID: uid, movie: movie, tier: .S,
            now: eveningUTC, calendar: calendar("America/Los_Angeles")
        )
        XCTAssertEqual(try jsonKeys(p), [
            "user_id", "media_type", "tmdb_id", "title", "poster_path",
            "tier", "template_id", "watched_date", "updated_at",
        ], "no palette, no mood_tags, no stub_line — DB defaults own those")
        XCTAssertEqual(p.media_type, "movie")
        XCTAssertEqual(p.tmdb_id, "603")
        XCTAssertEqual(p.poster_path, "https://image.tmdb.org/t/p/w500/matrix.jpg")
        XCTAssertEqual(p.tier, "S")
        XCTAssertEqual(p.template_id, "s_tier_gold")
        XCTAssertEqual(p.watched_date, "2026-07-06")
        XCTAssertTrue(p.updated_at.hasPrefix("2026-07-07T"), "updated_at is an ISO8601 instant, not a local day")
    }

    // MARK: conflict-update payload — refresh subset ONLY (audit §1.2)

    func testConflictUpdatePayloadOmitsPreservedColumns() throws {
        let p = StubWriteContract.conflictUpdatePayload(movie: movie, tier: .B, now: eveningUTC)
        XCTAssertEqual(try jsonKeys(p), ["title", "poster_path", "tier", "template_id", "updated_at"],
                       "watched_date/palette/mood_tags/stub_line must be preserved on re-rank")
        XCTAssertEqual(p.template_id, "default")
    }

    // MARK: shared unique-violation classifier

    func testIsUniqueViolationMatchesSQLState() {
        struct Fake: Error, CustomStringConvertible { let description: String }
        XCTAssertTrue(PostgresErrors.isUniqueViolation(Fake(description: "PostgrestError code 23505")))
        XCTAssertTrue(PostgresErrors.isUniqueViolation(Fake(description: "duplicate key value violates unique constraint")))
        XCTAssertFalse(PostgresErrors.isUniqueViolation(Fake(description: "PostgrestError code 42501 RLS")))
    }
}
