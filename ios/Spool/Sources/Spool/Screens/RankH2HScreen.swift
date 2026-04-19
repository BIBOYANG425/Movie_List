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
        let signals = SpoolPrediction.computePredictionSignals(
            allItems: all, primaryGenre: genres[0],
            bracket: bracket, globalScore: nil, tier: tier
        )
        let result = engine.start(
            newMovie: newItem, tier: tier,
            allItems: all, signals: signals
        )
        loading = false
        handle(result)

        if done {
            // Edge: first movie in tier — persist immediately.
            await persistRanking()
        }
    }

    private func submit(winnerId: String) {
        guard !done, comparison != nil else { return }
        do {
            let result = try engine.submitChoice(winnerId: winnerId)
            handle(result)
            if done { Task { await persistRanking() } }
        } catch {
            done = true
            Task { await persistRanking() }
        }
    }

    private func skip() {
        guard !done else { return }
        do {
            let result = try engine.skip()
            handle(result)
            if done { Task { await persistRanking() } }
        } catch {
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

    private func loadAllItems() async -> [RankedItem] {
        do {
            return try await RankingRepository.shared.getAllRankedItems()
        } catch {
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

    private func persistRanking() async {
        let insert = RankingInsert(
            tmdbId: movie.id,
            title: movie.title,
            year: String(movie.year),
            posterURL: movie.posterUrl,
            type: "movie",
            genres: movie.genres.isEmpty ? ["Drama"] : movie.genres,
            director: movie.director.isEmpty ? nil : movie.director,
            tier: tier,
            rankPosition: finalRank,
            notes: nil
        )
        _ = try? await RankingRepository.shared.insertRanking(insert)
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
