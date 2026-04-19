import Foundation

/// TMDB search client. Mirror of `services/tmdbService.ts` `searchMovies`
/// — same endpoint, same response shape.
///
/// Reads `TMDB_API_KEY` from `Info.plist`. Web exposes the key in the bundle
/// the same way (`VITE_TMDB_API_KEY`), so this matches the existing risk model.
/// When a backend edge-function proxy lands, swap this implementation without
/// changing call sites.
public enum TMDBService {

    public static let imageBase = "https://image.tmdb.org/t/p/w500"
    public static let defaultTimeout: TimeInterval = 4.5
    private static let base = "https://api.themoviedb.org/3"

    public static var hasKey: Bool {
        guard let key = apiKey, !key.isEmpty else { return false }
        return true
    }

    private static var apiKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String
    }

    /// Seed pool for brand-new users (taste profile not yet built).
    /// Mirror of web `getGenericSuggestions`: fetch recent popular (last 2y)
    /// + high-rated classics (older than 5y), interleave them, shuffle, cap at 12.
    /// Returns `[]` if TMDB key missing so callers can fall back to fixtures.
    public static func getGenericSuggestions(page: Int = 1, timeout: TimeInterval = defaultTimeout) async -> [TMDBMovie] {
        guard hasKey else { return [] }
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())

        async let recent: [TMDBMovie] = discover(
            sortBy: "popularity.desc",
            dateGTE: "\(year - 2)-01-01", dateLTE: nil,
            voteCountGTE: 50, page: page, timeout: timeout
        )
        async let classics: [TMDBMovie] = discover(
            sortBy: "vote_average.desc",
            dateGTE: nil, dateLTE: "\(year - 5)-12-31",
            voteCountGTE: 1000, page: page, timeout: timeout
        )
        let (r, c) = await (recent, classics)

        let newFilms = Array(r.prefix(6))
        let classicFilms = Array(c.prefix(6))
        let merged = interleave(newFilms, classicFilms)
        return Array(dedupByID(merged).prefix(12)).shuffled()
    }

    // MARK: /discover/movie

    private static func discover(
        sortBy: String, dateGTE: String?, dateLTE: String?,
        voteCountGTE: Int, page: Int, timeout: TimeInterval
    ) async -> [TMDBMovie] {
        guard let key = apiKey, !key.isEmpty else { return [] }
        var comps = URLComponents(string: "\(base)/discover/movie")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "language", value: locale()),
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "vote_count.gte", value: String(voteCountGTE)),
            URLQueryItem(name: "page", value: String(page)),
        ]
        if let d = dateGTE { items.append(URLQueryItem(name: "primary_release_date.gte", value: d)) }
        if let d = dateLTE { items.append(URLQueryItem(name: "primary_release_date.lte", value: d)) }
        comps.queryItems = items
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let wrapper = try JSONDecoder().decode(TMDBSearchResponse.self, from: data)
            return wrapper.results.compactMap(mapResult)
        } catch {
            return []
        }
    }

    private static func interleave(_ a: [TMDBMovie], _ b: [TMDBMovie]) -> [TMDBMovie] {
        var out: [TMDBMovie] = []
        let maxLen = max(a.count, b.count)
        for i in 0..<maxLen {
            if i < a.count { out.append(a[i]) }
            if i < b.count { out.append(b[i]) }
        }
        return out
    }

    private static func dedupByID(_ items: [TMDBMovie]) -> [TMDBMovie] {
        var seen = Set<Int>()
        var out: [TMDBMovie] = []
        for m in items where !seen.contains(m.tmdbId) {
            seen.insert(m.tmdbId)
            out.append(m)
        }
        return out
    }

    /// Returns at most 12 posters-only results, newest-first by TMDB's default
    /// relevance ordering. Swallow all errors into `[]` — search is best-effort.
    public static func searchMovies(query: String, timeout: TimeInterval = defaultTimeout) async -> [TMDBMovie] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = apiKey, !key.isEmpty, !trimmed.isEmpty else { return [] }

        var comps = URLComponents(string: "\(base)/search/movie")!
        comps.queryItems = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "language", value: locale()),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "include_adult", value: "false"),
        ]
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let wrapper = try JSONDecoder().decode(TMDBSearchResponse.self, from: data)
            return wrapper.results.compactMap(mapResult).prefix(12).map { $0 }
        } catch {
            return []
        }
    }

    // MARK: private

    private static func locale() -> String { "en-US" }

    private static func mapResult(_ raw: TMDBRaw) -> TMDBMovie? {
        guard let posterPath = raw.posterPath else { return nil }
        let year = raw.releaseDate.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } ?? "—"
        let genres = (raw.genreIds ?? []).compactMap { genreMap[$0] }.prefix(3).map { $0 }
        return TMDBMovie(
            id: "tmdb_\(raw.id)",
            tmdbId: raw.id,
            title: raw.title,
            year: year,
            posterUrl: "\(imageBase)\(posterPath)",
            genres: genres,
            overview: raw.overview ?? "",
            voteAverage: raw.voteAverage
        )
    }

    private struct TMDBSearchResponse: Decodable {
        let results: [TMDBRaw]
    }

    private struct TMDBRaw: Decodable {
        let id: Int
        let title: String
        let releaseDate: String?
        let posterPath: String?
        let genreIds: [Int]?
        let overview: String?
        let voteAverage: Double?

        enum CodingKeys: String, CodingKey {
            case id, title, overview
            case releaseDate = "release_date"
            case posterPath = "poster_path"
            case genreIds = "genre_ids"
            case voteAverage = "vote_average"
        }
    }

    // TMDB genre map — stable, lifted verbatim from web `GENRE_MAP`.
    private static let genreMap: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy",
        80: "Crime", 99: "Documentary", 18: "Drama", 10751: "Family",
        14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music",
        9648: "Mystery", 10749: "Romance", 878: "Sci-Fi", 10770: "TV Movie",
        53: "Thriller", 10752: "War", 37: "Western",
    ]
}

// MARK: - Public DTO

public struct TMDBMovie: Codable, Sendable, Hashable, Identifiable {
    public let id: String          // "tmdb_<tmdbId>"
    public let tmdbId: Int
    public let title: String
    public let year: String
    public let posterUrl: String?
    public let genres: [String]
    public let overview: String
    public let voteAverage: Double?

    public init(id: String, tmdbId: Int, title: String, year: String,
                posterUrl: String?, genres: [String], overview: String,
                voteAverage: Double?) {
        self.id = id
        self.tmdbId = tmdbId
        self.title = title
        self.year = year
        self.posterUrl = posterUrl
        self.genres = genres
        self.overview = overview
        self.voteAverage = voteAverage
    }
}
