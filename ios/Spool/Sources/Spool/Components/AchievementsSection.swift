import SwiftUI

/// Badge surface for the profile screens (C7-iOS Task 1). Mirrors web
/// `components/social/AchievementsView.tsx` render, adapted to the paper/ticket
/// idiom (SpoolThemeReader palette, mono/hand fonts, ruled cards).
///
/// Two modes, matching what web's `AchievementsView` shows per viewer:
///   - `.own` (ProfileScreen): ALL 16 badges, grouped by category in web order
///     (milestone → social → taste → special), unearned entries DIMMED with the
///     `requirement` hint and a lock glyph — exactly the own-profile grid web
///     renders. Header shows `earned/16` like web's `{n}/{total} unlocked`.
///   - `.viewer` (FriendProfileScreen): EARNED badges only. Web's
///     `AchievementsView` renders the same locked-inclusive grid for a viewer,
///     but the GRANT call is gated on `isOwnProfile` — a viewer never triggers a
///     grant, so a cross-user profile shows only what that user has actually
///     earned. iOS renders the earned subset (a flat wrap) rather than a viewer
///     seeing 15 grey "locked" cards for someone else's account, which reads as
///     the viewer's own to-do list on another user's page. When the user has no
///     badges yet, a short empty line renders instead of a blank section.
///
/// The section is self-loading: it fetches `AchievementsClient.earnedBadges`
/// for the given user on appear. It never triggers a grant — per the contract,
/// grants are post-write fire-and-forget (Task 2), not load-triggered on iOS.
///
/// Header last reviewed: 2026-07-10
public struct AchievementsSection: View {

    public enum Mode: Sendable, Equatable {
        /// Own profile — render all 16, unearned dimmed with hints.
        case own
        /// Cross-user profile — render earned badges only.
        case viewer
    }

    public var userId: UUID
    public var mode: Mode

    @State private var earnedKeys: Set<String> = []
    @State private var loaded: Bool = false

    public init(userId: UUID, mode: Mode) {
        self.userId = userId
        self.mode = mode
    }

    public var body: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 0) {
                header(t: t)

                switch mode {
                case .own:
                    ownGrid(t: t).padding(.top, 10)
                case .viewer:
                    viewerGrid(t: t).padding(.top, 10)
                }
            }
        }
        .task(id: userId) { await load() }
    }

    // MARK: header

    private func header(t: SpoolPalette) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.t("achievements.title"))
                .font(SpoolFonts.mono(10))
                .tracking(2)
                .foregroundStyle(t.inkSoft)
            if mode == .own {
                Text(L10n.t("achievements.count", [
                    "earned": "\(earnedKeys.count)",
                    "total": "\(BadgeCatalog.all.count)",
                ]))
                .font(SpoolFonts.mono(9))
                .tracking(1)
                .foregroundStyle(t.accent)
            }
        }
    }

    // MARK: own grid — all 16 by category, unearned dimmed

    private func ownGrid(t: SpoolPalette) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(BadgeCategory.allCases, id: \.self) { category in
                let badges = BadgeCatalog.inCategory(category)
                VStack(alignment: .leading, spacing: 6) {
                    Text(categoryLabel(category))
                        .font(SpoolFonts.mono(9))
                        .tracking(1.5)
                        .foregroundStyle(t.inkSoft)
                    wrap(badges: badges) { badge in
                        badgeCard(badge, earned: earnedKeys.contains(badge.key), t: t)
                    }
                }
            }
        }
    }

    // MARK: viewer grid — earned only

    @ViewBuilder
    private func viewerGrid(t: SpoolPalette) -> some View {
        let earned = BadgeCatalog.all.filter { earnedKeys.contains($0.key) }
        if earned.isEmpty {
            Text(L10n.t(loaded ? "achievements.noneYet" : "achievements.loading"))
                .font(SpoolFonts.hand(13))
                .foregroundStyle(t.inkSoft)
        } else {
            wrap(badges: earned) { badge in
                badgeCard(badge, earned: true, t: t)
            }
        }
    }

    // MARK: a single badge card

    private func badgeCard(_ badge: BadgeDefinition, earned: Bool, t: SpoolPalette) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(earned ? badge.icon : "🔒")
                .font(.system(size: 22))
            Text(badge.name)
                .font(SpoolFonts.hand(12))
                .foregroundStyle(earned ? t.ink : t.inkSoft)
                .lineLimit(1)
            Text(earned ? badge.description : badge.requirement)
                .font(SpoolFonts.mono(8))
                .foregroundStyle(t.inkSoft)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(width: 96, alignment: .leading)
        .frame(minHeight: 78, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(earned ? t.cream2 : t.cream2.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(t.rule, lineWidth: earned ? 1.5 : 1)
        )
        .opacity(earned ? 1.0 : 0.55)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(badge.name), \(earned ? badge.description : L10n.t("achievements.locked"))")
    }

    // MARK: simple flow-wrap (fixed 3-per-row) — avoids a Layout dependency

    /// Lays out `badges` three per row. A fixed column count keeps the card
    /// width stable and sidesteps needing a custom `Layout`; three 96pt cards +
    /// gaps fit the ~360pt content width the profile screens use.
    private func wrap<Content: View>(
        badges: [BadgeDefinition],
        @ViewBuilder card: @escaping (BadgeDefinition) -> Content
    ) -> some View {
        let columns = 3
        let rows = stride(from: 0, to: badges.count, by: columns).map { start in
            Array(badges[start..<min(start + columns, badges.count)])
        }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 6) {
                    ForEach(row) { badge in card(badge) }
                }
            }
        }
    }

    private func categoryLabel(_ category: BadgeCategory) -> String {
        L10n.t("achievements.category.\(category.rawValue)")
    }

    // MARK: loader

    private func load() async {
        do {
            let rows = try await AchievementsClient.earnedBadges(for: userId)
            earnedKeys = Set(rows.map(\.badgeKey))
        } catch {
            NSLog("[AchievementsSection] earnedBadges FAIL: \(error)")
            earnedKeys = []
        }
        loaded = true
    }
}
