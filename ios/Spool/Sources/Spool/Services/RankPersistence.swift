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
///  - signed-in: write to `user_rankings` via RankingRepository, then chain
///    the `movie_stubs` write via `StubWriter.writeStub` (fire-and-forget —
///    a stub failure never fails the rank save; a failed rank insert never
///    proceeds to the stub write, matching web where stub creation only
///    follows a successful rank upsert)
///  - preview mode: append to `OnboardingQueue` + flip AppStorage
///    `spool.show_signin_sheet` so SpoolAppRoot presents the sign-in sheet
///  - not configured: no-op (the sign-in sheet itself is disabled upstream)
///
/// Header last reviewed: 2026-07-07
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
        // Not-configured path: no Supabase client at all. Skip entirely so
        // we don't stash rows in the preview queue for an app that can
        // never flush them (e.g. a bundle without SUPABASE_URL). Previously
        // this fell through to the preview-mode branch, which would flip
        // `spool.show_signin_sheet` for an app that literally has no
        // sign-in — confusing and pointless.
        guard SpoolClient.shared != nil else {
            NSLog("[RankPersistence] save skipped: SpoolClient not configured")
            return
        }

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
                return
            }
            // Stub write mirrors web createStub (PR #30 contract). Fire-and-
            // forget inside StubWriter: a stub failure never fails the rank
            // save, and palette extraction runs detached.
            await StubWriter.writeStub(movie: movie, tier: tier)

            // STAGE-A journal write (audit stage-a): every rank produces a real
            // journal_entries row from the ceremony's moods + one-liner, so
            // ranking and journaling never drift. This does NOT replace the
            // `user_rankings.notes` write above (RankingInsert still carries the
            // line as `notes`); it ADDS the journal row so the Stubs→journal
            // list and the composer's probe-before-edit both find it. Full
            // replace on `(user_id, tmdb_id)`, so a later "write more" edit
            // round-trips through the same conflict key.
            await JournalQuickEntry.write(
                tmdbId: movie.id, title: movie.title, posterUrl: movie.posterUrl,
                line: line, moods: moods
            )
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
