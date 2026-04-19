import Foundation
import Supabase

/// End-to-end ranking writes: `user_rankings` + `activity_events` + `movie_stubs`.
/// Actor so state (the client reference) stays isolated. Reads/writes all go
/// through supabase-swift, RLS enforces scoping at the DB layer.
///
/// When `SpoolClient.shared` is nil (no credentials configured) every method
/// throws `.notConfigured` and the caller is expected to fall back to fixtures.
public actor RankingRepository {

    public static let shared = RankingRepository()

    public enum RepoError: Error {
        case notConfigured
        case notAuthenticated
    }

    // MARK: reads

    public func getTierItems(tier: Tier) async throws -> [RankingRow] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let rows: [RankingRow] = try await client
            .from("user_rankings")
            .select()
            .eq("user_id", value: userID.uuidString)
            .eq("tier", value: tier.rawValue)
            .order("rank_position", ascending: true)
            .execute()
            .value
        return rows
    }

    /// Search TMDB for movies matching `query`. Returns `[]` when `TMDB_API_KEY`
    /// is missing. Does not require a Supabase session — this is a pure API call.
    public func searchMovies(query: String) async -> [TMDBMovie] {
        await TMDBService.searchMovies(query: query)
    }

    /// All rankings for the signed-in user, across every tier. Used by the
    /// `SpoolRankingEngine` so it can compute prediction signals (genre +
    /// bracket averages) and walk the in-tier comparison graph.
    public func getAllRankedItems() async throws -> [RankedItem] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let rows: [RankingRow] = try await client
            .from("user_rankings")
            .select()
            .eq("user_id", value: userID.uuidString)
            .order("rank_position", ascending: true)
            .execute()
            .value
        return rows.compactMap(Self.rowToRankedItem)
    }

    private static func rowToRankedItem(_ row: RankingRow) -> RankedItem? {
        guard let tier = Tier(rawValue: row.tier) else { return nil }
        let yearInt = row.year.flatMap { Int($0) }
        let bracket = RankingAlgorithm.classifyBracket(genres: row.genres)
        return RankedItem(
            id: row.tmdb_id, title: row.title, year: yearInt,
            director: row.director ?? "—",
            genres: row.genres, tier: tier, rank: row.rank_position,
            bracket: bracket, globalScore: nil, seed: 0,
            posterUrl: row.poster_url
        )
    }

    // MARK: feed

    /// Returns the current user's most recent activity events (rankings they
    /// added) — newest first, up to `limit`. Used by the main feed when a
    /// Supabase session is active; otherwise the feed renders fixtures.
    public func getRecentActivity(limit: Int = 40) async throws -> [ActivityEventRow] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let rows: [ActivityEventRow] = try await client
            .from("activity_events")
            .select()
            .eq("actor_id", value: userID.uuidString)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows
    }

    // MARK: writes

    /// Insert a `user_rankings` row and an accompanying `activity_events` row.
    /// Both writes run sequentially, not in a transaction — the DB considers
    /// them independent. RLS enforces `auth.uid() = user_id` on both tables.
    public func insertRanking(_ ranking: RankingInsert) async throws -> RankingRow {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let payload = RankingPayload(
            user_id: userID,
            tmdb_id: ranking.tmdbId,
            title: ranking.title,
            year: ranking.year,
            poster_url: ranking.posterURL,
            type: ranking.type,
            genres: ranking.genres,
            director: ranking.director,
            tier: ranking.tier.rawValue,
            rank_position: ranking.rankPosition,
            notes: ranking.notes
        )

        let inserted: RankingRow = try await client
            .from("user_rankings")
            .insert(payload)
            .select()
            .single()
            .execute()
            .value

        let event = ActivityEventPayload(
            actor_id: userID,
            event_type: "ranking_add",
            target_user_id: nil,
            media_tmdb_id: ranking.tmdbId,
            media_title: ranking.title,
            media_tier: ranking.tier.rawValue,
            media_poster_url: ranking.posterURL
        )
        _ = try? await client.from("activity_events").insert(event).execute()

        return inserted
    }

    public func insertStub(_ stub: StubInsert) async throws -> StubRow {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let payload = StubPayload(
            user_id: userID,
            media_type: stub.mediaType,
            tmdb_id: stub.tmdbId,
            title: stub.title,
            poster_path: stub.posterPath,
            tier: stub.tier.rawValue,
            watched_date: ISODate.yyyyMMdd.string(from: stub.watchedDate),
            mood_tags: stub.moodTags,
            stub_line: stub.stubLine,
            palette: stub.palette,
            template_id: stub.templateID
        )

        let inserted: StubRow = try await client
            .from("movie_stubs")
            .insert(payload)
            .select()
            .single()
            .execute()
            .value
        return inserted
    }
}

// MARK: - DTOs (wire format, snake_case to match Postgres)

public struct RankingInsert: Sendable {
    public let tmdbId: String
    public let title: String
    public let year: String?
    public let posterURL: String?
    public let type: String            // "movie" | "tv" | "book"
    public let genres: [String]
    public let director: String?
    public let tier: Tier
    public let rankPosition: Int
    public let notes: String?

    public init(tmdbId: String, title: String, year: String?, posterURL: String?,
                type: String = "movie", genres: [String] = [], director: String? = nil,
                tier: Tier, rankPosition: Int, notes: String? = nil) {
        self.tmdbId = tmdbId
        self.title = title
        self.year = year
        self.posterURL = posterURL
        self.type = type
        self.genres = genres
        self.director = director
        self.tier = tier
        self.rankPosition = rankPosition
        self.notes = notes
    }
}

public struct StubInsert: Sendable {
    public let mediaType: String       // "movie" | "tv_season"
    public let tmdbId: String
    public let title: String
    public let posterPath: String?
    public let tier: Tier
    public let watchedDate: Date
    public let moodTags: [String]
    public let stubLine: String?
    public let palette: [String]
    public let templateID: String

    public init(mediaType: String = "movie", tmdbId: String, title: String,
                posterPath: String? = nil, tier: Tier, watchedDate: Date = Date(),
                moodTags: [String] = [], stubLine: String? = nil,
                palette: [String] = [], templateID: String = "default") {
        self.mediaType = mediaType
        self.tmdbId = tmdbId
        self.title = title
        self.posterPath = posterPath
        self.tier = tier
        self.watchedDate = watchedDate
        self.moodTags = moodTags
        self.stubLine = stubLine
        self.palette = palette
        self.templateID = templateID
    }
}

public struct RankingRow: Codable, Sendable, Hashable {
    public let id: UUID
    public let user_id: UUID
    public let tmdb_id: String
    public let title: String
    public let year: String?
    public let poster_url: String?
    public let type: String
    public let genres: [String]
    public let director: String?
    public let tier: String
    public let rank_position: Int
    public let notes: String?
}

public struct ActivityEventRow: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let actor_id: UUID
    public let event_type: String
    public let media_tmdb_id: String?
    public let media_title: String?
    public let media_tier: String?
    public let media_poster_url: String?
    public let created_at: String
}

public struct StubRow: Codable, Sendable, Hashable {
    public let id: UUID
    public let user_id: UUID
    public let media_type: String
    public let tmdb_id: String
    public let title: String
    public let poster_path: String?
    public let tier: String
    public let watched_date: String
    public let mood_tags: [String]
    public let stub_line: String?
    public let palette: [String]
    public let template_id: String
}

// MARK: - Encodable payloads (snake_case fields for PostgREST)

private struct RankingPayload: Encodable {
    let user_id: UUID
    let tmdb_id: String
    let title: String
    let year: String?
    let poster_url: String?
    let type: String
    let genres: [String]
    let director: String?
    let tier: String
    let rank_position: Int
    let notes: String?
}

private struct ActivityEventPayload: Encodable {
    let actor_id: UUID
    let event_type: String
    let target_user_id: UUID?
    let media_tmdb_id: String?
    let media_title: String?
    let media_tier: String?
    let media_poster_url: String?
}

private struct StubPayload: Encodable {
    let user_id: UUID
    let media_type: String
    let tmdb_id: String
    let title: String
    let poster_path: String?
    let tier: String
    let watched_date: String
    let mood_tags: [String]
    let stub_line: String?
    let palette: [String]
    let template_id: String
}

// MARK: - Date helper

private enum ISODate {
    static let yyyyMMdd: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
