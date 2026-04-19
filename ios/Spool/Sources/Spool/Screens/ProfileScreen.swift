import SwiftUI

public struct ProfileScreen: View {
    public init() {}

    public var body: some View {
        SpoolScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.top, 50)
                    bioBox.padding(.top, 14)
                    obsessed.padding(.top, 18)
                    topFour.padding(.top, 18)
                    recent.padding(.top, 18)
                    footerPills.padding(.top, 16)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 110)
            }
        }
    }

    private var header: some View {
        SpoolThemeReader { t, _ in
            HStack(alignment: .bottom, spacing: 14) {
                StripedAvatar(size: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text(SpoolData.me.handle)
                        .font(SpoolFonts.serif(30))
                        .tracking(-0.5)
                        .foregroundStyle(t.ink)
                    Text("\(SpoolData.me.pronouns) · \(SpoolData.me.city)")
                        .font(SpoolFonts.hand(13))
                        .foregroundStyle(t.inkSoft)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(SpoolData.me.stubs)")
                        .font(SpoolFonts.serif(30))
                        .foregroundStyle(t.accent)
                    Text("STUBS")
                        .font(SpoolFonts.mono(9))
                        .tracking(2)
                        .foregroundStyle(t.inkSoft)
                }
            }
        }
    }

    private var bioBox: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 0) {
                Text(SpoolData.me.bioLine1)
                    .font(SpoolFonts.script(22))
                    .foregroundStyle(t.ink)
                Text(SpoolData.me.bioLine2)
                    .font(SpoolFonts.script(18))
                    .foregroundStyle(t.inkSoft)
            }
            .lineSpacing(1)
            .padding(14)
            .background(RuledLines(color: t.rule, step: 23))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(t.rule)
            )
        }
    }

    private var obsessed: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 0) {
                Text("CURRENTLY OBSESSED")
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)

                ZStack {
                    VStack(spacing: 4) {
                        Text("NOW PLAYING")
                            .font(SpoolFonts.mono(10))
                            .tracking(3)
                            .foregroundStyle(t.cream.opacity(0.6))
                        Text("PAST LIVES")
                            .font(SpoolFonts.serif(30))
                            .tracking(1)
                            .foregroundStyle(t.yellow)
                            .padding(.top, 2)
                        Text("3rd rewatch this month")
                            .font(SpoolFonts.script(16))
                            .foregroundStyle(t.cream.opacity(0.8))
                    }
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                }
                .background(t.ink)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .top) { Bulbs(count: 9).padding(.horizontal, 12).padding(.top, 6) }
                .overlay(alignment: .bottom) { Bulbs(count: 9).padding(.horizontal, 12).padding(.bottom, 6) }
                .padding(.top, 6)
            }
        }
    }

    private var topFour: some View {
        SpoolThemeReader { _, _ in
            VStack(alignment: .leading, spacing: 0) {
                Text("MY TOP 4 · ALL TIME")
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(SpoolTokens.paper.inkSoft)

                HStack(spacing: 6) {
                    ForEach(Array(SpoolData.topFour.enumerated()), id: \.offset) { i, m in
                        topFourCard(index: i, entry: m)
                            .rotationEffect(.degrees([-3, 2, -1, 3][i]))
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func topFourCard(index: Int, entry: TopFourEntry) -> some View {
        SpoolThemeReader { t, _ in
            ZStack(alignment: .topLeading) {
                PosterBlock(title: firstWord(entry.title), director: "—", seed: entry.seed)
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

    private var recent: some View {
        SpoolThemeReader { t, mode in
            VStack(alignment: .leading, spacing: 0) {
                Text("RECENT STUBS · APR")
                    .font(SpoolFonts.mono(10))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)

                HStack(spacing: 4) {
                    ForEach(SpoolData.recent.prefix(5), id: \.self) { m in
                        VStack(spacing: 0) {
                            PosterBlock(title: firstWord(m.title), year: m.year,
                                        director: m.director, seed: m.seed,
                                        cornerRadius: 0)
                                .frame(maxWidth: .infinity)
                            Text(m.tier.rawValue)
                                .font(SpoolFonts.serif(16))
                                .foregroundStyle(tierColor(m.tier, mode: mode))
                                .frame(maxWidth: .infinity)
                                .frame(height: 22)
                                .background(t.ink)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(t.ink, lineWidth: 1.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var footerPills: some View {
        HStack(spacing: 6) {
            SpoolPill("◉ 14 friends", size: .sm)
            SpoolPill("taste twin @mei · 72%", size: .sm)
            SpoolPill("april recap 🎞", size: .sm)
        }
    }

    private func firstWord(_ s: String) -> String {
        s.split(separator: " ").first.map(String.init) ?? s
    }
}

#Preview {
    ProfileScreen().spoolMode(.paper)
}
