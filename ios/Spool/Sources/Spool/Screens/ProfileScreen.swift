import SwiftUI

public struct ProfileScreen: View {
    public var onOpenSettings: () -> Void

    @State private var hasSession: Bool = false
    @State private var loading: Bool = true
    @State private var profile: ProfileRow?
    @State private var stubsCount: Int = 0
    @State private var friendsCount: Int = 0
    @State private var topFour: [RankingRow] = []
    @State private var recent: [StubRow] = []
    @State private var topTwin: (handle: String, score: Int)?

    public init(onOpenSettings: @escaping () -> Void = {}) {
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        SpoolScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar.padding(.top, 14)
                    header.padding(.top, 26)
                    bioBox.padding(.top, 14)
                    obsessed.padding(.top, 18)
                    topFourSection.padding(.top, 18)
                    recentSection.padding(.top, 18)
                    footerPills.padding(.top, 16)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 110)
            }
            .refreshable { await reload() }
        }
        .task { await reload() }
    }

    /// Top-right settings affordance. Kept minimal so it doesn't compete with
    /// the page header — just a gear glyph inside a circle matching the
    /// palette toggle in SpoolAppRoot.
    private var topBar: some View {
        SpoolThemeReader { t, _ in
            HStack {
                Spacer()
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(t.ink)
                        .padding(9)
                        .background(Circle().fill(t.cream2))
                        .overlay(Circle().stroke(t.ink, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open settings")
            }
        }
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
        if let profile { return profile.handle }
        return hasSession ? "@you" : SpoolData.me.handle
    }

    private var subheaderLine: String {
        // Profiles table has no pronouns/city columns; display-name is the
        // closest thing. If the display name is empty, fall back to the
        // first line of bio so the row isn't blank.
        if let profile {
            if let d = profile.display_name, !d.isEmpty { return d }
            let line = profile.bioLines.first
            return line.isEmpty ? "—" : line
        }
        return hasSession ? "—" : "\(SpoolData.me.pronouns) · \(SpoolData.me.city)"
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
            return line.isEmpty ? "add a bio in settings." : line
        }
        return hasSession ? "add a bio in settings." : SpoolData.me.bioLine1
    }

    private var bioLine2: String {
        if let profile {
            return profile.bioLines.second
        }
        return hasSession ? "" : SpoolData.me.bioLine2
    }

    // MARK: obsessed — picks the newest S-tier as "now playing"

    private var obsessed: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 0) {
                Text("CURRENTLY OBSESSED")
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)

                ZStack {
                    VStack(spacing: 4) {
                        Text("NOW PLAYING")
                            .font(SpoolFonts.mono(10))
                            .tracking(3)
                            .foregroundStyle(t.cream.opacity(0.6))
                        Text(obsessedTitle.uppercased())
                            .font(SpoolFonts.serif(30))
                            .tracking(1)
                            .foregroundStyle(t.yellow)
                            .padding(.top, 2)
                        Text(obsessedSub)
                            .font(SpoolFonts.script(16))
                            .foregroundStyle(t.cream.opacity(0.8))
                    }
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                }
                .background(t.ink)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .top) { Bulbs(count: 9).padding(.horizontal, 12).padding(.top, 6) }
                .overlay(alignment: .bottom) { Bulbs(count: 9).padding(.horizontal, 12).padding(.bottom, 6) }
                .padding(.top, 6)
            }
        }
    }

    private var obsessedTitle: String {
        topFour.first?.title ?? (hasSession ? "nothing yet" : "Past Lives")
    }

    private var obsessedSub: String {
        if topFour.isEmpty {
            return hasSession ? "rank an S-tier to light this up" : "3rd rewatch this month"
        }
        return "your top S-tier."
    }

    // MARK: top 4 + recent

    private var topFourSection: some View {
        SpoolThemeReader { _, _ in
            VStack(alignment: .leading, spacing: 0) {
                Text("MY TOP 4 · ALL TIME")
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(SpoolTokens.paper.inkSoft)

                HStack(spacing: 6) {
                    if topFour.isEmpty {
                        ForEach(Array(SpoolData.topFour.enumerated()), id: \.offset) { i, m in
                            topFourCard(index: i, title: m.title, seed: m.seed, posterUrl: nil)
                                .rotationEffect(.degrees(Self.rotationFor(i)))
                                .opacity(hasSession ? 0.45 : 1.0)
                        }
                    } else {
                        ForEach(Array(topFour.prefix(4).enumerated()), id: \.offset) { i, row in
                            topFourCard(index: i,
                                        title: row.title,
                                        seed: Self.stableSeed(row.tmdb_id),
                                        posterUrl: row.poster_url)
                                .rotationEffect(.degrees(Self.rotationFor(i)))
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func topFourCard(index: Int, title: String, seed: Int, posterUrl: String?) -> some View {
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

    private var recentSection: some View {
        SpoolThemeReader { t, mode in
            VStack(alignment: .leading, spacing: 0) {
                Text("RECENT STUBS · \(Self.currentMonthAbbrev())")
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)

                HStack(spacing: 4) {
                    if recent.isEmpty {
                        ForEach(SpoolData.recent.prefix(5), id: \.self) { m in
                            recentTile(title: m.title, year: m.year, director: m.director,
                                       tier: m.tier, seed: m.seed, mode: mode, t: t)
                                .opacity(hasSession ? 0.45 : 1.0)
                        }
                    } else {
                        ForEach(Array(recent.prefix(5).enumerated()), id: \.offset) { _, stub in
                            if let tier = Tier(rawValue: stub.tier) {
                                recentTile(
                                    title: stub.title,
                                    year: Self.parseYear(stub.watched_date),
                                    director: "—",
                                    tier: tier,
                                    seed: Self.stableSeed(stub.tmdb_id),
                                    mode: mode, t: t
                                )
                            }
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

    // MARK: footer

    private var footerPills: some View {
        HStack(spacing: 6) {
            SpoolPill("◉ \(friendsCount) friends", size: .sm)
            if let twin = topTwin {
                SpoolPill("taste twin \(twin.handle) · \(twin.score)%", size: .sm)
            }
            // Recap pill hidden until the monthly-recap experience is real.
        }
    }

    // MARK: loader

    private func reload() async {
        loading = true
        defer { loading = false }

        let userID = await SpoolClient.currentUserID()
        hasSession = userID != nil
        NSLog("[ProfileScreen] reload: userID=\(userID?.uuidString ?? "nil"), isConfigured=\(SpoolClient.isConfigured)")

        guard let userID else {
            profile = nil
            stubsCount = SpoolData.me.stubs
            topFour = []
            recent = []
            friendsCount = SpoolData.friends.count
            topTwin = nil
            return
        }

        // Fetch everything in parallel — log each failure so we can see which
        // specific read blew up instead of silently falling back.
        do {
            profile = try await ProfileRepository.shared.getMyProfile()
            NSLog("[ProfileScreen] profile ok: \(profile?.username ?? "nil")")
        } catch {
            NSLog("[ProfileScreen] profile FAIL: \(error)")
            profile = nil
        }
        do {
            stubsCount = try await StubRepository.shared.countStubs(userID: userID)
            NSLog("[ProfileScreen] stubsCount ok: \(stubsCount)")
        } catch {
            NSLog("[ProfileScreen] stubsCount FAIL: \(error)")
            stubsCount = 0
        }
        do {
            topFour = try await StubRepository.shared.getTopTier(userID: userID, tier: .S, limit: 4)
            NSLog("[ProfileScreen] topFour ok: \(topFour.count) rows")
        } catch {
            NSLog("[ProfileScreen] topFour FAIL: \(error)")
            topFour = []
        }
        do {
            recent = try await StubRepository.shared.getAllStubs(userID: userID, limit: 5)
            NSLog("[ProfileScreen] recent ok: \(recent.count) rows")
        } catch {
            NSLog("[ProfileScreen] recent FAIL: \(error)")
            recent = []
        }

        let followed: [FollowedProfile]
        do {
            followed = try await FollowRepository.shared.getFollowing(userID: userID)
            NSLog("[ProfileScreen] following ok: \(followed.count) profiles")
        } catch {
            NSLog("[ProfileScreen] following FAIL: \(error)")
            followed = []
        }
        friendsCount = followed.count

        if !followed.isEmpty {
            do {
                let scores = try await TasteRepository.shared.getCompatibilityScores(
                    viewerID: userID, targetIDs: followed.map(\.id)
                )
                if let (topID, topScore) = scores.max(by: { $0.value < $1.value }),
                   let hit = followed.first(where: { $0.id == topID }) {
                    topTwin = (hit.profile.handle, topScore)
                } else {
                    topTwin = nil
                }
            } catch {
                NSLog("[ProfileScreen] topTwin FAIL: \(error)")
                topTwin = nil
            }
        } else {
            topTwin = nil
        }
    }

    // MARK: helpers

    private static func firstWord(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }

    private static func stableSeed(_ id: String) -> Int {
        abs(id.hashValue) % 10
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

    private static func currentMonthName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "LLLL"
        return f.string(from: Date()).lowercased()
    }
}

#Preview {
    ProfileScreen().spoolMode(.paper)
}
