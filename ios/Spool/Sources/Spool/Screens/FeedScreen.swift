import SwiftUI

public struct FeedScreen: View {
    @AppStorage("spool.user_handle") private var userHandle: String = "you"
    @State private var filter: FeedFilter = .week
    @State private var liveEvents: [ActivityEventRow] = []
    @State private var loading: Bool = true
    @State private var hasSession: Bool = false

    /// Invoked when the signed-in empty state's "rank something" CTA is tapped.
    /// SpoolAppRoot wires this to its rank-tab handler.
    private let onRankTap: (() -> Void)?

    public init(onRankTap: (() -> Void)? = nil) {
        self.onRankTap = onRankTap
    }

    enum FeedFilter { case all, week }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                SpoolHeader(title: "friends") {
                    HStack(spacing: 6) {
                        SpoolPill("all",     active: filter == .all,  size: .sm) { filter = .all }
                        SpoolPill("◷ week",  active: filter == .week, size: .sm) { filter = .week }
                    }
                }
                ScrollView {
                    content
                        .padding(.horizontal, 16)
                        .padding(.bottom, 110)
                        .padding(.top, 2)
                }
                .refreshable { await reload() }
            }
        }
        .task { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if hasSession {
            if liveFeedItems.isEmpty {
                signedInEmptyState
            } else {
                VStack(spacing: 14) {
                    ForEach(Array(liveFeedItems.enumerated()), id: \.element.id) { i, item in
                        FeedCardView(item: item, tilt: tiltFor(i))
                    }
                }
            }
        } else {
            VStack(spacing: 14) {
                demoHeaderCard
                ForEach(Array(SpoolData.feed.enumerated()), id: \.element.id) { i, item in
                    FeedCardView(item: item, tilt: tiltFor(i + 1))
                }
            }
        }
    }

    private var demoHeaderCard: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 6) {
                Text("DEMO — SIGN IN TO SEE REAL FRIENDS")
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(t.ink)
                Text("the cards below are sample friends. your real feed starts the moment you sign in.")
                    .font(SpoolFonts.hand(13))
                    .foregroundStyle(t.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(t.yellow.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(t.ink, lineWidth: 1.5)
            )
        }
    }

    private var signedInEmptyState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 16) {
                Spacer(minLength: 40)
                Text("no rankings yet")
                    .font(SpoolFonts.serif(26))
                    .foregroundStyle(t.ink)
                Text("rank something to start your feed")
                    .font(SpoolFonts.hand(15))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                SpoolPill("rank something", filled: true, size: .md) {
                    onRankTap?()
                }
                .padding(.top, 4)
                Spacer(minLength: 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, 24)
        }
    }

    private var liveFeedItems: [FeedItem] {
        liveEvents.compactMap { event -> FeedItem? in
            guard event.event_type == "ranking_add",
                  let title = event.media_title,
                  let tierStr = event.media_tier,
                  let tier = Tier(rawValue: tierStr) else { return nil }
            let seed = Int(event.media_tmdb_id?.hashValue ?? title.hashValue) % 12
            return FeedItem(
                actor: FeedActor(handle: "@\(userHandle)", when: relativeTime(from: event.created_at)),
                kind: .rank(title: title, tier: tier, line: "",
                            moods: [], seed: abs(seed), stubNo: "#\(String(event.id.uuidString.prefix(4)))"),
                likes: 0, comments: 0, seen: "just now"
            )
        }
    }

    private func reload() async {
        let userID = await SpoolClient.currentUserID()
        let sessionPresent = userID != nil

        if sessionPresent {
            do {
                let events = try await RankingRepository.shared.getRecentActivity(limit: 25)
                await MainActor.run {
                    liveEvents = events
                    hasSession = true
                    loading = false
                }
            } catch {
                await MainActor.run {
                    liveEvents = []
                    hasSession = true
                    loading = false
                }
            }
        } else {
            await MainActor.run {
                liveEvents = []
                hasSession = false
                loading = false
            }
        }
    }

    private func relativeTime(from iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? Date()
        let interval = Date().timeIntervalSince(date)
        if interval < 60       { return "now" }
        if interval < 3600     { return "\(Int(interval / 60))m" }
        if interval < 86400    { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }

    private func tiltFor(_ i: Int) -> Double {
        switch i % 4 {
        case 0: return -0.8
        case 1: return  0.6
        case 2: return -0.4
        default: return 0.5
        }
    }
}

struct FeedCardView: View {
    let item: FeedItem
    let tilt: Double

    var body: some View {
        SpoolThemeReader { t, mode in
            VStack(alignment: .leading, spacing: 0) {
                switch item.kind {
                case let .rank(title, tier, line, moods, seed, stubNo):
                    rankCard(title: title, tier: tier, line: line, moods: moods,
                             seed: seed, stubNo: stubNo, t: t, mode: mode)
                case let .shuffle(line, titles):
                    shuffleCard(line: line, titles: titles, t: t, mode: mode)
                case let .milestone(headline, sub):
                    milestoneCard(headline: headline, sub: sub, t: t, mode: mode)
                }
            }
            .padding(12)
            .background(cardBackground(t: t))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(t.ink, lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 0, x: 0, y: 2)
            .rotationEffect(.degrees(tilt))
            .overlay(alignment: .topLeading) { tapeOverlay(mode: mode) }
        }
    }

    @ViewBuilder
    private func cardBackground(t: SpoolPalette) -> some View {
        if case .milestone = item.kind {
            t.ink
        } else {
            t.cream
        }
    }

    @ViewBuilder
    private func tapeOverlay(mode: SpoolMode) -> some View {
        if case .milestone = item.kind {
            EmptyView()
        } else if case .shuffle = item.kind {
            Tape(color: Color(hex: 0xCE3B1F).opacity(0.35))
                .rotationEffect(.degrees(5))
                .offset(x: 200, y: -8)
        } else if case .rank = item.kind {
            Tape()
                .rotationEffect(.degrees(-6))
                .offset(x: 22, y: -8)
        }
    }

    // MARK: card variants

    @ViewBuilder
    private func rankCard(title: String, tier: Tier, line: String, moods: [String],
                          seed: Int, stubNo: String, t: SpoolPalette, mode: SpoolMode) -> some View {
        feedHeader(actor: item.actor, t: t, action: {
            HStack(spacing: 2) {
                Text("ranked")
                TierStamp(tier: tier, size: 18)
            }
        })
        AdmitStub(
            movie: Movie(id: title, title: title, year: 2023, director: "celine song", seed: seed),
            tier: tier, line: line, moods: moods,
            handle: item.actor.handle, stubNo: stubNo, compact: true
        )
        .padding(.top, 8)
        feedActions(likes: item.likes, comments: item.comments, seen: item.seen, dark: false, t: t)
    }

    @ViewBuilder
    private func shuffleCard(line: String, titles: [ShuffleTitle], t: SpoolPalette, mode: SpoolMode) -> some View {
        feedHeader(actor: item.actor, t: t, action: { Text("bumped 3 in A-tier") })
        HStack(spacing: 6) {
            ForEach(Array(titles.enumerated()), id: \.offset) { idx, st in
                if idx > 0 {
                    Text(st.direction == .up ? "↑↑" : (st.direction == .down ? "↓" : "—"))
                        .font(SpoolFonts.script(28))
                        .foregroundStyle(st.direction == .up ? t.accent : t.inkSoft)
                }
                PosterBlock(title: st.title, director: "—", seed: st.seed)
                    .frame(width: 52)
            }
        }
        .padding(.top, 10)
        Text("\"\(line)\"")
            .font(SpoolFonts.script(18))
            .foregroundStyle(t.ink)
            .padding(.top, 8)
        feedActions(likes: item.likes, comments: item.comments, seen: item.seen, dark: false, t: t)
    }

    @ViewBuilder
    private func milestoneCard(headline: String, sub: String, t: SpoolPalette, mode: SpoolMode) -> some View {
        ZStack {
            VStack(spacing: 6) {
                Text("NOW PLAYING · MILESTONE")
                    .font(SpoolFonts.mono(10))
                    .tracking(3)
                    .foregroundStyle(t.cream.opacity(0.6))
                Text(headline)
                    .font(SpoolFonts.serif(36))
                    .tracking(1)
                    .foregroundStyle(t.yellow)
                    .padding(.top, 6)
                Text(sub)
                    .font(SpoolFonts.script(20))
                    .foregroundStyle(t.cream)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 14)
            .overlay(alignment: .top) { Bulbs().padding(.horizontal, 12).padding(.top, 6) }
            .overlay(alignment: .bottom) { Bulbs().padding(.horizontal, 12).padding(.bottom, 6) }
        }
        feedActions(likes: item.likes, comments: item.comments, seen: item.seen, dark: true, t: t)
    }

    // MARK: primitives

    @ViewBuilder
    private func feedHeader<Action: View>(actor: FeedActor, t: SpoolPalette,
                                          @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            StripedAvatar(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(actor.handle).font(SpoolFonts.hand(14, weight: .bold))
                    action().font(SpoolFonts.hand(14))
                }
                .foregroundStyle(t.ink)
                Text("\(actor.when.uppercased()) AGO")
                    .font(SpoolFonts.mono(9))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func feedActions(likes: Int, comments: Int, seen: String, dark: Bool, t: SpoolPalette) -> some View {
        HStack(spacing: 14) {
            Text("♡ \(likes)")
            Text("💬 \(comments)")
            Spacer()
            Text(seen)
        }
        .font(SpoolFonts.mono(10))
        .tracking(1)
        .foregroundStyle(dark ? t.cream.opacity(0.7) : t.inkSoft)
        .padding(.top, 10)
    }
}

#Preview {
    FeedScreen().spoolMode(.paper)
}
