import SwiftUI

public enum SpoolTab: String, CaseIterable, Hashable {
    case feed, stubs, rank, friends, me
}

/// Bottom nav — capsule with four equal-weight tabs (feed, stubs, friends, me)
/// and a floating "+" rank button that sits as a true overlay on top of the
/// capsule rather than breaking out from inside the tab row.
///
/// Why not a 5-cell HStack with `.offset(y: -14)` on the middle cell (the old
/// layout)? The capsule clips anything outside its bounds, and a negative
/// offset makes the + look chopped at the top edge. Lifting the + into its own
/// ZStack layer lets it float cleanly above the capsule — no clipping, and
/// the visual weight reads as "primary action," which is what tapping + does.
///
/// Header last reviewed: 2026-04-20
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

    /// The pill with the four tabs. The + slot is reserved by a transparent
    /// spacer view of the same width so the other tabs don't shift when the
    /// overlay is added, removing the visual jitter you'd get if we just
    /// laid out 4 items and centered them.
    @ViewBuilder
    private func capsule(t: SpoolPalette) -> some View {
        HStack(alignment: .center, spacing: 0) {
            tabButton(.feed, label: "feed", icon: "☆", t: t)
            tabButton(.stubs, label: "stubs", icon: "▢", t: t)
            // Reserved slot for the floating +. Width matches the
            // plusOverlay circle diameter (54pt) so the four real tabs
            // stay evenly distributed and the button sits flush.
            Color.clear.frame(width: 54, height: 1)
            tabButton(.friends, label: "friends", icon: "○", t: t)
            tabButton(.me, label: "me", icon: "✦", t: t)
        }
        .padding(.horizontal, 10)
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
        .accessibilityLabel("Rank a new movie")
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
