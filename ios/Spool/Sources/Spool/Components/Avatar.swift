import SwiftUI

// MARK: Initials helper

/// Derives a single uppercase letter from a display name or handle string.
///
/// Contract:
/// - Leading "@" is stripped before scanning.
/// - The first Unicode letter or decimal-digit character is uppercased and
///   returned as the initial.
/// - CJK and other non-Latin letters are returned as-is (they are already
///   display-appropriate; uppercasing is a no-op for them).
/// - If the input is empty, whitespace-only, or contains no letter / digit
///   (e.g. pure emoji), returns "?" as a legible fallback glyph.
public func initialsLetter(from input: String) -> String {
    // Strip a leading "@" before scanning.
    let stripped = input.hasPrefix("@") ? String(input.dropFirst()) : input
    for scalar in stripped.unicodeScalars {
        let cat = scalar.properties.generalCategory
        if cat == .lowercaseLetter || cat == .uppercaseLetter ||
           cat == .titlecaseLetter || cat == .otherLetter ||
           cat == .modifierLetter || cat == .decimalNumber {
            return String(scalar).uppercased()
        }
    }
    return "?"
}

// MARK: MonogramAvatar

/// A filled-disc avatar that shows the person's initial letter.
///
/// Replaces the old `StripedAvatar` stripe design, which used `cream3`/`cream2`
/// — a <15-channel difference on the cream page — making the pattern invisible
/// and the circle read as a bare ink ring (design-check defect 4).
///
/// The disc is filled with `t.ink` and the letter is rendered in `t.cream` so
/// the monogram reads clearly in both paper and dark modes without any palette
/// special-casing.
///
/// `name` is the display name or handle used to derive the initial (one
/// uppercase character). Pass `""` (the default) to show a "?" fallback —
/// useful for sites where no name is in scope (small inline chips, etc.).
public struct StripedAvatar: View {
    public var size: CGFloat
    public var name: String

    public init(size: CGFloat = 42, name: String = "") {
        self.size = size
        self.name = name
    }

    public var body: some View {
        SpoolThemeReader { t, _ in
            ZStack {
                Circle()
                    .fill(t.ink)
                    .frame(width: size, height: size)
                Text(initialsLetter(from: name))
                    .font(.system(size: size * 0.42, weight: .semibold, design: .default))
                    .foregroundStyle(t.cream)
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
        StripedAvatar(size: 42, name: "bobby")
        StripedAvatar(size: 72, name: "@yurui")
        StripedAvatar(size: 42, name: "")
        StripedAvatar(size: 42, name: "🎬")
    }
    .padding()
    .spoolMode(.paper)
}
