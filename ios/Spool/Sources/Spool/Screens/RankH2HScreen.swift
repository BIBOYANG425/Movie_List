import SwiftUI

/// Runs placement through `PlacementSession` (compare-all walk, seed +
/// quartile search, or the 5-phase `SpoolRankingEngine`, picked by target
/// tier size). Loads the user's existing rankings from Supabase (falls back
/// to fixtures when not configured / not authenticated), emits live
/// `ComparisonRequest`s from the session, and returns
/// `(finalRank, finalScore)` via `onDone` once the session reports `.done`.
public struct RankH2HScreen: View {
    public var movie: Movie
    public var tier: Tier
    public var onDone: (Int, Double) -> Void
    public var onBack: () -> Void

    public init(movie: Movie, tier: Tier,
                onDone: @escaping (Int, Double) -> Void,
                onBack: @escaping () -> Void) {
        self.movie = movie
        self.tier = tier
        self.onDone = onDone
        self.onBack = onBack
    }

    /// `@State` keeps the session's identity stable across view-struct
    /// re-creations — same reason the engine property used it before.
    /// PlacementSession owns the small-tier / engine dispatch that used
    /// to live in this screen.
    @State private var session = PlacementSession()
    @State private var comparison: ComparisonRequest? = nil
    @State private var loading = true
    @State private var done = false
    @State private var finalRank = 0
    @State private var finalScore = 0.0
    @State private var allItems: [RankedItem] = []

    // Persistence intentionally lives OUTSIDE this screen. `onDone` surfaces
    // the computed `(finalRank, finalScore)` upward; the actual DB write runs
    // only when the user reaches the RankPrintedScreen finish callback.
    // Backing out of the flow from ceremony or printed should leave no row
    // behind, which is why we don't call RankPersistence.save here anymore.

    public var body: some View {
        SpoolScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Button(L10n.t("ceremony.back").uppercased(), action: onBack)
                        .font(SpoolFonts.mono(12))
                        .tracking(1)
                        .foregroundStyle(SpoolTokens.paper.inkSoft)

                    StepProgress(step: 2, total: 3).padding(.top, 10)

                    header

                    if loading {
                        loadingState.padding(.top, 60)
                    } else if done {
                        placedCelebration
                            .padding(.top, 40)
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                                    onDone(finalRank, finalScore)
                                }
                            }
                    } else if let c = comparison {
                        matchCards(for: c).padding(.top, 18)
                        voteRow.padding(.top, 12)
                        TierShelf(tier: tier, highlightPos: previewPosition, locked: false)
                            .padding(.top, 14)
                    } else {
                        // Engine returned .done immediately (edge: first item in tier).
                        placedCelebration
                            .padding(.top, 40)
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                                    onDone(finalRank, finalScore)
                                }
                            }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 50)
                .padding(.bottom, 40)
            }
        }
        .task { await start() }
    }

    // MARK: header / subviews

    @ViewBuilder
    private var header: some View {
        let roundLabel: String = {
            if let c = comparison, !done { return L10n.t("ceremony.step2Match", ["round": "\(c.round)"]).uppercased() }
            if done { return L10n.t("ceremony.step2Placed").uppercased() }
            return L10n.t("ceremony.step2WarmingUp").uppercased()
        }()

        Text(roundLabel)
            .font(SpoolFonts.mono(10))
            .tracking(2)
            .foregroundStyle(SpoolTokens.paper.inkSoft)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)

        if let c = comparison, !done {
            Text(c.question)
                .font(SpoolFonts.script(26))
                .foregroundStyle(SpoolTokens.paper.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 12)
        } else if !done {
            Text(L10n.t("ceremony.whichHitHarder"))
                .font(SpoolFonts.script(26))
                .foregroundStyle(SpoolTokens.paper.ink)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 12)
        }

        SpoolThemeReader { _, mode in
            HStack(spacing: 4) {
                Text(L10n.t("ceremony.placingWithin"))
                Text(L10n.t("ceremony.tierSuffix", ["tier": tier.rawValue]))
                    .foregroundStyle(tierColor(tier, mode: mode))
                    .bold()
            }
            .font(SpoolFonts.hand(12))
            .foregroundStyle(SpoolTokens.paper.inkSoft)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func matchCards(for c: ComparisonRequest) -> some View {
        VStack(spacing: 10) {
            // Both cards inherit the ceremony's media so the H2HCard shows the
            // right attribution (director/creator/author) + a tv season line. The
            // pool item's `director` is already the media attribution
            // (`rankedItem(from:)`), and `seasonTitle` rides through — a same-media
            // pool means movieB is the same media as the just-watched movieA.
            H2HCard(
                movie: h2hMovie(from: c.movieA),
                label: L10n.t("ceremony.justWatched").uppercased(),
                tilt: -1.2
            ) { submit(winnerId: c.movieA.id) }

            Text(L10n.t("ceremony.vs"))
                .font(SpoolFonts.script(26))
                .foregroundStyle(SpoolTokens.paper.accent)

            H2HCard(
                movie: h2hMovie(from: c.movieB),
                label: L10n.t("ceremony.yourTierRank", ["tier": tier.rawValue, "rank": "\(c.movieB.rank + 1)"]).uppercased(),
                tilt: 1
            ) { submit(winnerId: c.movieB.id) }
        }
    }

    /// Map a pool `RankedItem` into the display `Movie` for an H2H card, carrying
    /// the ceremony's `mediaType` + the item's `seasonTitle` so a tv card renders
    /// its season line and a book card shows the author. `director` on the item is
    /// already the media attribution (from `rankedItem(from:)`).
    private func h2hMovie(from item: RankedItem) -> Movie {
        Movie(
            id: item.id, title: item.title, year: item.year ?? 0,
            director: item.director, seed: item.seed, posterUrl: item.posterUrl,
            mediaType: movie.mediaType, seasonTitle: item.seasonTitle
        )
    }

    private var voteRow: some View {
        HStack(spacing: 6) {
            SpoolPill(L10n.t("ceremony.tie"), size: .sm) { skip() }
            SpoolPill(L10n.t("ceremony.haventSeen"), size: .sm) { skip() }
            SpoolPill(L10n.t("ceremony.skip"), filled: true, size: .sm) { skip() }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var loadingState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 10) {
                ProgressView().tint(t.accent)
                Text(L10n.t("ceremony.readingTaste"))
                    .font(SpoolFonts.hand(13))
                    .foregroundStyle(t.inkSoft)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var placedCelebration: some View {
        SpoolThemeReader { t, mode in
            VStack(spacing: 6) {
                Text(L10n.t("ceremony.placed"))
                    .font(SpoolFonts.script(30))
                    .foregroundStyle(t.accent)
                HStack(spacing: 6) {
                    Text(L10n.t("ceremony.rankIn", ["rank": "\(max(finalRank + 1, 1))"]))
                    Text(L10n.t("ceremony.tierSuffix", ["tier": tier.rawValue]))
                        .foregroundStyle(tierColor(tier, mode: mode))
                }
                .font(SpoolFonts.hand(16))
                .foregroundStyle(t.inkSoft)
                Text(String(format: "%.2f", finalScore))
                    .font(SpoolFonts.mono(22))
                    .foregroundStyle(t.ink)
                    .padding(.top, 4)
                TierShelf(tier: tier, highlightPos: finalRank + 1, locked: true)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var previewPosition: Int? {
        guard let c = comparison else { return nil }
        return c.movieB.rank + 1
    }

    // MARK: engine bridge

    @MainActor
    private func start() async {
        let all = await loadAllItems()
        self.allItems = all

        let genres = movie.genres.isEmpty ? ["Drama"] : movie.genres
        let bracket = RankingAlgorithm.classifyBracket(genres: genres)
        let newItem = RankedItem(
            id: movie.id, title: movie.title, year: movie.year,
            director: movie.attribution, genres: genres,
            tier: tier, rank: 0, bracket: bracket,
            // PER-MEDIA global-score seed (C5-iOS Task 5): a movie/tv seeds from
            // TMDB `vote_average` (tv via Task 3 `tvShowGlobalScore`), a book from
            // OpenLibrary `ratings_average` scaled 0-5 → 0-10 (NEVER TMDB for an
            // ol_ id). `movie.rankGlobalScore` owns that per-media choice. Feeds
            // the engine's predictScore (weight 0.35, sole signal for new users
            // below NEW_USER_THRESHOLD). Web's RankingFlowModal does the same.
            globalScore: movie.rankGlobalScore, seed: movie.seed,
            posterUrl: movie.posterUrl,
            seasonTitle: movie.seasonTitle
        )

        loading = false

        // PlacementSession owns the strategy dispatch (empty tier →
        // immediate placement at tier midpoint; 1-5 items → sequential
        // compare-all walk; 6-20 → seed + quartile binary search; >20 →
        // full probe/escalation engine) — same branching this screen used
        // to carry inline. Persistence stays deferred to RankPersistence
        // .save, invoked from RankPrintedScreen.onFinish — aborting
        // mid-flow (ceremony/printed back-out) leaves nothing behind.
        let result = session.start(newItem: newItem, tier: tier, allItems: all)
        handle(result)
    }

    private func submit(winnerId: String) {
        guard !done, comparison != nil else { return }
        if let result = session.submit(winnerId: winnerId) {
            handle(result)
            // Persist deferred to the printed-screen finish callback.
        } else {
            // Out-of-sync tap (stale double-tap) — the session stays
            // alive; the next valid tap drives forward.
            NSLog("[RankH2HScreen] submit ignored: out-of-sync tap")
        }
    }

    private func skip() {
        guard !done else { return }
        if let result = session.skip() {
            handle(result)
            // Persist deferred to the printed-screen finish callback.
        } else {
            // A genuine skip-fail is rare (engine already completed).
            // Finish the session at the tentative score rather than
            // leaving the user stuck.
            NSLog("[RankH2HScreen] skip errored: finishing at tentative state")
            done = true
        }
    }

    private func handle(_ result: EngineResult) {
        switch result {
        case .comparison(let c):
            comparison = c
        case .done(let rank, let score):
            finalRank = rank
            finalScore = score
            done = true
        }
    }

    // MARK: data

    /// Load the signed-in user's existing ranked items so the engine can
    /// place the new movie against their actual shelf. We intentionally do
    /// NOT fall back to fixture data for signed-in users: a transient fetch
    /// failure would otherwise rank the new movie against demo content and
    /// then persist a bogus `rankPosition` to `user_rankings`. Fixtures are
    /// only acceptable in preview mode, where writes go to the local queue
    /// and the user hasn't committed to a shelf yet.
    private func loadAllItems() async -> [RankedItem] {
        let hasSession = await SpoolClient.currentUserID() != nil
        do {
            // SAME-MEDIA POOL (C5-iOS Task 5): route the pool read to the SAME
            // vertical the new item belongs to (`movie.mediaType.mediaParam` →
            // `getAllRankedItems(media:)`), so a tv rank compares only against
            // tv_rankings and a book against book_rankings. Web parity:
            // AddTVSeasonModal / RankingFlowModal never cross media in the H2H
            // pool. A movie stays on `user_rankings` (the default), unchanged.
            return try await RankingRepository.shared.getAllRankedItems(media: movie.mediaType.mediaParam)
        } catch {
            if hasSession {
                // Bail rather than mix fixtures into a real shelf. Returning
                // [] means the engine treats this as a first-pick — the
                // predicted tier will be rough, but we never persist against
                // fake data.
                return []
            }
            return fixtureRankedItems()
        }
    }

    private func fixtureRankedItems() -> [RankedItem] {
        SpoolData.sTier.enumerated().map { (i, m) in
            RankedItem(
                id: m.id, title: m.title, year: m.year,
                director: m.director,
                genres: ["Drama"], tier: .S, rank: i,
                bracket: .artisan, globalScore: nil, seed: m.seed
            )
        }
    }

}

struct H2HCard: View {
    let movie: Movie
    let label: String
    let tilt: Double
    let onTap: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            Button(action: onTap) {
                HStack(spacing: 14) {
                    PosterBlock(title: firstWord(movie.title), year: movie.year,
                                director: movie.attribution, seed: movie.seed,
                                posterUrl: movie.posterUrl)
                        .frame(width: 76)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label)
                            .font(SpoolFonts.mono(9))
                            .tracking(2)
                            .foregroundStyle(t.inkSoft)
                        Text(movie.title)
                            .font(SpoolFonts.serif(20))
                            .foregroundStyle(t.ink)
                            .tracking(-0.3)
                        if movie.mediaType == .tv, let season = movie.seasonTitle, !season.isEmpty {
                            Text(season)
                                .font(SpoolFonts.hand(11))
                                .foregroundStyle(t.inkSoft)
                        }
                        Text("\(movie.attribution) · \(String(movie.year))")
                            .font(SpoolFonts.mono(10))
                            .foregroundStyle(t.inkSoft)
                        Text(L10n.t("ceremony.tapToPick"))
                            .font(SpoolFonts.script(16))
                            .foregroundStyle(t.accent)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(t.cream)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(t.ink, lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.08), radius: 0, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .rotationEffect(.degrees(tilt))
        }
    }

    private func firstWord(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }
}

struct TierShelf: View {
    let tier: Tier
    let highlightPos: Int?
    let locked: Bool

    var body: some View {
        SpoolThemeReader { t, mode in
            VStack(spacing: 6) {
                Text(L10n.t("ceremony.tierShelf", ["tier": tier.rawValue]).uppercased())
                    .font(SpoolFonts.mono(9))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<5, id: \.self) { i in
                        let hi = highlightPos != nil && (i + 1) == highlightPos!
                        ZStack {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(hi ? (locked ? tierColor(tier, mode: mode) : t.yellow) : t.cream3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(
                                            hi ? t.ink : t.rule,
                                            style: StrokeStyle(lineWidth: 1.5, dash: hi ? [] : [3, 2])
                                        )
                                )
                            Text(hi ? (locked ? "✓" : L10n.t("ceremony.new")) : "#\(i+1)")
                                .font(SpoolFonts.mono(9))
                                .foregroundStyle(hi ? t.cream : t.inkSoft)
                        }
                        .frame(width: 32)
                        .aspectRatio(2.0/3.0, contentMode: .fit)
                        .rotationEffect(.degrees(hi ? -3 : 0))
                        .offset(y: hi ? -4 : 0)
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(t.cream2)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(t.rule)
            )
        }
    }
}

#Preview {
    RankH2HScreen(
        movie: SpoolData.subject, tier: .S,
        onDone: { _, _ in }, onBack: {}
    )
    .spoolMode(.paper)
}
