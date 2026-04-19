import SwiftUI

public enum SpoolPillSize { case sm, md }

public struct SpoolPill: View {
    public var title: String
    public var active: Bool
    public var filled: Bool
    public var size: SpoolPillSize
    public var action: () -> Void

    public init(_ title: String, active: Bool = false, filled: Bool = false,
                size: SpoolPillSize = .md, action: @escaping () -> Void = {}) {
        self.title = title
        self.active = active
        self.filled = filled
        self.size = size
        self.action = action
    }

    public var body: some View {
        SpoolThemeReader { t, _ in
            Button(action: action) {
                Text(title)
                    .font(SpoolFonts.hand(size == .sm ? 12 : 14))
                    .foregroundStyle((filled || active) ? t.cream : t.ink)
                    .padding(.horizontal, size == .sm ? 10 : 14)
                    .padding(.vertical, size == .sm ? 4 : 8)
                    .background(
                        Capsule()
                            .fill(filled || active ? t.ink : Color.clear)
                    )
                    .overlay(Capsule().stroke(t.ink, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    HStack(spacing: 8) {
        SpoolPill("quiet", active: false) {}
        SpoolPill("quiet", active: true) {}
        SpoolPill("save", filled: true) {}
    }
    .padding()
    .spoolMode(.paper)
}
