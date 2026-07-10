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
/// `save` returns whether a CONFIRMED write landed (`true` only on the signed-in
/// insert success; preview-queue and not-configured return `false`). C3 Task 4
/// gates the watchlist-bookmark removal on that signal (B5-corrected) via the
/// pure `shouldRemoveBookmarkAfterRank`.
///
/// Header last reviewed: 2026-07-09
public enum RankPersistence {

    /// Persist the movie into the user's shelf. Fire-and-forget from the
    /// caller's perspective — errors surface via a ToastCenter toast. Safe
    /// to call once the rank flow has fully completed (printed screen's
    /// finish callback), not during intermediate steps.
    ///
    /// `writeJournalQuickEntry` gates the STAGE-A journal upsert. A PLAIN finish
    /// ("post to feed", no composer) leaves it `true` so every rank still writes
    /// a journal_entries row (audit stage-a). The "write more" finish passes
    /// `false`: the composer's explicit full-replace save is the authoritative
    /// journal write, so the quick-write must NOT also fire — otherwise the two
    /// race on the same `(user_id, tmdb_id)` key (rare clobber if the quick-write
    /// upsert lands after a fast composer save) and the composer probe could see
    /// a concurrently-written row instead of deterministically finding nil and
    /// seeding from moods+line. The two paths are mutually exclusive.
    /// Returns `true` only when a CONFIRMED `user_rankings` write landed (the
    /// signed-in insert did not throw). The preview-mode queue path and the
    /// not-configured no-op both return `false`: nothing durable was written
    /// yet, so any post-save side effect gated on a confirmed rank (C3 Task 4's
    /// watchlist-bookmark removal, B5-corrected) must NOT fire. The return is
    /// discardable so the existing plain call sites are unaffected.
    @discardableResult
    public static func save(
        movie: Movie,
        tier: Tier,
        rank: Int,
        moods: [String] = [],
        line: String = "",
        writeJournalQuickEntry: Bool = true
    ) async -> Bool {
        // Not-configured path: no Supabase client at all. Skip entirely so
        // we don't stash rows in the preview queue for an app that can
        // never flush them (e.g. a bundle without SUPABASE_URL). Previously
        // this fell through to the preview-mode branch, which would flip
        // `spool.show_signin_sheet` for an app that literally has no
        // sign-in — confusing and pointless.
        guard SpoolClient.shared != nil else {
            NSLog("[RankPersistence] save skipped: SpoolClient not configured")
            return false
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
                return false
            }
            // Stub write mirrors web createStub (PR #30 contract). Fire-and-
            // forget inside StubWriter: a stub failure never fails the rank
            // save, and palette extraction runs detached.
            await StubWriter.writeStub(movie: movie, tier: tier)

            // STAGE-A journal write (audit stage-a): a PLAIN rank produces a real
            // journal_entries row from the ceremony's moods + one-liner, so
            // ranking and journaling never drift. This does NOT replace the
            // `user_rankings.notes` write above (RankingInsert still carries the
            // line as `notes`); it ADDS the journal row so the Stubs→journal
            // list and the composer's probe-before-edit both find it. Full
            // replace on `(user_id, tmdb_id)`, so a later "write more" edit
            // round-trips through the same conflict key.
            //
            // SKIPPED on the "write more" path (`writeJournalQuickEntry == false`):
            // there, the composer's explicit save is the authoritative journal
            // write, so firing the quick-write too would double-write / race on
            // the same key. Mutually exclusive by construction.
            if shouldWriteQuickEntry(writeJournalQuickEntry: writeJournalQuickEntry) {
                await JournalQuickEntry.write(
                    tmdbId: movie.id, title: movie.title, posterUrl: movie.posterUrl,
                    line: line, moods: moods
                )
            }
            // Confirmed write landed — the caller may now run any post-save
            // side effect (C3 Task 4 deletes the watchlist bookmark here).
            return true
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
        // Preview mode only QUEUED the rank — nothing durable landed, so this is
        // NOT a confirmed save. A watchlist bookmark must stay put until the
        // queued rank actually flushes after sign-in.
        return false
    }

    /// Normalize a movie's integer year to the `year: String?` the DB expects.
    /// `0` means "unknown" in our model — store as `nil` rather than "0".
    private static func normalizedYear(_ y: Int) -> String? {
        y > 0 ? String(y) : nil
    }

    /// Pure gate for the STAGE-A quick journal upsert (tested —
    /// `RankPersistenceLogicTests`). The quick-write runs on a PLAIN finish
    /// (`true`) and is SKIPPED on the "write more" finish (`false`), keeping the
    /// stage-a quick-write and the composer's authoritative save mutually
    /// exclusive so they never double-write / race on `(user_id, tmdb_id)`.
    static func shouldWriteQuickEntry(writeJournalQuickEntry: Bool) -> Bool {
        writeJournalQuickEntry
    }

    /// Pure gate for the C3 Task 4 watchlist-bookmark removal (tested —
    /// `RankFromWatchlistTests`). B5-CORRECTED semantics: the bookmark is deleted
    /// ONLY after a CONFIRMED rank save (`save` returned `true`). On a failed or
    /// preview-queued save the bookmark stays, so the item survives to be ranked
    /// again. Mirrors web's post-save removal condition (audit finding B5).
    public static func shouldRemoveBookmarkAfterRank(saveSucceeded: Bool) -> Bool {
        saveSucceeded
    }
}
