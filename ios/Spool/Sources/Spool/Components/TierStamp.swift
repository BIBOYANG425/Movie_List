import SwiftUI

public struct TierStamp: View {
    public var tier: Tier
    public var size: CGFloat

    public init(tier: Tier, size: CGFloat = 56) {
        self.tier = tier
        self.size = size
    }

    public var body: some View {
        SpoolThemeReader { _, mode in
            Text(tier.rawValue)
                .font(SpoolFonts.serif(size * 0.7))
                .tracking(-1)
                .foregroundStyle(tierColor(tier, mode: mode))
                .frame(width: size, height: size)
        }
    }
}

#Preview {
    HStack {
        TierStamp(tier: .S, size: 40)
        TierStamp(tier: .A, size: 40)
    }
    .padding()
    .spoolMode(.paper)
}
