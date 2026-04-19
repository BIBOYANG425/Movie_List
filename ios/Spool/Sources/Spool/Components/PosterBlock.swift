import SwiftUI

/// Illustrative poster — colored background, title-only, six decorative
/// variants and twelve palettes. Mirrors `PosterBlock` in `tokens.jsx`.
/// When `posterUrl` is non-nil, a real image loads on top; the synthetic
/// palette stays behind as a placeholder during load and fallback on error.
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

    private static let palettes: [(bg: Color, fg: Color, accent: Color)] = [
        (.init(hex: 0xD94F1F), .init(hex: 0xF2ECDC), .init(hex: 0x1A1A1A)),
        (.init(hex: 0x1B2A3A), .init(hex: 0xEAD8A8), .init(hex: 0xD94F1F)),
        (.init(hex: 0x7A3FB8), .init(hex: 0xFDE8B8), .init(hex: 0x1A1A1A)),
        (.init(hex: 0x1F4E3D), .init(hex: 0xE8D19C), .init(hex: 0xD94F1F)),
        (.init(hex: 0xB93B2E), .init(hex: 0x1A1A1A), .init(hex: 0xF5C33B)),
        (.init(hex: 0xE0A833), .init(hex: 0x1A1A1A), .init(hex: 0xB93B2E)),
        (.init(hex: 0x262626), .init(hex: 0xF5C33B), .init(hex: 0xD94F1F)),
        (.init(hex: 0x4E1F2E), .init(hex: 0xF2D0B6), .init(hex: 0xF5C33B)),
        (.init(hex: 0xA89858), .init(hex: 0x1F1F1F), .init(hex: 0xD94F1F)),
        (.init(hex: 0x0E3A4A), .init(hex: 0xF5C97D), .init(hex: 0xE67E5C)),
        (.init(hex: 0xF0D9B8), .init(hex: 0x2A1B14), .init(hex: 0xB93B2E)),
        (.init(hex: 0x2D4A3E), .init(hex: 0xF0C878), .init(hex: 0xB93B2E)),
    ]

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let minDim = min(w, h)
            let p = Self.palettes[abs(seed) % Self.palettes.count]
            let decor = abs(seed) % 6

            ZStack {
                p.bg

                decorShape(kind: decor, fg: p.fg, accent: p.accent, w: w, h: h)

                VStack(alignment: .leading, spacing: 0) {
                    Text((director.isEmpty ? "dir. —" : "dir. \(director)").uppercased())
                        .font(SpoolFonts.mono(minDim * 0.052))
                        .tracking(minDim * 0.005)
                        .foregroundStyle(p.fg.opacity(0.7))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(title.uppercased())
                        .font(SpoolFonts.serif(minDim * 0.105))
                        .tracking(-0.5)
                        .foregroundStyle(p.fg)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

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
                .padding(.horizontal, w * 0.08)
                .padding(.vertical, h * 0.09)
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
                Rectangle()
                    .fill(fg.opacity(0.6))
                    .frame(width: 2, height: h * 0.5)
                    .offset(y: -h * 0.03)
                Circle()
                    .fill(accent)
                    .frame(width: 10, height: 10)
                    .offset(y: -h * 0.26)
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
                Circle()
                    .fill(accent.opacity(0.5))
                    .frame(width: w * 0.34, height: w * 0.34)
                    .blendMode(.screen)
                    .offset(x: -w * 0.14, y: -h * 0.14)
                Circle()
                    .fill(fg.opacity(0.4))
                    .frame(width: w * 0.34, height: w * 0.34)
                    .blendMode(.screen)
                    .offset(x: w * 0.14, y: -h * 0.08)
            }
        default:
            StripesPattern(color: fg.opacity(0.35), spacing: 7)
                .frame(width: w * 0.82, height: h * 0.26)
                .offset(y: -h * 0.16)
        }
    }
}

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
        } .allowsHitTesting(false)
    }
}

#Preview("grid") {
    let seeds = Array(0..<12)
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
