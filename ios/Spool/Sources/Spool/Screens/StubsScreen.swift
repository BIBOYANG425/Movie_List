import SwiftUI

public struct StubsScreen: View {
    public var onOpenDetail: (WatchedDay) -> Void

    @State private var hasSession: Bool = false
    @State private var loading: Bool = true
    @State private var topItems: [RankedItem] = []
    @State private var recentItems: [RankedItem] = []

    public init(onOpenDetail: @escaping (WatchedDay) -> Void = { _ in }) {
        self.onOpenDetail = onOpenDetail
    }

    public var body: some View {
        SpoolScreen {
            VStack(spacing: 0) {
                SpoolHeader(title: "my stubs") {
                    SpoolPill(monthLabel, active: true, size: .sm)
                }

                ScrollView {
                    content
                        .padding(.horizontal, 18)
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
        if loading {
            // Prevent a one-frame flash of preview-mode fixtures before
            // `reload()` resolves, same as FeedScreen.
            Color.clear.frame(height: 1)
        } else if hasSession {
            if topItems.isEmpty {
                signedInEmptyState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    topFourSection(items: topItems).padding(.top, 6)
                    recentSection(items: recentItems).padding(.top, 22)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                demoHeaderCard.padding(.top, 2)
                topFourSection(items: fixtureTopFour).padding(.top, 18)
                recentSection(items: fixtureRecent).padding(.top, 22)
            }
        }
    }

    // MARK: sections

    private func topFourSection(items: [RankedItem]) -> some View {
        SpoolThemeReader { _, _ in
            VStack(alignment: .leading, spacing: 0) {
                Text("MY TOP 4 · ALL TIME")
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(SpoolTokens.paper.inkSoft)

                HStack(spacing: 6) {
                    ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { i, item in
                        topFourCard(index: i, item: item)
                            .rotationEffect(.degrees([-3, 2, -1, 3][i % 4]))
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func topFourCard(index: Int, item: RankedItem) -> some View {
        SpoolThemeReader { t, _ in
            ZStack(alignment: .topLeading) {
                PosterBlock(
                    title: firstWord(item.title),
                    director: item.director,
                    seed: item.seed,
                    posterUrl: item.posterUrl
                )
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

    private func recentSection(items: [RankedItem]) -> some View {
        SpoolThemeReader { t, mode in
            VStack(alignment: .leading, spacing: 0) {
                Text("RECENT STUBS · \(monthLabel.uppercased())")
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(items.prefix(12).enumerated()), id: \.offset) { _, item in
                            recentCard(item: item, t: t, mode: mode)
                                .frame(width: 100)
                                .onTapGesture {
                                    onOpenDetail(watchedDay(from: item))
                                }
                        }
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private func recentCard(item: RankedItem, t: SpoolPalette, mode: SpoolMode) -> some View {
        VStack(spacing: 0) {
            PosterBlock(
                title: firstWord(item.title),
                year: item.year,
                director: item.director,
                seed: item.seed,
                cornerRadius: 0,
                posterUrl: item.posterUrl
            )
            .frame(maxWidth: .infinity)

            Text(item.tier.rawValue)
                .font(SpoolFonts.serif(20))
                .foregroundStyle(tierColor(item.tier, mode: mode))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(t.ink)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(t.ink, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: empty + demo

    private var signedInEmptyState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 16) {
                Spacer(minLength: 40)
                Text("no stubs yet")
                    .font(SpoolFonts.serif(26))
                    .foregroundStyle(t.ink)
                Text("rank a movie to collect your first stub")
                    .font(SpoolFonts.hand(15))
                    .foregroundStyle(t.inkSoft)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .padding(.horizontal, 24)
        }
    }

    private var demoHeaderCard: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 6) {
                Text("DEMO — SIGN IN TO SEE YOUR STUBS")
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(t.ink)
                Text("these are sample picks. your real top 4 and recent stubs appear once you sign in and rank.")
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

    // MARK: data

    private func reload() async {
        let userID = await SpoolClient.currentUserID()
        let sessionPresent = userID != nil

        if sessionPresent {
            do {
                let all = try await RankingRepository.shared.getAllRankedItems()
                let top = Array(all.prefix(4))
                let recent = Array(all.prefix(12))
                await MainActor.run {
                    topItems = top
                    recentItems = recent
                    hasSession = true
                    loading = false
                }
            } catch {
                await MainActor.run {
                    topItems = []
                    recentItems = []
                    hasSession = true
                    loading = false
                }
            }
        } else {
            await MainActor.run {
                topItems = []
                recentItems = []
                hasSession = false
                loading = false
            }
        }
    }

    // MARK: fixtures (preview-mode only)

    private var fixtureTopFour: [RankedItem] {
        SpoolData.topFour.enumerated().map { i, entry in
            RankedItem(id: "fixture-top-\(i)", title: entry.title,
                       year: nil, director: "—",
                       tier: .S, rank: i + 1, seed: entry.seed)
        }
    }

    private var fixtureRecent: [RankedItem] {
        SpoolData.recent.enumerated().map { i, stub in
            RankedItem(id: "fixture-recent-\(i)", title: stub.title,
                       year: stub.year, director: stub.director,
                       tier: stub.tier, rank: i + 1, seed: stub.seed)
        }
    }

    // MARK: helpers

    private var monthLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM"
        return f.string(from: Date()).lowercased()
    }

    private func firstWord(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }

    private func watchedDay(from item: RankedItem) -> WatchedDay {
        let day = Calendar.current.component(.day, from: Date())
        return WatchedDay(day: day, tier: item.tier, title: item.title)
    }
}

#Preview {
    StubsScreen(onOpenDetail: { _ in }).spoolMode(.paper)
}
