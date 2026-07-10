import SwiftUI

/// Standalone season grid for the rank-from-watchlist WHOLE-SHOW path (C5-iOS
/// Task 6). When a user taps "Rank It" on a whole-show TV bookmark (`tv_{n}`,
/// no season), the preselect router (`TVPreselectRouter.resolve`) routes to the
/// season grid; this screen presents it. Picking a season builds the composite
/// `tv_{n}_s{k}` `Movie` (T5 conventions) and hands it up via `onPick` to enter
/// the ceremony.
///
/// Backed by the SAME `RankEntryModel` as the in-flow entry grid, seeded via
/// `loadSeasonGrid(forShowId:fallbackName:)` — so the season loading, the
/// already-ranked-disabled rows, and the season `Movie` construction are shared
/// (one implementation, one set of tests). Specials are already filtered by
/// `getTVShowDetails`.
///
/// Header last reviewed: 2026-07-10
public struct SeasonSelectScreen: View {
    /// The numeric show id (derived/healed by the router before presenting).
    public let showId: Int
    /// A best-effort show name from the bookmark (used until the detail loads).
    public let showName: String
    /// Fires with the chosen season's rankable `Movie` → enter the ceremony.
    public var onPick: (Movie) -> Void
    /// Fires when the user backs out (abandon the rank).
    public var onClose: () -> Void

    @StateObject private var model: RankEntryModel

    public init(
        showId: Int, showName: String,
        onPick: @escaping (Movie) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.showId = showId
        self.showName = showName
        self.onPick = onPick
        self.onClose = onClose
        _model = StateObject(wrappedValue: RankEntryModel())
    }

    /// Test / preview seam — inject a fixture-loaded model.
    init(
        showId: Int, showName: String, model: RankEntryModel,
        onPick: @escaping (Movie) -> Void = { _ in },
        onClose: @escaping () -> Void = {}
    ) {
        self.showId = showId
        self.showName = showName
        self.onPick = onPick
        self.onClose = onClose
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        SpoolScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(headerName)
                            .font(SpoolFonts.serif(26))
                            .foregroundStyle(SpoolTokens.paper.ink)
                            .lineLimit(2)
                        Spacer()
                        Button(L10n.t("rankEntry.cancel"), action: onClose)
                            .font(SpoolFonts.mono(13))
                            .foregroundStyle(SpoolTokens.paper.inkSoft)
                    }

                    Text(L10n.t("rankEntry.whichSeason"))
                        .font(SpoolFonts.script(20))
                        .foregroundStyle(SpoolTokens.paper.inkSoft)
                        .padding(.top, 4)

                    grid
                }
                .padding(.horizontal, 18)
                .padding(.top, 60)
                .padding(.bottom, 40)
            }
        }
        .task { model.loadSeasonGrid(forShowId: showId, fallbackName: showName) }
    }

    private var headerName: String {
        if case .seasonGrid(let show) = model.stage, !show.name.isEmpty { return show.name }
        return showName
    }

    @ViewBuilder
    private var grid: some View {
        if model.isLoadingSeasons {
            HStack {
                Spacer()
                ProgressView().tint(SpoolTokens.paper.accent)
                Text(L10n.t("rankEntry.loadingSeasons"))
                    .font(SpoolFonts.mono(11))
                    .foregroundStyle(SpoolTokens.paper.inkSoft)
                Spacer()
            }
            .padding(.top, 40)
        } else if model.seasons.isEmpty {
            Text(L10n.t("rankEntry.seasonsLoadFailed"))
                .font(SpoolFonts.hand(14))
                .foregroundStyle(SpoolTokens.paper.inkSoft)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            ForEach(model.seasons, id: \.seasonNumber) { season in
                let ranked = model.rankedSeasonNumbers.contains(season.seasonNumber)
                SeasonRow(season: season, alreadyRanked: ranked) {
                    if let movie = model.seasonMovie(for: season) { onPick(movie) }
                }
                .padding(.top, 8)
            }
        }
    }
}

#Preview {
    SeasonSelectScreen(showId: 1399, showName: "Game of Thrones",
                       onPick: { _ in }, onClose: {})
        .spoolMode(.paper)
}
