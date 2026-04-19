import SwiftUI

public enum SpoolTab: String, CaseIterable, Hashable {
    case feed, stubs, rank, friends, me
}

public struct BottomNav: View {
    public var active: SpoolTab
    public var onTab: (SpoolTab) -> Void

    public init(active: SpoolTab, onTab: @escaping (SpoolTab) -> Void) {
        self.active = active
        self.onTab = onTab
    }

    public var body: some View {
        SpoolThemeReader { t, _ in
            HStack(alignment: .center, spacing: 0) {
                tabButton(.feed, label: "feed", icon: "☆", t: t)
                tabButton(.stubs, label: "stubs", icon: "▢", t: t)
                bigButton(t: t)
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
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
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

    @ViewBuilder
    private func bigButton(t: SpoolPalette) -> some View {
        Button { onTab(.rank) } label: {
            Text("+")
                .font(SpoolFonts.serif(26))
                .foregroundStyle(t.cream)
                .frame(width: 48, height: 48)
                .background(Circle().fill(t.accent))
                .overlay(Circle().stroke(t.ink, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.15), radius: 0, x: 0, y: 3)
                .offset(y: -14)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    BottomNav(active: .feed, onTab: { _ in })
        .spoolMode(.paper)
}
