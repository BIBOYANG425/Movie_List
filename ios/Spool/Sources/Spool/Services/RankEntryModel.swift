import Foundation

/// Which vertical the rank-entry screen is searching (C5-iOS Task 6). The
/// segmented `movie | tv | book` switch on `RankEntryScreen` drives this. Movie
/// is the default/leftmost so the pre-C5 movie flow is byte-identical.
public enum RankEntryMode: String, CaseIterable, Sendable, Hashable {
    case movie, tv, book

    /// The `RankMedia` the chosen rankable ends up with.
    public var rankMedia: RankMedia {
        switch self {
        case .movie: return .movie
        case .tv:    return .tv
        case .book:  return .book
        }
    }
}

/// The in-flow stage of the rank-entry screen. Movie/book modes stay on
/// `.search`; tv mode adds a `.seasonGrid` stage between picking a show and
/// entering the ceremony (the show search returns shows, the grid returns a
/// season). A pure enum so the entry state machine is testable.
public enum RankEntryStage: Equatable, Sendable {
    /// Searching within the current media (movie/tv/book results).
    case search
    /// A TV show was picked; showing its season grid. Carries the show + the
    /// loaded seasons + the show's global score + the already-ranked season
    /// numbers (disabled rows).
    case seasonGrid(show: TMDBTVShow)
}

/// Owns the rank-entry screen's media/stage state machine + the search &
/// season-loading IO (C5-iOS Task 6). Extracted from the view so the transitions
/// (mode switch resets stage + clears results; picking a show loads the grid;
/// picking a season builds the season `Movie`) are unit-testable with injected
/// closures instead of a live client.
///
/// SIGN-IN GATE: tv/book search requires sign-in (the fixture pool is
/// movie-shaped, and tv/book ranks write to Supabase). The model exposes
/// `requiresSignIn` per mode so the view shows the nudge instead of results.
///
/// Header last reviewed: 2026-07-10
@MainActor
public final class RankEntryModel: ObservableObject {

    // MARK: Injected IO

    public typealias SearchMovies = (String) async -> [TMDBMovie]
    public typealias SearchTV = (String) async -> [TMDBTVShow]
    public typealias SearchBooks = (String) async -> [OpenLibraryBook]
    /// Load a show's full detail (seasons list). Nil on failure.
    public typealias LoadShowDetails = (Int) async -> TMDBTVShow?
    /// Fetch the show's global score (seeds the season's `voteAverage`). Nil ok.
    public typealias LoadShowGlobalScore = (Int) async -> Double?
    /// Read the user's already-ranked tv ranking ids (disabled seasons). `[]` ok.
    public typealias LoadRankedTVIds = () async -> [String]
    /// Whether the user is signed in (tv/book require it).
    public typealias IsSignedIn = () -> Bool

    private let searchMoviesIO: SearchMovies
    private let searchTVIO: SearchTV
    private let searchBooksIO: SearchBooks
    private let loadShowDetailsIO: LoadShowDetails
    private let loadShowGlobalScoreIO: LoadShowGlobalScore
    private let loadRankedTVIdsIO: LoadRankedTVIds
    private let isSignedInIO: IsSignedIn

    // MARK: Published state

    @Published public private(set) var mode: RankEntryMode = .movie
    @Published public private(set) var stage: RankEntryStage = .search
    @Published public private(set) var isSearching: Bool = false

    @Published public private(set) var movieResults: [TMDBMovie] = []
    @Published public private(set) var tvResults: [TMDBTVShow] = []
    @Published public private(set) var bookResults: [OpenLibraryBook] = []

    /// The loaded seasons for the current `.seasonGrid` stage (Specials already
    /// filtered by `getTVShowDetails`).
    @Published public private(set) var seasons: [TMDBTVSeasonSummary] = []
    /// Season numbers of the current show ALREADY ranked (disabled in the grid).
    @Published public private(set) var rankedSeasonNumbers: Set<Int> = []
    /// The current show's global score (seeds the chosen season's `voteAverage`).
    @Published public private(set) var showGlobalScore: Double? = nil
    /// True while the season grid is loading its detail.
    @Published public private(set) var isLoadingSeasons: Bool = false

    private var searchTask: Task<Void, Never>? = nil
    private var seasonLoadTask: Task<Void, Never>? = nil
    /// Monotonic search generation so a stale async result is dropped.
    private var searchGeneration: Int = 0

    public init(
        searchMovies: @escaping SearchMovies = { await TMDBService.searchMovies(query: $0) },
        searchTV: @escaping SearchTV = { await TMDBService.searchTVShows(query: $0) },
        searchBooks: @escaping SearchBooks = { await OpenLibraryService.searchBooks(query: $0) },
        loadShowDetails: @escaping LoadShowDetails = { await TMDBService.getTVShowDetails(showId: $0) },
        loadShowGlobalScore: @escaping LoadShowGlobalScore = { await TMDBService.tvShowGlobalScore(showId: $0) },
        loadRankedTVIds: @escaping LoadRankedTVIds = {
            (try? await RankingRepository.shared.getAllRankedItems(media: "tv"))?.map(\.id) ?? []
        },
        isSignedIn: @escaping IsSignedIn = { SpoolClient.shared != nil }
    ) {
        self.searchMoviesIO = searchMovies
        self.searchTVIO = searchTV
        self.searchBooksIO = searchBooks
        self.loadShowDetailsIO = loadShowDetails
        self.loadShowGlobalScoreIO = loadShowGlobalScore
        self.loadRankedTVIdsIO = loadRankedTVIds
        self.isSignedInIO = isSignedIn
    }

    // MARK: Derived

    /// tv/book modes require sign-in (movie mode has a fixture fallback). The
    /// view shows a sign-in nudge instead of results when this is true.
    public var requiresSignIn: Bool {
        switch mode {
        case .movie: return false
        case .tv, .book: return !isSignedInIO()
        }
    }

    /// The placeholder for the current mode's search field.
    public var searchPlaceholder: String {
        switch mode {
        case .movie: return "search films…"
        case .tv:    return "search shows…"
        case .book:  return "search books…"
        }
    }

    // MARK: Mode switch

    /// Switch the search media. Resets the stage back to search, cancels any
    /// in-flight search / season load, and clears results (a stale movie result
    /// must never render under the tv segment). A no-op when the mode is
    /// unchanged so re-tapping the active pill doesn't clear a live search.
    public func setMode(_ newMode: RankEntryMode) {
        guard newMode != mode else { return }
        searchTask?.cancel()
        seasonLoadTask?.cancel()
        searchGeneration &+= 1
        mode = newMode
        stage = .search
        movieResults = []
        tvResults = []
        bookResults = []
        seasons = []
        rankedSeasonNumbers = []
        showGlobalScore = nil
        isSearching = false
        isLoadingSeasons = false
    }

    // MARK: Search (debounced by the view; the model runs the fetch)

    /// Run a search for the current mode. Cancels any prior search and bumps the
    /// generation so a stale async response is dropped. Empty/whitespace query
    /// clears results without a fetch. tv/book short-circuit to empty when signed
    /// out (the view shows the nudge). Debounce is the VIEW's job (the search
    /// field schedules this after a delay), matching the movie precedent.
    public func runSearch(_ raw: String) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        searchGeneration &+= 1
        let gen = searchGeneration

        guard !trimmed.isEmpty else {
            movieResults = []; tvResults = []; bookResults = []
            isSearching = false
            return
        }
        // Signed-out tv/book: no fetch (fixture pool is movie-shaped).
        if requiresSignIn {
            movieResults = []; tvResults = []; bookResults = []
            isSearching = false
            return
        }

        isSearching = true
        let currentMode = mode
        searchTask = Task { [weak self] in
            guard let self else { return }
            switch currentMode {
            case .movie:
                let r = await self.searchMoviesIO(trimmed)
                self.applyMovieResults(r, gen: gen, mode: currentMode)
            case .tv:
                let r = await self.searchTVIO(trimmed)
                self.applyTVResults(r, gen: gen, mode: currentMode)
            case .book:
                let r = await self.searchBooksIO(trimmed)
                self.applyBookResults(r, gen: gen, mode: currentMode)
            }
        }
    }

    private func applyMovieResults(_ r: [TMDBMovie], gen: Int, mode: RankEntryMode) {
        guard gen == searchGeneration, mode == self.mode else { return }
        movieResults = r; isSearching = false
    }
    private func applyTVResults(_ r: [TMDBTVShow], gen: Int, mode: RankEntryMode) {
        guard gen == searchGeneration, mode == self.mode else { return }
        tvResults = r; isSearching = false
    }
    private func applyBookResults(_ r: [OpenLibraryBook], gen: Int, mode: RankEntryMode) {
        guard gen == searchGeneration, mode == self.mode else { return }
        bookResults = r; isSearching = false
    }

    // MARK: TV: show → season grid

    /// The user tapped a show row. Enter the season-grid stage and load the
    /// show's detail (seasons — Specials already filtered), its global score, and
    /// the user's ranked season numbers (disabled rows) concurrently. A failed
    /// detail load leaves an empty grid (the view shows an empty/back state).
    public func pickShow(_ show: TMDBTVShow) {
        seasonLoadTask?.cancel()
        stage = .seasonGrid(show: show)
        seasons = []
        rankedSeasonNumbers = []
        showGlobalScore = nil
        isLoadingSeasons = true

        let showId = show.tmdbId
        seasonLoadTask = Task { [weak self] in
            guard let self else { return }
            async let detail = self.loadShowDetailsIO(showId)
            async let score = self.loadShowGlobalScoreIO(showId)
            async let rankedIds = self.loadRankedTVIdsIO()
            let (d, s, ids) = await (detail, score, rankedIds)
            self.applySeasonLoad(showId: showId, detail: d, score: s, rankedIds: ids)
        }
    }

    private func applySeasonLoad(showId: Int, detail: TMDBTVShow?, score: Double?, rankedIds: [String]) {
        // Drop a stale load if the user backed out or switched shows.
        guard case let .seasonGrid(show) = stage, show.tmdbId == showId else { return }
        seasons = detail?.seasons ?? []
        showGlobalScore = score
        rankedSeasonNumbers = TVPreselectRouter.rankedSeasonNumbers(
            showTmdbId: showId, rankedTVIds: rankedIds)
        isLoadingSeasons = false
    }

    /// Seed the season grid DIRECTLY for a known show id (the rank-from-watchlist
    /// whole-show path, C5-iOS Task 6). Unlike `pickShow`, the caller has only the
    /// numeric show id + a fallback name (from the bookmark), so we fetch the full
    /// detail first, THEN enter the grid stage with the real `TMDBTVShow`. On a
    /// failed detail load the stage is left at search-with-no-show (the screen
    /// shows an error / back). Used by `SeasonSelectScreen`.
    public func loadSeasonGrid(forShowId showId: Int, fallbackName: String) {
        seasonLoadTask?.cancel()
        mode = .tv
        seasons = []
        rankedSeasonNumbers = []
        showGlobalScore = nil
        isLoadingSeasons = true

        seasonLoadTask = Task { [weak self] in
            guard let self else { return }
            async let detail = self.loadShowDetailsIO(showId)
            async let score = self.loadShowGlobalScoreIO(showId)
            async let rankedIds = self.loadRankedTVIdsIO()
            let (d, s, ids) = await (detail, score, rankedIds)
            self.applyDirectSeasonLoad(
                showId: showId, fallbackName: fallbackName,
                detail: d, score: s, rankedIds: ids)
        }
    }

    private func applyDirectSeasonLoad(
        showId: Int, fallbackName: String,
        detail: TMDBTVShow?, score: Double?, rankedIds: [String]
    ) {
        // Build the grid stage's show from the detail, or a minimal placeholder
        // from the fallback name so the header + season construction still work.
        let show = detail ?? TMDBTVShow(
            id: "tv_\(showId)", tmdbId: showId, name: fallbackName, year: "",
            posterUrl: nil, backdropUrl: nil, genres: [], overview: "",
            seasonCount: 0, status: "", creators: [], voteAverage: score,
            seasons: [])
        stage = .seasonGrid(show: show)
        seasons = detail?.seasons ?? []
        showGlobalScore = score
        rankedSeasonNumbers = TVPreselectRouter.rankedSeasonNumbers(
            showTmdbId: showId, rankedTVIds: rankedIds)
        isLoadingSeasons = false
    }

    /// Back out of the season grid to the show search (keeps the search results).
    public func backToSearch() {
        seasonLoadTask?.cancel()
        stage = .search
        seasons = []
        rankedSeasonNumbers = []
        showGlobalScore = nil
        isLoadingSeasons = false
    }

    /// Build the rankable `Movie` for a chosen season summary. Returns nil if not
    /// in the season-grid stage or the season is already ranked (disabled). The
    /// caller passes the resulting Movie to `onPick` to enter the ceremony.
    public func seasonMovie(for summary: TMDBTVSeasonSummary) -> Movie? {
        guard case let .seasonGrid(show) = stage else { return nil }
        guard !rankedSeasonNumbers.contains(summary.seasonNumber) else { return nil }
        // Build a TMDBTVSeason from the summary (the grid has all we need; the
        // ceremony doesn't require the full episode list — episodeCount rides on
        // the summary). This avoids a second season-detail round-trip.
        let season = TMDBTVSeason(
            id: 0,
            showTmdbId: show.tmdbId,
            seasonNumber: summary.seasonNumber,
            name: summary.name,
            showName: show.name,
            posterUrl: summary.posterUrl,
            episodeCount: summary.episodeCount,
            airDate: summary.airDate,
            overview: ""
        )
        return Movie.tvSeason(show: show, season: season, showGlobalScore: showGlobalScore)
    }

    /// Build the rankable `Movie` for a chosen book.
    public func bookMovie(for book: OpenLibraryBook) -> Movie {
        Movie.book(book)
    }
}
