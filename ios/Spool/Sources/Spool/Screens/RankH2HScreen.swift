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
    /// When the target tier has ≤5 items we use a sequential walk-through
    /// instead of the probe/escalation engine — matches the web's
    /// RankingFlowModal `compare_all` branch. iOS previously ran the
    /// engine unconditionally, which terminates in ~2 rounds on small
    /// tiers and felt like a premature abort. Nil means engine mode.
    @State private var smallTier: SmallTierState? = nil

    /// State for the compare-all walk. `tierItems` is the target tier
    /// sorted by rank (best first); `cursor` is the next item to compare
    /// the new movie against. The new movie stops at the first item it
    /// beats and inserts at that rank, or falls through to the end.
    private struct SmallTierState {
        var tierItems: [RankedItem]
        var cursor: Int
        var round: Int
    }

    /// Cross-view signal: when a preview-mode rank is captured into the queue
    /// we flip this flag and let `SpoolAppRoot` present its own `SignInSheet`.
    /// Keeping the sheet parent at the app root avoids a race where this
    /// screen unmounts ~0.9s after `onDone` fires — a sheet anchored here
    /// would get orphaned on the way out, and (worse) its onDone would not
    /// clear `previewMode` since that state lives at the root.
    @AppStorage("spool.show_signin_sheet") private var showSignInSheet: Bool = false

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
            globalScore: nil, seed: movie.seed,
            posterUrl: movie.posterUrl
        )

        // Web parity: branch on target-tier size. Empty → place immediately;
        // 1-5 items → sequential compare-all walk; >5 → full engine.
        let tierItems = all.filter { $0.tier == tier }.sorted { $0.rank < $1.rank }
        loading = false

        if tierItems.isEmpty {
            finalRank = 0
            let range = SpoolConstants.tierScoreRanges[tier] ?? ScoreRange(min: 0, max: 10)
            finalScore = (range.min + range.max) / 2
            done = true
            await persistRanking()
            return
        }

        if tierItems.count <= 5 {
            startCompareAll(newItem: newItem, tierItems: tierItems)
            return
        }

        let signals = SpoolPrediction.computePredictionSignals(
            allItems: all, primaryGenre: genres[0],
            bracket: bracket, globalScore: nil, tier: tier
        )
        let result = engine.start(
            newMovie: newItem, tier: tier,
            allItems: all, signals: signals
        )
        handle(result)
        if done { await persistRanking() }
    }

    /// Emit the first comparison for the sequential walk-through.
    @MainActor
    private func startCompareAll(newItem: RankedItem, tierItems: [RankedItem]) {
        smallTier = SmallTierState(tierItems: tierItems, cursor: 0, round: 1)
        comparison = ComparisonRequest(
            movieA: newItem,
            movieB: tierItems[0],
            question: "which do you love more?",
            phase: .probe,
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
            if done { Task { await persistRanking() } }
        } catch {
            // Engine errors here (notActive / unexpectedPhase) mean the
            // caller is out of sync with the state machine — we used to
            // mark the session done and persist mid-flow, which is what
            // made H2H terminate after a couple of taps. Keep the session
            // alive instead; the next valid tap drives forward.
            NSLog("[RankH2HScreen] submit ignored: \(error)")
        }
    }

    /// Compare-all walk: "does new beat the current tier item?" If yes,
    /// insert at the current cursor position. If no, advance. If the
    /// cursor runs off the end, insert at rank N (below everyone).
    @MainActor
    private func submitSmallTier(winnerId: String) {
        guard var st = smallTier, let c = comparison else { return }
        let newMovieWins = (winnerId == c.movieA.id)
        let insert: (Int) -> Void = { rank in
            self.finalRank = rank
            let range = SpoolConstants.tierScoreRanges[self.tier] ?? ScoreRange(min: 0, max: 10)
            // Approximate score interpolating across the tier — the real
            // insertion order happens via rank_position in the DB, score
            // here is just for the celebration copy.
            let total = max(st.tierItems.count + 1, 1)
            let frac = Double(total - rank - 1) / Double(total)
            self.finalScore = ((range.min + (range.max - range.min) * frac) * 100).rounded() / 100
            self.done = true
            self.smallTier = nil
            self.comparison = nil
            Task { await self.persistRanking() }
        }

        if newMovieWins {
            insert(st.cursor)
            return
        }
        // Lost → advance cursor. If we've compared against everyone, insert at end.
        let next = st.cursor + 1
        if next >= st.tierItems.count {
            insert(st.tierItems.count)
            return
        }
        st.cursor = next
        st.round += 1
        smallTier = st
        comparison = ComparisonRequest(
            movieA: c.movieA,
            movieB: st.tierItems[next],
            question: "which do you love more?",
            phase: .probe,
            round: st.round
        )
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
            Task { await persistRanking() }
            return
        }

        do {
            let result = try engine.skip()
            handle(result)
            if done { Task { await persistRanking() } }
        } catch {
            // A genuine skip-fail is rare (engine already completed).
            // Finish the session at the tentative score rather than
            // leaving the user stuck.
            NSLog("[RankH2HScreen] skip errored: \(error)")
            done = true
            Task { await persistRanking() }
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

    /// Persist the newly-ranked movie, or queue it if the user is in preview
    /// mode (no session). Never blocks the stub ceremony — the sign-in sheet,
    /// when needed, is presented alongside the proceeding flow so the user
    /// can keep going. The sheet itself lives on `SpoolAppRoot`; we just
    /// flip `spool.show_signin_sheet` via `@AppStorage` and let the root
    /// pick it up.
    private func persistRanking() async {
        let genres = movie.genres.isEmpty ? ["Drama"] : movie.genres
        let director = movie.director.isEmpty ? nil : movie.director
        let year = Self.normalizedYear(movie.year)

        if await SpoolClient.currentUserID() != nil {
            // Signed-in path: write directly. Surface failures via a toast so
            // the user knows the rank didn't land — prior silent `try?` hid
            // every network/RLS error.
            let insert = RankingInsert(
                tmdbId: movie.id,
                title: movie.title,
                year: year,
                posterURL: movie.posterUrl,
                type: "movie",
                genres: genres,
                director: director,
                tier: tier,
                rankPosition: finalRank,
                notes: nil
            )
            do {
                _ = try await RankingRepository.shared.insertRanking(insert)
            } catch {
                await MainActor.run {
                    ToastCenter.shared.show(
                        "couldn't save your rank — check connection",
                        level: .error
                    )
                }
            }
            return
        }

        // Preview mode: append to the queue and ask SpoolAppRoot to present
        // its sign-in sheet. AuthService will flush the queue on a successful
        // sign-in so this row lands without a second trip through ranking.
        let queued = QueuedRanking(
            tmdbId: movie.id,
            title: movie.title,
            year: year,
            posterURL: movie.posterUrl,
            genres: genres,
            director: director,
            tier: tier.rawValue,
            rankPosition: finalRank
        )
        await MainActor.run {
            OnboardingQueue.append(queued)
            // @AppStorage write — SpoolAppRoot observes the same key and will
            // present its SignInSheet. Survives this view unmounting when the
            // stub ceremony advances.
            showSignInSheet = true
        }
    }

    /// Normalize a movie's integer year to the `year: String?` the DB expects.
    /// `0` means "unknown" in our model — store as `nil` rather than "0".
    private static func normalizedYear(_ y: Int) -> String? {
        y > 0 ? String(y) : nil
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
