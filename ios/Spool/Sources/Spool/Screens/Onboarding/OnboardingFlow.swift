import SwiftUI

/// Bold 9-step onboarding flow with sign-in slotted before a friend-search
/// finale so users experience the product, commit to an account, and then
/// populate their graph before landing in the app.
/// Completion persists via `@AppStorage` so the flow only appears on first launch.
///
/// Persistence: on finish, tier picks from the Grid step (and the H2H
/// winner/loser order) are either inserted into `user_rankings` (signed-in
/// path) or queued to `UserDefaults` via `OnboardingQueue.enqueue` so a
/// later sign-in can flush them. `AuthService.signInOrSignUp` calls
/// `flushOnboardingQueue` automatically, so signing in at step 7 drains
/// anything that was queued while previewing earlier steps — and by the
/// time step 8 (friend search) renders, the user's rankings already exist.
///
/// Steps:
///  0 Cold Open        — tap "take your seat ↘"
///  1 Manifesto        — house rules
///  2 Grid tap         — seed 4+ films into tiers
///  3 H2H              — pick one S-tier head-to-head
///  4 Print            — stub prints with stamp animation
///  5 Identity         — @handle + two bio questions
///  6 Season           — "start spooling ▸" advances to sign-in
///  7 Sign In / Sign Up — email+password, or skip into preview mode
///  8 Friend Search    — search profiles + follow (terminal; calls finish)
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
    /// In-flight ranking-insert Task, if any. Set when step 7's sign-in
    /// triggers the signed-in persist path; re-entered by `finish()` at
    /// step 8 so the terminal callback awaits rather than spawning a
    /// second persist off the same `picks` array.
    @State private var persistTask: Task<Void, Never>? = nil

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
        case 0: OnbColdOpen(onNext: { advance() })
        case 1: OnbManifesto(onNext: { advance() })
        case 2: OnbGrid(onNext: { newPicks in
                    picks = newPicks
                    advance()
                })
        case 3: OnbH2H(contenders: h2hContenders, onNext: { winner, losers in
                    h2hWinner = winner
                    h2hLosers = losers
                    advance()
                })
        case 4: OnbPrint(onNext: { advance() })
        case 5: OnbIdentity(onNext: { newHandle in
                    handle = newHandle
                    advance()
                })
        case 6: OnbSeason(handle: handle, onNext: { advance() })
        case 7: OnbSignInScreen(onDone: { result in
                    signedIn = (result == .signedIn)
                    // Persist the picks now — friend search (step 8) works
                    // off the session that was just established, not the
                    // ranking flush. Advancing instead of finishing keeps the
                    // user in the flow for one more screen.
                    persistIfNeeded()
                    advance()
                })
        case 8: OnbFriendSearch(onNext: { finish() })
        default:
            Color.clear.onAppear { finish() }
        }
    }

    private func advance() { step += 1 }

    /// Terminal step handler. Kicks off any remaining persistence (no-op if
    /// step 7's sign-in path already handled it) and hands control back to
    /// the caller. Never blocks the callback on a failing insert.
    private func finish() {
        persistIfNeeded {
            onFinish(.init(handle: handle, signedIn: signedIn))
        }
    }

    /// Build the ordered ranking list and either insert (signed-in path) or
    /// enqueue (preview path). Called twice: once at sign-in (step 7) so the
    /// friend-search step has a clean-slate session with rankings already
    /// saved, and once at finish (step 8).
    ///
    /// Re-entry safety: when step 7 kicks off a background insert Task, we
    /// store it in `persistTask` and clear `picks` synchronously BEFORE the
    /// Task launches. If `finish()` re-enters while that Task is still in
    /// flight, we chain the completion behind the in-flight Task rather
    /// than spawning a second persist off a stale `picks` snapshot.
    private func persistIfNeeded(completion: (() -> Void)? = nil) {
        // Re-entry: an earlier call is still persisting. Wait for it to
        // finish before firing our completion. Do NOT rebuild rankings
        // from `picks` — that was already consumed by the in-flight Task.
        if let inFlight = persistTask {
            Task {
                await inFlight.value
                await MainActor.run { completion?() }
            }
            return
        }

        let rankings = buildRankings()
        guard !rankings.isEmpty else {
            completion?()
            return
        }

        // Clear picks synchronously so any concurrent re-entry sees empty
        // state. The Task below captures `rankings` by value.
        picks = []

        if signedIn, SpoolClient.shared != nil {
            persisting = true
            let task = Task { [rankings] in
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
                        print("[OnboardingFlow] insertRanking failed: \(error)")
                    }
                }
                await MainActor.run {
                    OnboardingQueue.replace([])
                    persisting = false
                    persistTask = nil
                    completion?()
                }
            }
            persistTask = task
        } else {
            OnboardingQueue.replace(rankings)
            completion?()
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
