import SwiftUI

/// Bold 8-step onboarding flow with an inserted sign-in screen after the
/// Cold Open "take your seat" CTA. Completion persists via `@AppStorage`
/// so the flow only appears on first launch.
///
/// Steps:
///  0 Cold Open     — tap "take your seat ↘"
///  1 Sign In       — email+password, or skip
///  2 Manifesto     — house rules
///  3 Grid tap      — seed 4+ films into tiers
///  4 H2H           — pick one S-tier head-to-head
///  5 Print         — stub prints with stamp animation
///  6 Identity      — @handle + two bio questions
///  7 Twins         — revealed taste twins
///  8 Season        — "start spooling ▸" closes the flow
public struct OnboardingFlow: View {
    public var onFinish: (OnboardingOutcome) -> Void
    @State private var step: Int = 0
    @State private var signedIn: Bool = false
    @State private var handle: String = "yurui"
    @State private var picks: [OnbPick] = []

    public init(onFinish: @escaping (OnboardingOutcome) -> Void) {
        self.onFinish = onFinish
    }

    public var body: some View {
        content
            .spoolMode(.paper)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: step)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: OnbColdOpen(onNext: { advance() })
        case 1: OnbSignInScreen(onDone: { result in
                    signedIn = (result == .signedIn)
                    advance()
                })
        case 2: OnbManifesto(onNext: { advance() })
        case 3: OnbGrid(onNext: { newPicks in
                    picks = newPicks
                    advance()
                })
        case 4: OnbH2H(contenders: h2hContenders, onNext: { advance() })
        case 5: OnbPrint(onNext: { advance() })
        case 6: OnbIdentity(onNext: { newHandle in
                    handle = newHandle
                    advance()
                })
        case 7: OnbTwins(onNext: { advance() })
        case 8: OnbSeason(handle: handle, onFinish: {
                    onFinish(.init(handle: handle, signedIn: signedIn))
                })
        default:
            Color.clear.onAppear { onFinish(.init(handle: handle, signedIn: signedIn)) }
        }
    }

    private func advance() { step += 1 }

    /// Contenders for the H2H round. Walk S → A → B → C → D and pick the first
    /// tier with ≥2 picks so the sort is "within-tier". Cap at 5 so the round
    /// doesn't drag — that's up to 4 matchups (N-1). Empty if no tier qualifies,
    /// in which case OnbH2H shows a "skip →" CTA.
    private var h2hContenders: [TMDBMovie] {
        for tier in [Tier.S, .A, .B, .C, .D] {
            let movies = picks.filter { $0.tier == tier }.map(\.movie)
            if movies.count >= 2 { return Array(movies.prefix(5)) }
        }
        return []
    }
}

public struct OnboardingOutcome: Sendable, Equatable {
    public let handle: String
    public let signedIn: Bool
}
