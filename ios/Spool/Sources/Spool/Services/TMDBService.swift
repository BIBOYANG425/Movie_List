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
    ///
    /// Zero-result typo-retry backoff (mirror of web `searchMovies` in
    /// `services/tmdbService.ts`): when the primary query maps to no results, we
    /// retry with the cheap deterministic variants from `typoRetryVariants`,
    /// cheapest-first, and take the first non-empty set. An HTTP-error (non-2xx)
    /// response does NOT trigger or continue the variant loop — that distinguishes
    /// a real zero-result from a 429/5xx/401 so we don't hammer TMDB. Between
    /// variant requests we honor `Task` cancellation: debounced callers cancel
    /// stale searches, and a cancelled search must not fire more requests.
    public static func searchMovies(query: String, timeout: TimeInterval = defaultTimeout) async -> [TMDBMovie] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = apiKey, !key.isEmpty, !trimmed.isEmpty else { return [] }

        // One fetch+map for a single query term. Reused verbatim by the retry
        // loop so retries share the exact request/mapping path. Returns `nil` on
        // a non-ok HTTP response so the caller can distinguish a real zero-result
        // from an HTTP error and skip the variant loop. Throws on transport
        // errors / cancellation, which the caller swallows to `[]`.
        func fetchAndMap(_ term: String) async throws -> [TMDBMovie]? {
            var comps = URLComponents(string: "\(base)/search/movie")!
            comps.queryItems = [
                URLQueryItem(name: "api_key", value: key),
                URLQueryItem(name: "query", value: term),
                URLQueryItem(name: "language", value: locale()),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "include_adult", value: "false"),
            ]
            guard let url = comps.url else { return [] }

            var req = URLRequest(url: url, timeoutInterval: timeout)
            req.httpMethod = "GET"

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let wrapper = try JSONDecoder().decode(TMDBSearchResponse.self, from: data)
            return wrapper.results.compactMap(mapResult).prefix(12).map { $0 }
        }

        do {
            let primary = try await fetchAndMap(trimmed)
            // nil means HTTP error — bail immediately, no variant loop.
            guard let primary else { return [] }
            if !primary.isEmpty { return primary }

            // Zero-result path only: retry with cheap typo variants, first
            // non-empty wins. A non-ok response during variants also stops the
            // loop. Bail immediately if the search was cancelled while awaiting.
            for variant in typoRetryVariants(query) {
                try Task.checkCancellation()
                let retry = try await fetchAndMap(variant)
                if retry == nil { break }
                if let retry, !retry.isEmpty { return retry }
            }

            return primary
        } catch {
            return []
        }
    }

    // MARK: - Typo-retry variants

    // Thresholds — kept 1:1 with web `services/searchVariants.ts`.
    private static let minQueryLen = 4
    private static let minChopTokenLen = 4
    private static let minDropRemainderLen = 3
    private static let maxVariants = 3

    /// Build up to 3 deduped retry variants for `q`, cheapest-first, never
    /// including the original normalized query. Pure port of web
    /// `services/searchVariants.ts` `typoRetryVariants` — same rules/thresholds.
    ///
    /// TMDB search has no typo tolerance ("shawshenk" -> 0 results) but strong
    /// prefix matching ("shawsh" -> hits). When a primary search returns nothing,
    /// `searchMovies` retries with these cheap deterministic variants and takes
    /// the first non-empty result set.
    ///
    /// Returns `[]` for queries that are too short (< 4 chars) or contain CJK
    /// (TMDB handles CJK; chopping CJK characters is nonsense).
    ///
    /// Variant order:
    ///   1. inner-whitespace collapse — only when the last token is a single stray char
    ///   2. last-token trailing chop by 1 then 2 chars — while the chopped token stays >= 4 chars
    ///   3. drop the last token entirely — only if >= 2 tokens and the remainder is >= 3 chars
    static func typoRetryVariants(_ q: String) -> [String] {
        // Trim + collapse any run of whitespace to a single space (web: `.trim().replace(/\s+/g, ' ')`).
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")

        if normalized.count < minQueryLen { return [] }
        if containsCJK(normalized) { return [] }

        var variants: [String] = []
        var seen: Set<String> = [normalized]

        func push(_ candidate: String) {
            if variants.count >= maxVariants { return }
            if candidate.isEmpty || seen.contains(candidate) { return }
            seen.insert(candidate)
            variants.append(candidate)
        }

        let tokens = normalized.split(separator: " ").map(String.init)

        // 1. Inner-whitespace collapse for the fat-finger stray-space case
        // (e.g. "matri x" -> "matrix"). Only when the last token is a single
        // stray character; two legitimate words ("dark knigt") must NOT be mashed.
        if tokens.count >= 2, tokens[tokens.count - 1].count == 1 {
            push(normalized.replacingOccurrences(of: " ", with: ""))
        }

        // 2. Progressive trailing-char chop on the last token ("shawshenk" ->
        // "shawshen" -> "shawshe"), stopping once the chopped token would fall
        // below 4 chars.
        let lastToken = tokens[tokens.count - 1]
        let prefix = tokens.dropLast().joined(separator: " ")
        for chop in 1...2 {
            guard lastToken.count - chop >= minChopTokenLen else { break }
            let chopped = String(lastToken.prefix(lastToken.count - chop))
            push(prefix.isEmpty ? chopped : "\(prefix) \(chopped)")
        }

        // 3. Drop the last token entirely, only for multi-token queries whose
        // remainder still carries enough signal (>= 3 chars).
        if tokens.count >= 2, prefix.count >= minDropRemainderLen {
            push(prefix)
        }

        return Array(variants.prefix(maxVariants))
    }

    /// Matches web regex `/[぀-ヿ㐀-鿿]/`: Hiragana/Katakana (U+3040–U+30FF) or
    /// CJK Unified Ideographs (U+3400–U+9FFF).
    private static func containsCJK(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) || (0x3400...0x9FFF).contains(v) {
                return true
            }
        }
        return false
    }

    // MARK: private

    /// TMDB `language=` code following the user's device locale, mirroring web
    /// `getTmdbLocale()` (`services/tmdbService.ts`) which maps the persisted
    /// `spool_locale` preference: Chinese -> `zh-CN`, everything else -> `en-US`.
    /// iOS has no in-app language toggle yet, so the device's preferred language
    /// is the source of truth for zh/en. `en-US` stays the fallback.
    private static func locale() -> String {
        let code = Locale.preferredLanguages.first
            ?? Locale.current.identifier
        return code.lowercased().hasPrefix("zh") ? "zh-CN" : "en-US"
    }

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
