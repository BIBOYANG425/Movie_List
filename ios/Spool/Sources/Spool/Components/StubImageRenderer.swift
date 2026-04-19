import SwiftUI

#if canImport(UIKit)
import UIKit

/// Renders an `AdmitStub` to a `UIImage` suitable for share-sheet handoff.
/// iOS 16+ only. Must run on the main actor because `ImageRenderer` needs a
/// live SwiftUI environment.
@MainActor
public enum StubImageRenderer {

    public static func render(
        movie: Movie,
        tier: Tier,
        line: String,
        moods: [String],
        date: String,
        handle: String,
        stubNo: String,
        mode: SpoolMode = .paper,
        scale: CGFloat = 3,
        width: CGFloat = 420
    ) -> UIImage? {
        let palette = (mode == .paper) ? SpoolTokens.paper : SpoolTokens.dark

        let content = AdmitStub(
            movie: movie, tier: tier, line: line, moods: moods,
            date: date, handle: handle, stubNo: stubNo
        )
        .spoolMode(mode)
        .padding(20)
        .background(palette.cream)
        .frame(width: width)

        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return renderer.uiImage
    }
}
#endif
