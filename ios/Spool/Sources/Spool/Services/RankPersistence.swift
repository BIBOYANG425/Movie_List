import Foundation
import SwiftUI

/// Shared persistence of a newly-ranked movie. Extracted from
/// `RankH2HScreen` so the actual write can be deferred to the end of the
/// rank flow (RankPrintedScreen's "finish" callback), not fired mid-flow
/// at the moment the H2H engine reports done. Without the deferral,
/// backing out during the ceremony or printed screen still left a saved
/// `user_rankings` row behind — exactly the "aborting still saves" bug.
///
/// Three paths, keyed on session state:
///  - signed-in: write directly to `user_rankings` via RankingRepository
///  - preview mode: append to `OnboardingQueue` + flip AppStorage
///    `spool.show_signin_sheet` so SpoolAppRoot presents the sign-in sheet
///  - not configured: no-op (the sign-in sheet itself is disabled upstream)
///
/// Header last reviewed: 2026-04-20
public enum RankPersistence {

    /// Persist the movie into the user's shelf. Fire-and-forget from the
    /// caller's perspective — errors surface via a ToastCenter toast. Safe
    /// to call once the rank flow has fully completed (printed screen's
    /// finish callback), not during intermediate steps.
    public static func save(
        movie: Movie,
        tier: Tier,
        rank: Int,
        moods: [String] = [],
        line: String = ""
    ) async {
        let genres = movie.genres.isEmpty ? ["Drama"] : movie.genres
        let director = movie.director.isEmpty ? nil : movie.director
        let year = normalizedYear(movie.year)

        if await SpoolClient.currentUserID() != nil {
            let insert = RankingInsert(
                tmdbId: movie.id,
                title: movie.title,
                year: year,
                posterURL: movie.posterUrl,
                type: "movie",
                genres: genres,
                director: director,
                tier: tier,
                rankPosition: rank,
                notes: line.isEmpty ? nil : line
            )
            do {
                _ = try await RankingRepository.shared.insertRanking(insert)
            } catch {
                NSLog("[RankPersistence] insertRanking failed: \(error)")
                await MainActor.run {
                    ToastCenter.shared.show(
                        "couldn't save your rank — check connection",
                        level: .error
                    )
                }
            }
            // TODO: when stub insertion is wired (moods + line → movie_stubs
            // via RankingRepository.insertStub), chain it here so we have
            // a single atomic finish path.
            return
        }

        // Preview mode: queue the ranking + signal SpoolAppRoot to present
        // its sign-in sheet. AuthService drains the queue on successful
        // sign-in so the row lands without a second trip through ranking.
        let queued = QueuedRanking(
            tmdbId: movie.id,
            title: movie.title,
            year: year,
            posterURL: movie.posterUrl,
            genres: genres,
            director: director,
            tier: tier.rawValue,
            rankPosition: rank
        )
        await MainActor.run {
            OnboardingQueue.append(queued)
            UserDefaults.standard.set(true, forKey: "spool.show_signin_sheet")
        }
    }

    /// Normalize a movie's integer year to the `year: String?` the DB expects.
    /// `0` means "unknown" in our model — store as `nil` rather than "0".
    private static func normalizedYear(_ y: Int) -> String? {
        y > 0 ? String(y) : nil
    }
}
