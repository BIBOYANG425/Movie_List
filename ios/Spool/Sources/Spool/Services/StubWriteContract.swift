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

    private enum CodingKeys: String, CodingKey {
        case user_id, media_type, tmdb_id, title, poster_path
        case tier, template_id, watched_date, updated_at
    }

    /// Custom encoder solely so a nil `poster_path` becomes an explicit
    /// JSON `null` (web sends `posterPath ?? null`). Synthesized Encodable
    /// would omit the key, and PostgREST treats a missing key as "don't
    /// touch" — a vanished poster would never clear.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(user_id, forKey: .user_id)
        try c.encode(media_type, forKey: .media_type)
        try c.encode(tmdb_id, forKey: .tmdb_id)
        try c.encode(title, forKey: .title)
        try c.encode(poster_path, forKey: .poster_path) // explicit null when nil
        try c.encode(tier, forKey: .tier)
        try c.encode(template_id, forKey: .template_id)
        try c.encode(watched_date, forKey: .watched_date)
        try c.encode(updated_at, forKey: .updated_at)
    }
}

public struct StubConflictUpdatePayload: Encodable, Equatable {
    let title: String
    let poster_path: String?
    let tier: String
    let template_id: String
    let updated_at: String

    private enum CodingKeys: String, CodingKey {
        case title, poster_path, tier, template_id, updated_at
    }

    /// Same explicit-null rule as `StubInsertPayload` — the conflict UPDATE
    /// must clear a stored poster when the fresh TMDB data has none.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(poster_path, forKey: .poster_path) // explicit null when nil
        try c.encode(tier, forKey: .tier)
        try c.encode(template_id, forKey: .template_id)
        try c.encode(updated_at, forKey: .updated_at)
    }
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

    /// The `movie_stubs.media_type` value for a rankable media, or `nil` when NO
    /// stub is written. The `movie_stubs` CHECK constraint only allows
    /// `('movie', 'tv_season')` (`20260325_movie_stubs.sql:11`), so:
    ///   - `.movie` → `"movie"` stub
    ///   - `.tv`    → `"tv_season"` stub (web `createStub({mediaType:'tv_season'})`)
    ///   - `.book`  → `nil` — BOOKS WRITE NO STUB. Web `handleAddBookItem` never
    ///     calls `createStub`, and a `'book'` media_type would 400 on the CHECK.
    /// Pure so the stub-decision matrix is unit-tested with zero network.
    public static func stubMediaType(for media: RankMedia) -> String? {
        switch media {
        case .movie: return "movie"
        case .tv:    return "tv_season"
        case .book:  return nil
        }
    }

    /// User-local calendar day. Deliberately NOT a GMT-pinned yyyy-MM-dd
    /// formatter — the exact bug PR #30 fixed on web (evening ranks
    /// landing on tomorrow's date).
    public static func localDateString(from date: Date = Date(),
                                       calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `mediaType` is the resolved `movie_stubs.media_type` string
    /// (`"movie" | "tv_season"`), defaulting to `"movie"` for the existing movie
    /// call sites. `StubWriter` resolves it via `stubMediaType(for:)` — books are
    /// filtered out BEFORE this builder (no `nil` reaches it). `tmdb_id` is
    /// `movie.id` verbatim: for a tv item that is the composite `tv_{id}_s{n}`,
    /// matching the ranking row's `tmdb_id` (web `createStub({tmdbId:newItem.id})`).
    public static func insertPayload(userID: UUID, movie: Movie, tier: Tier,
                                     mediaType: String = "movie",
                                     now: Date = Date(),
                                     calendar: Calendar = .current) -> StubInsertPayload {
        StubInsertPayload(
            user_id: userID,
            media_type: mediaType,
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
