import Foundation

/// Onboarding persistence queue.
///
/// The onboarding flow (`OnboardingFlow`) collects tier picks and an H2H winner
/// before the user has necessarily signed in. Two paths:
///
///  1. Signed in: `OnboardingFlow` calls `RankingRepository.insertRanking`
///     directly for each pick.
///  2. Skipped sign-in: picks are serialized here under a stable UserDefaults
///     key (`spool.onboarding_queue`). When the user eventually signs in
///     (`AuthService.signInOrSignUp` success path), `flush()` drains the queue
///     into `user_rankings` and clears the key.
///
/// Design notes:
///  - We never block the onboarding flow on a network call. Failures log only.
///  - `QueuedRanking` is a pure value type that mirrors the subset of
///    `RankingInsert` fields we can capture from `OnbPick`. No director, since
///    `TMDBMovie` doesn't carry one — caller passes `nil`.
///  - `pending` is a computed read of the UserDefaults key; no in-memory cache
///    so the queue stays consistent across calls.
///
/// Concurrency: the whole enum is `@MainActor`. The `defaults` property is
/// mutable static state (tests swap in a suite-specific `UserDefaults`), so
/// isolating to the main actor gives us a single serial queue for reads/writes
/// without pulling in a dedicated actor. All current callers already hop to an
/// async context (AuthService flushes via `await`, the onboarding flow's Task
/// inherits main actor from its enclosing View), so this is zero-cost at the
/// call sites.
///
/// Two write entry points:
///   - `replace(_:)` — one-shot onboarding write (overwrites prior queue).
///   - `append(_:)`  — preview-mode rank capture after onboarding is done;
///                     appends without disturbing existing rows.
///
/// Header last reviewed: 2026-04-18
@MainActor
public enum OnboardingQueue {

    /// UserDefaults key — stable, do not rename without a migration.
    public static let storageKey = "spool.onboarding_queue"

    /// Overridable store for tests. Production uses `UserDefaults.standard`.
    internal static var defaults: UserDefaults = .standard

    public enum QueueError: Error, Sendable {
        /// Raised when `flush()` is called without a Supabase session.
        case notAuthenticated
        /// Raised when `flush()` is called but Supabase isn't configured.
        case notConfigured
    }

    // MARK: API

    /// Replace the queued set with `rankings`. Callers assemble the full list
    /// for a single onboarding pass and call this once — we don't append.
    ///
    /// Name is `replace` (not `enqueue`) to make the semantics obvious at the
    /// call site: a subsequent call discards the prior queue.
    public static func replace(_ rankings: [QueuedRanking]) {
        writeRows(rankings)
    }

    /// Drain the queue into `user_rankings`. Throws if there's no session or
    /// Supabase isn't configured. On any per-row failure the queue is kept
    /// intact so a retry can pick up where this left off.
    public static func flush() async throws {
        let rows = pending
        guard !rows.isEmpty else { return }
        guard SpoolClient.shared != nil else { throw QueueError.notConfigured }
        guard await SpoolClient.currentUserID() != nil else { throw QueueError.notAuthenticated }

        for row in rows {
            let insert = RankingInsert(
                tmdbId: row.tmdbId,
                title: row.title,
                year: row.year,
                posterURL: row.posterURL,
                type: "movie",
                genres: row.genres,
                director: row.director,
                tier: Tier(rawValue: row.tier) ?? .B,
                rankPosition: row.rankPosition,
                notes: nil
            )
            _ = try await RankingRepository.shared.insertRanking(insert)
        }

        clear()
    }

    /// Current queue contents (empty when no key is set or decode fails).
    public static var pending: [QueuedRanking] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([QueuedRanking].self, from: data)) ?? []
    }

    /// Remove the queue entirely. Safe to call even if no key is set.
    public static func clear() {
        defaults.removeObject(forKey: storageKey)
    }

    /// Add a single ranking to the end of the queue without replacing existing
    /// entries. Used by `RankH2HScreen` preview mode (Task 2) to capture an
    /// ad-hoc rank after onboarding is already done — separate semantics from
    /// `replace`, which is a one-shot write for the whole onboarding pass.
    public static func append(_ ranking: QueuedRanking) {
        var current = pending
        current.append(ranking)
        writeRows(current)
    }

    // MARK: Internal

    /// Single write path so `replace` and `append` can't drift in failure
    /// handling. Best-effort: drops the queue on encode failure rather than
    /// crashing. A lost queue is recoverable (user can rank again) — a crash
    /// on the happy path is not.
    private static func writeRows(_ rankings: [QueuedRanking]) {
        do {
            let data = try JSONEncoder().encode(rankings)
            defaults.set(data, forKey: storageKey)
        } catch {
            defaults.removeObject(forKey: storageKey)
        }
    }
}

// MARK: - Queued row

/// A single onboarding ranking, captured before (or after) sign-in.
/// Shape chosen to match what `OnbGrid` / `OnbH2H` can give us from `TMDBMovie`
/// — no director (TMDB search doesn't surface it), no notes (onboarding
/// doesn't collect any).
public struct QueuedRanking: Codable, Sendable, Equatable {
    public let tmdbId: String
    public let title: String
    public let year: String?
    public let posterURL: String?
    public let genres: [String]
    public let director: String?
    public let tier: String
    public let rankPosition: Int

    public init(tmdbId: String, title: String, year: String?, posterURL: String?,
                genres: [String], director: String?, tier: String, rankPosition: Int) {
        self.tmdbId = tmdbId
        self.title = title
        self.year = year
        self.posterURL = posterURL
        self.genres = genres
        self.director = director
        self.tier = tier
        self.rankPosition = rankPosition
    }
}
