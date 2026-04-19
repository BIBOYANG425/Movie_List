import SwiftUI

public struct Tape: View {
    public var color: Color
    public var width: CGFloat
    public var height: CGFloat

    public init(color: Color = Color(hex: 0xF5C33B).opacity(0.55), width: CGFloat = 70, height: CGFloat = 18) {
        self.color = color
        self.width = width
        self.height = height
    }

    public var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: width, height: height)
            .overlay(
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .foregroundStyle(Color.black.opacity(0.15))
            )
            .blendMode(.multiply)
    }
}

#Preview {
    Tape()
        .padding()
        .background(SpoolTokens.paper.cream)
        .spoolMode(.paper)
}
