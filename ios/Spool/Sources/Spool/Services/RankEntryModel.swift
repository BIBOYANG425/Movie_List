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
/// IN-FLOW SUGGESTIONS GRID (C5-iOS Task 7 for tv; C7-iOS Task 3 for movie): the
/// movie/tv search stage carries a suggestions grid below the empty search field,
/// consuming `SuggestionsClient.fetch(mediaType:)`. ONE media-parameterized
/// implementation drives both verticals (the `suggestionMediaType` seam maps the
/// mode → `.movie`/`.tv`). It replicates the web `AddMediaModal`/`AddTVSeasonModal`
/// choreography (suggestions + backfill prefetch, consume-splice on pick with
/// refill from the backfill pool, re-request backfill page+1 when the pool drops
/// below 3, Refresh = suggestions page+1, session excludes = consumed ids capped
/// 200). Divergence is only at the PICK and the render:
///   * tv — a picked SHOW routes into the season-grid flow (`pickShow`); the
///     excludes are SHOW ids `tv_{n}`.
///   * movie — a picked MOVIE goes STRAIGHT to the ceremony (`onPick`, no season
///     grid); `voteAverage` rides along so the ceremony's prediction seeds
///     (`RankEntryModel.rankMovie(from:)`); the excludes are movie ids `tmdb_{n}`.
///
/// The generic store is `[SuggestionItem]`; `tvSuggestions`/`movieSuggestions`
/// are typed projections over it so each render surface reads its own DTO and the
/// C5 tv tests keep their exact `tvSuggestions`/`pickSuggestedShow` API.
///
/// MEDIA ASYMMETRY: book mode is search-only (no engine). Movie mode ALSO keeps
/// its Discover-screen suggestions surface; this in-flow grid is the web-modal
/// parity surface (a picked movie → ceremony), independent of Discover.
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
    /// Fetch a page of suggestions/backfill for the in-flow grid (Task 7 tv;
    /// C7-iOS Task 3 movie). Media-parameterized so ONE closure serves both
    /// verticals. Throws so the model can map 401→empty vs other→error
    /// (Discover/T6 conventions).
    public typealias FetchSuggestions =
        (_ media: SuggestionMediaType, _ mode: SuggestionMode, _ page: Int, _ sessionExcludeIds: [String]) async throws -> [SuggestionItem]

    private let searchMoviesIO: SearchMovies
    private let searchTVIO: SearchTV
    private let searchBooksIO: SearchBooks
    private let loadShowDetailsIO: LoadShowDetails
    private let loadShowGlobalScoreIO: LoadShowGlobalScore
    private let loadRankedTVIdsIO: LoadRankedTVIds
    private let isSignedInIO: IsSignedIn
    private let fetchSuggestionsIO: FetchSuggestions

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

    // MARK: In-flow suggestions grid (Task 7 tv; C7-iOS Task 3 movie)

    /// The generic visible-grid store — raw engine items for the CURRENT mode's
    /// media. Consumed items are spliced out and refilled from `backfillPool`.
    /// Empty when signed out / not yet loaded / no suggestions returned. The typed
    /// `tvSuggestions`/`movieSuggestions` projections read off this so each render
    /// surface gets its own DTO without a second store.
    @Published public private(set) var suggestionItems: [SuggestionItem] = []

    /// The visible tv suggestions grid (SHOWS) — a typed projection of
    /// `suggestionItems` for the tv render + the C5 test API. Only meaningful in
    /// tv mode; empty otherwise.
    public var tvSuggestions: [TMDBTVShow] { suggestionItems.map(Self.show(from:)) }
    /// The visible movie suggestions grid — a typed projection of `suggestionItems`
    /// for the movie render + tests. Only meaningful in movie mode; empty otherwise.
    public var movieSuggestions: [TMDBMovie] { suggestionItems.map(Self.movieDTO(from:)) }

    /// True while the initial suggestions page is loading (skeleton state).
    @Published public private(set) var isLoadingTVSuggestions: Bool = false
    /// True once a backfill item has been mixed into the grid (web `hasBackfillMixed`
    /// — flips the header copy from "popular right now" to "based on your taste").
    @Published public private(set) var tvSuggestionsHasBackfill: Bool = false
    /// True when the last suggestions load hit a non-auth error (the grid shows a
    /// retry). 401/notAuthenticated map to a silent empty grid, not this flag.
    @Published public private(set) var tvSuggestionsFailed: Bool = false

    /// Prefetched backfill pool — the reservoir the consume-splice refills from.
    /// Generic items (media matches the current grid).
    private var backfillPool: [SuggestionItem] = []
    /// Session-consumed ids this session (`tv_{n}` shows in tv mode, `tmdb_{n}`
    /// movies in movie mode); the server excludes on these ids. Ordered so the cap
    /// keeps the most recent 200 (web parity).
    private var sessionExcludeIds: [String] = []
    /// The current suggestions page (Refresh advances it — web `page+1`).
    private var suggestionsPage = 1
    /// The current backfill page (re-request advances it when the pool drops <3).
    private var backfillPage = 1
    private var suggestionsTask: Task<Void, Never>? = nil
    private var backfillTask: Task<Void, Never>? = nil

    /// The server's session-exclude cap (mirrors `SuggestionsClient`'s prefix(200)
    /// and web `sessionExcludeRef` cap).
    static let sessionExcludeCap = 200
    /// Refill the backfill pool when it drops below this many items (web `< 3`).
    static let backfillRefillThreshold = 3

    private var searchTask: Task<Void, Never>? = nil
    private var seasonLoadTask: Task<Void, Never>? = nil
    /// Monotonic search generation so a stale async result is dropped.
    private var searchGeneration: Int = 0
    /// Monotonic suggestions generation so a stale suggestions/backfill load (after
    /// a Refresh or a mode switch) is dropped.
    private var suggestionsGeneration: Int = 0

    public init(
        searchMovies: @escaping SearchMovies = { await TMDBService.searchMovies(query: $0) },
        searchTV: @escaping SearchTV = { await TMDBService.searchTVShows(query: $0) },
        searchBooks: @escaping SearchBooks = { await OpenLibraryService.searchBooks(query: $0) },
        loadShowDetails: @escaping LoadShowDetails = { await TMDBService.getTVShowDetails(showId: $0) },
        loadShowGlobalScore: @escaping LoadShowGlobalScore = { await TMDBService.tvShowGlobalScore(showId: $0) },
        loadRankedTVIds: @escaping LoadRankedTVIds = {
            (try? await RankingRepository.shared.getAllRankedItems(media: "tv"))?.map(\.id) ?? []
        },
        isSignedIn: @escaping IsSignedIn = { SpoolClient.shared != nil },
        fetchTVSuggestions: @escaping FetchSuggestions = { media, mode, page, excludes in
            try await SuggestionsClient.fetch(
                mode: mode, mediaType: media, page: page, sessionExcludeIds: excludes
            ).items
        }
    ) {
        self.searchMoviesIO = searchMovies
        self.searchTVIO = searchTV
        self.searchBooksIO = searchBooks
        self.loadShowDetailsIO = loadShowDetails
        self.loadShowGlobalScoreIO = loadShowGlobalScore
        self.loadRankedTVIdsIO = loadRankedTVIds
        self.isSignedInIO = isSignedIn
        self.fetchSuggestionsIO = fetchTVSuggestions
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

    /// The engine media the in-flow suggestions grid fetches for the current mode.
    /// Movie and tv each have a grid; book has none (the caller gates on
    /// `modeHasSuggestionGrid` before reading this).
    var suggestionMediaType: SuggestionMediaType {
        mode == .movie ? .movie : .tv
    }

    /// Whether the current mode surfaces an in-flow suggestions grid. Movie + tv
    /// do (each maps to a `suggestionMediaType`); book is search-only. The grid
    /// ALSO requires a signed-in session (the engine 401s signed-out) — the view
    /// checks `suggestionsGateOpen`.
    var modeHasSuggestionGrid: Bool {
        mode == .movie || mode == .tv
    }

    /// Whether the suggestions grid may load for the current mode: the mode has a
    /// grid AND the caller is signed in. Movie mode's `requiresSignIn` is always
    /// false (it has a fixtures search fallback), so the grid can NOT gate on
    /// `requiresSignIn` — it gates on the raw session instead. tv mode's grid
    /// happens to coincide with `!requiresSignIn`, preserved byte-identically.
    var suggestionsGateOpen: Bool {
        modeHasSuggestionGrid && isSignedInIO()
    }

    /// The placeholder for the current mode's search field.
    public var searchPlaceholder: String {
        switch mode {
        case .movie: return L10n.t("rankEntry.searchFilms")
        case .tv:    return L10n.t("rankEntry.searchShows")
        case .book:  return L10n.t("rankEntry.searchBooks")
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
        // Leaving a grid mode tears the suggestions grid down; entering a grid
        // mode (movie/tv, signed in) loads it fresh. Book never shows a grid.
        // A mode switch crosses media (tv_ ↔ tmdb_ ids), so the per-session page
        // counter + excludes are media-specific — reset them so the new media's
        // grid starts at page 1 with a clean exclude set (web has separate modals
        // ⇒ separate refs; the shared model mirrors that by resetting on switch).
        // Within a mode, resetTVSuggestions still PRESERVES page/excludes so a
        // Refresh keeps advancing and re-entered picks keep their excludes.
        suggestionsPage = 1
        backfillPage = 1
        sessionExcludeIds = []
        resetTVSuggestions()
        loadTVSuggestions()
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

    // MARK: TV suggestions grid (Task 7)

    /// (Re)load the tv suggestions grid at the current `suggestionsPage`, and
    /// prefetch the backfill pool at page 1. Signed-out is a no-op (the view shows
    /// the sign-in nudge, and a suggestions fetch would 401). Mirrors web
    /// `loadInitialTVSuggestions`: suggestions is the visible grid, backfill is the
    /// silent reservoir consume-splice refills from. A `notAuthenticated`/401 error
    /// lands an empty grid (no retry); any other error flips `tvSuggestionsFailed`.
    public func loadTVSuggestions() {
        // Movie + tv modes have a grid; the engine requires a session (movie's
        // requiresSignIn is always false, so gate on the raw session via
        // suggestionsGateOpen — signed-out movie shows fixtures, no engine grid).
        guard suggestionsGateOpen else { resetTVSuggestions(); return }
        suggestionsTask?.cancel()
        backfillTask?.cancel()
        suggestionsGeneration &+= 1
        let gen = suggestionsGeneration

        isLoadingTVSuggestions = true
        tvSuggestionsHasBackfill = false
        tvSuggestionsFailed = false
        // Reset the backfill reservoir for a fresh page load (web parity).
        backfillPage = 1
        backfillPool = []

        let media = suggestionMediaType
        let page = suggestionsPage
        let excludes = sessionExcludeIds
        suggestionsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let items = try await self.fetchSuggestionsIO(media, .suggestions, page, excludes)
                self.applySuggestions(items, gen: gen)
            } catch {
                self.applySuggestionsError(error, gen: gen)
            }
        }
        backfillTask = Task { [weak self] in
            guard let self else { return }
            // A backfill failure is silent — the reservoir just stays empty; the
            // visible grid degrades to fewer refills, never an error banner.
            let items = (try? await self.fetchSuggestionsIO(media, .backfill, 1, excludes)) ?? []
            self.applyBackfill(items, gen: gen)
        }
    }

    private func applySuggestions(_ items: [SuggestionItem], gen: Int) {
        guard gen == suggestionsGeneration else { return }
        suggestionItems = items
        isLoadingTVSuggestions = false
        tvSuggestionsFailed = false
    }

    private func applySuggestionsError(_ error: Error, gen: Int) {
        guard gen == suggestionsGeneration else { return }
        isLoadingTVSuggestions = false
        suggestionItems = []
        // 401 / not-authenticated → silent empty (retry would 401 again); every
        // other failure → a retry affordance (Discover/T6 outage-vs-401 contract).
        switch error {
        case SuggestionsClient.SuggestionsError.notAuthenticated,
             SuggestionsClient.SuggestionsError.http(401):
            tvSuggestionsFailed = false
        default:
            tvSuggestionsFailed = true
        }
    }

    private func applyBackfill(_ items: [SuggestionItem], gen: Int) {
        guard gen == suggestionsGeneration else { return }
        backfillPool = items
    }

    /// Refresh the suggestions grid — advance the page and reload (web
    /// `handleRefreshSuggestions`: `suggestionPageRef += 1`). Both the visible grid
    /// and the backfill reservoir re-request under the new page.
    public func refreshTVSuggestions() {
        guard suggestionsGateOpen else { return }
        suggestionsPage += 1
        loadTVSuggestions()
    }

    /// The user tapped a SUGGESTED show. Consume it (splice out + refill from the
    /// backfill pool, note its show id in the session excludes) and route into the
    /// SAME season-grid flow as a search pick (`pickShow`). Mirrors web
    /// `handleSelectSuggestion`.
    public func pickSuggestedShow(_ show: TMDBTVShow) {
        consumeSuggestion(id: show.id)
        pickShow(show)
    }

    /// The user tapped a SUGGESTED movie (C7-iOS Task 3). Consume it (splice out +
    /// refill + note the movie id `tmdb_{n}` in the excludes) and return the
    /// rankable `Movie` — a picked movie goes STRAIGHT to the ceremony (no season
    /// grid). `voteAverage` rides along via `RankEntryModel.rankMovie(from:)` so the ceremony's
    /// prediction seeds (the C3A concern class). Mirrors web `handleSelectMovie`
    /// with `fromSuggestion=true`. Returns nil if the id isn't in the current grid
    /// (a stale tap after a mode switch / refresh).
    public func pickSuggestedMovie(_ movie: TMDBMovie) -> Movie? {
        guard let item = suggestionItems.first(where: { $0.id == movie.id }) else { return nil }
        consumeSuggestion(id: movie.id)
        return Self.rankMovie(from: item)
    }

    /// Mint the rankable `Movie` for a picked movie suggestion. Threads
    /// `voteAverage` so the ceremony's prediction seeds (the C3A concern class).
    /// Kept local so `RankEntryModel` doesn't depend on a screen helper.
    static func rankMovie(from item: SuggestionItem) -> Movie {
        Movie(
            id: item.id,
            title: item.title,
            year: Int(item.year) ?? 0,
            director: "—",
            seed: Self.stableSeed(item.id),
            genres: item.genres,
            posterUrl: (item.posterUrl?.isEmpty == false) ? item.posterUrl : nil,
            voteAverage: item.voteAverage
        )
    }

    /// djb2 seed for a stable poster placeholder from an id. Pure djb2 hash
    /// modulo 1000 — mirrors `RankEntryScreen.stableSeed(from:)`, NOT
    /// `DiscoverCardCopy.stableSeed` (which uses trailing-digit extraction and
    /// mod 20).
    static func stableSeed(_ id: String) -> Int {
        var h: UInt64 = 5381
        for b in id.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(h % 1000)
    }

    /// Splice a consumed item out of the grid by id, refill one slot from the
    /// backfill pool (skipping ids already present), note the id in the session
    /// excludes (capped 200), and re-request the backfill pool when it drops below
    /// the refill threshold. Media-generic — mirrors web `consumeSuggestion` in
    /// both the movie modal (`AddMediaModal`) and the tv modal.
    private func consumeSuggestion(id consumedId: String) {
        noteConsumed(consumedId)
        var without = suggestionItems.filter { $0.id != consumedId }
        if !backfillPool.isEmpty {
            let present = Set(without.map(\.id))
            var fill: SuggestionItem? = nil
            while !backfillPool.isEmpty {
                let candidate = backfillPool.removeFirst()
                if !present.contains(candidate.id) { fill = candidate; break }
            }
            if let fill {
                tvSuggestionsHasBackfill = true
                without.append(fill)
            }
            if backfillPool.count < Self.backfillRefillThreshold {
                requestBackfillNextPage()
            }
        }
        suggestionItems = without
    }

    /// Re-request the backfill pool at the next page and REPLACE the reservoir
    /// (web `prefetchBackfillPool(page)` overwrites `backfillPoolRef`). Runs under
    /// the current suggestions generation so a stale Refresh/mode-switch drops it.
    private func requestBackfillNextPage() {
        backfillPage += 1
        let media = suggestionMediaType
        let page = backfillPage
        let excludes = sessionExcludeIds
        let gen = suggestionsGeneration
        backfillTask?.cancel()
        backfillTask = Task { [weak self] in
            guard let self else { return }
            let items = (try? await self.fetchSuggestionsIO(media, .backfill, page, excludes)) ?? []
            self.applyBackfill(items, gen: gen)
        }
    }

    /// Test seam — run the consume-splice choreography without the `pickShow`
    /// stage transition (so the exclude-cap accumulation can be exercised over many
    /// shows without the grid re-rendering into the season-grid stage each time).
    func consumeForTest(_ show: TMDBTVShow) { consumeSuggestion(id: show.id) }
    /// Movie-mode analogue of `consumeForTest` — exercises the exclude-cap
    /// accumulation over many movies without routing to the ceremony each time.
    func consumeForTest(_ movie: TMDBMovie) { consumeSuggestion(id: movie.id) }

    /// Note a consumed id in the session excludes, de-duped and capped at 200
    /// keeping the most recent (web `noteConsumed`). The id is already the media's
    /// stub form (`tv_{n}` shows in tv mode, `tmdb_{n}` movies in movie mode);
    /// the server excludes on these ids.
    private func noteConsumed(_ id: String) {
        guard !sessionExcludeIds.contains(id) else { return }
        sessionExcludeIds.append(id)
        if sessionExcludeIds.count > Self.sessionExcludeCap {
            sessionExcludeIds = Array(sessionExcludeIds.suffix(Self.sessionExcludeCap))
        }
    }

    /// Tear the suggestions grid + reservoir down (leaving tv / signed out). Does
    /// NOT reset `suggestionsPage`/`sessionExcludeIds` — those persist for the
    /// session so a Refresh keeps advancing and re-entered tv keeps its excludes.
    private func resetTVSuggestions() {
        suggestionsTask?.cancel()
        backfillTask?.cancel()
        suggestionsGeneration &+= 1
        suggestionItems = []
        backfillPool = []
        isLoadingTVSuggestions = false
        tvSuggestionsHasBackfill = false
        tvSuggestionsFailed = false
    }

    /// Build a `TMDBTVShow` from a tv `SuggestionItem` so a tapped suggestion can
    /// route through `pickShow` (which loads the real season detail). The id is the
    /// suggestion's `tv_{n}` show id; seasons are nil (the grid pick re-fetches
    /// full detail). Genres/creators the suggestion payload doesn't carry are left
    /// empty — `applySeasonLoad` fills them on the `seasonMovie` that is built
    /// from the tapped show's fields; the stage show itself is never swapped out.
    static func show(from item: SuggestionItem) -> TMDBTVShow {
        TMDBTVShow(
            id: item.id,
            tmdbId: item.tmdbId,
            name: item.title,
            year: item.year,
            posterUrl: item.posterUrl,
            backdropUrl: item.backdropUrl,
            genres: item.genres,
            overview: item.overview,
            seasonCount: item.seasonCount,
            status: "",
            creators: [],
            voteAverage: item.voteAverage,
            seasons: nil
        )
    }

    /// Build a `TMDBMovie` from a movie `SuggestionItem` so the movie grid can
    /// render a search-result-shaped row (C7-iOS Task 3). The id is the
    /// suggestion's `tmdb_{n}` movie id; `voteAverage` is preserved so the picked
    /// `Movie` seeds the ceremony's prediction. This DTO is a render/tap key only —
    /// the picked `Movie` is minted from the raw `SuggestionItem` via
    /// `Self.rankMovie(from:)`, which threads `voteAverage` directly.
    static func movieDTO(from item: SuggestionItem) -> TMDBMovie {
        TMDBMovie(
            id: item.id,
            tmdbId: item.tmdbId,
            title: item.title,
            year: item.year,
            posterUrl: item.posterUrl,
            genres: item.genres,
            overview: item.overview,
            voteAverage: item.voteAverage
        )
    }

    /// Seed the season grid DIRECTLY for a known show id (the rank-from-watchlist
    /// whole-show path, C5-iOS Task 6). Unlike `pickShow`, the caller has only the
    /// numeric show id + a fallback name (from the bookmark), so we fetch the full
    /// detail first, THEN enter the grid stage with the real `TMDBTVShow`. On a
    /// failed detail load the stage enters `.seasonGrid` with a minimal placeholder
    /// show (name from `fallbackName`, seasons empty) so the screen shows the
    /// empty/back state rather than hanging. Used by `SeasonSelectScreen`.
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
