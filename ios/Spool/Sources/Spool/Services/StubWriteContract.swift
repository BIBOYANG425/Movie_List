import Foundation

// Wire payloads for `movie_stubs`, mirroring the web contract fixed in
// PR #30 (docs/plans/audits/2026-07-07-c0-stub-web-audit.md §1):
//  - INSERT carries an explicit user-LOCAL watched_date and never touches
//    palette/mood_tags/stub_line (DB defaults own them).
//  - The 23505 fallback UPDATE refreshes only title/poster_path/tier/
//    template_id/updated_at so re-ranks preserve the user's stub history.

public struct StubInsertPayload: Encodable, Equatable {
    let user_id: UUID
    let media_type: String
    let tmdb_id: String
    let title: String
    let poster_path: String?
    let tier: String
    let template_id: String
    let watched_date: String
    let updated_at: String
}

public struct StubConflictUpdatePayload: Encodable, Equatable {
    let title: String
    let poster_path: String?
    let tier: String
    let template_id: String
    let updated_at: String
}

public enum StubWriteContract {

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func templateID(for tier: Tier) -> String {
        tier == .S ? "s_tier_gold" : "default"
    }

    /// User-local calendar day. Deliberately NOT `ISODate.yyyyMMdd`, which
    /// is GMT-pinned — the exact bug PR #30 fixed on web (evening ranks
    /// landing on tomorrow's date).
    public static func localDateString(from date: Date = Date(),
                                       calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func insertPayload(userID: UUID, movie: Movie, tier: Tier,
                                     now: Date = Date(),
                                     calendar: Calendar = .current) -> StubInsertPayload {
        StubInsertPayload(
            user_id: userID,
            media_type: "movie",
            tmdb_id: movie.id,
            title: movie.title,
            poster_path: movie.posterUrl,
            tier: tier.rawValue,
            template_id: templateID(for: tier),
            watched_date: localDateString(from: now, calendar: calendar),
            updated_at: iso8601.string(from: now)
        )
    }

    public static func conflictUpdatePayload(movie: Movie, tier: Tier,
                                             now: Date = Date()) -> StubConflictUpdatePayload {
        StubConflictUpdatePayload(
            title: movie.title,
            poster_path: movie.posterUrl,
            tier: tier.rawValue,
            template_id: templateID(for: tier),
            updated_at: iso8601.string(from: now)
        )
    }
}
