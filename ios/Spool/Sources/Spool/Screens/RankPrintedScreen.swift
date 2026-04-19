import SwiftUI

public struct RankPrintedScreen: View {
    public var movie: Movie
    public var tier: Tier
    public var moods: [String]
    public var line: String
    public var finalRank: Int
    public var finalScore: Double
    public var onClose: () -> Void
    public var onFinish: () -> Void

    @State private var printed: Bool = false

    public init(movie: Movie, tier: Tier, moods: [String], line: String,
                finalRank: Int = 0, finalScore: Double = 0,
                onClose: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.movie = movie
        self.tier = tier
        self.moods = moods
        self.line = line
        self.finalRank = finalRank
        self.finalScore = finalScore
        self.onClose = onClose
        self.onFinish = onFinish
    }

    public var body: some View {
        SpoolThemeReader { t, _ in
            SpoolScreen(
                background: AnyShapeStyle(
                    RadialGradient(colors: [t.cream2, t.cream],
                                   center: .init(x: 0.5, y: 0.2),
                                   startRadius: 0, endRadius: 400)
                )
            ) {
                ScrollView {
                    VStack(spacing: 0) {
                        StepProgress(step: 4, total: 4)

                        Text("your stub is ready.")
                            .font(SpoolFonts.script(30))
                            .foregroundStyle(t.ink)
                            .padding(.top, 14)

                        Text("#0128 of your collection")
                            .font(SpoolFonts.hand(13))
                            .foregroundStyle(t.inkSoft)

                        if finalScore > 0 {
                            HStack(spacing: 6) {
                                Text("#\(finalRank + 1) in \(tier.rawValue)-tier")
                                Text("·")
                                Text(String(format: "%.2f", finalScore))
                                    .font(SpoolFonts.mono(13))
                            }
                            .font(SpoolFonts.mono(11))
                            .tracking(1)
                            .foregroundStyle(t.inkSoft)
                            .padding(.top, 4)
                        }

                        stubWithTape
                            .padding(.top, 22)
                            .padding(.horizontal, 8)

                        HStack(spacing: 8) {
                            SpoolPill("↗ share to story")
                            SpoolPill("save PNG")
                        }
                        .padding(.top, 22)
                        .padding(.horizontal, 8)

                        SpoolPill("post to feed ✓", filled: true, action: onFinish)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)

                        Button("keep private →", action: onClose)
                            .font(SpoolFonts.script(17))
                            .foregroundStyle(t.inkSoft)
                            .padding(.top, 14)

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 50)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                    printed = true
                }
            }
        }
    }

    private var stubWithTape: some View {
        ZStack(alignment: .top) {
            AdmitStub(
                movie: movie, tier: tier, line: line, moods: moods,
                date: formattedToday(), stubNo: "#0128"
            )
            Tape()
                .rotationEffect(.degrees(-4))
                .offset(x: -90, y: -8)
            Tape(color: Color(hex: 0xCE3B1F).opacity(0.35))
                .rotationEffect(.degrees(5))
                .offset(x: 90, y: -8)
        }
        .rotationEffect(.degrees(printed ? -2 : -12))
        .offset(y: printed ? 0 : -40)
        .opacity(printed ? 1 : 0)
    }

    private func formattedToday() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM · dd · yyyy"
        return f.string(from: Date()).uppercased()
    }
}

#Preview {
    RankPrintedScreen(
        movie: SpoolData.subject, tier: .S,
        moods: ["tender", "devastating"], line: "cried on the 6 train.",
        onClose: {}, onFinish: {}
    )
    .spoolMode(.paper)
}
