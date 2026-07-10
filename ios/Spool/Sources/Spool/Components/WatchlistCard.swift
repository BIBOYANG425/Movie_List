import SwiftUI

/// One watchlist row rendered as a ticket/paper card: a poster on the left, the
/// title / year / "added" line on the right, and the media-appropriate action
/// buttons underneath. ALL media now get **Rank It** (primary, filled) +
/// **Remove**: the media-generic rank ceremony (C5-iOS T5) and the tv/book
/// preselect router (T6) exist, so a tv bookmark ranks through the season grid
/// and a book/season bookmark ranks straight into the ceremony.
///
/// The card is a pure view — it owns no state. `onRankIt` / `onRemove` are
/// injected by `WatchlistScreen`, which routes them through `WatchlistModel`.
/// The card just hands the item up; the ROOT routes per media through the
/// preselect router, so the model's `rankIt` seam stays media-agnostic.
///
/// Header last reviewed: 2026-07-10
struct WatchlistCard: View {
    let item: WatchlistItem
    /// Fired when the user taps Rank It (all media — the root routes per media).
    let onRankIt: () -> Void
    /// Fired when the user taps Remove (all media).
    let onRemove: () -> Void

    /// Rank It is offered for every vertical now the media-generic ceremony +
    /// tv/book preselect router exist (C5-iOS Task 6).
    private var showsRankIt: Bool { true }

    var body: some View {
        SpoolThemeReader { t, _ in
            HStack(alignment: .top, spacing: 12) {
                poster
                    .frame(width: 72)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(SpoolFonts.serif(17))
                        .tracking(-0.3)
                        .foregroundStyle(t.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(metaLine)
                        .font(SpoolFonts.mono(10))
                        .tracking(1)
                        .foregroundStyle(t.inkSoft)

                    Text(addedLine)
                        .font(SpoolFonts.hand(12))
                        .foregroundStyle(t.inkSoft)

                    Spacer(minLength: 6)

                    actions(t: t)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(t.cream2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(t.ink, lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        }
    }

    // MARK: poster

    private var poster: some View {
        PosterBlock(
            title: item.title,
            year: Int(item.year),
            director: item.director ?? item.author ?? item.creator ?? "—",
            seed: Self.stableSeed(item.id),
            cornerRadius: 4,
            posterUrl: item.posterUrl.isEmpty ? nil : item.posterUrl
        )
    }

    // MARK: action row

    @ViewBuilder
    private func actions(t: SpoolPalette) -> some View {
        HStack(spacing: 8) {
            if showsRankIt {
                actionButton(L10n.t("watchlist.rankIt"), filled: true, t: t, action: onRankIt)
                    .accessibilityLabel(L10n.t("watchlist.rankA11y", ["title": item.title]))
            }
            actionButton(L10n.t("watchlist.remove"), filled: false, t: t, action: onRemove)
                .accessibilityLabel(L10n.t("watchlist.removeA11y", ["title": item.title]))
        }
    }

    /// A small pill button in the ticket idiom — filled for the primary action,
    /// outlined for the secondary. Mirrors `SpoolPill`'s look but stays local so
    /// the card controls its own sizing and hit target.
    @ViewBuilder
    private func actionButton(_ title: String, filled: Bool,
                              t: SpoolPalette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(SpoolFonts.hand(12, weight: filled ? .bold : .regular))
                .foregroundStyle(filled ? t.cream : t.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(filled ? t.accent : Color.clear))
                .overlay(Capsule().stroke(t.ink, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: derived strings

    /// "MOVIE · 2020" style meta line (media type + year). Year omitted when
    /// blank (the row's `year` coalesced to "").
    private var metaLine: String {
        let kind = item.mediaType.rawValue.uppercased()
        return item.year.isEmpty ? kind : "\(kind) · \(item.year)"
    }

    /// "added apr 18" — the bookmark date in the app's lowercase hand voice.
    /// The date string stays en-formatted; the "added" wrapper localizes.
    private var addedLine: String {
        L10n.t("watchlist.added", ["date": Self.addedFormatter.string(from: item.addedAt).lowercased()])
    }

    private static let addedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    /// Deterministic 0-19 seed for the synthetic poster palette, stable across
    /// launches. Mirrors `StubsScreen.stableSeed` — parse a trailing integer
    /// from the id when possible, else a djb2 digest.
    private static func stableSeed(_ id: String) -> Int {
        if let digits = id.split(separator: "_").last.flatMap({ Int($0.filter(\.isNumber)) }) {
            return abs(digits) % 20
        }
        var h: UInt64 = 5381
        for b in id.utf8 { h = h &* 33 &+ UInt64(b) }
        return Int(h % 20)
    }
}

#if DEBUG
#Preview("watchlist card · movie") {
    WatchlistCard(
        item: WatchlistItem(
            id: "tmdb_603", title: "The Matrix", year: "1999", posterUrl: "",
            mediaType: .movie, genres: ["Sci-Fi"], addedAt: Date(),
            director: "The Wachowskis"
        ),
        onRankIt: {}, onRemove: {}
    )
    .padding()
    .spoolMode(.paper)
}

#Preview("watchlist card · tv (rank it + remove)") {
    WatchlistCard(
        item: WatchlistItem(
            id: "tv_1399_s1", title: "Game of Thrones", year: "2011", posterUrl: "",
            mediaType: .tv, genres: [], addedAt: Date(),
            showTmdbId: 1399, seasonNumber: 1
        ),
        onRankIt: {}, onRemove: {}
    )
    .padding()
    .spoolMode(.dark)
}
#endif
