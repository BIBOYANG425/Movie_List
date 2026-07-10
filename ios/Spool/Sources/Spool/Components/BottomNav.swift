import SwiftUI

public enum SpoolTab: String, CaseIterable, Hashable {
    case feed, stubs, watchlist, rank, friends, me
}

/// Bottom nav — capsule with five equal-weight tabs (feed, stubs, watchlist,
/// friends, me) and a floating "+" rank button that sits as a true overlay on
/// top of the capsule rather than breaking out from inside the tab row.
///
/// Why not a 5-cell HStack with `.offset(y: -14)` on the middle cell (the old
/// layout)? The capsule clips anything outside its bounds, and a negative
/// offset makes the + look chopped at the top edge. Lifting the + into its own
/// ZStack layer lets it float cleanly above the capsule — no clipping, and
/// the visual weight reads as "primary action," which is what tapping + does.
///
/// Capacity note (C3, watchlist): five tabs + the floating + is the practical
/// ceiling for this capsule at these paddings. A sixth surface should go behind
/// a "more" affordance or into an existing tab rather than a seventh cell.
///
/// Localized labels: tab titles + the rank-button a11y label flow through
/// `L10n.t` (C6-iOS Task 2). These are the first wired L10n consumers; the
/// root's `.id(rawLocale)` re-renders them on a language toggle.
///
/// Header last reviewed: 2026-07-10
public struct BottomNav: View {
    public var active: SpoolTab
    public var onTab: (SpoolTab) -> Void

    public init(active: SpoolTab, onTab: @escaping (SpoolTab) -> Void) {
        self.active = active
        self.onTab = onTab
    }

    public var body: some View {
        SpoolThemeReader { t, _ in
            ZStack(alignment: .top) {
                capsule(t: t)
                plusOverlay(t: t)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
            // Space above the capsule for the floating + so it has room to
            // breathe and isn't snug against the top edge of the nav bar.
            .padding(.top, 22)
        }
    }

    /// The pill with the five tabs. The + slot is reserved by a transparent
    /// spacer view of the same width so the other tabs don't shift when the
    /// overlay is added, removing the visual jitter you'd get if we just
    /// laid out 5 items and centered them.
    @ViewBuilder
    private func capsule(t: SpoolPalette) -> some View {
        HStack(alignment: .center, spacing: 0) {
            // Labels flow through `L10n.t` (C6-iOS Task 2): these are the FIRST
            // wired consumers, proving the toggle → live-flip contract. The root
            // (`SpoolAppRoot`) applies `.id(rawLocale)` so a language change
            // re-renders this nav with the new copy.
            tabButton(.feed, label: L10n.t("nav.feed"), icon: "☆", t: t)
            tabButton(.stubs, label: L10n.t("nav.stubs"), icon: "▢", t: t)
            tabButton(.watchlist, label: L10n.t("nav.queue"), icon: "☰", t: t)
            // Reserved slot for the floating +. Width matches the
            // plusOverlay circle diameter (54pt) so the five real tabs
            // stay evenly distributed and the button sits flush.
            Color.clear.frame(width: 54, height: 1)
            tabButton(.friends, label: L10n.t("nav.friends"), icon: "○", t: t)
            tabButton(.me, label: L10n.t("nav.me"), icon: "✦", t: t)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(t.cream)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(t.ink, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    /// The floating + sits centered horizontally on top of the capsule.
    /// With a 54pt-diameter button and `.offset(y: -22)`, the button's
    /// center sits 5pt below the capsule's top edge — 22pt of the circle
    /// extends above the capsule, the other 32pt overlaps. That's the
    /// intentional asymmetry: a true half-in-half-out circle (offset
    /// -27) reads as floating and detached, whereas this slight overlap
    /// keeps it visually anchored to the nav.
    @ViewBuilder
    private func plusOverlay(t: SpoolPalette) -> some View {
        Button { onTab(.rank) } label: {
            Text("+")
                .font(SpoolFonts.serif(28))
                .foregroundStyle(t.cream)
                .frame(width: 54, height: 54)
                .background(Circle().fill(t.accent))
                .overlay(Circle().stroke(t.ink, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 3)
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        // 22pt above the capsule edge, 32pt overlaps. Tweaking to -27
        // would true-center on the capsule top.
        .offset(y: -22)
        .accessibilityLabel(L10n.t("nav.rankNew"))
    }

    @ViewBuilder
    private func tabButton(_ tab: SpoolTab, label: String, icon: String, t: SpoolPalette) -> some View {
        Button { onTab(tab) } label: {
            VStack(spacing: 2) {
                Text(icon).font(.system(size: 16))
                Text(label).font(SpoolFonts.hand(11, weight: active == tab ? .bold : .regular))
            }
            .foregroundStyle(active == tab ? t.ink : t.inkSoft)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        // VoiceOver reads glyphs like "☆" as "White Star" etc. — use the
        // human label instead and mark the active tab as selected.
        .accessibilityLabel(label)
        .accessibilityAddTraits(active == tab ? .isSelected : [])
    }
}

#Preview {
    ZStack {
        SpoolTokens.paper.cream.ignoresSafeArea()
        VStack {
            Spacer()
            BottomNav(active: .feed, onTab: { _ in })
        }
    }
    .spoolMode(.paper)
}
