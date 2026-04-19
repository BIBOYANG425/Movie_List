import SwiftUI

public struct SpoolHeader<Trailing: View>: View {
    public var title: String
    public var small: Bool
    public var trailing: Trailing

    public init(title: String, small: Bool = false, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.small = small
        self.trailing = trailing()
    }

    public var body: some View {
        SpoolThemeReader { t, _ in
            HStack(alignment: .bottom) {
                Text(title)
                    .font(SpoolFonts.serif(small ? 22 : 30))
                    .tracking(-0.5)
                    .foregroundStyle(t.ink)
                Spacer()
                trailing
            }
            .padding(.horizontal, 18)
            .padding(.top, small ? 60 : 62)
            .padding(.bottom, small ? 10 : 14)
        }
    }
}

#Preview {
    SpoolHeader(title: "friends") {
        SpoolPill("◷ week", active: true, size: .sm) {}
    }
    .spoolMode(.paper)
}
