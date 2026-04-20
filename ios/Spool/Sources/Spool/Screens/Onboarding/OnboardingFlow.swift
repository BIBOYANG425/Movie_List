import SwiftUI

/// Bold 8-step onboarding flow with an inserted sign-in screen after the
/// Cold Open "take your seat" CTA. Completion persists via `@AppStorage`
/// so the flow only appears on first launch.
///
/// Persistence: on finish, tier picks from step 3 (and the H2H winner/loser
/// order from step 4) are either inserted into `user_rankings` (signed-in
/// path) or queued to `UserDefaults` via `OnboardingQueue.enqueue` so a
/// later sign-in can flush them.
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
///
/// Header last reviewed: 2026-04-18
public struct OnboardingFlow: View {
    public var onFinish: (OnboardingOutcome) -> Void
    @State private var step: Int = 0
    @State private var signedIn: Bool = false
    @State private var handle: String = "yurui"
    @State private var picks: [OnbPick] = []
    @State private var h2hWinner: TMDBMovie? = nil
    @State private var h2hLosers: [TMDBMovie] = []
    @State private var persisting: Bool = false
    /// True when the user arrived at the sign-in step via the top-right
    /// "log in ↗" shortcut on Cold Open (i.e. a returning user). On
    /// successful sign-in we skip the rest of onboarding — they already
    /// have data in Supabase and shouldn't re-rank.
    @State private var loginShortcut: Bool = false

    public init(onFinish: @escaping (OnboardingOutcome) -> Void) {
        self.onFinish = onFinish
    }

    public var body: some View {
        content
            .spoolMode(.paper)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: step)
            .overlay(alignment: .top) {
                if persisting {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("saving your picks…").font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.opacity)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: OnbColdOpen(
                    onNext: { advance() },
                    onLogin: {
                        loginShortcut = true
                        step = 1
                    }
                )
        case 1: OnbSignInScreen(onDone: { result in
                    signedIn = (result == .signedIn)
                    // Returning user took the log-in shortcut AND signed in
                    // successfully → skip the rest of onboarding. They have
                    // data in Supabase already and shouldn't re-rank.
                    // Hydrate `handle` from the real profile first so the
                    // AppStorage `spool.user_handle` isn't overwritten with
                    // the "yurui" default that was seeded for new users.
                    if loginShortcut, result == .signedIn {
                        Task {
                            if let row = try? await ProfileRepository.shared.getMyProfile() {
                                await MainActor.run {
                                    handle = row.username
                                }
                            }
                            await MainActor.run { finish() }
                        }
                        return
                    }
                    advance()
                })
        case 2: OnbManifesto(onNext: { advance() })
        case 3: OnbGrid(onNext: { newPicks in
                    picks = newPicks
                    advance()
                })
        case 4: OnbH2H(contenders: h2hContenders, onNext: { winner, losers in
                    h2hWinner = winner
                    h2hLosers = losers
                    advance()
                })
        case 5: OnbPrint(onNext: { advance() })
        case 6: OnbIdentity(onNext: { newHandle in
                    handle = newHandle
                    advance()
                })
        // OnbTwins (old fixture taste-twins step) was replaced upstream by
        // OnbFriendSearch — real debounced profile search + follow. Same
        // init signature, strictly better UX for signed-in users; preview
        // users see its skip-only state.
        case 7: OnbFriendSearch(onNext: { advance() })
        // OnbSeason's terminal callback was renamed `onNext` upstream
        // (previously `onFinish`) — same semantics, just aligned with the
        // rest of the onboarding screens.
        case 8: OnbSeason(handle: handle, onNext: { finish() })
        default:
            Color.clear.onAppear { finish() }
        }
    }

    private func advance() { step += 1 }

    /// Build the ordered insert list, then either persist (if signed in) or
    /// enqueue (if skipped). Never blocks the flow's completion callback — a
    /// failed insert path still calls `onFinish`.
    private func finish() {
        let rankings = buildRankings()
        guard !rankings.isEmpty else {
            onFinish(.init(handle: handle, signedIn: signedIn))
            return
        }
        if signedIn, SpoolClient.shared != nil {
            persisting = true
            Task {
                for r in rankings {
                    do {
                        let insert = RankingInsert(
                            tmdbId: r.tmdbId,
                            title: r.title,
                            year: r.year,
                            posterURL: r.posterURL,
                            type: "movie",
                            genres: r.genres,
                            director: r.director,
                            tier: Tier(rawValue: r.tier) ?? .B,
                            rankPosition: r.rankPosition,
                            notes: nil
                        )
                        _ = try await RankingRepository.shared.insertRanking(insert)
                    } catch {
                        // Toast is deferred to Task 4 — log for now so the
                        // failure isn't silent during development.
                        print("[OnboardingFlow] insertRanking failed: \(error)")
                    }
                }
                await MainActor.run {
                    persisting = false
                    onFinish(.init(handle: handle, signedIn: signedIn))
                }
            }
        } else {
            OnboardingQueue.replace(rankings)
            onFinish(.init(handle: handle, signedIn: signedIn))
        }
    }

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

    /// Tier that H2H was run on (the first with ≥2 picks), or nil if no tier
    /// qualified.
    private var contenderTier: Tier? {
        for tier in [Tier.S, .A, .B, .C, .D] {
            if picks.filter({ $0.tier == tier }).count >= 2 { return tier }
        }
        return nil
    }

    /// Assemble `QueuedRanking` rows with sensible per-tier `rank_position`s.
    ///
    /// Contender tier layout:
    ///   1. H2H winner
    ///   2..K. H2H losers in elimination order (earliest out first)
    ///   K+1..M. Any remaining picks in that tier that weren't in h2hContenders
    ///           (because of the 5-cap), in their original grid order.
    ///
    /// Non-contender tiers: picks in grid order, positions 1..N.
    private func buildRankings() -> [QueuedRanking] {
        var result: [QueuedRanking] = []
        let cTier = contenderTier
        let contenderSet: Set<Int> = Set(h2hContenders.map(\.tmdbId))

        // Group picks by tier, preserving their original grid order.
        var byTier: [Tier: [TMDBMovie]] = [:]
        for p in picks {
            byTier[p.tier, default: []].append(p.movie)
        }

        for tier in Tier.allCases {
            guard let movies = byTier[tier], !movies.isEmpty else { continue }

            if tier == cTier {
                // Contender tier: winner, losers, then any remaining (5-cap overflow).
                var ordered: [TMDBMovie] = []
                if let w = h2hWinner { ordered.append(w) }
                ordered.append(contentsOf: h2hLosers)
                // Safety: if H2H was skipped/empty for some reason, fall back
                // to the full contender list in grid order.
                if ordered.isEmpty {
                    ordered.append(contentsOf: movies.filter { contenderSet.contains($0.tmdbId) })
                }
                // Append overflow picks (not in the capped h2hContenders set).
                ordered.append(contentsOf: movies.filter { !contenderSet.contains($0.tmdbId) })

                // De-dupe while preserving order (guards against any oddity).
                var seen = Set<Int>()
                let unique = ordered.filter { seen.insert($0.tmdbId).inserted }

                for (i, m) in unique.enumerated() {
                    result.append(Self.makeQueued(movie: m, tier: tier, rank: i + 1))
                }
            } else {
                for (i, m) in movies.enumerated() {
                    result.append(Self.makeQueued(movie: m, tier: tier, rank: i + 1))
                }
            }
        }
        return result
    }

    private static func makeQueued(movie m: TMDBMovie, tier: Tier, rank: Int) -> QueuedRanking {
        QueuedRanking(
            tmdbId: String(m.tmdbId),
            title: m.title,
            year: m.year == "—" ? nil : m.year,
            posterURL: m.posterUrl,
            genres: m.genres,
            director: nil,
            tier: tier.rawValue,
            rankPosition: rank
        )
    }
}

public struct OnboardingOutcome: Sendable, Equatable {
    public let handle: String
    public let signedIn: Bool
}
