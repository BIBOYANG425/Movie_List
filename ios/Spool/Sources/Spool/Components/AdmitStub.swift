import SwiftUI

public struct AdmitStub: View {
    public var movie: Movie
    public var tier: Tier
    public var line: String
    public var moods: [String]
    public var date: String
    public var handle: String
    public var stubNo: String
    public var compact: Bool

    public init(movie: Movie, tier: Tier = .S, line: String = "",
                moods: [String] = [], date: String = Self.defaultDate(),
                handle: String = "@yurui", stubNo: String = "#0127",
                compact: Bool = false) {
        self.movie = movie
        self.tier = tier
        self.line = line
        self.moods = moods
        self.date = date
        self.handle = handle
        self.stubNo = stubNo
        self.compact = compact
    }

    /// Default when the caller doesn't pass a date. Today's date in the same
    /// "APR · 18 · 2026" shape as the real stubs use. Replaces the old
    /// hardcoded "APR · 18 · 2026" which made every unscoped preview look
    /// like it was watched on April 18.
    /// Public because `public init`'s default argument needs a same-or-wider
    /// access level than the init itself.
    public static func defaultDate() -> String {
        let calendar = Calendar(identifier: .gregorian)
        let comps = calendar.dateComponents([.year, .month, .day], from: Date())
        let months = ["", "JAN", "FEB", "MAR", "APR", "MAY", "JUN",
                      "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        let m = comps.month.map { (1...12).contains($0) ? months[$0] : "—" } ?? "—"
        let d = comps.day.map { String(format: "%02d", $0) } ?? "—"
        let y = comps.year.map(String.init) ?? "—"
        return "\(m) · \(d) · \(y)"
    }

    public var body: some View {
        SpoolThemeReader { t, _ in
            HStack(spacing: 0) {
                leftSide(t: t)
                rightSide(t: t)
            }
            .background(t.cream)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(t.ink, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 0, x: 0, y: 1)
        }
    }

    @ViewBuilder
    private func leftSide(t: SpoolPalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ADMIT ONE · \(stubNo)")
                .font(SpoolFonts.mono(9))
                .tracking(2)
                .foregroundStyle(t.inkSoft)

            Text(movie.title)
                .font(SpoolFonts.serif(compact ? 22 : 30))
                .tracking(-0.3)
                .lineLimit(2)
                .foregroundStyle(t.ink)
                .padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(movie.director.uppercased()) · \(movie.year)")
                .font(SpoolFonts.mono(10))
                .tracking(1)
                .foregroundStyle(t.inkSoft)
                .padding(.top, 4)

            if !line.isEmpty {
                Text("\"\(line)\"")
                    .font(SpoolFonts.script(compact ? 18 : 22))
                    .foregroundStyle(t.accent)
                    .lineSpacing(2)
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !moods.isEmpty {
                FlowLayout(spacing: 4, rowSpacing: 4) {
                    ForEach(moods, id: \.self) { m in
                        Text(m)
                            .font(SpoolFonts.hand(11))
                            .foregroundStyle(t.ink)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .overlay(Capsule().stroke(t.ink, lineWidth: 1))
                    }
                }
                .padding(.top, 10)
            }

            Divider().overlay(t.rule).padding(.top, compact ? 10 : 14)
            HStack {
                Text(handle)
                Spacer()
                Text(date)
            }
            .font(SpoolFonts.mono(9))
            .tracking(1)
            .foregroundStyle(t.inkSoft)
            .padding(.top, 6)
        }
        .padding(compact ? 14 : 20)
        .padding(.leading, compact ? 0 : 0)
        .overlay(
            // dashed right edge (perforation)
            Rectangle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .foregroundStyle(t.ink)
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
                .frame(maxWidth: .infinity, alignment: .trailing)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rightSide(t: SpoolPalette) -> some View {
        VStack(spacing: 6) {
            Text("TIER")
                .font(SpoolFonts.mono(8))
                .tracking(2)
                .foregroundStyle(t.cream.opacity(0.6))
            TierStamp(tier: tier, size: compact ? 40 : 54)
                .colorScheme(.dark)
            Text("SPOOL · 2026")
                .font(SpoolFonts.mono(8))
                .tracking(3)
                .foregroundStyle(t.cream.opacity(0.5))
                .rotationEffect(.degrees(-90))
                .fixedSize()
                .frame(height: 80)
                .padding(.top, 4)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 10)
        .frame(width: 72)
        .frame(maxHeight: .infinity)
        .background(t.ink)
    }
}

// MARK: Flow layout (for mood chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width {
                y += rowH + rowSpacing
                x = 0
                rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxW = max(maxW, x)
        }
        return CGSize(width: min(maxW, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX {
                y += rowH + rowSpacing
                x = bounds.minX
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

#Preview("paper") {
    AdmitStub(
        movie: SpoolData.subject,
        tier: .S,
        line: "cried on the 6 train.",
        moods: ["tender", "devastating"]
    )
    .padding()
    .background(SpoolTokens.paper.cream)
    .spoolMode(.paper)
}

#Preview("dark") {
    AdmitStub(
        movie: SpoolData.subject,
        tier: .S,
        line: "cried on the 6 train.",
        moods: ["tender", "devastating"]
    )
    .padding()
    .background(SpoolTokens.dark.cream)
    .spoolMode(.dark)
}
