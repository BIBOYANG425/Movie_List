import SwiftUI

public struct TwinScreen: View {
    public var friend: Friend
    public var onClose: () -> Void

    @State private var compat: TasteCompatibility?
    @State private var recs: [RecommendedMovie] = []
    @State private var loading: Bool = true
    @State private var viewerHandle: String = "you"

    public init(friend: Friend, onClose: @escaping () -> Void) {
        self.friend = friend
        self.onClose = onClose
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                HStack {
                    Button("← FRIENDS", action: onClose)
                        .font(SpoolFonts.mono(12))
                        .tracking(1)
                        .foregroundStyle(SpoolTokens.paper.ink)
                    Spacer()
                    SpoolPill("↗ share card", size: .sm)
                }
                .padding(.horizontal, 18)
                .padding(.top, 50)
                .padding(.bottom, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        tasteTwinCard

                        Text("YOUR LIBRARIES")
                            .font(SpoolFonts.mono(10))
                            .tracking(2)
                            .foregroundStyle(SpoolTokens.paper.inkSoft)
                            .padding(.top, 22)

                        VennChart(
                            friendHandle: friend.handle,
                            viewerOnly: compat?.viewerOnlyCount ?? 24,
                            targetOnly: compat?.targetOnlyCount ?? 19,
                            shared: compat?.sharedCount ?? 38
                        )
                        .frame(height: 200)
                        .padding(.top, 6)

                        Text("BIGGEST FIGHTS")
                            .font(SpoolFonts.mono(10))
                            .tracking(2)
                            .foregroundStyle(SpoolTokens.paper.inkSoft)
                            .padding(.top, 8)

                        fightsSection

                        Text("RECOMMEND TO \(friend.handle.uppercased())")
                            .font(SpoolFonts.mono(10))
                            .tracking(2)
                            .foregroundStyle(SpoolTokens.paper.inkSoft)
                            .padding(.top, 16)

                        recsSection

                        HStack {
                            Spacer()
                            SpoolPill("send 3 recs →", filled: true)
                            Spacer()
                        }
                        .padding(.top, 12)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 110)
                }
            }
        }
        .task { await reload() }
    }

    // MARK: taste twin card

    private var tasteTwinCard: some View {
        SpoolThemeReader { t, _ in
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Text("SPOOL · TASTE TWIN")
                        .font(SpoolFonts.mono(9))
                        .tracking(3)
                        .foregroundStyle(t.inkSoft)
                        .frame(maxWidth: .infinity)

                    HStack(spacing: 14) {
                        StripedAvatar(size: 56)
                        Text("\(displayedScore)%")
                            .font(SpoolFonts.serif(44))
                            .foregroundStyle(t.accent)
                        StripedAvatar(size: 56)
                    }
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .center)

                    Text("\(viewerHandle) × \(friend.handle)")
                        .font(SpoolFonts.hand(14))
                        .foregroundStyle(t.ink)
                        .padding(.top, 4)

                    DashedLine(color: t.rule).padding(.vertical, 12)

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(twinSummaryLines.enumerated()), id: \.offset) { _, line in
                            line
                        }
                    }
                    .font(SpoolFonts.script(17))
                    .foregroundStyle(t.ink)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .background(t.cream)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(t.ink, lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.08), radius: 0, x: 0, y: 4)

                Tape().rotationEffect(.degrees(-4)).offset(x: -90, y: -8)
                Tape(color: Color(hex: 0xCE3B1F).opacity(0.35))
                    .rotationEffect(.degrees(5))
                    .offset(x: 90, y: -8)
            }
            .rotationEffect(.degrees(-1))
            .padding(.top, 8)
        }
    }

    /// Score shown in the big number. Prefer the freshly-computed overall
    /// score over the one passed through from FriendsScreen; they should
    /// agree, but real data wins if they disagree after a rank change.
    private var displayedScore: Int {
        compat?.score ?? friend.twin
    }

    /// Three hand-scripted lines that summarize the taste relationship.
    /// Built from real data when available, falls back to generic placeholders
    /// when we don't have enough signal.
    private var twinSummaryLines: [Text] {
        guard let compat, compat.sharedCount > 0 else {
            return [
                Text("you both love ") + markText("a24 heartbreak") + Text("."),
                Text("she's into ") + markText("body horror") + Text(", you aren't."),
                Text("you're a ") + markText("wong kar-wai") + Text(" head, she's new.")
            ]
        }

        var lines: [Text] = []
        // Strongest agreement line — the top shared S/A title
        if let shared = compat.topShared.first {
            lines.append(
                Text("you both ") + markText("obsess over ") + markText(shared.title) + Text(".")
            )
        }
        // Biggest fight line — the widest tier split
        if let fight = compat.biggestFights.first, abs(fight.tierDelta) >= 2 {
            let verb = fight.tierDelta > 0 ? "loves" : "is over"
            let target = fight.tierDelta > 0 ? "you love" : "she loves"
            lines.append(
                Text("\(target) ") + markText(fight.title) + Text(", she \(verb) it less.")
            )
        }
        // Disagreement count line if we have enough data to make it feel real
        if compat.sharedCount >= 5 {
            lines.append(
                Text("you agree on ") + markText("\(compat.agreements)") +
                Text(" and argue about ") + markText("\(compat.disagreements)") + Text(".")
            )
        }
        while lines.count < 3 {
            lines.append(Text("shared \(compat.sharedCount) films so far."))
        }
        return Array(lines.prefix(3))
    }

    // MARK: fights + recs sections

    @ViewBuilder
    private var fightsSection: some View {
        if loading {
            Color.clear.frame(height: 40)
        } else if let fights = compat?.biggestFights.filter({ abs($0.tierDelta) >= 2 }),
                  !fights.isEmpty {
            ForEach(Array(fights.prefix(3).enumerated()), id: \.offset) { _, movie in
                fightRow(movie).padding(.top, 8)
            }
        } else if friend.userID == nil {
            // Preview mode — keep fixture fights
            ForEach(SpoolData.twinFights, id: \.self) { f in
                fixtureFightRow(f).padding(.top, 8)
            }
        } else {
            SpoolThemeReader { t, _ in
                Text("no big disagreements yet. rank more to find friction.")
                    .font(SpoolFonts.hand(13))
                    .foregroundStyle(t.inkSoft)
                    .padding(.vertical, 14)
            }
        }
    }

    @ViewBuilder
    private var recsSection: some View {
        if loading {
            Color.clear.frame(height: 120)
        } else if !recs.isEmpty {
            HStack(spacing: 8) {
                ForEach(recs) { r in
                    VStack(spacing: 4) {
                        PosterBlock(title: firstWord(r.title), director: "—",
                                    seed: Self.stableSeed(r.tmdbId))
                        Text(r.title)
                            .font(SpoolFonts.mono(9))
                            .foregroundStyle(SpoolTokens.paper.inkSoft)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8)
        } else if friend.userID == nil {
            // Preview mode — fixture recs
            HStack(spacing: 8) {
                ForEach(SpoolData.twinRecs, id: \.self) { r in
                    VStack(spacing: 4) {
                        PosterBlock(title: firstWord(r.t), director: "—", seed: r.s)
                        Text(r.t)
                            .font(SpoolFonts.mono(9))
                            .foregroundStyle(SpoolTokens.paper.inkSoft)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 8)
        } else {
            SpoolThemeReader { t, _ in
                Text("nothing to recommend yet — rank more S/A films.")
                    .font(SpoolFonts.hand(13))
                    .foregroundStyle(t.inkSoft)
                    .padding(.vertical, 14)
            }
        }
    }

    private func fightRow(_ movie: SharedMovie) -> some View {
        SpoolThemeReader { t, _ in
            HStack(spacing: 10) {
                PosterBlock(title: firstWord(movie.title), director: "—",
                            seed: Self.stableSeed(movie.tmdbId))
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(movie.title)
                        .font(SpoolFonts.serif(15))
                        .foregroundStyle(t.ink)
                    Text("you \(movie.viewerTier.rawValue) · her \(movie.targetTier.rawValue)")
                        .font(SpoolFonts.hand(11))
                        .foregroundStyle(t.inkSoft)
                }
                Spacer()
                TierStamp(tier: movie.viewerTier, size: 26)
                Text("argue →").font(SpoolFonts.script(16)).foregroundStyle(t.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(t.cream2)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(t.rule, lineWidth: 1.5)
            )
        }
    }

    private func fixtureFightRow(_ f: TwinFight) -> some View {
        SpoolThemeReader { t, _ in
            HStack(spacing: 10) {
                PosterBlock(title: firstWord(f.t), director: "—", seed: f.s)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.t)
                        .font(SpoolFonts.serif(15))
                        .foregroundStyle(t.ink)
                    Text("you \(f.yours.rawValue) · her \(f.theirs.rawValue)")
                        .font(SpoolFonts.hand(11))
                        .foregroundStyle(t.inkSoft)
                }
                Spacer()
                TierStamp(tier: f.yours, size: 26)
                Text("argue →").font(SpoolFonts.script(16)).foregroundStyle(t.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(t.cream2)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(t.rule, lineWidth: 1.5)
            )
        }
    }

    // MARK: loader

    private func reload() async {
        loading = true
        defer { loading = false }

        guard let targetID = friend.userID,
              let viewerID = await SpoolClient.currentUserID() else {
            // Preview mode — keep fixtures (rendered by the sections above
            // when userID is nil).
            compat = nil
            recs = []
            return
        }

        // Hydrate viewer handle for the card's "@you × @friend" line.
        if let me = try? await ProfileRepository.shared.getMyProfile() {
            viewerHandle = me.handle
        }

        async let compatRes = try? TasteRepository.shared
            .getTasteCompatibility(viewerID: viewerID, targetID: targetID)
        async let recsRes = try? TasteRepository.shared
            .getRecommendationsForFriend(viewerID: viewerID, targetID: targetID, limit: 4)

        compat = (await compatRes) ?? nil
        recs = (await recsRes) ?? []
    }

    // MARK: helpers

    private func markText(_ s: String) -> Text {
        Text(s).foregroundColor(SpoolTokens.paper.ink)
    }

    private func firstWord(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }

    private static func stableSeed(_ id: String) -> Int {
        abs(id.hashValue) % 10
    }
}

struct DashedLine: View {
    var color: Color
    var body: some View {
        Rectangle()
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            .foregroundStyle(color)
            .frame(height: 1)
    }
}

struct VennChart: View {
    let friendHandle: String
    let viewerOnly: Int
    let targetOnly: Int
    let shared: Int

    var body: some View {
        SpoolThemeReader { t, mode in
            GeometryReader { g in
                let w = g.size.width
                let h = g.size.height
                let r = min(w * 0.25, h * 0.4)
                let c1 = CGPoint(x: w * 0.36, y: h * 0.5)
                let c2 = CGPoint(x: w * 0.64, y: h * 0.5)

                ZStack {
                    Circle()
                        .fill((mode == .paper ? Color(hex: 0xCE3B1F, opacity: 0.10) : Color(hex: 0xF5C33B, opacity: 0.12)))
                        .frame(width: r * 2, height: r * 2)
                        .overlay(Circle().stroke(t.ink, lineWidth: 1.8))
                        .position(c1)
                    Circle()
                        .fill(mode == .paper ? Color.black.opacity(0.06) : Color(hex: 0xF2ECDC, opacity: 0.08))
                        .frame(width: r * 2, height: r * 2)
                        .overlay(Circle().stroke(t.ink, lineWidth: 1.8))
                        .position(c2)

                    Text("you only")
                        .font(SpoolFonts.hand(14))
                        .foregroundStyle(t.ink)
                        .position(x: w * 0.18, y: h * 0.14)
                    Text("\(viewerOnly) films")
                        .font(SpoolFonts.mono(11))
                        .foregroundStyle(t.inkSoft)
                        .position(x: w * 0.18, y: h * 0.22)

                    Text("\(friendHandle.replacingOccurrences(of: "@", with: "")) only")
                        .font(SpoolFonts.hand(14))
                        .foregroundStyle(t.ink)
                        .position(x: w * 0.82, y: h * 0.14)
                    Text("\(targetOnly) films")
                        .font(SpoolFonts.mono(11))
                        .foregroundStyle(t.inkSoft)
                        .position(x: w * 0.82, y: h * 0.22)

                    Text("both ♡ \(shared)")
                        .font(SpoolFonts.script(20))
                        .foregroundStyle(t.accent)
                        .position(x: w * 0.5, y: h * 0.06)
                }
            }
        }
    }
}

#Preview {
    TwinScreen(friend: SpoolData.friends[0], onClose: {}).spoolMode(.paper)
}
