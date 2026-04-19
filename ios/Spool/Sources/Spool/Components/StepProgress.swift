import SwiftUI

public struct StepProgress: View {
    public var step: Int
    public var total: Int
    public init(step: Int, total: Int = 4) { self.step = step; self.total = total }

    public var body: some View {
        SpoolThemeReader { t, _ in
            HStack(spacing: 6) {
                ForEach(0..<total, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(i < step ? t.ink : t.rule)
                        .frame(width: i < step ? 30 : 18, height: 3)
                        .animation(.easeInOut(duration: 0.3), value: step)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        StepProgress(step: 1, total: 4)
        StepProgress(step: 3, total: 4)
    }
    .padding()
    .spoolMode(.paper)
}
