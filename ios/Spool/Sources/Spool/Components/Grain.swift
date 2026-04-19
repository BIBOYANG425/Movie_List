import SwiftUI

/// Cheap paper grain — random noise dots rendered by Canvas. Opacity is
/// low by default so it reads as texture, not pattern.
public struct Grain: View {
    public var opacity: Double
    public init(opacity: Double = 0.06) { self.opacity = opacity }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            var seed: UInt64 = 0xC001_BABE
            let density: Int = Int((size.width * size.height) / 80)
            for _ in 0..<density {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let x = CGFloat((seed >> 33) & 0xFFFFF) / CGFloat(0xFFFFF) * size.width
                let y = CGFloat((seed >> 13) & 0xFFFFF) / CGFloat(0xFFFFF) * size.height
                let a = CGFloat((seed >> 3)  & 0xFF) / 255.0
                let rect = CGRect(x: x, y: y, width: 1, height: 1)
                ctx.fill(Path(rect), with: .color(.black.opacity(Double(a) * 0.5)))
            }
        }
        .opacity(opacity)
        .blendMode(.multiply)
        .allowsHitTesting(false)
    }
}

#Preview {
    ZStack {
        SpoolTokens.paper.cream
        Grain(opacity: 0.08)
    }
    .frame(width: 200, height: 200)
    .spoolMode(.paper)
}
