import SwiftUI

/// The rank-flow entry screen (C5-iOS Task 6). A `movie | tv | book` segmented
/// switch drives three search modes off one `RankEntryModel`:
///
///  * MOVIE — an empty search field surfaces a SUGGESTIONS grid (MOVIES, C7-iOS
///    Task 3, signed-in only) via `SuggestionsClient.fetch(mediaType: .movie)`;
///    typing swaps it for film search. Tap a suggested/searched movie →
///    `onPick(movie)` STRAIGHT to the ceremony (no season grid); a picked
///    suggestion threads `voteAverage` (`Movie.movie(from:)`) so the ceremony's
///    prediction seeds. Signed-out movie keeps its demo-fixtures search path and
///    shows NO grid (the engine 401s signed-out).
///  * TV — an empty search field surfaces a SUGGESTIONS grid (SHOWS, Task 7) via
///    `SuggestionsClient.fetch(mediaType: .tv)`; typing swaps it for show search.
///    Tap a suggested/searched show → season grid (Specials filtered by
///    `getTVShowDetails`, already-ranked seasons disabled) → tap season →
///    `onPick(seasonMovie)` with the composite `tv_{show}_s{n}` id + real tv
///    fields (T5's construction conventions via `Movie.tvSeason`). The grid's
///    consume-splice / backfill / Refresh choreography lives in `RankEntryModel`,
///    ONE media-parameterized implementation shared with movie mode.
///  * BOOK — OpenLibrary search → tap book → `onPick(bookMovie)` (`ol_` id,
///    author, `olRatingsAverage`; `voteAverage` stays nil). No grid.
///
/// tv/book modes require sign-in (the fixture pool is movie-shaped); the model's
/// `requiresSignIn` gates the results with a sign-in nudge. `onSignIn` bubbles a
/// nudge tap up to the root so it can present the sign-in sheet.
///
/// Header last reviewed: 2026-07-10
public struct RankEntryScreen: View {
    public var onPick: (Movie) -> Void
    public var onClose: () -> Void
    /// Called when the user taps the sign-in nudge in a tv/book mode while signed
    /// out. The root presents the sign-in sheet. Defaulted to a no-op.
    public var onSignIn: () -> Void

    @StateObject private var model: RankEntryModel
    @State private var query: String = ""
    @State private var searchDebounce: Task<Void, Never>? = nil
    /// One-shot guard so the initial-mode suggestions grid loads exactly once on
    /// first appearance (the default movie mode never fires a `setMode`, which is
    /// what loads the tv grid — without this the default movie grid would stay
    /// empty until the user tabbed away and back).
    @State private var didLoadInitialSuggestions = false

    public init(
        onPick: @escaping (Movie) -> Void,
        onClose: @escaping () -> Void,
        onSignIn: @escaping () -> Void = {},
        /// A LIVE closure that reads the current auth/preview state each time it
        /// is called. Must NOT be frozen to a value at init time: after signing in
        /// via the nudge the model's gate re-evaluates immediately (no flow
        /// re-entry required). Mirror the pattern `SpoolAppRoot` uses for
        /// previewMode/SpoolClient (checked at call time, not captured as a Bool).
        isSignedIn: @escaping () -> Bool = { SpoolClient.shared != nil }
    ) {
        self.onPick = onPick
        self.onClose = onClose
        self.onSignIn = onSignIn
        // Pass the LIVE closure through to the model so requiresSignIn re-reads
        // the current session after the user signs in from the nudge. Previously
        // a Bool was captured once at init and the gate froze permanently.
        _model = StateObject(wrappedValue: RankEntryModel(isSignedIn: isSignedIn))
    }

    /// Test / preview seam — inject a fixture-loaded model.
    init(
        model: RankEntryModel,
        onPick: @escaping (Movie) -> Void = { _ in },
        onClose: @escaping () -> Void = {},
        onSignIn: @escaping () -> Void = {}
    ) {
        self.onPick = onPick
        self.onClose = onClose
        self.onSignIn = onSignIn
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        SpoolScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Text(L10n.t("rankEntry.makeStub"))
                        .font(SpoolFonts.script(20))
                        .foregroundStyle(SpoolTokens.paper.inkSoft)
                        .padding(.top, 4)

                    mediaSwitcher
                        .padding(.top, 16)

                    stageContent
                }
                .padding(.horizontal, 18)
                .padding(.top, 60)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            // Load the initial-mode suggestions grid once (the default movie mode
            // opens without a setMode, which is the tv grid's load trigger). Gated
            // internally: signed-out movie / book are no-ops.
            guard !didLoadInitialSuggestions else { return }
            didLoadInitialSuggestions = true
            model.loadTVSuggestions()
        }
    }

    // MARK: header

    private var header: some View {
        HStack {
            Text(headerTitle)
                .font(SpoolFonts.serif(28))
                .foregroundStyle(SpoolTokens.paper.ink)
            Spacer()
            Button(backOrCancelLabel, action: backOrCancel)
                .font(SpoolFonts.mono(13))
                .foregroundStyle(SpoolTokens.paper.inkSoft)
        }
    }

    private var headerTitle: String {
        if case .seasonGrid(let show) = model.stage { return show.name }
        switch model.mode {
        case .movie: return L10n.t("rankEntry.justWatched")
        case .tv:    return L10n.t("rankEntry.justWatched")
        case .book:  return L10n.t("rankEntry.justRead")
        }
    }

    private var backOrCancelLabel: String {
        if case .seasonGrid = model.stage { return L10n.t("rankEntry.back") }
        return L10n.t("rankEntry.cancel")
    }

    private func backOrCancel() {
        if case .seasonGrid = model.stage {
            model.backToSearch()
        } else {
            onClose()
        }
    }

    // MARK: media switcher (movie | tv | book pills)

    private var mediaSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(RankEntryMode.allCases, id: \.self) { m in
                SpoolPill(label(for: m), active: model.mode == m, size: .sm) {
                    guard model.mode != m else { return }
                    model.setMode(m)
                    // Re-run the search under the new media so an existing query
                    // shows the new vertical's results.
                    scheduleSearch(for: query)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func label(for m: RankEntryMode) -> String {
        switch m {
        case .movie: return L10n.t("rankEntry.modeMovies")
        case .tv:    return L10n.t("rankEntry.modeTV")
        case .book:  return L10n.t("rankEntry.modeBooks")
        }
    }

    // MARK: stage content

    @ViewBuilder
    private var stageContent: some View {
        switch model.stage {
        case .search:
            searchStage
        case .seasonGrid:
            seasonGridStage
        }
    }

    // MARK: search stage

    @ViewBuilder
    private var searchStage: some View {
        SearchField(text: $query, placeholder: model.searchPlaceholder)
            .padding(.top, 16)
            .onChange(of: query) { newValue in scheduleSearch(for: newValue) }
            // Always-present view: observe the sign-in gate here so the
            // true→false transition fires regardless of which branch is
            // currently rendered. Attaching to `resultsSection` was wrong —
            // that view only exists in the `else` branch, so it is being
            // INSERTED (not updated) when requiresSignIn flips false, and
            // SwiftUI never calls onChange on initial attachment.
            .onChange(of: model.requiresSignIn) { nowRequires in
                // After a signed-out user signs in from the nudge, load the
                // tv suggestions that were suppressed behind the gate.
                if !nowRequires && model.mode == .tv { model.loadTVSuggestions() }
            }
            // Movie mode's requiresSignIn never flips (always false — fixtures
            // fallback), so observe the raw suggestions gate instead: once a
            // signed-out movie user signs in, load the movie grid that the engine
            // 401 was suppressing. Harmless for tv (loadTVSuggestions re-gates).
            .onChange(of: model.suggestionsGateOpen) { gateOpen in
                if gateOpen { model.loadTVSuggestions() }
            }

        if model.requiresSignIn {
            signInNudge
        } else {
            resultsSection
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty query: movie mode surfaces a MOVIES grid (signed-in only;
            // signed-out movie shows nothing here, its fixtures render only on a
            // typed query); tv mode surfaces a SHOWS grid; book shows nothing.
            switch model.mode {
            case .movie: movieSuggestionsGrid
            case .tv:    tvSuggestionsGrid
            case .book:  EmptyView()
            }
        } else {
            switch model.mode {
            case .movie: movieResults
            case .tv:    tvResults
            case .book:  bookResults
            }
        }
    }

    // MARK: movie results (byte-identical to pre-C5)

    @ViewBuilder
    private var movieResults: some View {
        if !model.movieResults.isEmpty {
            sectionLabel(L10n.t("rankEntry.sectionMatches"))
            ForEach(model.movieResults) { m in
                let asMovie = Movie(
                    id: m.id, title: m.title,
                    year: Int(m.year) ?? 0,
                    director: "",
                    seed: stableSeed(from: m.title),
                    genres: m.genres,
                    posterUrl: m.posterUrl,
                    voteAverage: m.voteAverage
                )
                MovieRow(movie: asMovie, highlight: false) { onPick(asMovie) }
                    .padding(.top, 8)
            }
        } else if model.isSearching {
            searchingRow
        } else if !TMDBService.hasKey {
            sectionLabel(L10n.t("rankEntry.sectionDemo"))
            ForEach(SpoolData.searchResults) { m in
                MovieRow(movie: m, highlight: m.rec) { onPick(m) }
                    .padding(.top, 8)
            }
        } else {
            noResults
        }
    }

    // MARK: tv results (show rows)

    @ViewBuilder
    private var tvResults: some View {
        if !model.tvResults.isEmpty {
            sectionLabel(L10n.t("rankEntry.sectionShows"))
            ForEach(model.tvResults) { show in
                ShowRow(show: show) { model.pickShow(show) }
                    .padding(.top, 8)
            }
        } else if model.isSearching {
            searchingRow
        } else {
            noResults
        }
    }

    // MARK: tv suggestions grid (Task 7) — shown under an empty search field

    @ViewBuilder
    private var tvSuggestionsGrid: some View {
        if model.isLoadingTVSuggestions {
            searchingRow
        } else if !model.tvSuggestions.isEmpty {
            HStack {
                Text((model.tvSuggestionsHasBackfill ? L10n.t("rankEntry.basedOnTaste") : L10n.t("rankEntry.popularNow")).uppercased())
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(SpoolTokens.paper.inkSoft)
                Spacer()
                Button(action: { model.refreshTVSuggestions() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text(L10n.t("rankEntry.refresh"))
                            .font(SpoolFonts.mono(10))
                    }
                    .foregroundStyle(SpoolTokens.paper.inkSoft)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 18)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)],
                      spacing: 12) {
                ForEach(model.tvSuggestions) { show in
                    SuggestedShowCard(show: show) { model.pickSuggestedShow(show) }
                }
            }
            .padding(.top, 12)
        } else if model.tvSuggestionsFailed {
            VStack(spacing: 10) {
                Text(L10n.t("rankEntry.suggestionsLoadFailed"))
                    .font(SpoolFonts.hand(14))
                    .foregroundStyle(SpoolTokens.paper.inkSoft)
                SpoolPill(L10n.t("rankEntry.retry"), size: .sm) { model.loadTVSuggestions() }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        } else {
            // No suggestions (fresh account / server empty) — a quiet hint to search.
            Text(L10n.t("rankEntry.searchShowHint"))
                .font(SpoolFonts.hand(14))
                .foregroundStyle(SpoolTokens.paper.inkSoft)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        }
    }

    // MARK: movie suggestions grid (C7-iOS Task 3) — shown under an empty search field

    @ViewBuilder
    private var movieSuggestionsGrid: some View {
        // Signed-out movie shows NO grid (the engine 401s; the fixtures path only
        // renders on a typed query). Only render when the gate is open.
        if !model.suggestionsGateOpen {
            EmptyView()
        } else if model.isLoadingTVSuggestions {
            searchingRow
        } else if !model.movieSuggestions.isEmpty {
            HStack {
                Text((model.tvSuggestionsHasBackfill ? L10n.t("rankEntry.basedOnTaste") : L10n.t("rankEntry.popularNow")).uppercased())
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(SpoolTokens.paper.inkSoft)
                Spacer()
                Button(action: { model.refreshTVSuggestions() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text(L10n.t("rankEntry.refresh"))
                            .font(SpoolFonts.mono(10))
                    }
                    .foregroundStyle(SpoolTokens.paper.inkSoft)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 18)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)],
                      spacing: 12) {
                ForEach(model.movieSuggestions) { movie in
                    SuggestedMovieCard(movie: movie) {
                        if let picked = model.pickSuggestedMovie(movie) { onPick(picked) }
                    }
                }
            }
            .padding(.top, 12)
        } else if model.tvSuggestionsFailed {
            VStack(spacing: 10) {
                Text(L10n.t("rankEntry.suggestionsLoadFailed"))
                    .font(SpoolFonts.hand(14))
                    .foregroundStyle(SpoolTokens.paper.inkSoft)
                SpoolPill(L10n.t("rankEntry.retry"), size: .sm) { model.loadTVSuggestions() }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        } else {
            // No suggestions (fresh account / server empty) — a quiet hint to search.
            Text(L10n.t("rankEntry.searchFilmHint"))
                .font(SpoolFonts.hand(14))
                .foregroundStyle(SpoolTokens.paper.inkSoft)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        }
    }

    // MARK: book results

    @ViewBuilder
    private var bookResults: some View {
        if !model.bookResults.isEmpty {
            sectionLabel(L10n.t("rankEntry.sectionBooks"))
            ForEach(model.bookResults) { book in
                BookRow(book: book) { onPick(model.bookMovie(for: book)) }
                    .padding(.top, 8)
            }
        } else if model.isSearching {
            searchingRow
        } else {
            noResults
        }
    }

    // MARK: season grid stage

    @ViewBuilder
    private var seasonGridStage: some View {
        if model.isLoadingSeasons {
            searchingRow
        } else if model.seasons.isEmpty {
            Text(L10n.t("rankEntry.seasonsLoadFailed"))
                .font(SpoolFonts.hand(14))
                .foregroundStyle(SpoolTokens.paper.inkSoft)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        } else {
            sectionLabel(L10n.t("rankEntry.pickSeason"))
            ForEach(model.seasons, id: \.seasonNumber) { season in
                let ranked = model.rankedSeasonNumbers.contains(season.seasonNumber)
                SeasonRow(season: season, alreadyRanked: ranked) {
                    if let movie = model.seasonMovie(for: season) { onPick(movie) }
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: shared bits

    private var searchingRow: some View {
        HStack {
            Spacer()
            ProgressView().tint(SpoolTokens.paper.accent)
            Text(L10n.t("rankEntry.searching"))
                .font(SpoolFonts.mono(11))
                .foregroundStyle(SpoolTokens.paper.inkSoft)
            Spacer()
        }
        .padding(.top, 24)
    }

    private var noResults: some View {
        Text(L10n.t("rankEntry.noResults"))
            .font(SpoolFonts.hand(14))
            .foregroundStyle(SpoolTokens.paper.inkSoft)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
    }

    private var signInNudge: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 12) {
                Text(model.mode == .tv
                     ? L10n.t("rankEntry.signInShows")
                     : L10n.t("rankEntry.signInBooks"))
                    .font(SpoolFonts.script(20))
                    .foregroundStyle(t.ink)
                Text(L10n.t("rankEntry.signInHint"))
                    .font(SpoolFonts.hand(13))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                SpoolPill(L10n.t("rankEntry.signIn"), filled: true, action: onSignIn)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            .padding(.horizontal, 20)
        }
    }

    // MARK: search scheduling (debounce owned by the view)

    private func scheduleSearch(for value: String) {
        searchDebounce?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            model.runSearch("")
            return
        }
        searchDebounce = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            if Task.isCancelled { return }
            model.runSearch(trimmed)
        }
    }

    private func stableSeed(from s: String) -> Int {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(h % 1000)
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s.uppercased())
            .font(SpoolFonts.mono(10))
            .tracking(2)
            .foregroundStyle(SpoolTokens.paper.inkSoft)
            .padding(.top, 18)
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder: String = L10n.t("rankEntry.searchFilms")
    var body: some View {
        SpoolThemeReader { t, _ in
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(t.ink)
                TextField(placeholder, text: $text)
                    .font(SpoolFonts.serif(18))
                    .foregroundStyle(t.ink)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .overlay(Capsule().stroke(t.ink, lineWidth: 1.5))
        }
    }
}

struct MovieRow: View {
    let movie: Movie
    let highlight: Bool
    let action: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            Button(action: action) {
                HStack(spacing: 12) {
                    PosterBlock(title: firstWord(movie.title), year: movie.year,
                                director: movie.director, seed: movie.seed,
                                posterUrl: movie.posterUrl)
                        .frame(width: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(movie.title)
                            .font(SpoolFonts.serif(16))
                            .foregroundStyle(t.ink)
                            .lineLimit(1)
                        Text("\(String(movie.year)) · \(movie.director)")
                            .font(SpoolFonts.mono(10))
                            .foregroundStyle(t.inkSoft)
                    }
                    Spacer()
                    if highlight {
                        Text(L10n.t("rankEntry.onList"))
                            .font(SpoolFonts.hand(11))
                            .foregroundStyle(t.ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(t.yellow))
                            .overlay(Capsule().stroke(t.ink, lineWidth: 1))
                    }
                }
                .padding(10)
                .background(highlight ? t.cream2 : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(highlight ? t.ink : t.rule, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func firstWord(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }
}

/// A TV show search result row → taps into the season grid.
struct ShowRow: View {
    let show: TMDBTVShow
    let action: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            Button(action: action) {
                HStack(spacing: 12) {
                    PosterBlock(title: firstWord(show.name), year: Int(show.year),
                                director: show.creators.first ?? "—",
                                seed: seed(show.id), posterUrl: show.posterUrl)
                        .frame(width: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(show.name)
                            .font(SpoolFonts.serif(16))
                            .foregroundStyle(t.ink)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(SpoolFonts.mono(10))
                            .foregroundStyle(t.inkSoft)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(t.inkSoft)
                }
                .padding(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(t.rule, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var subtitle: String {
        let year = show.year.isEmpty ? "—" : show.year
        return L10n.t("rankEntry.tvYear", ["year": year])
    }
    private func firstWord(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }
    private func seed(_ id: String) -> Int {
        var h: UInt64 = 5381
        for b in id.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(h % 1000)
    }
}

/// A suggested SHOW poster card in the tv suggestions grid (Task 7). Tapping it
/// routes into the same season-grid flow as a search pick (`pickSuggestedShow`).
struct SuggestedShowCard: View {
    let show: TMDBTVShow
    let action: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            Button(action: action) {
                VStack(alignment: .leading, spacing: 4) {
                    PosterBlock(title: firstWord(show.name), year: Int(show.year),
                                director: show.creators.first ?? "—",
                                seed: seed(show.id), posterUrl: show.posterUrl)
                    Text(show.name)
                        .font(SpoolFonts.serif(13))
                        .foregroundStyle(t.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(show.year.isEmpty ? "—" : show.year)
                        .font(SpoolFonts.mono(9))
                        .foregroundStyle(t.inkSoft)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func firstWord(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }
    private func seed(_ id: String) -> Int {
        var h: UInt64 = 5381
        for b in id.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(h % 1000)
    }
}

/// A suggested MOVIE poster card in the movie suggestions grid (C7-iOS Task 3).
/// Tapping it consumes the suggestion and routes STRAIGHT to the ceremony (no
/// season grid), mirroring the suggested-show card's layout.
struct SuggestedMovieCard: View {
    let movie: TMDBMovie
    let action: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            Button(action: action) {
                VStack(alignment: .leading, spacing: 4) {
                    PosterBlock(title: firstWord(movie.title), year: Int(movie.year),
                                director: "—",
                                seed: seed(movie.id), posterUrl: movie.posterUrl)
                    Text(movie.title)
                        .font(SpoolFonts.serif(13))
                        .foregroundStyle(t.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(movie.year.isEmpty ? "—" : movie.year)
                        .font(SpoolFonts.mono(9))
                        .foregroundStyle(t.inkSoft)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func firstWord(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }
    private func seed(_ id: String) -> Int {
        var h: UInt64 = 5381
        for b in id.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(h % 1000)
    }
}

/// One season row in the grid — disabled (dimmed, non-tappable) when already ranked.
struct SeasonRow: View {
    let season: TMDBTVSeasonSummary
    let alreadyRanked: Bool
    let action: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            Button(action: { if !alreadyRanked { action() } }) {
                HStack(spacing: 12) {
                    PosterBlock(title: "S\(season.seasonNumber)", year: nil,
                                director: "", seed: season.seasonNumber * 37,
                                posterUrl: season.posterUrl)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(season.name)
                            .font(SpoolFonts.serif(16))
                            .foregroundStyle(t.ink)
                            .lineLimit(1)
                        Text(L10n.t(season.episodeCount == 1 ? "rankEntry.episodeSingular" : "rankEntry.episodePlural",
                                    ["n": "\(season.episodeCount)"]))
                            .font(SpoolFonts.mono(10))
                            .foregroundStyle(t.inkSoft)
                    }
                    Spacer()
                    if alreadyRanked {
                        Text(L10n.t("rankEntry.ranked"))
                            .font(SpoolFonts.hand(11))
                            .foregroundStyle(t.ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(t.yellow))
                            .overlay(Capsule().stroke(t.ink, lineWidth: 1))
                    }
                }
                .padding(10)
                .opacity(alreadyRanked ? 0.5 : 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(t.rule, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(alreadyRanked)
        }
    }
}

/// A book search result row.
struct BookRow: View {
    let book: OpenLibraryBook
    let action: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            Button(action: action) {
                HStack(spacing: 12) {
                    PosterBlock(title: firstWord(book.title), year: Int(book.year),
                                director: book.author, seed: seed(book.id),
                                posterUrl: book.posterUrl.isEmpty ? nil : book.posterUrl)
                        .frame(width: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.title)
                            .font(SpoolFonts.serif(16))
                            .foregroundStyle(t.ink)
                            .lineLimit(1)
                        Text("\(book.year.isEmpty ? "—" : book.year) · \(book.author)")
                            .font(SpoolFonts.mono(10))
                            .foregroundStyle(t.inkSoft)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(t.rule, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func firstWord(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }
    private func seed(_ id: String) -> Int {
        var h: UInt64 = 5381
        for b in id.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(h % 1000)
    }
}

#Preview {
    RankEntryScreen(onPick: { _ in }, onClose: {}).spoolMode(.paper)
}
