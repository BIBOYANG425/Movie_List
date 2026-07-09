import Foundation

/// Models + pure contract layer for the three parallel watchlist tables
/// (`watchlist_items`, `tv_watchlist_items`, `book_watchlist_items`). The
/// network-free half of `WatchlistRepository`: row↔model mapping, whole-show
/// detection, the B2 corrupt-row rejection, id-format helpers, the §1.4 TV
/// exclusion-id expansion, and the add-payload wire shapes. All of it is
/// tested without a live client (`WatchlistContractTests`).
///
/// Binding contract: C3 web audit §1.1 (three tables, per-media columns) +
/// §1.4 (TV excludeIds must contain show-level ids). Mirrors web
/// `rowToWatchlistItem` / `rowToTVWatchlistItem` / `rowToBookWatchlistItem`
/// and the three `addTo*Watchlist` upsert payloads
/// (`pages/RankingAppPage.tsx:131-221, 646-697, 1184-1191`).
///
/// Header last reviewed: 2026-07-09

// MARK: - Media type

/// The three watchlist media kinds. `dbType` is the value stored in the
/// tables' `type` column ("movie" / "tv_season" / "book"); the enum cases stay
/// `movie` / `tv` / `book` so the UI reads clean. Round-trips via `init?(dbType:)`.
public enum WatchlistMediaType: String, Sendable, Hashable, CaseIterable {
    case movie
    case tv
    case book

    /// The `type` column value the DB stores for this media kind. TV rows use
    /// the web's `'tv_season'` sentinel, not `'tv'`.
    public var dbType: String {
        switch self {
        case .movie: return "movie"
        case .tv: return "tv_season"
        case .book: return "book"
        }
    }

    /// Parse a DB `type` column value. Unknown values → nil (caller decides
    /// whether to skip). `'tv_season'` maps to `.tv`.
    public init?(dbType: String) {
        switch dbType {
        case "movie": self = .movie
        case "tv_season", "tv": self = .tv
        case "book": self = .book
        default: return nil
        }
    }
}

// MARK: - The unified watchlist item (the model Tasks 3-5 consume)

/// One watchlist entry, unified across all three tables. Movie fields are
/// always present; per-media fields are populated only for their media type
/// (TV: `showTmdbId`/`seasonNumber`/`seasonTitle`/`creator`; book:
/// `author`/`pageCount`/`isbn`/`olWorkKey`/`olRatingsAverage`).
///
/// `id` is the `tmdb_id` column verbatim (`tmdb_{n}` / `tv_{n}_s{m}` /
/// `tv_{n}` / `ol_{key}`). `addedAt` is parsed from the `added_at` timestamptz.
public struct WatchlistItem: Identifiable, Sendable, Hashable {
    /// The `tmdb_id` column: `tmdb_{n}` (movie), `tv_{n}_s{m}` or `tv_{n}`
    /// (TV), `ol_{workKey}` (book).
    public let id: String
    public let title: String
    /// `''` when the row's `year` is null (web `year ?? ''`).
    public let year: String
    /// Full poster URL; `''` when null (web `poster_url ?? ''`).
    public let posterUrl: String
    public let mediaType: WatchlistMediaType
    public let genres: [String]
    public let addedAt: Date

    // movie / TV
    public let director: String?
    // TV
    public let creator: String?
    public let showTmdbId: Int?
    public let seasonNumber: Int?
    public let seasonTitle: String?
    // book
    public let author: String?
    public let pageCount: Int?
    public let isbn: String?
    public let olWorkKey: String?
    public let olRatingsAverage: Double?

    public init(
        id: String, title: String, year: String, posterUrl: String,
        mediaType: WatchlistMediaType, genres: [String], addedAt: Date,
        director: String? = nil, creator: String? = nil,
        showTmdbId: Int? = nil, seasonNumber: Int? = nil, seasonTitle: String? = nil,
        author: String? = nil, pageCount: Int? = nil, isbn: String? = nil,
        olWorkKey: String? = nil, olRatingsAverage: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.posterUrl = posterUrl
        self.mediaType = mediaType
        self.genres = genres
        self.addedAt = addedAt
        self.director = director
        self.creator = creator
        self.showTmdbId = showTmdbId
        self.seasonNumber = seasonNumber
        self.seasonTitle = seasonTitle
        self.author = author
        self.pageCount = pageCount
        self.isbn = isbn
        self.olWorkKey = olWorkKey
        self.olRatingsAverage = olRatingsAverage
    }

    /// True when this TV bookmark covers the WHOLE show rather than a single
    /// season — `seasonNumber` is nil (schema intent) OR 0 (the web writer's
    /// coalesced value). Both mean "whole show" per audit D6. Always false for
    /// movies/books.
    public var isWholeShow: Bool {
        mediaType == .tv && WatchlistContract.isWholeShow(seasonNumber: seasonNumber)
    }
}

// MARK: - Row DTOs (snake_case, match Postgres columns)

/// `watchlist_items` row (`supabase_schema.sql:37-49`).
public struct WatchlistRow: Codable, Sendable, Hashable {
    public let id: UUID
    public let user_id: UUID
    public let tmdb_id: String
    public let title: String
    public let year: String?
    public let poster_url: String?
    public let type: String
    public let genres: [String]?
    public let director: String?
    public let added_at: String
}

/// `tv_watchlist_items` row (`supabase_tv_rankings.sql:65-80`). `season_number`
/// is nullable (NULL = whole show). `show_tmdb_id = 0` is corrupt legacy (B2).
public struct TVWatchlistRow: Codable, Sendable, Hashable {
    public let id: UUID
    public let user_id: UUID
    public let tmdb_id: String
    public let show_tmdb_id: Int
    public let season_number: Int?
    public let title: String
    public let season_title: String?
    public let year: String?
    public let poster_url: String?
    public let type: String
    public let genres: [String]?
    public let creator: String?
    public let added_at: String
}

/// `book_watchlist_items` row (`supabase_book_rankings.sql:67-83`).
public struct BookWatchlistRow: Codable, Sendable, Hashable {
    public let id: UUID
    public let user_id: UUID
    public let tmdb_id: String
    public let title: String
    public let year: String?
    public let poster_url: String?
    public let type: String
    public let genres: [String]?
    public let author: String?
    public let page_count: Int?
    public let isbn: String?
    public let ol_work_key: String?
    public let ol_ratings_average: Double?
    public let added_at: String
}

// MARK: - Pure contract layer (no client, no I/O — fully unit-tested)

/// The network-free bits of `WatchlistRepository`: row→model mappers, id
/// helpers, whole-show detection, the §1.4 exclusion-id expansion, and the
/// add-payload builders. Extracted so every wire shape and every mapping edge
/// (B2 rejection, 0-vs-NULL whole-show) is tested without a live client.
public enum WatchlistContract {

    // MARK: id-format helpers

    /// Movie watchlist id: `tmdb_{n}` (web `mapTmdbResult`, `tmdbService.ts:99`).
    public static func movieId(_ tmdbID: Int) -> String { "tmdb_\(tmdbID)" }

    /// Whole-show TV id: `tv_{showId}` (web `tmdbService.ts:1334`).
    public static func showId(_ showTmdbID: Int) -> String { "tv_\(showTmdbID)" }

    /// Season TV id: `tv_{showId}_s{n}` (web `AddTVSeasonModal.tsx:331`).
    public static func tvSeasonId(showId: Int, season: Int) -> String {
        "tv_\(showId)_s\(season)"
    }

    /// Book watchlist id: `ol_{workKey}`.
    public static func bookId(_ workKey: String) -> String { "ol_\(workKey)" }

    /// Postgres table backing each media type.
    public static func tableName(for media: WatchlistMediaType) -> String {
        switch media {
        case .movie: return "watchlist_items"
        case .tv: return "tv_watchlist_items"
        case .book: return "book_watchlist_items"
        }
    }

    // MARK: whole-show detection (D6)

    /// A TV bookmark is a WHOLE show when its `season_number` is NULL (schema
    /// intent) OR 0 (the web writer's coalesced value). Treat BOTH.
    public static func isWholeShow(seasonNumber: Int?) -> Bool {
        seasonNumber == nil || seasonNumber == 0
    }

    // MARK: §1.4 TV exclusion-id expansion

    /// Expand one id into the ids an exclusion set must contain. A season id
    /// `tv_{n}_s{m}` yields BOTH itself AND the show-level id `tv_{n}` (the TV
    /// engine excludes on show ids — `AddTVSeasonModal.tsx:86-89`,
    /// audit §1.4). Every other id (whole-show `tv_{n}`, movie `tmdb_{n}`,
    /// book `ol_{key}`) passes through unchanged.
    public static func expandExclusionIds(for id: String) -> [String] {
        guard let showID = seasonIdShowLevel(id) else { return [id] }
        return [id, showID]
    }

    /// Fold `expandExclusionIds` over a whole collection into a deduped Set —
    /// the shape `allBookmarkedIds` returns. Season ids contribute their show
    /// id too; overlapping show ids collapse.
    public static func expandedBookmarkedIds(_ ids: some Sequence<String>) -> Set<String> {
        var out = Set<String>()
        for id in ids { out.formUnion(expandExclusionIds(for: id)) }
        return out
    }

    /// If `id` is a season id `tv_{n}_s{m}`, return its show-level id `tv_{n}`;
    /// otherwise nil. Matches the web regex `/^tv_(\d+)_s\d+$/`.
    private static func seasonIdShowLevel(_ id: String) -> String? {
        guard id.hasPrefix("tv_"), let sRange = id.range(of: "_s", options: .backwards)
        else { return nil }
        let showPart = String(id[..<sRange.lowerBound])            // "tv_1399"
        let seasonPart = String(id[sRange.upperBound...])          // "1"
        // Digits after "tv_" and after "_s" — reject "tv_abc_sX" / "tv_1399_s".
        let digits = showPart.dropFirst(3)                          // after "tv_"
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber),
              !seasonPart.isEmpty, seasonPart.allSatisfy(\.isNumber)
        else { return nil }
        return showPart
    }

    // MARK: row → model mappers (no silent drops)

    /// `watchlist_items` row → `WatchlistItem`. Coalesces null year/poster to
    /// `''` and null genres to `[]` (web `rowToWatchlistItem`). Unknown `type`
    /// falls back to `.movie` (this is the movie table). Bad timestamp →
    /// `.distantPast` (the row still surfaces; ordering already came from the
    /// query's `added_at desc`).
    public static func mapMovieRow(_ row: WatchlistRow) -> WatchlistItem? {
        WatchlistItem(
            id: row.tmdb_id,
            title: row.title,
            year: row.year ?? "",
            posterUrl: row.poster_url ?? "",
            mediaType: WatchlistMediaType(dbType: row.type) ?? .movie,
            genres: row.genres ?? [],
            addedAt: parseAddedAt(row.added_at),
            director: row.director
        )
    }

    /// `tv_watchlist_items` row → `WatchlistItem`. REJECTS (returns nil) rows
    /// with `show_tmdb_id = 0` — corrupt legacy that must never propagate
    /// (audit B2). Whole-show rows (`season_number` 0 or NULL) map through with
    /// `isWholeShow == true`.
    public static func mapTVRow(_ row: TVWatchlistRow) -> WatchlistItem? {
        guard row.show_tmdb_id != 0 else {
            NSLog("[WatchlistRepository] rejecting corrupt TV row (show_tmdb_id=0): tmdb_id=\(row.tmdb_id)")
            return nil
        }
        return WatchlistItem(
            id: row.tmdb_id,
            title: row.title,
            year: row.year ?? "",
            posterUrl: row.poster_url ?? "",
            mediaType: .tv,
            genres: row.genres ?? [],
            addedAt: parseAddedAt(row.added_at),
            creator: row.creator,
            showTmdbId: row.show_tmdb_id,
            seasonNumber: row.season_number,
            seasonTitle: row.season_title
        )
    }

    /// `book_watchlist_items` row → `WatchlistItem` (web `rowToBookWatchlistItem`).
    public static func mapBookRow(_ row: BookWatchlistRow) -> WatchlistItem? {
        WatchlistItem(
            id: row.tmdb_id,
            title: row.title,
            year: row.year ?? "",
            posterUrl: row.poster_url ?? "",
            mediaType: .book,
            genres: row.genres ?? [],
            addedAt: parseAddedAt(row.added_at),
            author: row.author,
            pageCount: row.page_count,
            isbn: row.isbn,
            olWorkKey: row.ol_work_key,
            olRatingsAverage: row.ol_ratings_average
        )
    }

    // MARK: add-payload builders (wire shape — NO added_at, DB default)

    /// `watchlist_items` upsert payload — the 8 client columns the web sends
    /// (`RankingAppPage.tsx:646-655`). `type` is always `'movie'`; `added_at`
    /// is never sent (DB `default now()`).
    public static func movieAddPayload(_ item: WatchlistItem, userID: UUID) -> MovieAddPayload {
        MovieAddPayload(
            user_id: userID.uuidString.lowercased(),
            tmdb_id: item.id,
            title: item.title,
            year: item.year,
            poster_url: item.posterUrl,
            type: WatchlistMediaType.movie.dbType,
            genres: item.genres,
            director: item.director
        )
    }

    /// `tv_watchlist_items` upsert payload (`RankingAppPage.tsx:685-697`).
    /// `show_tmdb_id`/`season_number` coalesce nil to 0 (web `?? 0`);
    /// `type` = `'tv_season'`.
    public static func tvAddPayload(_ item: WatchlistItem, userID: UUID) -> TVAddPayload {
        TVAddPayload(
            user_id: userID.uuidString.lowercased(),
            tmdb_id: item.id,
            show_tmdb_id: item.showTmdbId ?? 0,
            season_number: item.seasonNumber ?? 0,
            title: item.title,
            season_title: item.seasonTitle,
            year: item.year,
            poster_url: item.posterUrl,
            type: WatchlistMediaType.tv.dbType,
            genres: item.genres,
            creator: item.creator
        )
    }

    /// `book_watchlist_items` upsert payload (`RankingAppPage.tsx:1184-1191`).
    public static func bookAddPayload(_ item: WatchlistItem, userID: UUID) -> BookAddPayload {
        BookAddPayload(
            user_id: userID.uuidString.lowercased(),
            tmdb_id: item.id,
            title: item.title,
            year: item.year,
            poster_url: item.posterUrl,
            type: WatchlistMediaType.book.dbType,
            genres: item.genres,
            author: item.author,
            page_count: item.pageCount,
            isbn: item.isbn,
            ol_work_key: item.olWorkKey,
            ol_ratings_average: item.olRatingsAverage
        )
    }

    // MARK: timestamp parsing

    /// PostgREST timestamptz → Date, tolerating fractional seconds or none
    /// (same fallback FeedCards uses). A genuinely unparseable value maps to
    /// `.distantPast` so the row still surfaces (the query already ordered by
    /// `added_at desc`; the model just can't re-sort a bad value correctly).
    static func parseAddedAt(_ raw: String) -> Date {
        isoFractional.date(from: raw) ?? isoPlain.date(from: raw) ?? .distantPast
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    // MARK: - Encodable payloads (snake_case for PostgREST)

    /// `watchlist_items` upsert body. Optionals encode EXPLICIT null (parity
    /// with the web `director ?? null`) so the UPSERT-UPDATE path clears the
    /// column rather than leaving a stale value; synthesized Encodable would
    /// omit nil, hence the custom `encode(to:)`. `added_at` is absent by
    /// construction (DB `default now()`).
    public struct MovieAddPayload: Encodable, Equatable {
        public let user_id: String
        public let tmdb_id: String
        public let title: String
        public let year: String
        public let poster_url: String
        public let type: String
        public let genres: [String]
        public let director: String?

        enum CodingKeys: String, CodingKey {
            case user_id, tmdb_id, title, year, poster_url, type, genres, director
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(user_id, forKey: .user_id)
            try c.encode(tmdb_id, forKey: .tmdb_id)
            try c.encode(title, forKey: .title)
            try c.encode(year, forKey: .year)
            try c.encode(poster_url, forKey: .poster_url)
            try c.encode(type, forKey: .type)
            try c.encode(genres, forKey: .genres)
            try c.encode(director, forKey: .director)   // explicit null when nil
        }
    }

    /// `tv_watchlist_items` upsert body. Optionals encode explicit null (web
    /// `?? null`); `show_tmdb_id`/`season_number` are non-optional (coalesced
    /// to 0 by the builder).
    public struct TVAddPayload: Encodable, Equatable {
        public let user_id: String
        public let tmdb_id: String
        public let show_tmdb_id: Int
        public let season_number: Int
        public let title: String
        public let season_title: String?
        public let year: String
        public let poster_url: String
        public let type: String
        public let genres: [String]
        public let creator: String?

        enum CodingKeys: String, CodingKey {
            case user_id, tmdb_id, show_tmdb_id, season_number, title,
                 season_title, year, poster_url, type, genres, creator
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(user_id, forKey: .user_id)
            try c.encode(tmdb_id, forKey: .tmdb_id)
            try c.encode(show_tmdb_id, forKey: .show_tmdb_id)
            try c.encode(season_number, forKey: .season_number)
            try c.encode(title, forKey: .title)
            try c.encode(season_title, forKey: .season_title)   // explicit null
            try c.encode(year, forKey: .year)
            try c.encode(poster_url, forKey: .poster_url)
            try c.encode(type, forKey: .type)
            try c.encode(genres, forKey: .genres)
            try c.encode(creator, forKey: .creator)             // explicit null
        }
    }

    /// `book_watchlist_items` upsert body. Optionals encode explicit null (web
    /// `?? null`).
    public struct BookAddPayload: Encodable, Equatable {
        public let user_id: String
        public let tmdb_id: String
        public let title: String
        public let year: String
        public let poster_url: String
        public let type: String
        public let genres: [String]
        public let author: String?
        public let page_count: Int?
        public let isbn: String?
        public let ol_work_key: String?
        public let ol_ratings_average: Double?

        enum CodingKeys: String, CodingKey {
            case user_id, tmdb_id, title, year, poster_url, type, genres,
                 author, page_count, isbn, ol_work_key, ol_ratings_average
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(user_id, forKey: .user_id)
            try c.encode(tmdb_id, forKey: .tmdb_id)
            try c.encode(title, forKey: .title)
            try c.encode(year, forKey: .year)
            try c.encode(poster_url, forKey: .poster_url)
            try c.encode(type, forKey: .type)
            try c.encode(genres, forKey: .genres)
            try c.encode(author, forKey: .author)                       // explicit null
            try c.encode(page_count, forKey: .page_count)               // explicit null
            try c.encode(isbn, forKey: .isbn)                           // explicit null
            try c.encode(ol_work_key, forKey: .ol_work_key)             // explicit null
            try c.encode(ol_ratings_average, forKey: .ol_ratings_average) // explicit null
        }
    }
}
