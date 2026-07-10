import Foundation
import Supabase

/// Client for the `suggestions` edge function (C3 Part B, Task 5).
///
/// The 5-pool suggestion engine moved server-side (`supabase/functions/
/// suggestions/index.ts`): the function reads the caller's rankings + watchlist
/// under their forwarded JWT, builds the taste profile + exclusions, runs the
/// TMDB pools, and returns provenance-tagged items. The TMDB key never touches
/// the bundle. This client is the iOS half of that plumbing; the Discover grid
/// UI (Task 6) consumes it.
///
/// Contract mirror (`index.ts`):
///   request  {mediaType, mode, page, sessionExcludeIds?, poolSlots?, locale?, limit?}
///   response {items: [SuggestionItem], totalRanked}
///   errors   400 (bad body) / 401 (no/expired token) / 405 / 429 (rate) / 502 (upstream)
///
/// Auth: `functions.invoke` auto-attaches the session JWT (Bearer) + anon apikey
/// via the client's auth-state listener, exactly as web's
/// `supabase.functions.invoke('suggestions', …)` does. A signed-out caller has
/// no session, so `functions.invoke` would fall back to the anon key and the
/// function would 401. We short-circuit that BEFORE the network by throwing
/// `notAuthenticated` — Task 6 gates the Discover grid on a session, so this is
/// the explicit signed-out seam (parity with web's proxyFetch synthetic 401 and
/// the old key-gated engine returning empty).
///
/// Error posture: HTTP errors surface as `SuggestionsError.http(status:)` so the
/// Task 6 UI can distinguish 401 (empty state) from 429/502 (error banner),
/// mirroring web `fetchMovieSuggestionsWithProvenance`. Decode failures surface
/// as `.decoding`. Transport/network errors (offline, DNS, timeout — any
/// URLError or unexpected throw) surface as `.transport(Error)` so Task 6 can
/// distinguish connectivity failures from auth/http failures without catching
/// raw URLError. Cancellation propagates (never swallowed here).
///
/// Header last reviewed: 2026-07-10
public enum SuggestionsClient {

    public enum SuggestionsError: Error {
        /// No client configured (missing SUPABASE_URL / anon key).
        case notConfigured
        /// No signed-in session — the caller must gate on auth (Task 6).
        case notAuthenticated
        /// The function returned a non-2xx status (401/405/429/502/…).
        case http(status: Int)
        /// The response body could not be decoded to `SuggestionsResponse`.
        case decoding
        /// A transport-level failure (URLError offline, DNS, timeout, etc.).
        /// The wrapped error is the original so callers can inspect if needed,
        /// but `.transport` as a case is enough to distinguish from `http`/`decoding`.
        case transport(Error)
    }

    /// Invoke the `suggestions` edge function and decode its response.
    ///
    /// - Throws: `SuggestionsError.notConfigured` / `.notAuthenticated` before any
    ///   network call; `.http(status:)` on a non-2xx response; `.decoding` on a
    ///   malformed body; `.transport(Error)` on a URLError / connectivity failure;
    ///   `CancellationError` if the surrounding task is cancelled.
    public static func fetch(
        mode: SuggestionMode,
        mediaType: SuggestionMediaType,
        page: Int = 1,
        sessionExcludeIds: [String] = [],
        limit: Int? = nil
    ) async throws -> SuggestionsResponse {
        guard let client = SpoolClient.shared else {
            NSLog("[SuggestionsClient] fetch: no client (not configured)")
            throw SuggestionsError.notConfigured
        }

        // Signed-out gate: no session → throw before hitting the network so we
        // never send the bare anon key to the function (which would 401 anyway).
        guard (try? await client.auth.session) != nil else {
            NSLog("[SuggestionsClient] fetch: no session (not authenticated)")
            throw SuggestionsError.notAuthenticated
        }

        let body = SuggestionsRequest(
            mediaType: mediaType,
            mode: mode,
            page: page,
            // Cap client-side to match the server's SESSION_EXCLUDE_CAP (200) so
            // the payload stays small; the server also slices.
            sessionExcludeIds: Array(sessionExcludeIds.prefix(200)),
            locale: locale(),
            limit: limit
        )

        do {
            // functions.invoke throws FunctionsError.httpError on non-2xx and
            // auto-attaches JWT + apikey headers.
            let response: SuggestionsResponse = try await client.functions.invoke(
                "suggestions",
                options: FunctionInvokeOptions(body: body)
            )
            return response
        } catch let error as FunctionsError {
            switch error {
            case let .httpError(code, _):
                NSLog("[SuggestionsClient] fetch: http \(code)")
                throw SuggestionsError.http(status: code)
            case .relayError:
                NSLog("[SuggestionsClient] fetch: relay error")
                throw SuggestionsError.http(status: 502)
            }
        } catch let error as DecodingError {
            NSLog("[SuggestionsClient] fetch: decode failed (\(error))")
            throw SuggestionsError.decoding
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Transport failure (URLError offline, DNS, timeout, TLS, …).
            // Wrap in .transport so Task 6 can distinguish connectivity errors
            // from auth/http/decode errors without catching raw URLError.
            NSLog("[SuggestionsClient] fetch: transport error (\(error))")
            throw SuggestionsError.transport(error)
        }
    }

    /// TMDB `language=`-shaped locale, mirroring `TMDBService.locale()` /
    /// web `getTmdbLocale()`: Chinese → `zh-CN`, else `en-US`.
    ///
    /// Re-sourced from `LocaleStore.current` (Task 1) — the SAME single source of
    /// truth `TMDBService.locale()` reads and the Settings toggle writes. The old
    /// duplicated `Locale.preferredLanguages.first` device-read is gone so the
    /// in-app toggle re-routes suggestion content on the next fetch.
    static func locale() -> String {
        locale(for: LocaleStore.current)
    }

    /// Pure `SpoolLocale` → TMDB `language=` mapping, identical to
    /// `TMDBService.locale(for:)`. `.zh` → `zh-CN`, `.en` → `en-US`. Extracted so
    /// the mapping is unit-tested with no store / `Locale.preferredLanguages` read.
    static func locale(for locale: SpoolLocale) -> String {
        locale == .zh ? "zh-CN" : "en-US"
    }
}

// MARK: - Wire types

/// Media type the suggestion engine ranks (`mediaType` in the request).
public enum SuggestionMediaType: String, Codable, Sendable {
    case movie
    case tv
}

/// Engine mode (`mode` in the request). `new_releases` is movie-only server-side.
public enum SuggestionMode: String, Codable, Sendable {
    case suggestions
    case backfill
    case newReleases = "new_releases"
}

/// Engine provenance pool tag (mirrors `index.ts` §1.3 pool tags). Decoded
/// unknown-safe: a tag the client doesn't recognize becomes `.unknown(raw)`
/// rather than a decode failure, so a new server pool never crashes old clients.
public enum SuggestionPool: Codable, Sendable, Equatable, Hashable {
    case similar
    case taste
    case trending
    case variety
    case friend
    case generic
    case backfill
    case newRelease
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "similar": self = .similar
        case "taste": self = .taste
        case "trending": self = .trending
        case "variety": self = .variety
        case "friend": self = .friend
        case "generic": self = .generic
        case "backfill": self = .backfill
        case "new_release": self = .newRelease
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The server-wire string for this pool.
    public var rawValue: String {
        switch self {
        case .similar: "similar"
        case .taste: "taste"
        case .trending: "trending"
        case .variety: "variety"
        case .friend: "friend"
        case .generic: "generic"
        case .backfill: "backfill"
        case .newRelease: "new_release"
        case let .unknown(raw): raw
        }
    }
}

/// Request body for the `suggestions` function. Optionals are omitted from the
/// JSON when nil (Swift's default `encodeIfPresent` behavior via the synthesized
/// encoder), matching what the server treats as absent.
public struct SuggestionsRequest: Codable, Sendable {
    public let mediaType: SuggestionMediaType
    public let mode: SuggestionMode
    public let page: Int
    public let sessionExcludeIds: [String]?
    public let locale: String?
    public let limit: Int?

    public init(
        mediaType: SuggestionMediaType,
        mode: SuggestionMode,
        page: Int,
        sessionExcludeIds: [String]?,
        locale: String?,
        limit: Int?
    ) {
        self.mediaType = mediaType
        self.mode = mode
        self.page = page
        self.sessionExcludeIds = sessionExcludeIds
        self.locale = locale
        self.limit = limit
    }
}

/// A single provenance-tagged suggestion (one `items[]` entry from `index.ts`
/// `toResponseItem`). Carries fields the Discover grid (Task 6) renders that the
/// legacy `TMDBMovie` DTO doesn't (`backdropUrl`, `mediaType`, `seasonCount`,
/// `pool`), so it is its own type rather than a reuse of `TMDBMovie`.
public struct SuggestionItem: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let tmdbId: Int
    public let title: String
    public let year: String
    public let posterUrl: String?
    public let backdropUrl: String?
    public let mediaType: SuggestionMediaType
    public let genres: [String]
    public let overview: String
    public let voteAverage: Double?
    public let seasonCount: Int
    public let pool: SuggestionPool?

    public init(
        id: String, tmdbId: Int, title: String, year: String,
        posterUrl: String?, backdropUrl: String?, mediaType: SuggestionMediaType,
        genres: [String], overview: String, voteAverage: Double?,
        seasonCount: Int, pool: SuggestionPool?
    ) {
        self.id = id
        self.tmdbId = tmdbId
        self.title = title
        self.year = year
        self.posterUrl = posterUrl
        self.backdropUrl = backdropUrl
        self.mediaType = mediaType
        self.genres = genres
        self.overview = overview
        self.voteAverage = voteAverage
        self.seasonCount = seasonCount
        self.pool = pool
    }
}

/// Top-level response envelope (`{items, totalRanked}` from `index.ts`).
public struct SuggestionsResponse: Codable, Sendable {
    public let items: [SuggestionItem]
    public let totalRanked: Int

    public init(items: [SuggestionItem], totalRanked: Int) {
        self.items = items
        self.totalRanked = totalRanked
    }
}
