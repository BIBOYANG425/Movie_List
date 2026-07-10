import SwiftUI

/// The Watchlist tab (C3-iOS Part A, Task 3) — the owner's bookmarked movies,
/// tv seasons, and books, one media segment at a time. A `movie | tv | books`
/// segmented switcher (the feed / stubs `SpoolPill` idiom) sits under the
/// header; each segment renders a wall of `WatchlistCard`s with per-media
/// loading / empty / error states.
///
/// State is owned by a `WatchlistModel` (`@MainActor ObservableObject`, iOS-16
/// floor — the `JournalListModel` precedent). All IO is injected there, so this
/// view is pure layout. Movie cards expose **Rank It** (routed to the model's
/// `rankIt` seam → `onRankIt`, which the app root wires into the rank ceremony
/// in Task 4) plus **Remove**; tv/book cards get **Remove** only.
///
/// Header last reviewed: 2026-07-09
public struct WatchlistScreen: View {

    @StateObject private var model: WatchlistModel

    /// Production entry — the app root passes the Rank It routing closure. The
    /// model binds its list/remove/toast closures to the real repository.
    public init(onRankIt: @escaping (WatchlistItem) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: WatchlistModel(onRankIt: onRankIt))
    }

    /// Test/preview seam — inject a pre-built model (fixture-loaded) so previews
    /// render populated / empty / error states without a live client.
    init(model: WatchlistModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                SpoolHeader(title: "watchlist")

                mediaSwitcher

                content
            }
        }
        .task { await model.loadCurrent() }
    }

    // MARK: media switcher

    /// movie ⇄ tv ⇄ books segmented control — the stubs/feed `SpoolPill` idiom
    /// (`StubsScreen.tabSwitcher`). Movie is the primary/leftmost segment.
    private var mediaSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(WatchlistMediaType.allCases, id: \.self) { media in
                SpoolPill(label(for: media),
                          active: model.selectedMedia == media,
                          size: .sm) {
                    Task { await model.select(media: media) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func label(for media: WatchlistMediaType) -> String {
        switch media {
        case .movie: return "movies"
        case .tv:    return "tv"
        case .book:  return "books"
        }
    }

    // MARK: content (per-media state machine)

    @ViewBuilder
    private var content: some View {
        switch model.currentState {
        case .loading:
            loadingState
        case .empty:
            emptyState
        case .failed:
            failedState
        case .loaded(let items):
            cardWall(items: items)
        }
    }

    @ViewBuilder
    private func cardWall(items: [WatchlistItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(items) { item in
                    WatchlistCard(
                        item: item,
                        onRankIt: { model.rankIt(item: item) },
                        onRemove: { Task { await model.remove(item: item) } }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
        .refreshable { await model.reload() }
    }

    // MARK: states

    private var loadingState: some View {
        SpoolThemeReader { t, _ in
            VStack {
                Spacer(minLength: 40)
                ProgressView()
                    .tint(t.inkSoft)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 12) {
                Spacer(minLength: 40)
                Text(emptyLine)
                    .font(SpoolFonts.hand(15))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
        }
    }

    private var failedState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 14) {
                Spacer(minLength: 40)
                Text("couldn't load your watchlist")
                    .font(SpoolFonts.hand(15))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                SpoolPill("try again", size: .sm) {
                    Task { await model.reload() }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
        }
    }

    /// Per-media empty copy in the app's lowercase hand voice.
    private var emptyLine: String {
        switch model.selectedMedia {
        case .movie: return "no movies saved yet — bookmark something to watch later"
        case .tv:    return "no shows saved yet — bookmark a season to watch later"
        case .book:  return "no books saved yet — bookmark one to read later"
        }
    }
}

#if DEBUG
@MainActor
private func previewModel(
    movies: [WatchlistItem] = [],
    fail: Bool = false
) -> WatchlistModel {
    WatchlistModel(
        list: { media in
            if fail { struct Boom: Error {}; throw Boom() }
            return media == .movie ? movies : []
        },
        remove: { _, _ in },
        toast: { _, _ in },
        onRankIt: { _ in }
    )
}

private func fixtureMovie(_ id: String, _ title: String, _ year: String) -> WatchlistItem {
    WatchlistItem(
        id: id, title: title, year: year, posterUrl: "",
        mediaType: .movie, genres: ["Drama"], addedAt: Date(timeIntervalSince1970: 1_713_400_000),
        director: "A Director"
    )
}

#Preview("watchlist · movies") {
    WatchlistScreen(model: previewModel(movies: [
        fixtureMovie("tmdb_603", "The Matrix", "1999"),
        fixtureMovie("tmdb_27205", "Inception", "2010"),
        fixtureMovie("tmdb_155", "The Dark Knight", "2008"),
    ]))
    .spoolMode(.paper)
}

#Preview("watchlist · empty") {
    WatchlistScreen(model: previewModel(movies: []))
        .spoolMode(.paper)
}

#Preview("watchlist · failed") {
    WatchlistScreen(model: previewModel(fail: true))
        .spoolMode(.dark)
}
#endif
