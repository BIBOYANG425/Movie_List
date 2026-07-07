import SwiftUI

/// Generic flip container for a feed ticket — a 3D Y-rotation that swaps
/// `front` and `back` in place (spec §2 "flip the ticket"). The flip must
/// feel physical: a spring drives the rotation and the paper shadow deepens
/// through the mid-flip so the card reads as a real object turning over.
///
/// The card rotates 0° → 180°. The back is pre-rotated a further 180° so that,
/// once the container passes the halfway point, the back's text reads the
/// right way round instead of mirror-flipped. Only the currently-facing side
/// is hit-testable, so taps never fall through to the hidden face.
///
/// Container-only: it owns the animation, not the content. `FeedTicket`
/// (front) and `FeedTicketBack` (Task 4) plug in via the trailing closures.
///
/// Contract: docs/plans/2026-07-08-c1-ios-feed-ui-plan.md (Task 3),
/// spec docs/plans/2026-07-08-c1-ios-feed-ui-design.md §2.
public struct FeedTicketFlip<Front: View, Back: View>: View {
    @Binding var isFlipped: Bool
    let front: () -> Front
    let back: () -> Back

    /// Y-axis of the 3D rotation. Fixed so front and back share one hinge.
    private let axis: (x: CGFloat, y: CGFloat, z: CGFloat) = (0, 1, 0)

    public init(isFlipped: Binding<Bool>,
                @ViewBuilder front: @escaping () -> Front,
                @ViewBuilder back: @escaping () -> Back) {
        self._isFlipped = isFlipped
        self.front = front
        self.back = back
    }

    /// 0 (front) or 180 (back). Animated via the flip spring at the binding
    /// change site so external `isFlipped` toggles still animate.
    private var angle: Double { isFlipped ? 180 : 0 }

    public var body: some View {
        ZStack {
            // Front: visible 0°→90°, hidden past the halfway line.
            front()
                .modifier(FlipFace(angle: angle, faceUp: !isFlipped))
                .rotation3DEffect(.degrees(angle), axis: axis, perspective: 0.4)

            // Back: pre-rotated 180° so its content is upright once revealed.
            back()
                .rotation3DEffect(.degrees(180), axis: axis)
                .modifier(FlipFace(angle: angle, faceUp: isFlipped))
                .rotation3DEffect(.degrees(angle), axis: axis, perspective: 0.4)
        }
        // Shadow deepens toward the mid-flip (angle 90°) then eases back — the
        // "slight paper shadow" that sells the physicality (spec §2).
        .shadow(color: .black.opacity(midFlipShadowOpacity), radius: 6, x: 0, y: 3)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isFlipped)
    }

    /// Peaks at the halfway point of the flip, near zero at rest on either
    /// face. `sin` of the rotation angle gives a clean 0→1→0 hump.
    private var midFlipShadowOpacity: Double {
        0.08 + 0.22 * abs(sin(angle * .pi / 180))
    }
}

/// Hides whichever face is pointing away from the viewer. Without this both
/// faces would render on top of each other (SwiftUI has no back-face culling),
/// so we gate opacity + hit-testing on which side is currently up.
private struct FlipFace: ViewModifier {
    let angle: Double
    /// True when THIS face should be the visible one at the current angle.
    let faceUp: Bool

    func body(content: Content) -> some View {
        // Past 90° the face has turned away; only show the side whose `faceUp`
        // matches the flip state. Opacity flips exactly at the midpoint.
        let showing = faceUp
        return content
            .opacity(showing ? 1 : 0)
            .accessibilityHidden(!showing)
            .allowsHitTesting(showing)
    }
}

// MARK: - Previews

#if DEBUG
private struct FeedTicketFlipPreviewHost: View {
    @State private var flipped = false
    var body: some View {
        SpoolThemeReader { t, _ in
            VStack(spacing: 16) {
                FeedTicketFlip(
                    isFlipped: $flipped,
                    front: {
                        FeedTicket(card: .preview(
                            kind: .ranking,
                            metadata: ["notes": .string("cried on the 6 train.")]
                        ), onFlip: { flipped.toggle() })
                    },
                    back: {
                        // Placeholder back — Task 4 ships FeedTicketBack.
                        VStack(spacing: 10) {
                            Text("REACTIONS + REPLIES")
                                .font(SpoolFonts.mono(11)).tracking(2)
                            Text("(flip-side arrives in Task 4)")
                                .font(SpoolFonts.script(18))
                            Button("TAP TO FLIP BACK") { flipped.toggle() }
                                .font(SpoolFonts.mono(10))
                                .foregroundStyle(t.accent)
                        }
                        .foregroundStyle(t.ink)
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .background(RoundedRectangle(cornerRadius: 6).fill(t.cream2))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.ink, lineWidth: 1.5))
                    }
                )
                .frame(height: 220)

                Button("toggle flip") { flipped.toggle() }
                    .font(SpoolFonts.mono(11))
                    .foregroundStyle(t.accent)
            }
            .padding()
        }
    }
}

#Preview("flip · interactive") {
    FeedTicketFlipPreviewHost()
        .background(SpoolTokens.paper.cream)
        .spoolMode(.paper)
}

#Preview("flip · resting on back") {
    FeedTicketFlip(
        isFlipped: .constant(true),
        front: { FeedTicket(card: .preview(kind: .ranking)) },
        back: {
            SpoolThemeReader { t, _ in
                Text("BACK FACE")
                    .font(SpoolFonts.mono(12)).tracking(3)
                    .foregroundStyle(t.ink)
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.cream2))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.ink, lineWidth: 1.5))
            }
        }
    )
    .frame(height: 220)
    .padding()
    .background(SpoolTokens.paper.cream)
    .spoolMode(.paper)
}
#endif
