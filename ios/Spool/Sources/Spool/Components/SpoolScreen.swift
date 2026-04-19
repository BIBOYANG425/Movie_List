import SwiftUI

/// Full-bleed paper background with grain overlay. All screens wrap in this.
public struct SpoolScreen<Content: View>: View {
    public var background: AnyShapeStyle?
    @ViewBuilder public var content: () -> Content

    public init(background: AnyShapeStyle? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.background = background
        self.content = content
    }

    public var body: some View {
        SpoolThemeReader { t, _ in
            ZStack {
                if let bg = background {
                    Rectangle().fill(bg).ignoresSafeArea()
                } else {
                    t.cream.ignoresSafeArea()
                }
                Grain(opacity: 0.04).ignoresSafeArea()
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

#Preview {
    SpoolScreen {
        Text("SpoolScreen")
            .font(SpoolFonts.serif(24))
            .padding(.top, 80)
    }
    .spoolMode(.paper)
}
