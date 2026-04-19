import SwiftUI

public struct RankTierScreen: View {
    public var movie: Movie
    public var onPick: (Tier) -> Void
    public var onBack: () -> Void

    public init(movie: Movie, onPick: @escaping (Tier) -> Void, onBack: @escaping () -> Void) {
        self.movie = movie
        self.onPick = onPick
        self.onBack = onBack
    }

    public var body: some View {
        SpoolScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Button("← BACK", action: onBack)
                        .font(SpoolFonts.mono(12))
                        .tracking(1)
                        .foregroundStyle(SpoolTokens.paper.inkSoft)

                    StepProgress(step: 1, total: 3).padding(.top, 10)

                    Text("STEP 1 OF 3 · GUT CHECK")
                        .font(SpoolFonts.mono(10))
                        .tracking(2)
                        .foregroundStyle(SpoolTokens.paper.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)

                    justWatchedCard.padding(.top, 18)

                    Text("how did it feel?")
                        .font(SpoolFonts.script(26))
                        .foregroundStyle(SpoolTokens.paper.ink)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 18)

                    VStack(spacing: 8) {
                        ForEach(Tier.allCases) { tier in
                            tierButton(tier)
                        }
                    }
                    .padding(.top, 10)
                }
                .padding(.horizontal, 18)
                .padding(.top, 50)
                .padding(.bottom, 40)
            }
        }
    }

    private var justWatchedCard: some View {
        SpoolThemeReader { t, _ in
            HStack(spacing: 14) {
                PosterBlock(title: firstWord(movie.title), year: movie.year,
                            director: movie.director, seed: movie.seed,
                            posterUrl: movie.posterUrl)
                    .frame(width: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text("JUST WATCHED")
                        .font(SpoolFonts.mono(9))
                        .tracking(2)
                        .foregroundStyle(t.inkSoft)
                    Text(movie.title)
                        .font(SpoolFonts.serif(22))
                        .foregroundStyle(t.ink)
                        .tracking(-0.3)
                    Text("\(movie.director) · \(String(movie.year))")
                        .font(SpoolFonts.mono(10))
                        .foregroundStyle(t.inkSoft)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(t.cream2)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(t.ink, lineWidth: 1.5)
            )
        }
    }

    private func tierButton(_ tier: Tier) -> some View {
        SpoolThemeReader { t, _ in
            Button { onPick(tier) } label: {
                HStack(spacing: 12) {
                    TierStamp(tier: tier, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tier.label)
                            .font(SpoolFonts.serif(20))
                            .foregroundStyle(t.ink)
                        Text(tier.sub)
                            .font(SpoolFonts.hand(12))
                            .foregroundStyle(t.inkSoft)
                    }
                    Spacer()
                    Text("›").font(.system(size: 18)).foregroundStyle(t.inkSoft)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(t.cream)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(t.ink, lineWidth: 1.5)
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
    RankTierScreen(movie: SpoolData.subject, onPick: { _ in }, onBack: {})
        .spoolMode(.paper)
}
