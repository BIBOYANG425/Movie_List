import SwiftUI

/// Generic flip container for a feed ticket — a 3D Y-rotation that swaps
/// `front` and `back` in place (spec §2 "flip the ticket"). The flip must
/// feel physical: a spring drives the rotation, the face switches EXACTLY at
/// the 90° hinge, and the paper shadow deepens through the mid-flip so the
/// card reads as a real object turning over.
///
/// How the hinge works: the target angle is 0 (front) or 180 (back), and the
/// spring interpolates it. Both face modifiers and the shadow modifier conform
/// to `Animatable`, so their `animatableData` receives every INTERPOLATED
/// angle frame — the face switch (`FeedTicketFlipHinge.frontShowing`), the
/// shadow peak (`shadowOpacity`), and hit-testing all track the live angle,
/// not just the endpoints. The back face rotates `angle - 180`, which lands
/// at 0° when the flip completes, so its text reads upright, not mirrored.
///
/// Hinge math is pure and XCTest-covered (`FeedTicketFlipHinge` in
/// FeedTicketLogicTests); the "hinge switch" preview freezes 89° vs 91° to
/// make the switch visually verifiable.
///
/// Container-only: it owns the animation, not the content. `FeedTicket`
/// (front) and `FeedTicketBack` (Task 4) plug in via the trailing closures.
///
/// Contract: docs/plans/2026-07-08-c1-ios-feed-ui-plan.md (Task 3, corrected
/// signature — no `card:` param), spec
/// docs/plans/2026-07-08-c1-ios-feed-ui-design.md §2.
public struct FeedTicketFlip<Front: View, Back: View>: View {
    @Binding var isFlipped: Bool
    let front: () -> Front
    let back: () -> Back

    public init(isFlipped: Binding<Bool>,
                @ViewBuilder front: @escaping () -> Front,
                @ViewBuilder back: @escaping () -> Back) {
        self._isFlipped = isFlipped
        self.front = front
        self.back = back
    }

    /// Target angle; the Animatable modifiers below see its interpolation.
    private var angle: Double { isFlipped ? 180 : 0 }

    public var body: some View {
        ZStack {
            front().modifier(FlipFaceModifier(angle: angle, isFront: true))
            back().modifier(FlipFaceModifier(angle: angle, isFront: false))
        }
        .modifier(FlipShadowModifier(angle: angle))
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isFlipped)
    }
}

// MARK: - Hinge math (pure, tested)

/// The flip's pure geometry: which face shows at a given interpolated angle,
/// and how deep the paper shadow runs. Kept SwiftUI-free so
/// FeedTicketLogicTests can pin the hinge behavior.
public enum FeedTicketFlipHinge {

    /// Front is showing strictly below the 90° hinge; the switch happens AT
    /// 90° exactly (the edge-on frame already belongs to the back).
    public static func frontShowing(at angle: Double) -> Bool {
        angle < 90
    }

    /// Shadow opacity: 0.08 at rest on either face, peaking 0.30 at the 90°
    /// hinge — `sin` of the rotation gives a clean 0→1→0 hump across the flip.
    public static func shadowOpacity(at angle: Double) -> Double {
        0.08 + 0.22 * abs(sin(angle * .pi / 180))
    }
}

// MARK: - Animatable face modifier

/// Rotates one face and shows/hides it based on the LIVE interpolated angle.
/// `Animatable` conformance is what makes this real: without it SwiftUI would
/// hand the modifier only the endpoint values (0/180) and crossfade the two
/// faces over the whole spring, never switching at the hinge. Hit-testing and
/// VoiceOver visibility follow the showing face so taps never land on the
/// hidden side.
/// Internal (not private) so the test target can render mid-flight frames.
struct FlipFaceModifier: ViewModifier, Animatable {
    var angle: Double
    let isFront: Bool

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    private var showing: Bool {
        isFront ? FeedTicketFlipHinge.frontShowing(at: angle)
                : !FeedTicketFlipHinge.frontShowing(at: angle)
    }

    func body(content: Content) -> some View {
        content
            // Front turns 0→180 with the flip; back turns -180→0 so it
            // arrives upright (text reading correctly) at completion.
            .rotation3DEffect(.degrees(isFront ? angle : angle - 180),
                              axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            .opacity(showing ? 1 : 0)
            .allowsHitTesting(showing)
            .accessibilityHidden(!showing)
    }
}

// MARK: - Animatable shadow modifier

/// Deepens the paper shadow toward the 90° hinge and relaxes it at rest —
/// the "slight paper shadow" that sells the physicality (spec §2). Animatable
/// for the same reason as `FlipFaceModifier`: the opacity must follow the
/// interpolated angle, peaking mid-flip instead of holding the resting value.
/// Internal (not private) so the test target can render mid-flight frames.
struct FlipShadowModifier: ViewModifier, Animatable {
    var angle: Double

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        content.shadow(
            color: .black.opacity(FeedTicketFlipHinge.shadowOpacity(at: angle)),
            radius: 6, x: 0, y: 3
        )
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

/// One face pair frozen at a fixed interpolated angle — the visual proof the
/// hinge switches at 90°: at 89° the front is still showing (nearly edge-on),
/// at 91° the back has taken over; 45° shows the deepened mid-turn shadow.
private struct FrozenHinge: View {
    let angle: Double
    var body: some View {
        SpoolThemeReader { t, _ in
            ZStack {
                Text("FRONT")
                    .font(SpoolFonts.mono(12)).tracking(3)
                    .foregroundStyle(t.ink)
                    .frame(width: 220, height: 120)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.cream))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.ink, lineWidth: 1.5))
                    .modifier(FlipFaceModifier(angle: angle, isFront: true))
                Text("BACK")
                    .font(SpoolFonts.mono(12)).tracking(3)
                    .foregroundStyle(t.cream)
                    .frame(width: 220, height: 120)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.ink))
                    .modifier(FlipFaceModifier(angle: angle, isFront: false))
            }
            .modifier(FlipShadowModifier(angle: angle))
        }
    }
}

#Preview("hinge switch · 89° vs 91°") {
    VStack(spacing: 24) {
        VStack(spacing: 6) {
            Text("89° — front showing, shadow near peak").font(SpoolFonts.mono(9))
            FrozenHinge(angle: 89)
        }
        VStack(spacing: 6) {
            Text("91° — back showing").font(SpoolFonts.mono(9))
            FrozenHinge(angle: 91)
        }
        VStack(spacing: 6) {
            Text("45° — mid-turn, deepened shadow").font(SpoolFonts.mono(9))
            FrozenHinge(angle: 45)
        }
    }
    .padding()
    .background(SpoolTokens.paper.cream)
    .spoolMode(.paper)
}
#endif
