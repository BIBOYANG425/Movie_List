import SwiftUI

public struct StripedAvatar: View {
    public var size: CGFloat
    public init(size: CGFloat = 42) { self.size = size }

    public var body: some View {
        SpoolThemeReader { t, _ in
            ZStack {
                StripePattern(a: t.cream3, b: t.cream2, spacing: 4)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                Circle().stroke(t.ink, lineWidth: 1.5)
            }
            .frame(width: size, height: size)
        }
    }
}

public struct StripePattern: View {
    public var a: Color
    public var b: Color
    public var spacing: CGFloat

    public init(a: Color, b: Color, spacing: CGFloat = 4) {
        self.a = a; self.b = b; self.spacing = spacing
    }

    public var body: some View {
        Canvas { ctx, size in
            let diag = sqrt(size.width * size.width + size.height * size.height)
            let step = spacing * 2
            var x = -diag
            var toggle = true
            while x < diag {
                var p = Path()
                p.move(to: CGPoint(x: x, y: -diag))
                p.addLine(to: CGPoint(x: x + diag, y: diag))
                p.addLine(to: CGPoint(x: x + diag + spacing, y: diag))
                p.addLine(to: CGPoint(x: x + spacing, y: -diag))
                p.closeSubpath()
                ctx.fill(p, with: .color(toggle ? a : b))
                x += step
                toggle.toggle()
            }
        }
    }
}

public struct Bulbs: View {
    public var count: Int
    public init(count: Int = 7) { self.count = count }
    public var body: some View {
        HStack {
            ForEach(0..<count, id: \.self) { _ in
                Circle()
                    .fill(Color(hex: 0xF5C33B))
                    .frame(width: 6, height: 6)
                    .shadow(color: Color(hex: 0xF5C33B).opacity(0.6), radius: 3)
                Spacer(minLength: 0)
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        StripedAvatar(size: 42)
        StripedAvatar(size: 72)
    }
    .padding()
    .spoolMode(.paper)
}
