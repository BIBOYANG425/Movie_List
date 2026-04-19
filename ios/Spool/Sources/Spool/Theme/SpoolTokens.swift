import SwiftUI

public enum SpoolMode: String, CaseIterable, Sendable {
    case paper
    case dark
}

public struct SpoolPalette: Sendable {
    public let cream: Color
    public let cream2: Color
    public let cream3: Color
    public let ink: Color
    public let ink2: Color
    public let inkSoft: Color
    public let rule: Color
    public let accent: Color
    public let accentSoft: Color
    public let yellow: Color
    public let tierS: Color
    public let tierA: Color
    public let tierB: Color
    public let tierC: Color
    public let tierD: Color
}

public enum SpoolTokens {
    public static let paper = SpoolPalette(
        cream:      Color(hex: 0xF2ECDC),
        cream2:     Color(hex: 0xE8E0C9),
        cream3:     Color(hex: 0xDDD3B8),
        ink:        Color(hex: 0x141414),
        ink2:       Color(hex: 0x3A3A3A),
        inkSoft:    Color(hex: 0x6B6B6B),
        rule:       Color(hex: 0xC9BE9C),
        accent:     Color(hex: 0xCE3B1F),
        accentSoft: Color(hex: 0xF2B8A6),
        yellow:     Color(hex: 0xF5C33B),
        tierS:      Color(hex: 0x8E4DCC),
        tierA:      Color(hex: 0x2F67C7),
        tierB:      Color(hex: 0x1F9167),
        tierC:      Color(hex: 0xD18A1A),
        tierD:      Color(hex: 0xB93B2E)
    )

    public static let dark = SpoolPalette(
        cream:      Color(hex: 0x0F0D0B),
        cream2:     Color(hex: 0x1A1714),
        cream3:     Color(hex: 0x26211B),
        ink:        Color(hex: 0xF0E6D0),
        ink2:       Color(hex: 0xD3C6A8),
        inkSoft:    Color(hex: 0x8A7F6A),
        rule:       Color(hex: 0x3A3128),
        accent:     Color(hex: 0xF2B233),
        accentSoft: Color(hex: 0x5C4217),
        yellow:     Color(hex: 0xF5C33B),
        tierS:      Color(hex: 0xD9A8FF),
        tierA:      Color(hex: 0x7FB8FF),
        tierB:      Color(hex: 0x8EE0B1),
        tierC:      Color(hex: 0xF5C97D),
        tierD:      Color(hex: 0xFF9583)
    )

    public static func palette(for mode: SpoolMode) -> SpoolPalette {
        switch mode {
        case .paper: return paper
        case .dark:  return dark
        }
    }
}

// MARK: Environment

private struct SpoolModeKey: EnvironmentKey {
    static let defaultValue: SpoolMode = .paper
}

public extension EnvironmentValues {
    var spoolMode: SpoolMode {
        get { self[SpoolModeKey.self] }
        set { self[SpoolModeKey.self] = newValue }
    }
}

public extension View {
    func spoolMode(_ mode: SpoolMode) -> some View {
        environment(\.spoolMode, mode)
    }
}

// MARK: Palette-aware helper

public struct SpoolThemeReader<Content: View>: View {
    @Environment(\.spoolMode) private var mode
    let content: (SpoolPalette, SpoolMode) -> Content

    public init(@ViewBuilder content: @escaping (SpoolPalette, SpoolMode) -> Content) {
        self.content = content
    }

    public var body: some View {
        content(SpoolTokens.palette(for: mode), mode)
    }
}

// MARK: Hex init

public extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xff) / 255.0
        let g = Double((hex >> 8) & 0xff) / 255.0
        let b = Double(hex & 0xff) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
