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
    /// "write more" — open the full journal composer seeded with the ceremony's
    /// moods + one-liner (Task 6). Defaulted to a no-op so existing call sites /
    /// previews that don't wire it still compile.
    public var onWriteMore: () -> Void

    @State private var printed: Bool = false

    public init(movie: Movie, tier: Tier, moods: [String], line: String,
                finalRank: Int = 0, finalScore: Double = 0,
                onClose: @escaping () -> Void, onFinish: @escaping () -> Void,
                onWriteMore: @escaping () -> Void = {}) {
        self.movie = movie
        self.tier = tier
        self.moods = moods
        self.line = line
        self.finalRank = finalRank
        self.finalScore = finalScore
        self.onClose = onClose
        self.onFinish = onFinish
        self.onWriteMore = onWriteMore
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

                        Text(L10n.t("printed.ready"))
                            .font(SpoolFonts.script(30))
                            .foregroundStyle(t.ink)
                            .padding(.top, 14)

                        Text(L10n.t("printed.collectionNo", ["no": "#0128"]))
                            .font(SpoolFonts.hand(13))
                            .foregroundStyle(t.inkSoft)

                        if finalScore > 0 {
                            HStack(spacing: 6) {
                                Text(L10n.t("printed.rankInTier", ["rank": "\(finalRank + 1)", "tier": tier.rawValue]))
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
                            SpoolPill(L10n.t("printed.shareStory"))
                            SpoolPill(L10n.t("printed.savePNG"))
                        }
                        .padding(.top, 22)
                        .padding(.horizontal, 8)

                        SpoolPill(L10n.t("printed.postToFeed"), filled: true, action: onFinish)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)

                        // "write more" opens the journal composer, which is
                        // MOVIE-KEYED (the journal is a movie feature). The
                        // persistence quick-entry gate already refuses to write a
                        // journal row for tv/book; here we hide the UI affordance
                        // too so a tv/book stub never offers a dead-end button
                        // (C5-iOS Task 6). Movie keeps it.
                        if movie.mediaType == .movie {
                            Button(action: onWriteMore) {
                                HStack(spacing: 6) {
                                    Image(systemName: "pencil.line")
                                        .font(.system(size: 13))
                                    Text(L10n.t("printed.writeMore"))
                                        .font(SpoolFonts.script(18))
                                }
                                .foregroundStyle(t.accent)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 12)
                        }

                        Button(L10n.t("printed.keepPrivate"), action: onClose)
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
