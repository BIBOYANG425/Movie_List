import SwiftUI

/// Illustrative poster — colored background, title-only, many decorative
/// variants and palettes. When `posterUrl` is non-nil, the real image loads
/// on top; the synthetic palette stays behind as a placeholder during load
/// and as a fallback on error.
///
/// Variety comes from three independent axes — palette × decor shape × layout
/// — so two adjacent stubs rarely look alike. Each axis is driven by the
/// `seed` with a different prime multiplier so seeds differing by 1 still
/// produce visibly distinct posters (simple `seed % N` on all three would
/// lock them in lockstep).
///
/// Header last reviewed: 2026-04-20
public struct PosterBlock: View {
    public var title: String
    public var year: Int?
    public var director: String
    public var seed: Int
    public var cornerRadius: CGFloat
    public var posterUrl: String?

    public init(title: String = "UNTITLED", year: Int? = nil,
                director: String = "—", seed: Int = 0,
                cornerRadius: CGFloat = 3, posterUrl: String? = nil) {
        self.title = title
        self.year = year
        self.director = director
        self.seed = seed
        self.cornerRadius = cornerRadius
        self.posterUrl = posterUrl
    }

    // MARK: palettes — 20 combinations spanning warm, cool, muted, bold,
    // monochrome and pastel. Order is deliberate: adjacent seeds get visually
    // distant palettes, not incremental shifts.
    private static let palettes: [(bg: Color, fg: Color, accent: Color)] = [
        (.init(hex: 0xD94F1F), .init(hex: 0xF2ECDC), .init(hex: 0x1A1A1A)), // vermillion + cream
        (.init(hex: 0x1B2A3A), .init(hex: 0xEAD8A8), .init(hex: 0xD94F1F)), // midnight + gold
        (.init(hex: 0x7A3FB8), .init(hex: 0xFDE8B8), .init(hex: 0x1A1A1A)), // grape + butter
        (.init(hex: 0x1F4E3D), .init(hex: 0xE8D19C), .init(hex: 0xD94F1F)), // forest + sand
        (.init(hex: 0xB93B2E), .init(hex: 0x1A1A1A), .init(hex: 0xF5C33B)), // tomato on ink
        (.init(hex: 0xE0A833), .init(hex: 0x1A1A1A), .init(hex: 0xB93B2E)), // mustard + ink
        (.init(hex: 0x262626), .init(hex: 0xF5C33B), .init(hex: 0xD94F1F)), // charcoal + marigold
        (.init(hex: 0x4E1F2E), .init(hex: 0xF2D0B6), .init(hex: 0xF5C33B)), // oxblood + blush
        (.init(hex: 0xA89858), .init(hex: 0x1F1F1F), .init(hex: 0xD94F1F)), // olive + ink
        (.init(hex: 0x0E3A4A), .init(hex: 0xF5C97D), .init(hex: 0xE67E5C)), // teal + apricot
        (.init(hex: 0xF0D9B8), .init(hex: 0x2A1B14), .init(hex: 0xB93B2E)), // vanilla + espresso
        (.init(hex: 0x2D4A3E), .init(hex: 0xF0C878), .init(hex: 0xB93B2E)), // pine + honey
        (.init(hex: 0x2B1E5C), .init(hex: 0xE3C7FF), .init(hex: 0xF5C33B)), // indigo + orchid
        (.init(hex: 0xC8A2C8), .init(hex: 0x2A1B14), .init(hex: 0x4E1F2E)), // lilac pastel
        (.init(hex: 0x0A0A0A), .init(hex: 0xE8E0C9), .init(hex: 0xF5C33B)), // near-black + cream
        (.init(hex: 0xE8B4A0), .init(hex: 0x2A1B14), .init(hex: 0x4E1F2E)), // peach + oxblood
        (.init(hex: 0x36423A), .init(hex: 0xD8C0A0), .init(hex: 0xE67E5C)), // moss + clay
        (.init(hex: 0xB7A4F2), .init(hex: 0x1F1140), .init(hex: 0xF5C33B)), // periwinkle + plum
        (.init(hex: 0x6B2A1F), .init(hex: 0xF0D9B8), .init(hex: 0xF5C33B)), // rust + vanilla
        (.init(hex: 0x4D5C4A), .init(hex: 0xF2ECDC), .init(hex: 0xD94F1F)), // sage + cream
    ]

    /// Number of decor variants rendered by `decorShape`. Bump this when you
    /// add a case and keep the modulo math in sync.
    private static let decorCount = 12

    /// Number of text-layout variants. Bump when you add a case to `layout`.
    private static let layoutCount = 4

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let absSeed = abs(seed)

            // Three axes use different primes so a single-step seed change
            // flips all three, not just one. With `% N` on the raw seed,
            // seeds 0..11 would share the same layout (0) even though the
            // palette rotates — we want them all to feel different.
            let paletteIdx = absSeed % Self.palettes.count
            let decorIdx = (absSeed * 7) % Self.decorCount
            let layoutIdx = (absSeed * 13) % Self.layoutCount

            let p = Self.palettes[paletteIdx]

            ZStack {
                p.bg
                decorShape(kind: decorIdx, fg: p.fg, accent: p.accent, w: w, h: h)
                layout(kind: layoutIdx, palette: p, w: w, h: h)
            }
            .frame(width: w, height: h)
            .overlay(
                // Real poster on top of the synthetic art when a URL is supplied.
                Group {
                    if let urlString = posterUrl, let url = URL(string: urlString) {
                        AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.2))) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure, .empty:
                                Color.clear
                            @unknown default:
                                Color.clear
                            }
                        }
                        .frame(width: w, height: h)
                        .clipped()
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: 1)
        }
        .aspectRatio(2.0/3.0, contentMode: .fit)
    }

    // MARK: - Layout variants

    /// Swaps where title / director / year sit on the poster. Keeps the same
    /// information density so every variant is readable, just differently
    /// composed.
    @ViewBuilder
    private func layout(kind: Int, palette p: (bg: Color, fg: Color, accent: Color),
                        w: CGFloat, h: CGFloat) -> some View {
        let minDim = min(w, h)
        switch kind {
        case 0:
            // Classic: director top-left, title bottom-left, year+SPOOL footer
            VStack(alignment: .leading, spacing: 0) {
                Text(directorLabel).font(SpoolFonts.mono(minDim * 0.052))
                    .tracking(minDim * 0.005).foregroundStyle(p.fg.opacity(0.7)).lineLimit(1)
                Spacer(minLength: 0)
                Text(title.uppercased())
                    .font(SpoolFonts.serif(minDim * 0.105))
                    .tracking(-0.5).foregroundStyle(p.fg).lineLimit(3)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                footer(palette: p, minDim: minDim)
            }
            .padding(.horizontal, w * 0.08).padding(.vertical, h * 0.09)

        case 1:
            // Title top, director+year bottom. Feels editorial.
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased())
                    .font(SpoolFonts.serif(minDim * 0.11))
                    .tracking(-0.6).foregroundStyle(p.fg).lineLimit(3)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(directorLabel).font(SpoolFonts.mono(minDim * 0.052))
                        .tracking(minDim * 0.005).foregroundStyle(p.fg.opacity(0.7)).lineLimit(1)
                    footer(palette: p, minDim: minDim)
                }
            }
            .padding(.horizontal, w * 0.08).padding(.vertical, h * 0.09)

        case 2:
            // Centered title, director tag above, year+SPOOL below. Feels
            // like a repertory screening card.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(directorLabel).font(SpoolFonts.mono(minDim * 0.050))
                    .tracking(minDim * 0.006).foregroundStyle(p.fg.opacity(0.7)).lineLimit(1)
                Text(title.uppercased())
                    .font(SpoolFonts.serif(minDim * 0.115))
                    .tracking(-0.5).foregroundStyle(p.fg).lineLimit(3)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                Spacer(minLength: 0)
                footer(palette: p, minDim: minDim)
            }
            .padding(.horizontal, w * 0.08).padding(.vertical, h * 0.1)

        case 3:
            // Vertical-right badge (title rotated along the right edge) with
            // year + director stacked left. High-variance layout — prevents
            // the grid from looking uniform.
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(year.map(String.init) ?? "")
                        .font(SpoolFonts.serif(minDim * 0.2))
                        .tracking(-1).foregroundStyle(p.fg.opacity(0.35))
                    Spacer(minLength: 0)
                    Text(directorLabel).font(SpoolFonts.mono(minDim * 0.052))
                        .tracking(minDim * 0.005).foregroundStyle(p.fg.opacity(0.75)).lineLimit(2)
                    Text("SPOOL").font(SpoolFonts.mono(minDim * 0.048))
                        .tracking(minDim * 0.008).foregroundStyle(p.fg.opacity(0.55))
                }
                Spacer(minLength: 0)
                Text(title.uppercased())
                    .font(SpoolFonts.serif(minDim * 0.115))
                    .tracking(-0.4).foregroundStyle(p.fg).lineLimit(2)
                    .multilineTextAlignment(.leading).fixedSize()
                    .rotationEffect(.degrees(-90), anchor: .center)
                    .frame(width: minDim * 0.16)
            }
            .padding(.horizontal, w * 0.08).padding(.vertical, h * 0.09)

        default:
            EmptyView()
        }
    }

    private var directorLabel: String {
        (director.isEmpty ? "dir. —" : "dir. \(director)").uppercased()
    }

    @ViewBuilder
    private func footer(palette p: (bg: Color, fg: Color, accent: Color), minDim: CGFloat) -> some View {
        HStack {
            Text(year.map(String.init) ?? "")
            Spacer(minLength: 0)
            Text("SPOOL")
        }
        .font(SpoolFonts.mono(minDim * 0.048))
        .tracking(minDim * 0.006)
        .foregroundStyle(p.fg.opacity(0.55))
        .padding(.top, 2)
    }

    // MARK: - Decor shapes

    @ViewBuilder
    private func decorShape(kind: Int, fg: Color, accent: Color, w: CGFloat, h: CGFloat) -> some View {
        switch kind {
        case 0:
            Circle()
                .stroke(accent.opacity(0.85), lineWidth: 2)
                .frame(width: w * 0.7, height: w * 0.7)
                .offset(y: -h * 0.1)
        case 1:
            ZStack {
                Rectangle().fill(fg.opacity(0.6)).frame(width: 2, height: h * 0.5).offset(y: -h * 0.03)
                Circle().fill(accent).frame(width: 10, height: 10).offset(y: -h * 0.26)
            }
        case 2:
            Rectangle()
                .fill(accent.opacity(0.25))
                .frame(width: w * 0.82, height: h * 0.22)
                .rotationEffect(.degrees(-4))
                .offset(y: -h * 0.18)
        case 3:
            Text("※")
                .font(SpoolFonts.serif(w * 0.9))
                .foregroundStyle(accent.opacity(0.18))
                .offset(y: -h * 0.1)
        case 4:
            ZStack {
                Circle().fill(accent.opacity(0.5)).frame(width: w * 0.34, height: w * 0.34)
                    .blendMode(.screen).offset(x: -w * 0.14, y: -h * 0.14)
                Circle().fill(fg.opacity(0.4)).frame(width: w * 0.34, height: w * 0.34)
                    .blendMode(.screen).offset(x: w * 0.14, y: -h * 0.08)
            }
        case 5:
            StripesPattern(color: fg.opacity(0.35), spacing: 7)
                .frame(width: w * 0.82, height: h * 0.26)
                .offset(y: -h * 0.16)

        // NEW variants

        case 6:
            // Concentric circles
            ZStack {
                ForEach([0.32, 0.48, 0.64, 0.80], id: \.self) { r in
                    Circle()
                        .stroke(accent.opacity(Double(0.38 - r * 0.3)), lineWidth: 1.5)
                        .frame(width: w * r, height: w * r)
                }
            }
            .offset(y: -h * 0.08)
        case 7:
            // Half-moon wedge — bold graphic shape lower-right
            Circle()
                .fill(accent.opacity(0.55))
                .frame(width: w * 1.4, height: w * 1.4)
                .offset(x: w * 0.6, y: h * 0.4)
                .blendMode(.multiply)
        case 8:
            // Chevron arrows stacked
            VStack(spacing: w * 0.04) {
                ForEach(0..<3, id: \.self) { _ in
                    Text("▼")
                        .font(SpoolFonts.serif(w * 0.22))
                        .foregroundStyle(fg.opacity(0.25))
                }
            }
            .offset(y: -h * 0.05)
        case 9:
            // Dotted grid
            DotGridPattern(color: fg.opacity(0.30), spacing: 10)
                .frame(width: w * 0.75, height: h * 0.40)
                .offset(y: -h * 0.12)
        case 10:
            // Asymmetric burst — radial lines from a corner
            BurstPattern(color: accent.opacity(0.35), count: 9)
                .frame(width: w * 1.2, height: h * 0.7)
                .offset(x: -w * 0.35, y: h * 0.18)
        case 11:
            // Thick diagonal slash + small circle accent
            ZStack {
                Rectangle()
                    .fill(accent.opacity(0.3))
                    .frame(width: w * 1.5, height: w * 0.12)
                    .rotationEffect(.degrees(-30))
                Circle()
                    .fill(fg.opacity(0.5))
                    .frame(width: 14, height: 14)
                    .offset(x: w * 0.22, y: -h * 0.12)
            }
            .offset(y: -h * 0.06)
        default:
            EmptyView()
        }
    }
}

// MARK: - Pattern primitives

private struct StripesPattern: View {
    var color: Color
    var spacing: CGFloat
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 0
            while y < size.height {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(color), lineWidth: 1)
                y += spacing
            }
        }.allowsHitTesting(false)
    }
}

private struct DotGridPattern: View {
    var color: Color
    var spacing: CGFloat
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    let r = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                    ctx.fill(Path(ellipseIn: r), with: .color(color))
                    x += spacing
                }
                y += spacing
            }
        }.allowsHitTesting(false)
    }
}

/// Radial lines emanating from the leading edge — think sunburst / vintage
/// movie poster flourish. Count controls density.
private struct BurstPattern: View {
    var color: Color
    var count: Int
    var body: some View {
        Canvas { ctx, size in
            let origin = CGPoint(x: 0, y: size.height / 2)
            let radius = max(size.width, size.height)
            let spread = 110.0 // degrees of arc to cover
            let step = spread / Double(max(count - 1, 1))
            let start = -spread / 2
            for i in 0..<count {
                let angle = (start + Double(i) * step) * .pi / 180
                let end = CGPoint(
                    x: origin.x + CGFloat(cos(angle)) * radius,
                    y: origin.y + CGFloat(sin(angle)) * radius
                )
                var p = Path()
                p.move(to: origin)
                p.addLine(to: end)
                ctx.stroke(p, with: .color(color), lineWidth: 1.2)
            }
        }.allowsHitTesting(false)
    }
}

#Preview("grid") {
    let seeds = Array(0..<24)
    return ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
            ForEach(seeds, id: \.self) { s in
                PosterBlock(title: "TITLE \(s)", year: 2020 + s, director: "dir \(s)", seed: s)
            }
        }
        .padding()
    }
    .background(SpoolTokens.paper.cream)
    .spoolMode(.paper)
}
