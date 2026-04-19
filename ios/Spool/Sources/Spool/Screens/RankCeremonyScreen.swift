import SwiftUI

public struct RankCeremonyScreen: View {
    public var movie: Movie
    public var tier: Tier
    public var onDone: (_ moods: [String], _ line: String) -> Void
    public var onBack: () -> Void

    @State private var moods: [String] = ["tender", "devastating"]
    @State private var line: String = "cried on the 6 train."

    public init(movie: Movie, tier: Tier,
                onDone: @escaping (_ moods: [String], _ line: String) -> Void,
                onBack: @escaping () -> Void) {
        self.movie = movie
        self.tier = tier
        self.onDone = onDone
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

                    StepProgress(step: 3, total: 3).padding(.top, 10)

                    Text("STEP 3 OF 3 · CEREMONY")
                        .font(SpoolFonts.mono(10))
                        .tracking(2)
                        .foregroundStyle(SpoolTokens.paper.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)

                    Text("now bottle it up.")
                        .font(SpoolFonts.serif(28))
                        .foregroundStyle(SpoolTokens.paper.ink)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 10)

                    Text("pick up to 3 moods · one line to remember")
                        .font(SpoolFonts.script(17))
                        .foregroundStyle(SpoolTokens.paper.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .center)

                    moodCloud.padding(.top, 14)
                    lineBox.padding(.top, 16)

                    HStack(spacing: 8) {
                        SpoolPill("← back", action: onBack)
                        SpoolPill("print my stub →", filled: true) { onDone(moods, line) }
                    }
                    .padding(.top, 20)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 18)
                .padding(.top, 50)
                .padding(.bottom, 40)
            }
        }
    }

    private var moodCloud: some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            ForEach(Array(SpoolData.moods.enumerated()), id: \.element) { idx, m in
                moodChip(m, index: idx)
            }
        }
    }

    private func moodChip(_ m: String, index: Int) -> some View {
        SpoolThemeReader { t, _ in
            Button { toggle(m) } label: {
                Text(m)
                    .font(SpoolFonts.hand(14))
                    .foregroundStyle(moods.contains(m) ? t.cream : t.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(moods.contains(m) ? t.ink : Color.clear))
                    .overlay(Capsule().stroke(t.ink, lineWidth: 1.5))
                    .rotationEffect(.degrees(Double((index * 37) % 5 - 2)))
            }
            .buttonStyle(.plain)
        }
    }

    private var lineBox: some View {
        SpoolThemeReader { t, _ in
            VStack(alignment: .leading, spacing: 6) {
                Text("A LINE TO REMEMBER")
                    .font(SpoolFonts.mono(9))
                    .tracking(2)
                    .foregroundStyle(t.inkSoft)
                TextEditor(text: $line)
                    .font(SpoolFonts.script(22))
                    .foregroundStyle(t.accent)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60)
            }
            .padding(16)
            .background(RuledLines(color: t.rule, step: 23))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(t.ink)
            )
            .frame(minHeight: 100)
        }
    }

    private func toggle(_ m: String) {
        if moods.contains(m) {
            moods.removeAll { $0 == m }
        } else if moods.count < 3 {
            moods.append(m)
        }
    }
}

struct RuledLines: View {
    var color: Color
    var step: CGFloat

    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = step
            while y < size.height {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(color), lineWidth: 1)
                y += step
            }
        }
    }
}

#Preview {
    RankCeremonyScreen(movie: SpoolData.subject, tier: .S, onDone: { _, _ in }, onBack: {})
        .spoolMode(.paper)
}
