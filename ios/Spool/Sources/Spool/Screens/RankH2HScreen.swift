import SwiftUI

/// Runs the real 5-phase `SpoolRankingEngine`. Loads the user's existing
/// rankings from Supabase (falls back to fixtures when not configured /
/// not authenticated), emits live `ComparisonRequest`s from the engine, and
/// returns `(finalRank, finalScore)` via `onDone` once the engine reports
/// `.done`.
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

    @State private var engine = SpoolRankingEngine()
    @State private var comparison: ComparisonRequest? = nil
    @State private var loading = true
    @State private var done = false
    @State private var finalRank = 0
    @State private var finalScore = 0.0
    @State private var allItems: [RankedItem] = []
    /// When the target tier has ≤20 items we skip the probe/escalation
    /// engine in favour of a lightweight path — matches the web's
    /// RankingFlowModal `smallTierRef` branch. iOS previously ran the
    /// engine unconditionally, which terminates in ~2 rounds on small
    /// tiers and felt like a premature abort. Nil means engine mode.
    ///
    /// Three sub-modes mirror the web:
    ///  - `.compareAll` (≤5 items): sequential walk from rank 0 downward.
    ///  - `.seed` (6–20 items, first comparison only): pivot on
    ///    `computeSeedIndex` so the new movie meets a neighbour near its
    ///    global-avg first.
    ///  - `.quartile` (6–20 items, every subsequent comparison): narrow
    ///    the [low, high) window by 25/75 quartile jumps for faster
    ///    3–4 round convergence.
    @State private var smallTier: SmallTierState? = nil

    /// State machine for the small-tier path. Shape mirrors the web's
    /// `smallTierRef` exactly — `low`, `high`, `mid`, `seedIdx`, `round`
    /// are carried across all modes so transitions are a simple
    /// field-copy. The view holds the actual `tierItems` array here so
    /// it can render posters; the pure algorithm only takes the count.
    /// `cursor` is a compatibility alias for `mid` in `.compareAll` mode.
    private struct SmallTierState {
        enum Mode { case compareAll, seed, quartile }
        var mode: Mode
        var tierItems: [RankedItem]
        var low: Int
        var high: Int
        var mid: Int
        var round: Int
        var seedIdx: Int

        /// Sequential-walk accessor for `.compareAll` — returns `mid`,
        /// which is the "next item to compare against" for that mode.
        var cursor: Int {
            get { mid }
            set { mid = newValue }
        }
    }

    // Persistence intentionally lives OUTSIDE this screen. `onDone` surfaces
    // the computed `(finalRank, finalScore)` upward; the actual DB write runs
    // only when the user reaches the RankPrintedScreen finish callback.
    // Backing out of the flow from ceremony or printed should leave no row
    // behind, which is why we don't call RankPersistence.save here anymore.

    public var body: some View {
        SpoolScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Button("← BACK", action: onBack)
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
            if let c = comparison, !done { return "STEP 2 · MATCH \(c.round)" }
            if done { return "STEP 2 · PLACED" }
            return "STEP 2 · WARMING UP"
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
            Text("which hit harder?")
                .font(SpoolFonts.script(26))
                .foregroundStyle(SpoolTokens.paper.ink)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 12)
        }

        SpoolThemeReader { _, mode in
            HStack(spacing: 4) {
                Text("placing within")
                Text("\(tier.rawValue)-tier")
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
            H2HCard(
                movie: Movie(
                    id: c.movieA.id, title: c.movieA.title,
                    year: c.movieA.year ?? 0, director: c.movieA.director,
                    seed: c.movieA.seed,
                    posterUrl: c.movieA.posterUrl
                ),
                label: "JUST WATCHED",
                tilt: -1.2
            ) { submit(winnerId: c.movieA.id) }

            Text("— vs —")
                .font(SpoolFonts.script(26))
                .foregroundStyle(SpoolTokens.paper.accent)

            H2HCard(
                movie: Movie(
                    id: c.movieB.id, title: c.movieB.title,
                    year: c.movieB.year ?? 0, director: c.movieB.director,
                    seed: c.movieB.seed,
                    posterUrl: c.movieB.posterUrl
                ),
                label: "YOUR \(tier.rawValue)-TIER · #\(c.movieB.rank + 1)",
                tilt: 1
            ) { submit(winnerId: c.movieB.id) }
        }
    }

    private var voteRow: some View {
        HStack(spacing: 6) {
            SpoolPill("= tie", size: .sm) { skip() }
            SpoolPill("? haven't seen", size: .sm) { skip() }
            SpoolPill("skip", filled: true, size: .sm) { skip() }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var loadingState: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 10) {
                ProgressView().tint(t.accent)
                Text("reading your taste…")
                    .font(SpoolFonts.hand(13))
                    .foregroundStyle(t.inkSoft)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var placedCelebration: some View {
        SpoolThemeReader { t, mode in
            VStack(spacing: 6) {
                Text("placed ✓")
                    .font(SpoolFonts.script(30))
                    .foregroundStyle(t.accent)
                HStack(spacing: 6) {
                    Text("#\(max(finalRank + 1, 1)) in")
                    Text("\(tier.rawValue)-tier")
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
            director: movie.director, genres: genres,
            tier: tier, rank: 0, bracket: bracket,
            // TMDB vote_average (0-10) becomes the engine's globalScore.
            // Web's RankingFlowModal does the same. Weight 0.35 inside
            // predictScore, and the sole signal for new users below
            // NEW_USER_THRESHOLD — iOS was dropping it (always nil)
            // which meant every new iOS user's prediction landed at
            // tier midpoint.
            globalScore: movie.voteAverage, seed: movie.seed,
            posterUrl: movie.posterUrl
        )

        // Web parity: branch on target-tier size. Empty → place immediately;
        // 1-5 items → sequential compare-all walk; 6-20 → seed + quartile
        // binary search (mirrors web's `smallTierRef` seed/quartile modes);
        // >20 → full probe/escalation engine.
        let tierItems = all.filter { $0.tier == tier }.sorted { $0.rank < $1.rank }
        loading = false

        if tierItems.isEmpty {
            finalRank = 0
            let range = SpoolConstants.tierScoreRanges[tier] ?? ScoreRange(min: 0, max: 10)
            finalScore = (range.min + range.max) / 2
            done = true
            // Persistence deferred to RankPersistence.save, invoked
            // from RankPrintedScreen.onFinish — aborting mid-flow
            // (ceremony/printed back-out) leaves nothing behind.
            return
        }

        if tierItems.count <= 5 {
            startCompareAll(newItem: newItem, tierItems: tierItems)
            return
        }

        if tierItems.count <= 20 {
            startSeedMode(newItem: newItem, tierItems: tierItems)
            return
        }

        let signals = SpoolPrediction.computePredictionSignals(
            allItems: all, primaryGenre: genres[0],
            bracket: bracket,
            // Carry vote_average through to the engine's prediction so
            // new-user ranking lands near the TMDB consensus instead of
            // defaulting to tier midpoint. See RankedItem.globalScore above.
            globalScore: movie.voteAverage, tier: tier
        )
        let result = engine.start(
            newMovie: newItem, tier: tier,
            allItems: all, signals: signals
        )
        handle(result)
        // No persist here. See RankPersistence.save call
        // in SpoolAppRoot.onFinish.
    }

    /// Emit the first comparison for the sequential walk-through (≤5 items).
    @MainActor
    private func startCompareAll(newItem: RankedItem, tierItems: [RankedItem]) {
        smallTier = SmallTierState(
            mode: .compareAll,
            tierItems: tierItems,
            low: 0, high: tierItems.count,
            mid: 0, round: 1, seedIdx: 0
        )
        comparison = ComparisonRequest(
            movieA: newItem,
            movieB: tierItems[0],
            question: "which do you love more?",
            phase: .probe,
            round: 1
        )
    }

    /// Emit the first comparison for the seed + quartile binary search
    /// (6-20 items). Matches web RankingFlowModal `proceedFromNotes`'s
    /// `tierItems.length <= 20` branch: compute tier scores for each
    /// existing slot, then pivot on `computeSeedIndex` so the new movie
    /// meets a neighbour near its global-avg first.
    @MainActor
    private func startSeedMode(newItem: RankedItem, tierItems: [RankedItem]) {
        let range = SpoolConstants.tierScoreRanges[tier] ?? ScoreRange(min: 0, max: 10)
        let tierScores: [Double] = (0..<tierItems.count).map { idx in
            RankingAlgorithm.computeTierScore(
                position: idx, totalInTier: tierItems.count,
                tierMin: range.min, tierMax: range.max
            )
        }
        let seedIdx = RankingAlgorithm.computeSeedIndex(
            tierItemScores: tierScores,
            tierMin: range.min, tierMax: range.max,
            globalAvg: newItem.globalScore
        )
        smallTier = SmallTierState(
            mode: .seed,
            tierItems: tierItems,
            low: 0, high: tierItems.count,
            mid: seedIdx, round: 1, seedIdx: seedIdx
        )
        comparison = ComparisonRequest(
            movieA: newItem,
            movieB: tierItems[seedIdx],
            question: "which do you love more?",
            phase: .binarySearch,
            round: 1
        )
    }

    private func submit(winnerId: String) {
        guard !done, comparison != nil else { return }

        if smallTier != nil {
            submitSmallTier(winnerId: winnerId)
            return
        }

        do {
            let result = try engine.submitChoice(winnerId: winnerId)
            handle(result)
            // Persist deferred to the printed-screen finish callback.
        } catch {
            // Engine errors here (notActive / unexpectedPhase) mean the
            // caller is out of sync with the state machine — we used to
            // mark the session done and persist mid-flow, which is what
            // made H2H terminate after a couple of taps. Keep the session
            // alive instead; the next valid tap drives forward.
            NSLog("[RankH2HScreen] submit ignored: \(error)")
        }
    }

    /// Advance the small-tier state machine by one user choice. Delegates
    /// to the pure `RankingAlgorithm.advanceSmallTier` helper; this
    /// function is just the view-level glue that updates `smallTier` /
    /// `comparison` / `done` based on the algorithm's decision.
    @MainActor
    private func submitSmallTier(winnerId: String) {
        guard let st = smallTier, let c = comparison else { return }
        let pick: RankingAlgorithm.NarrowChoice =
            winnerId == c.movieA.id ? .new : .existing
        let movieA = c.movieA

        // Bridge the view's inline enum to the algorithm's public enum.
        let algoMode: RankingAlgorithm.SmallTierMode = {
            switch st.mode {
            case .compareAll: return .compareAll
            case .seed:       return .seed
            case .quartile:   return .quartile
            }
        }()
        let algoState = RankingAlgorithm.SmallTierState(
            mode: algoMode,
            tierCount: st.tierItems.count,
            low: st.low, high: st.high, mid: st.mid,
            round: st.round, seedIdx: st.seedIdx
        )
        switch RankingAlgorithm.advanceSmallTier(state: algoState, pick: pick) {
        case .done(let rank):
            finalRank = rank
            let range = SpoolConstants.tierScoreRanges[tier] ?? ScoreRange(min: 0, max: 10)
            // Approximate score for celebration copy only — true
            // insertion order is set by rank_position in the DB.
            let total = max(st.tierItems.count + 1, 1)
            let frac = Double(total - rank - 1) / Double(total)
            finalScore = ((range.min + (range.max - range.min) * frac) * 100).rounded() / 100
            done = true
            smallTier = nil
            comparison = nil

        case .next(let nextState):
            let viewMode: SmallTierState.Mode = {
                switch nextState.mode {
                case .compareAll: return .compareAll
                case .seed:       return .seed
                case .quartile:   return .quartile
                }
            }()
            var nst = st
            nst.mode = viewMode
            nst.low = nextState.low
            nst.high = nextState.high
            nst.mid = nextState.mid
            nst.round = nextState.round
            smallTier = nst
            comparison = ComparisonRequest(
                movieA: movieA,
                movieB: nst.tierItems[nst.mid],
                question: "which do you love more?",
                phase: nst.mode == .compareAll ? .probe : .binarySearch,
                round: nst.round
            )
        }
    }

    private func skip() {
        guard !done else { return }

        // In compare-all mode, "skip" means "insert at the current cursor"
        // — same semantics as the web's too_tough/skip branch for
        // smallTier.mode == 'compare_all'.
        if let st = smallTier {
            finalRank = st.cursor
            let range = SpoolConstants.tierScoreRanges[tier] ?? ScoreRange(min: 0, max: 10)
            finalScore = ((range.min + range.max) / 2 * 100).rounded() / 100
            done = true
            smallTier = nil
            comparison = nil
            // Persist deferred to the printed-screen finish callback.
            return
        }

        do {
            let result = try engine.skip()
            handle(result)
            // Persist deferred to the printed-screen finish callback.
        } catch {
            // A genuine skip-fail is rare (engine already completed).
            // Finish the session at the tentative score rather than
            // leaving the user stuck.
            NSLog("[RankH2HScreen] skip errored: \(error)")
            done = true
            // Persist deferred to the printed-screen finish callback.
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
            return try await RankingRepository.shared.getAllRankedItems()
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
                                director: movie.director, seed: movie.seed,
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
                        Text("\(movie.director) · \(String(movie.year))")
                            .font(SpoolFonts.mono(10))
                            .foregroundStyle(t.inkSoft)
                        Text("tap to pick")
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
                Text("\(tier.rawValue)-TIER SHELF")
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
                            Text(hi ? (locked ? "✓" : "new") : "#\(i+1)")
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
