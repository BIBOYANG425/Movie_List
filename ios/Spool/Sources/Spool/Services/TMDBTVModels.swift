import Foundation

/// Public TV DTOs + pure TV-genre helpers. Mirror of the TV section of
/// `services/tmdbService.ts` (`TMDBTVShow`, `TMDBTVSeasonSummary`, `TMDBTVSeason`,
/// `TV_GENRE_MAP`, `normalizeTVGenres`, `mapTVGenres`).
///
/// The genre table + normalization are pure functions so they can be unit-tested
/// entry-for-entry against the web table (see `TVGenreTests`). Keeping them out of
/// the network-touching `TMDBService` seam makes the parity diff obvious.
///
/// Header last reviewed: 2026-07-10

// MARK: - Public DTOs

/// A TV show as surfaced by search + details. Mirror of web `TMDBTVShow`.
/// `id` is the minted `"tv_<tmdbId>"` show id (parity with web's `tv_${s.id}`),
/// distinct from the movie `"tmdb_<id>"` namespace so the two never collide.
public struct TMDBTVShow: Codable, Sendable, Hashable, Identifiable {
    public let id: String              // "tv_<tmdbId>"
    public let tmdbId: Int
    public let name: String
    public let year: String
    public let posterUrl: String?
    public let backdropUrl: String?
    public let genres: [String]
    public let overview: String
    public let seasonCount: Int
    public let status: String
    public let creators: [String]
    public let voteAverage: Double?
    public let seasons: [TMDBTVSeasonSummary]?

    public init(id: String, tmdbId: Int, name: String, year: String,
                posterUrl: String?, backdropUrl: String?, genres: [String],
                overview: String, seasonCount: Int, status: String,
                creators: [String], voteAverage: Double?,
                seasons: [TMDBTVSeasonSummary]?) {
        self.id = id
        self.tmdbId = tmdbId
        self.name = name
        self.year = year
        self.posterUrl = posterUrl
        self.backdropUrl = backdropUrl
        self.genres = genres
        self.overview = overview
        self.seasonCount = seasonCount
        self.status = status
        self.creators = creators
        self.voteAverage = voteAverage
        self.seasons = seasons
    }
}

/// A season row in a show's season grid. Mirror of web `TMDBTVSeasonSummary`.
public struct TMDBTVSeasonSummary: Codable, Sendable, Hashable {
    public let seasonNumber: Int
    public let name: String
    public let posterUrl: String?
    public let episodeCount: Int
    public let airDate: String?

    public init(seasonNumber: Int, name: String, posterUrl: String?,
                episodeCount: Int, airDate: String?) {
        self.seasonNumber = seasonNumber
        self.name = name
        self.posterUrl = posterUrl
        self.episodeCount = episodeCount
        self.airDate = airDate
    }
}

/// Full detail for one season (the ceremony target). Mirror of web `TMDBTVSeason`.
public struct TMDBTVSeason: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let showTmdbId: Int
    public let seasonNumber: Int
    public let name: String
    public let showName: String
    public let posterUrl: String?
    public let episodeCount: Int
    public let airDate: String?
    public let overview: String

    public init(id: Int, showTmdbId: Int, seasonNumber: Int, name: String,
                showName: String, posterUrl: String?, episodeCount: Int,
                airDate: String?, overview: String) {
        self.id = id
        self.showTmdbId = showTmdbId
        self.seasonNumber = seasonNumber
        self.name = name
        self.showName = showName
        self.posterUrl = posterUrl
        self.episodeCount = episodeCount
        self.airDate = airDate
        self.overview = overview
    }
}

// MARK: - Pure TV genre helpers

public enum TMDBTVGenres {

    /// TMDB TV genre ID → name. Lifted entry-for-entry from web `TV_GENRE_MAP`
    /// (`services/tmdbService.ts`). NOTE: the TV genre namespace differs from the
    /// movie one — e.g. `16` is "Animation" in both, but `10759` "Action &
    /// Adventure", `10765` "Sci-Fi & Fantasy" and `10768` "War & Politics" are
    /// TV-only compound genres normalized below.
    public static let genreMap: [Int: String] = [
        10759: "Action & Adventure",
        16: "Animation",
        35: "Comedy",
        80: "Crime",
        99: "Documentary",
        18: "Drama",
        10751: "Family",
        10762: "Kids",
        9648: "Mystery",
        10763: "News",
        10764: "Reality",
        10765: "Sci-Fi & Fantasy",
        10766: "Soap",
        10767: "Talk",
        10768: "War & Politics",
        37: "Western",
    ]

    /// Map raw TMDB TV genre ids → display names, unknowns dropped, capped at 3.
    /// Mirror of web `mapTVGenres`.
    public static func mapGenreIds(_ genreIds: [Int]) -> [String] {
        let names = genreIds.compactMap { genreMap[$0] }
        return Array(names.prefix(3))
    }

    /// Normalize compound TV genre names to movie-compatible names for bracket
    /// classification. Mirror of web `normalizeTVGenres`:
    ///   "Action and Adventure" -> "Action" + "Adventure"
    ///   "Sci-Fi and Fantasy"   -> "Sci-Fi" + "Fantasy"
    ///   "War and Politics"     -> "War"
    ///   "Kids"                 -> "Family"
    ///   "Soap"                 -> "Drama"
    ///   "News", "Reality", "Talk" -> dropped (empty)
    /// Non-compound names pass through unchanged; dedupe preserving first-seen
    /// order, capped at 3. Empty input maps to empty output.
    public static func normalize(_ tvGenreNames: [String]) -> [String] {
        // Compound expansions; an empty value means "drop this genre entirely".
        let compound: [String: [String]] = [
            "Action & Adventure": ["Action", "Adventure"],
            "Sci-Fi & Fantasy": ["Sci-Fi", "Fantasy"],
            "War & Politics": ["War"],
            "Kids": ["Family"],
            "News": [],
            "Reality": [],
            "Soap": ["Drama"],
            "Talk": [],
        ]

        var result: [String] = []
        for g in tvGenreNames {
            if let expanded = compound[g] {
                result.append(contentsOf: expanded)
            } else {
                result.append(g)
            }
        }

        // Dedupe preserving first-seen order, then take up to 3.
        var seen: Set<String> = []
        var deduped: [String] = []
        for name in result where !seen.contains(name) {
            seen.insert(name)
            deduped.append(name)
        }
        return Array(deduped.prefix(3))
    }
}
