import SwiftUI

public struct RankEntryScreen: View {
    public var onPick: (Movie) -> Void
    public var onClose: () -> Void

    @State private var query: String = ""
    @State private var remoteResults: [TMDBMovie] = []
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var isSearching: Bool = false

    public init(onPick: @escaping (Movie) -> Void, onClose: @escaping () -> Void) {
        self.onPick = onPick
        self.onClose = onClose
    }

    public var body: some View {
        SpoolScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("just watched?")
                            .font(SpoolFonts.serif(28))
                            .foregroundStyle(SpoolTokens.paper.ink)
                        Spacer()
                        Button("cancel ✕", action: onClose)
                            .font(SpoolFonts.mono(13))
                            .foregroundStyle(SpoolTokens.paper.inkSoft)
                    }

                    Text("let's make you a stub.")
                        .font(SpoolFonts.script(20))
                        .foregroundStyle(SpoolTokens.paper.inkSoft)
                        .padding(.top, 4)

                    SearchField(text: $query)
                        .padding(.top, 20)
                        .onChange(of: query) { newValue in
                            scheduleSearch(for: newValue)
                        }

                    resultsSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 60)
                .padding(.bottom, 40)
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyView()
        } else if !remoteResults.isEmpty {
            sectionLabel("MATCHES")
            ForEach(remoteResults) { m in
                let asMovie = Movie(
                    id: m.id, title: m.title,
                    year: Int(m.year) ?? 0,
                    director: "",
                    seed: stableSeed(from: m.title),
                    genres: m.genres,
                    posterUrl: m.posterUrl,
                    // Forward TMDB's 0-10 rating so the ranking engine has
                    // the `globalScore` signal it needs — matches web's
                    // RankingFlowModal path.
                    voteAverage: m.voteAverage
                )
                MovieRow(movie: asMovie, highlight: false) { onPick(asMovie) }
                    .padding(.top, 8)
            }
        } else if isSearching {
            HStack {
                Spacer()
                ProgressView().tint(SpoolTokens.paper.accent)
                Text("searching…")
                    .font(SpoolFonts.mono(11))
                    .foregroundStyle(SpoolTokens.paper.inkSoft)
                Spacer()
            }
            .padding(.top, 24)
        } else if !TMDBService.hasKey {
            // Without a key we fall back to the fixture list so the flow is
            // still demo-able.
            sectionLabel("DEMO RESULTS")
            ForEach(SpoolData.searchResults) { m in
                MovieRow(movie: m, highlight: m.rec) { onPick(m) }
                    .padding(.top, 8)
            }
        } else {
            Text("no results")
                .font(SpoolFonts.hand(14))
                .foregroundStyle(SpoolTokens.paper.inkSoft)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        }
    }

    private func scheduleSearch(for value: String) {
        searchTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            remoteResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            if Task.isCancelled { return }
            let results = await TMDBService.searchMovies(query: trimmed)
            if Task.isCancelled { return }
            await MainActor.run {
                self.remoteResults = results
                self.isSearching = false
            }
        }
    }

    private func stableSeed(from s: String) -> Int {
        // Deterministic hash in [0, 999] so PosterBlock picks a stable palette
        // per title rather than a different one each render.
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Int(h % 1000)
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s)
            .font(SpoolFonts.mono(10))
            .tracking(2)
            .foregroundStyle(SpoolTokens.paper.inkSoft)
            .padding(.top, 18)
    }
}

struct SearchField: View {
    @Binding var text: String
    var body: some View {
        SpoolThemeReader { t, _ in
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(t.ink)
                TextField("search films…", text: $text)
                    .font(SpoolFonts.serif(18))
                    .foregroundStyle(t.ink)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .overlay(Capsule().stroke(t.ink, lineWidth: 1.5))
        }
    }
}

struct MovieRow: View {
    let movie: Movie
    let highlight: Bool
    let action: () -> Void

    var body: some View {
        SpoolThemeReader { t, _ in
            Button(action: action) {
                HStack(spacing: 12) {
                    PosterBlock(title: firstWord(movie.title), year: movie.year,
                                director: movie.director, seed: movie.seed,
                                posterUrl: movie.posterUrl)
                        .frame(width: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(movie.title)
                            .font(SpoolFonts.serif(16))
                            .foregroundStyle(t.ink)
                            .lineLimit(1)
                        Text("\(String(movie.year)) · \(movie.director)")
                            .font(SpoolFonts.mono(10))
                            .foregroundStyle(t.inkSoft)
                    }
                    Spacer()
                    if highlight {
                        Text("on list")
                            .font(SpoolFonts.hand(11))
                            .foregroundStyle(t.ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(t.yellow))
                            .overlay(Capsule().stroke(t.ink, lineWidth: 1))
                    }
                }
                .padding(10)
                .background(highlight ? t.cream2 : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(highlight ? t.ink : t.rule, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func firstWord(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }
}

#Preview {
    RankEntryScreen(onPick: { _ in }, onClose: {}).spoolMode(.paper)
}
