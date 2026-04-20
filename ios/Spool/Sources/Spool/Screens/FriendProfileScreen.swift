import SwiftUI

/// Read-only friend profile. Reachable from FriendsScreen via a secondary
/// "view profile" affordance — the primary tap target on a friend row still
/// opens TwinScreen. Mirrors `ProfileScreen`'s paper-card structure (header,
/// bio, top 4, recent stubs) minus anything self-referential (gear, edit,
/// "currently obsessed" — obsessed uses "NOW PLAYING" copy that only makes
/// sense as the viewer's own top S-tier).
///
/// Two extra affordances that ProfileScreen doesn't have:
///   - Taste twin pill linking back to TwinScreen, so Profile ↔ Twin are
///     both reachable from either surface.
///   - Follow / unfollow button (optimistic local state — we don't refetch
///     follow edges cross-session).
///
/// Header last reviewed: 2026-04-19
public struct FriendProfileScreen: View {
    public var friend: Friend
    public var onClose: () -> Void
    public var onOpenTwin: () -> Void

    @State private var loading: Bool = true
    @State private var hasSession: Bool = false
    @State private var profile: ProfileRow?
    @State private var stubsCount: Int = 0
    @State private var topFour: [RankingRow] = []
    @State private var recent: [StubRow] = []
    @State private var compat: TasteCompatibility?
    @State private var mutualCount: Int = 0
    /// Optimistic follow state — seeded true on load because we got here from
    /// FriendsScreen which lists `getFollowing`. Flipping this locally after a
    /// tap avoids a round-trip to re-verify.
    @State private var isFollowing: Bool = true
    @State private var followBusy: Bool = false

    public init(friend: Friend,
                onClose: @escaping () -> Void,
                onOpenTwin: @escaping () -> Void = {}) {
        self.friend = friend
        self.onClose = onClose
        self.onOpenTwin = onOpenTwin
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 18)
                    .padding(.top, 50)
                    .padding(.bottom, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header.padding(.top, 6)
                        bioBox.padding(.top, 14)
                        twinPill.padding(.top, 14)
                        topFourSection.padding(.top, 18)
                        recentSection.padding(.top, 18)
                        footerPills.padding(.top, 16)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 110)
                }
                .refreshable { await reload() }
            }
        }
        .task { await reload() }
    }

    // MARK: top bar (back + follow toggle)

    private var topBar: some View {
        SpoolThemeReader { t, _ in
            HStack {
                Button("← FRIENDS", action: onClose)
                    .font(SpoolFonts.mono(12))
                    .tracking(1)
                    .foregroundStyle(t.ink)
                Spacer()
                if hasSession, friend.userID != nil {
                    followButton(t: t)
                }
            }
        }
    }

    private func followButton(t: SpoolPalette) -> some View {
        Button {
            Task { await toggleFollow() }
        } label: {
            Text(isFollowing ? "following" : "+ follow")
                .font(SpoolFonts.hand(12))
                .foregroundStyle(isFollowing ? t.cream : t.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isFollowing ? t.ink : Color.clear)
                )
                .overlay(Capsule().stroke(t.ink, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(followBusy)
        .opacity(followBusy ? 0.5 : 1.0)
        .accessibilityLabel(isFollowing ? "Unfollow" : "Follow")
    }

    // MARK: header

    private var header: some View {
        SpoolThemeReader { t, _ in
            HStack(alignment: .bottom, spacing: 14) {
                StripedAvatar(size: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayedHandle)
                        .font(SpoolFonts.serif(30))
                        .tracking(-0.5)
                        .foregroundStyle(t.ink)
                    Text(subheaderLine)
                        .font(SpoolFonts.hand(13))
                        .foregroundStyle(t.inkSoft)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(stubsCount)")
                        .font(SpoolFonts.serif(30))
                        .foregroundStyle(t.accent)
                    Text("STUBS")
                        .font(SpoolFonts.mono(9))
                        .tracking(2)
                        .foregroundStyle(t.inkSoft)
                }
            }
        }
    }

    private var displayedHandle: String {
        profile?.handle ?? friend.handle
    }

    private var subheaderLine: String {
        if let profile {
            if let d = profile.display_name, !d.isEmpty { return d }
            let line = profile.bioLines.first
            if !line.isEmpty { return line }
        }
        return friend.name.isEmpty ? "—" : friend.name
    }

    // MARK: bio

    private var bioBox: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 0) {
                Text(bioLine1)
                    .font(SpoolFonts.script(22))
                    .foregroundStyle(t.ink)
                Text(bioLine2)
                    .font(SpoolFonts.script(18))
                    .foregroundStyle(t.inkSoft)
            }
            .lineSpacing(1)
            .padding(14)
            .background(RuledLines(color: t.rule, step: 23))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(t.rule)
            )
        }
    }

    private var bioLine1: String {
        if let profile {
            let line = profile.bioLines.first
            return line.isEmpty ? "no bio yet." : line
        }
        return "—"
    }

    private var bioLine2: String {
        profile?.bioLines.second ?? ""
    }

    // MARK: taste twin pill

    @ViewBuilder
    private var twinPill: some View {
        if let compat {
            SpoolThemeReader { t, _ in
                Button(action: onOpenTwin) {
                    HStack(spacing: 8) {
                        Text("\(compat.score)% TASTE TWIN")
                            .font(SpoolFonts.mono(11))
                            .tracking(2)
                            .foregroundStyle(t.ink)
                        Text("· SEE MORE →")
                            .font(SpoolFonts.mono(10))
                            .tracking(1)
                            .foregroundStyle(t.accent)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(t.cream2))
                    .overlay(Capsule().stroke(t.ink, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open taste twin detail")
            }
        }
    }

    // MARK: top 4

    private var topFourSection: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 0) {
                Text("THEIR TOP 4 · ALL TIME")
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)

                HStack(spacing: 6) {
                    if topFour.isEmpty {
                        ForEach(0..<4, id: \.self) { i in
                            emptyTopFourCard(index: i, t: t)
                                .rotationEffect(.degrees(Self.rotationFor(i)))
                        }
                    } else {
                        ForEach(Array(topFour.prefix(4).enumerated()), id: \.offset) { i, row in
                            topFourCard(index: i,
                                        title: row.title,
                                        seed: Self.stableSeed(row.tmdb_id))
                                .rotationEffect(.degrees(Self.rotationFor(i)))
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func topFourCard(index: Int, title: String, seed: Int) -> some View {
        SpoolThemeReader { t, _ in
            ZStack(alignment: .topLeading) {
                PosterBlock(title: Self.firstWord(title), director: "—", seed: seed)
                Text("\(index + 1)")
                    .font(SpoolFonts.mono(10))
                    .foregroundStyle(t.ink)
                    .frame(width: 18, height: 18)
                    .background(t.yellow)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(t.ink, lineWidth: 1))
                    .rotationEffect(.degrees(-6))
                    .offset(x: 4, y: -4)
            }
        }
    }

    private func emptyTopFourCard(index: Int, t: SpoolPalette) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(t.cream2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(t.rule, lineWidth: 1.5)
                )
                .aspectRatio(2.0/3.0, contentMode: .fit)
            Text("—")
                .font(SpoolFonts.mono(10))
                .foregroundStyle(t.inkSoft)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: recent

    private var recentSection: some View {
        SpoolThemeReader { t, mode in
            VStack(alignment: .leading, spacing: 0) {
                Text("RECENT STUBS · \(Self.currentMonthAbbrev())")
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)

                HStack(spacing: 4) {
                    if recent.isEmpty {
                        ForEach(0..<5, id: \.self) { _ in
                            emptyRecentTile(t: t)
                        }
                    } else {
                        ForEach(Array(recent.prefix(5).enumerated()), id: \.offset) { _, stub in
                            recentTile(
                                title: stub.title,
                                year: Self.parseYear(stub.watched_date),
                                director: "—",
                                tier: Tier(rawValue: stub.tier) ?? .B,
                                seed: Self.stableSeed(stub.tmdb_id),
                                mode: mode, t: t
                            )
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func recentTile(title: String, year: Int, director: String,
                            tier: Tier, seed: Int,
                            mode: SpoolMode, t: SpoolPalette) -> some View {
        VStack(spacing: 0) {
            PosterBlock(title: Self.firstWord(title), year: year,
                        director: director, seed: seed, cornerRadius: 0)
                .frame(maxWidth: .infinity)
            Text(tier.rawValue)
                .font(SpoolFonts.serif(16))
                .foregroundStyle(tierColor(tier, mode: mode))
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(t.ink)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(t.ink, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func emptyRecentTile(t: SpoolPalette) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(t.cream2)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(t.rule, lineWidth: 1.5)
            )
            .aspectRatio(2.0/3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
    }

    // MARK: footer

    private var footerPills: some View {
        HStack(spacing: 6) {
            if mutualCount > 0 {
                SpoolPill("◉ \(mutualCount) mutual", size: .sm)
            }
            SpoolPill("\(stubsCount) stubs", size: .sm)
        }
    }

    // MARK: loader

    private func reload() async {
        loading = true
        defer { loading = false }

        let viewerID = await SpoolClient.currentUserID()
        hasSession = viewerID != nil

        // Preview mode — no session, show a friendly state. Friend fixtures
        // don't have a userID so we can't fetch anyway.
        guard let targetID = friend.userID else {
            profile = nil
            topFour = []
            recent = []
            stubsCount = 0
            compat = nil
            mutualCount = 0
            NSLog("[FriendProfileScreen] preview-mode (friend.userID nil)")
            return
        }

        async let profileRes = try? await ProfileRepository.shared.getProfile(id: targetID)
        async let topFourRes = try? await StubRepository.shared.getTopTier(
            userID: targetID, tier: .S, limit: 4
        )
        async let recentRes = try? await StubRepository.shared.getAllStubs(
            userID: targetID, limit: 5
        )
        async let countRes = try? await StubRepository.shared.countStubs(userID: targetID)

        profile = await profileRes ?? nil
        topFour = (await topFourRes) ?? []
        recent = (await recentRes) ?? []
        stubsCount = (await countRes) ?? 0

        // Viewer-dependent reads. Only fire when signed in — RLS would reject
        // these anyway, but skipping saves two round-trips in preview mode.
        if let viewerID {
            async let compatRes = try? await TasteRepository.shared
                .getTasteCompatibility(viewerID: viewerID, targetID: targetID)
            async let mutualRes = try? await FollowRepository.shared
                .getMutualFollowCount(viewerID: viewerID, targetID: targetID)
            compat = await compatRes ?? nil
            mutualCount = (await mutualRes) ?? 0
        } else {
            compat = nil
            mutualCount = 0
        }

        NSLog("[FriendProfileScreen] loaded handle=\(profile?.handle ?? friend.handle) stubs=\(stubsCount)")
    }

    private func toggleFollow() async {
        guard friend.userID != nil, !followBusy else { return }
        followBusy = true
        defer { followBusy = false }

        let target = friend.userID!
        let wasFollowing = isFollowing
        // Optimistic flip — revert on failure.
        isFollowing.toggle()

        do {
            let ok: Bool
            if wasFollowing {
                ok = try await FollowRepository.shared.unfollow(targetID: target)
            } else {
                ok = try await FollowRepository.shared.follow(targetID: target)
            }
            if !ok { isFollowing = wasFollowing }
        } catch {
            NSLog("[FriendProfileScreen] toggleFollow FAIL: \(error)")
            isFollowing = wasFollowing
        }
    }

    // MARK: helpers

    private static func firstWord(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }

    private static func stableSeed(_ id: String) -> Int {
        // See ProfileScreen.stableSeed — process-stable across launches so
        // poster palettes don't re-shuffle.
        if let digits = id.split(separator: "_").last.flatMap({ Int($0) }) {
            return abs(digits) % 10
        }
        var h: UInt64 = 5381
        for b in id.utf8 { h = h &* 33 &+ UInt64(b) }
        return Int(h % 10)
    }

    private static func parseYear(_ dateString: String) -> Int {
        let parts = dateString.split(separator: "-")
        return parts.first.flatMap { Int($0) } ?? Calendar.current.component(.year, from: Date())
    }

    private static func rotationFor(_ index: Int) -> Double {
        [-3, 2, -1, 3][index % 4]
    }

    private static func currentMonthAbbrev() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM"
        return f.string(from: Date()).uppercased()
    }
}

#Preview {
    FriendProfileScreen(friend: SpoolData.friends[0], onClose: {}).spoolMode(.paper)
}
