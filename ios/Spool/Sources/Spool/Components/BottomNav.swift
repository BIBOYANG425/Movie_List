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
            // Reserved slot for the floating +. The button is rendered in
            // `plusOverlay`; this spacer keeps horizontal footprint in the
            // flow so the four real tabs stay evenly distributed. Height is
            // left to natural (tabButton's intrinsic) so the capsule stays
            // pill-shaped — letting this fill vertically makes the nav
            // grow to fill the available overlay space.
            Color.clear.frame(width: 48, height: 1)
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

    /// The floating + sits centered horizontally on top of the capsule. Its
    /// vertical center aligns with the capsule's top edge so half the circle
    /// sticks up above the nav — classic "raised FAB" look without clipping.
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
        // Shift up so the button is half above / half overlapping the capsule.
        // 54-height / 2 = 27 → offset -22 keeps most of the button above the
        // pill while still overlapping enough to feel attached, not orphaned.
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
