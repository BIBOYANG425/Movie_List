import Foundation
import Supabase

/// TMDB search/details client — proxy-routed. Mirror of `services/tmdbService.ts`
/// (search + details seams), same endpoints, same response shapes.
///
/// The iOS bundle no longer holds a TMDB key. Every TMDB request goes through the
/// authenticated `tmdb-proxy` edge function (see `TMDBProxy`): the proxy injects
/// `TMDB_API_KEY` server-side and enforces a path allowlist. Requests carry the
/// caller's Supabase session JWT (Bearer) + the anon `apikey` header, mirroring
/// how web's `proxyRequest` invokes the proxy. Signed-out callers have no session,
/// so `proxyFetch` short-circuits to a synthetic 401 WITHOUT hitting the network —
/// every consumer already treats a non-ok response as "no results", preserving the
/// pre-migration signed-out behavior (empty → callers fall back to fixtures/no-results).
///
/// The 5-pool suggestion engine (getGenericSuggestions + discover pools) moved
/// server-side into the `suggestions` edge function (see `SuggestionsClient`).
/// Only the seams that still have client callers remain here: search + movie
/// details (`vote_average` enrichment).
///
/// Header last reviewed: 2026-07-10
public enum TMDBService {

    public static let imageBase = "https://image.tmdb.org/t/p/w500"
    public static let defaultTimeout: TimeInterval = 4.5

    /// Whether the proxy path is reachable at all — i.e. the Supabase client is
    /// configured. When false the app is in credential-free preview mode: TMDB is
    /// unreachable and callers fall back to their local fixtures (mirrors the old
    /// `hasKey`-gated demo path, now keyed on backend config instead of a bundled
    /// TMDB key that no longer exists).
    public static var hasKey: Bool {
        SpoolClient.isConfigured
    }

    // MARK: - Proxy fetch seam

    /// Route a bare TMDB path (with its own query string, minus api_key) through
    /// the tmdb-proxy edge function using the caller's session JWT.
    ///
    /// A signed-out caller (no session / no client) yields a synthetic 401
    /// `(Data, HTTPURLResponse)` WITHOUT hitting the network — callers already
    /// read non-2xx as empty, so this is the signed-out gate. Any proxy non-2xx
    /// (401/403/429/502) is surfaced verbatim to the caller's status check, which
    /// keeps typo-retry's "non-2xx skips variants" rule intact now that proxy
    /// statuses stand in for the old direct-TMDB statuses.
    ///
    /// Throws only on transport failure / cancellation (mirroring `URLSession`),
    /// which callers already swallow to `[]`.
    private static func proxyFetch(_ tmdbPath: String, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        guard let client = SpoolClient.shared else {
            return synthetic401()
        }
        guard
            let session = try? await client.auth.session,
            !session.accessToken.isEmpty,
            let supabaseURL = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let anonKey = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String
        else {
            // Signed out (or config gone) — no session to authenticate the proxy.
            // Synthetic 401 so every caller's non-ok branch yields empty as before.
            return synthetic401()
        }

        let urlString = TMDBProxy.buildProxyURL(supabaseURL: supabaseURL, tmdbPath: tmdbPath)
        guard let url = URL(string: urlString) else { return synthetic401() }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        // A non-HTTP response is treated as a hard failure (unexpected transport).
        guard let http = response as? HTTPURLResponse else { return synthetic401() }
        return (data, http)
    }

    /// A synthetic 401 response used for the signed-out / unconfigured gate — no
    /// network is touched. `URL` is a stable placeholder never dereferenced.
    private static func synthetic401() -> (Data, HTTPURLResponse) {
        let http = HTTPURLResponse(
            url: URL(string: "https://spool.invalid/unauthenticated")!,
            statusCode: 401, httpVersion: nil, headerFields: nil
        )!
        return (Data(#"{"error":"Not authenticated"}"#.utf8), http)
    }

    // MARK: /movie/{id} — minimal details (vote_average enrichment)

    /// Fetch just the `vote_average` for a movie by its numeric TMDB id. Used by
    /// the C3 rank-from-watchlist path (Task 4): a `WatchlistItem` doesn't carry
    /// the 0-10 rating, and dropping it regresses the ranking engine's prediction
    /// signal for new users (see `Movie.voteAverage`). The normal search→rank
    /// path already has this from the search result; this backfills it for the
    /// watchlist path. Best-effort: returns `nil` on signed-out / HTTP error /
    /// transport failure so the caller falls back to a nil `voteAverage` (the
    /// engine then uses the tier midpoint, exactly as before this field existed).
    public static func movieVoteAverage(tmdbId: Int, timeout: TimeInterval = defaultTimeout) async -> Double? {
        let path = "movie/\(tmdbId)?language=\(locale())"
        do {
            let (data, http) = try await proxyFetch(path, timeout: timeout)
            guard http.statusCode == 200 else { return nil }
            let detail = try JSONDecoder().decode(TMDBDetailResponse.self, from: data)
            return detail.voteAverage
        } catch {
            return nil
        }
    }

    private struct TMDBDetailResponse: Decodable {
        let voteAverage: Double?
        enum CodingKeys: String, CodingKey {
            case voteAverage = "vote_average"
        }
    }

    // MARK: /search/movie

    /// Returns at most 12 posters-only results, newest-first by TMDB's default
    /// relevance ordering. Swallow all errors into `[]` — search is best-effort.
    ///
    /// Zero-result typo-retry backoff (mirror of web `searchMovies` in
    /// `services/tmdbService.ts`): when the primary query maps to no results, we
    /// retry with the cheap deterministic variants from `typoRetryVariants`,
    /// cheapest-first, and take the first non-empty set. An HTTP-error (non-2xx)
    /// response does NOT trigger or continue the variant loop — that distinguishes
    /// a real zero-result from a proxy 401/403/429/502 so we don't hammer the proxy.
    /// Between variant requests we honor `Task` cancellation: debounced callers
    /// cancel stale searches, and a cancelled search must not fire more requests.
    public static func searchMovies(query: String, timeout: TimeInterval = defaultTimeout) async -> [TMDBMovie] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // One fetch+map for a single query term. Reused verbatim by the retry
        // loop so retries share the exact request/mapping path. Returns `nil` on
        // a non-ok HTTP response so the caller can distinguish a real zero-result
        // from an HTTP error and skip the variant loop. Throws on transport
        // errors / cancellation, which the caller swallows to `[]`.
        func fetchAndMap(_ term: String) async throws -> [TMDBMovie]? {
            // Pack the TMDB query into the proxy `path` param (buildProxyURL
            // handles encoding). api_key is never sent — the proxy injects it.
            let path = buildSearchQuery(term: term)

            let (data, http) = try await proxyFetch(path, timeout: timeout)
            guard http.statusCode == 200 else { return nil }
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

    // MARK: /search/tv

    /// TV-show search — same shape and best-effort contract as `searchMovies`,
    /// mirror of web `searchTVShows` (`services/tmdbService.ts`).
    ///
    /// Poster filter parity: web filters `results` to entries WITH a `poster_path`
    /// (`.filter(s => s.poster_path)`) BEFORE the 12-cap, so a posterless show is
    /// dropped and does NOT consume a slot. The movie mapper instead drops
    /// posterless rows in `compactMap` after `prefix(12)` — a subtle difference, so
    /// here we replicate the web TV behavior exactly: filter first, then cap at 12.
    ///
    /// Zero-result typo-retry backoff shares the exact same `typoRetryVariants`
    /// loop as `searchMovies`: HTTP-error (non-2xx) bails without retrying, a real
    /// zero-result retries cheapest-first taking the first non-empty set, and
    /// `Task.checkCancellation()` runs between variants so a cancelled (debounced)
    /// search fires no further requests.
    public static func searchTVShows(query: String, timeout: TimeInterval = defaultTimeout) async -> [TMDBTVShow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        func fetchAndMap(_ term: String) async throws -> [TMDBTVShow]? {
            let path = buildTVSearchQuery(term: term)
            let (data, http) = try await proxyFetch(path, timeout: timeout)
            guard http.statusCode == 200 else { return nil }
            let wrapper = try JSONDecoder().decode(TMDBTVSearchResponse.self, from: data)
            // Poster filter FIRST, then cap at 12 (web parity).
            return wrapper.results
                .filter { $0.posterPath != nil }
                .prefix(12)
                .map(mapTVSearchResult)
        }

        do {
            let primary = try await fetchAndMap(trimmed)
            guard let primary else { return [] }
            if !primary.isEmpty { return primary }

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

    // MARK: /tv/{id} — full show details (seasons array)

    /// Full TV show details incl. the seasons list. Mirror of web
    /// `getTVShowDetails`. Filters out season 0 ("Specials", D6) so the season
    /// grid only shows numbered seasons; `seasonCount` reflects that filtered
    /// count. `genres` are the RAW TMDB genre names from the detail payload
    /// (`genres[].name`), not id-mapped — normalization is a separate step.
    /// `creators` are the `created_by[].name` entries. Best-effort: `nil` on
    /// signed-out / HTTP error / transport failure.
    public static func getTVShowDetails(showId: Int, timeout: TimeInterval = 5.0) async -> TMDBTVShow? {
        guard showId != 0 else { return nil }
        let path = "tv/\(showId)?language=\(locale())"
        do {
            let (data, http) = try await proxyFetch(path, timeout: timeout)
            guard http.statusCode == 200 else { return nil }
            let detail = try JSONDecoder().decode(TMDBTVDetailRaw.self, from: data)
            return mapTVDetail(detail)
        } catch {
            return nil
        }
    }

    /// Pure mapper for a decoded `tv/{id}` payload → `TMDBTVShow`. Extracted so
    /// the season-0 filter + shape can be tested against a fixture without a
    /// network round-trip.
    static func mapTVDetail(_ detail: TMDBTVDetailRaw) -> TMDBTVShow {
        let seasons: [TMDBTVSeasonSummary] = (detail.seasons ?? [])
            .filter { $0.seasonNumber > 0 }
            .map { s in
                TMDBTVSeasonSummary(
                    seasonNumber: s.seasonNumber,
                    name: s.name,
                    posterUrl: s.posterPath.map { "\(imageBase)\($0)" },
                    episodeCount: s.episodeCount ?? 0,
                    airDate: s.airDate
                )
            }
        return TMDBTVShow(
            id: "tv_\(detail.id)",
            tmdbId: detail.id,
            name: detail.name,
            year: detail.firstAirDate.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } ?? "—",
            posterUrl: detail.posterPath.map { "\(imageBase)\($0)" },
            backdropUrl: detail.backdropPath.map { "\(imageBase)\($0)" },
            genres: (detail.genres ?? []).map(\.name),
            overview: detail.overview ?? "",
            seasonCount: seasons.count,
            status: detail.status ?? "",
            creators: (detail.createdBy ?? []).map(\.name),
            voteAverage: detail.voteAverage,
            seasons: seasons
        )
    }

    // MARK: /tv/{id}/season/{n} — one season's detail

    /// Details for a single season. Mirror of web `getTVSeasonDetails`.
    /// `episodeCount` is the length of the returned `episodes` array (web parity —
    /// web uses `data.episodes.length`, NOT a summary `episode_count`). `name`
    /// falls back to `"Season {n}"` when TMDB omits it. `showName` is passed
    /// through unchanged for the ceremony header. Best-effort: `nil` on
    /// signed-out / HTTP error / transport failure.
    public static func getTVSeasonDetails(
        showId: Int, seasonNumber: Int, showName: String = "", timeout: TimeInterval = 5.0
    ) async -> TMDBTVSeason? {
        guard showId != 0 else { return nil }
        let path = "tv/\(showId)/season/\(seasonNumber)?language=\(locale())"
        do {
            let (data, http) = try await proxyFetch(path, timeout: timeout)
            guard http.statusCode == 200 else { return nil }
            let raw = try JSONDecoder().decode(TMDBTVSeasonRaw.self, from: data)
            return mapTVSeason(raw, showId: showId, requestedSeason: seasonNumber, showName: showName)
        } catch {
            return nil
        }
    }

    /// Pure mapper for a decoded `tv/{id}/season/{n}` payload → `TMDBTVSeason`.
    static func mapTVSeason(
        _ raw: TMDBTVSeasonRaw, showId: Int, requestedSeason: Int, showName: String
    ) -> TMDBTVSeason {
        TMDBTVSeason(
            id: raw.id,
            showTmdbId: showId,
            seasonNumber: raw.seasonNumber,
            name: raw.name ?? "Season \(requestedSeason)",
            showName: showName,
            posterUrl: raw.posterPath.map { "\(imageBase)\($0)" },
            episodeCount: (raw.episodes ?? []).count,
            airDate: raw.airDate,
            overview: raw.overview ?? ""
        )
    }

    // MARK: /tv/{id} — global score (vote_average only)

    /// Global average score (`vote_average`) for a TV show. Mirror of web
    /// `getTVShowGlobalScore` and the same shape as `movieVoteAverage`. Returns
    /// `nil` on signed-out / HTTP error / transport failure so the caller falls
    /// back to a nil score (engine uses the tier midpoint).
    public static func tvShowGlobalScore(showId: Int, timeout: TimeInterval = defaultTimeout) async -> Double? {
        guard showId != 0 else { return nil }
        let path = "tv/\(showId)?language=\(locale())"
        do {
            let (data, http) = try await proxyFetch(path, timeout: timeout)
            guard http.statusCode == 200 else { return nil }
            let detail = try JSONDecoder().decode(TMDBDetailResponse.self, from: data)
            return detail.voteAverage
        } catch {
            return nil
        }
    }

    // MARK: - Query builder

    /// Build the TMDB search path string for a given query term.
    ///
    /// Extracted from the inner `fetchAndMap` closure so it is unit-testable in
    /// isolation (see `testPlusInQueryIsEncodedAsPercent2B` in `OnbGridPoolTests`).
    ///
    /// `+` encoding note: `URLComponents.percentEncodedQuery` leaves `+` unencoded
    /// (RFC 3986 allows `+` as a literal `+` in query strings). However the proxy's
    /// `URLSearchParams` decodes `+` as a space (application/x-www-form-urlencoded
    /// convention). Force-encode `+` → `%2B` so a title like "9+1" arrives at the
    /// proxy intact. Web uses `URLSearchParams` which encodes `+` → `%2B` for the
    /// same reason — same byte-level outcome.
    static func buildSearchQuery(term: String) -> String {
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "query", value: term),
            URLQueryItem(name: "language", value: locale()),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "include_adult", value: "false"),
        ]
        let tmdbQuery = (comps.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
        return "search/movie?\(tmdbQuery)"
    }

    /// Build the TMDB TV-search path string. Same param set / encoding rules as
    /// `buildSearchQuery` (incl. the `+`→`%2B` fix) but against `search/tv`.
    static func buildTVSearchQuery(term: String) -> String {
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "query", value: term),
            URLQueryItem(name: "language", value: locale()),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "include_adult", value: "false"),
        ]
        let tmdbQuery = (comps.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
        return "search/tv?\(tmdbQuery)"
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

    // MARK: - TV decode + map

    /// Map a decoded `search/tv` result row → `TMDBTVShow`. Mirror of web's TV
    /// search mapper: `tv_<id>` show id, `name` (not `title`), first-air-date
    /// year, `mapTVGenres` for id→name, and `seasonCount`/`status`/`creators`
    /// left empty (not available in search results). Callers pre-filter posterless
    /// rows, so `posterPath` is expected present, but the mapper is null-safe.
    static func mapTVSearchResult(_ raw: TMDBTVRaw) -> TMDBTVShow {
        let year = raw.firstAirDate.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } ?? "—"
        return TMDBTVShow(
            id: "tv_\(raw.id)",
            tmdbId: raw.id,
            name: raw.name,
            year: year,
            posterUrl: raw.posterPath.map { "\(imageBase)\($0)" },
            backdropUrl: raw.backdropPath.map { "\(imageBase)\($0)" },
            genres: TMDBTVGenres.mapGenreIds(raw.genreIds ?? []),
            overview: raw.overview ?? "",
            seasonCount: 0,
            status: "",
            creators: [],
            voteAverage: raw.voteAverage,
            seasons: nil
        )
    }

    private struct TMDBTVSearchResponse: Decodable {
        let results: [TMDBTVRaw]
    }

    struct TMDBTVRaw: Decodable {
        let id: Int
        let name: String
        let firstAirDate: String?
        let posterPath: String?
        let backdropPath: String?
        let genreIds: [Int]?
        let overview: String?
        let voteAverage: Double?

        enum CodingKeys: String, CodingKey {
            case id, name, overview
            case firstAirDate = "first_air_date"
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case genreIds = "genre_ids"
            case voteAverage = "vote_average"
        }
    }

    /// Decoded `tv/{id}` detail payload. `genres` and `created_by` carry `name`s;
    /// `seasons` carries the per-season summaries (season 0 filtered downstream).
    struct TMDBTVDetailRaw: Decodable {
        let id: Int
        let name: String
        let firstAirDate: String?
        let posterPath: String?
        let backdropPath: String?
        let overview: String?
        let status: String?
        let voteAverage: Double?
        let genres: [NamedRaw]?
        let createdBy: [NamedRaw]?
        let seasons: [SeasonSummaryRaw]?

        enum CodingKeys: String, CodingKey {
            case id, name, overview, status, genres, seasons
            case firstAirDate = "first_air_date"
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case voteAverage = "vote_average"
            case createdBy = "created_by"
        }

        struct NamedRaw: Decodable { let name: String }

        struct SeasonSummaryRaw: Decodable {
            let seasonNumber: Int
            let name: String
            let posterPath: String?
            let episodeCount: Int?
            let airDate: String?

            enum CodingKeys: String, CodingKey {
                case name
                case seasonNumber = "season_number"
                case posterPath = "poster_path"
                case episodeCount = "episode_count"
                case airDate = "air_date"
            }
        }
    }

    /// Decoded `tv/{id}/season/{n}` payload. `episodeCount` is derived from the
    /// length of `episodes` (web parity), not a summary field.
    struct TMDBTVSeasonRaw: Decodable {
        let id: Int
        let seasonNumber: Int
        let name: String?
        let posterPath: String?
        let airDate: String?
        let overview: String?
        let episodes: [EpisodeRaw]?

        enum CodingKeys: String, CodingKey {
            case id, name, overview, episodes
            case seasonNumber = "season_number"
            case posterPath = "poster_path"
            case airDate = "air_date"
        }

        struct EpisodeRaw: Decodable {}
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
