import Foundation
import SwiftUI

/// Shared persistence of a newly-ranked item. Extracted from
/// `RankH2HScreen` so the actual write can be deferred to the end of the
/// rank flow (RankPrintedScreen's "finish" callback), not fired mid-flow
/// at the moment the H2H engine reports done. Without the deferral,
/// backing out during the ceremony or printed screen still left a saved
/// ranking row behind — exactly the "aborting still saves" bug.
///
/// MEDIA-GENERIC (C5-iOS Task 5): `save` derives the vertical from
/// `movie.mediaType` (`.movie`/`.tv`/`.book`), so the ONE ceremony persists all
/// three media. The per-media side-effect matrix:
///  - INSERT: `movie.rankingInsert(...)` builds the right `RankingInsert`
///    (movie → `user_rankings` w/ director; tv → `tv_rankings` w/ show/season;
///    book → `book_rankings` w/ OpenLibrary columns). `RankingRepository`
///    routes table/RPC/emission by the discriminator.
///  - STUB: `StubWriter.writeStub(media:)` — movie → `"movie"` stub, tv →
///    `"tv_season"` stub, book → NO stub (`movie_stubs` CHECK allows only
///    movie|tv_season; web's book path writes no stub).
///  - JOURNAL quick-entry: MOVIE-ONLY (Q3 adjudication). A tv/book rank forces
///    the stage-A gate to `.skip` (`quickEntryDecision(media:)`), so the
///    movie-shaped quick-write path is structurally unreachable cross-media.
///  - EMISSION: media-agnostic — `CeremonyEmission` is pure and the event's
///    `media_tmdb_id` carries the item's id verbatim (composite `tv_{id}_s{n}`
///    or `ol_{workKey}`).
/// The MOVIE path is byte-identical to pre-C5 (stubs + quick-entry + emission).
///
/// Three paths, keyed on session state:
///  - signed-in: write to the media's ranking table via RankingRepository, then
///    chain the media's stub write via `StubWriter.writeStub` (fire-and-forget —
///    a stub failure never fails the rank save; a failed rank insert never
///    proceeds to the stub write, matching web where stub creation only
///    follows a successful rank upsert)
///  - preview mode: append to `OnboardingQueue` + flip AppStorage
///    `spool.show_signin_sheet` so SpoolAppRoot presents the sign-in sheet.
///    MOVIE-ONLY (`shouldQueuePreviewRanking`): the queue is movie-shaped and
///    flushes into `user_rankings`, so a tv/book rank that reaches this branch
///    (expired session — the entry flows gate on live sign-in) fails the save
///    with a toast instead of queueing a cross-media row
///  - not configured: no-op (the sign-in sheet itself is disabled upstream)
///
/// `save` returns whether a CONFIRMED write landed (`true` only on the signed-in
/// insert success; preview-queue and not-configured return `false`). C3 Task 4
/// gates the watchlist-bookmark removal on that signal (B5-corrected) via the
/// pure `shouldRemoveBookmarkAfterRank`.
///
/// The stage-a journal write is OUTCOME-AWARE (C3 Part B Task 0 — re-rank wipe
/// fix): `save` threads `insertRanking`'s `InsertOutcome` through the pure
/// `quickEntryDecision`. A fresh `.inserted` quick-writes as before; a `.moved`
/// re-rank with no ceremony input skips the write; a `.moved` with input takes a
/// PROBED MERGE (`JournalQuickEntry.writeMergingReRank`) that folds only the new
/// moods + one-liner onto the full owner row so a rich entry is never wiped.
///
/// Header last reviewed: 2026-07-10
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
        // Trim whitespace once here; use `trimmedLine` throughout so a
        // whitespace-only one-liner is treated as empty at every gate
        // (notes column, hasCeremonyInput, quick-write, merge).
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if await SpoolClient.currentUserID() != nil {
            // PER-MEDIA insert: the movie path is byte-identical to before
            // (`.movie` payload, director, no vertical columns); tv/book route
            // through their own factories via `movie.rankingInsert`. The
            // discriminator (`movie.mediaType`) drives the whole method — table,
            // stub decision, and the quick-entry gate below.
            let insert = movie.rankingInsert(
                year: year,
                genres: genres,
                director: director,
                tier: tier,
                rankPosition: rank,
                notes: trimmedLine.isEmpty ? nil : trimmedLine
            )
            let outcome: RankingRepository.InsertOutcome
            do {
                outcome = try await RankingRepository.shared.insertRanking(insert)
            } catch {
                NSLog("[RankPersistence] insertRanking failed: \(error)")
                await MainActor.run {
                    ToastCenter.shared.show(
                        L10n.t("toast.rankSaveFailed"),
                        level: .error
                    )
                }
                return false
            }
            // Stub write mirrors web createStub (PR #30 contract). Fire-and-
            // forget inside StubWriter: a stub failure never fails the rank
            // save, and palette extraction runs detached. MEDIA-AWARE: movie →
            // "movie" stub, tv → "tv_season" stub, book → NO stub (StubWriter
            // early-returns; the `movie_stubs` CHECK allows only movie|tv_season).
            await StubWriter.writeStub(movie: movie, tier: tier, media: movie.mediaType)

            // STAGE-A journal write (audit stage-a), now OUTCOME-AWARE (C3 Part B
            // Task 0 — the re-rank wipe fix). The quick-write is a FULL-REPLACE
            // upsert on `(user_id, tmdb_id)`; on a RE-RANK of a movie whose entry
            // is already rich (review text, moments, photos, takeaway,
            // visibility), a blank quick draft would WIPE all of it. So the write
            // decision folds in the insert outcome + whether the ceremony
            // captured any moods/one-liner:
            //  - `.inserted` (fresh rank) → plain quick-write, unchanged (still
            //    guarantees the audit stage-a row even with no input);
            //  - `.moved` + NO input → NO journal write at all (nothing to merge,
            //    a blank full-replace would wipe the existing entry);
            //  - `.moved` + input → PROBED MERGE: fetch the full owner row and
            //    fold ONLY the new moods + one-liner onto it, preserving every
            //    other field (probe failure → skip + log loudly; no existing row
            //    → plain quick-write). Never a blind full-replace on `.moved`.
            //
            // SKIPPED entirely on the "write more" path
            // (`writeJournalQuickEntry == false`): the composer's explicit save is
            // the authoritative journal write, so firing the quick-write too would
            // double-write / race on the same key. Mutually exclusive by
            // construction. No review-event / journal_tag side effects fire on
            // any of these paths (the quick-write and merge are ROW-only — the
            // review event is the composer's job on an explicit public save), so
            // C2's emission exclusivity is preserved.
            //
            // MOVIE-ONLY (C5-iOS Task 5, Q3 adjudication): the stage-a journal
            // quick-write targets `journal_entries` keyed by a MOVIE tmdb_id — web
            // only journals movie ranks (no tv/book quick-entry). So the effective
            // gate ANDs the incoming flag with `mediaType == .movie`: a tv/book
            // rank ALWAYS resolves `.skip`, making the movie-shaped stage-A path
            // structurally UNREACHABLE cross-media (test-pinned). This is the
            // `writeJournalQuickEntry:false`-equivalent the brief requires.
            switch quickEntryDecision(
                writeJournalQuickEntry: writeJournalQuickEntry,
                media: movie.mediaType,
                outcome: outcome,
                hasInput: Self.hasCeremonyInput(moods: moods, line: trimmedLine)
            ) {
            case .skip:
                break
            case .quickWrite:
                await JournalQuickEntry.write(
                    tmdbId: movie.id, title: movie.title, posterUrl: movie.posterUrl,
                    line: trimmedLine, moods: moods
                )
            case .probedMerge:
                await JournalQuickEntry.writeMergingReRank(
                    tmdbId: movie.id, title: movie.title, posterUrl: movie.posterUrl,
                    line: trimmedLine, moods: moods
                )
            }
            // Confirmed write landed — the caller may now run any post-save
            // side effect (C3 Task 4 deletes the watchlist bookmark here).
            return true
        }

        // Preview mode: queue the ranking + signal SpoolAppRoot to present
        // its sign-in sheet. AuthService drains the queue on successful
        // sign-in so the row lands without a second trip through ranking.
        //
        // MOVIE-ONLY (C5-iOS final review): the queue is movie-shaped and its
        // flush inserts into `user_rankings` unconditionally, so queueing a
        // tv/book item here would later mint a `tv_…`/`ol_…` id into the MOVIE
        // table — the exact cross-media corruption class C5 exists to prevent.
        // Every tv/book entry flow gates on a live sign-in, so this branch is
        // reachable for them only if the session died mid-ceremony; fail the
        // save honestly (bookmark stays, B5) instead of queueing corruption.
        guard Self.shouldQueuePreviewRanking(media: movie.mediaType) else {
            NSLog("[RankPersistence] preview queue is movie-only; dropping \(movie.mediaType.rawValue) rank for \(movie.id)")
            await MainActor.run {
                ToastCenter.shared.show(
                    L10n.t("toast.rankSaveSignIn"),
                    level: .error
                )
            }
            return false
        }
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
    /// Retained as the base (movie) gate; `quickEntryDecision` layers the
    /// outcome-aware re-rank wipe guard on top.
    static func shouldWriteQuickEntry(writeJournalQuickEntry: Bool) -> Bool {
        shouldWriteQuickEntry(writeJournalQuickEntry: writeJournalQuickEntry, media: .movie)
    }

    /// Media-aware base gate (C5-iOS Task 5). The stage-a journal quick-write is
    /// MOVIE-ONLY (Q3 adjudication) — web journals only movie ranks, and the
    /// quick-write targets a movie `journal_entries` row. So a tv/book rank NEVER
    /// writes a quick entry regardless of the incoming flag: the effective gate is
    /// `writeJournalQuickEntry && media == .movie`. This makes the movie-shaped
    /// stage-A path structurally unreachable cross-media.
    static func shouldWriteQuickEntry(writeJournalQuickEntry: Bool, media: RankMedia) -> Bool {
        writeJournalQuickEntry && media == .movie
    }

    /// What the stage-a journal write should do, folding the base gate together
    /// with the re-rank wipe guard (C3 Part B Task 0). Pure + tested
    /// (`RankPersistenceLogicTests`).
    enum QuickEntryDecision: Equatable {
        /// No journal write at all (write-more path, or a re-rank with nothing to
        /// merge — a blank full-replace would wipe the existing rich entry).
        case skip
        /// Plain full-replace quick-write from the ceremony's moods + one-liner
        /// (a fresh rank, or a re-rank with input but no existing row to merge —
        /// the latter is resolved inside `writeMergingReRank`).
        case quickWrite
        /// Probed merge: fetch the full owner row and fold ONLY the new moods +
        /// one-liner onto it, preserving every other field. Never a blind replace.
        case probedMerge
    }

    /// The re-rank wipe guard's decision table (tested). `writeJournalQuickEntry
    /// == false` (write-more) always `.skip`s — the composer owns the write. A
    /// fresh `.inserted` always `.quickWrite`s (unchanged, input or not). A
    /// `.moved` re-rank `.skip`s with no input (nothing to merge, a blank replace
    /// would wipe the rich row) and `.probedMerge`s with input. Movie-media
    /// overload (retained for the existing movie pins); delegates to the
    /// media-aware form with `.movie`.
    static func quickEntryDecision(
        writeJournalQuickEntry: Bool,
        outcome: RankingRepository.InsertOutcome,
        hasInput: Bool
    ) -> QuickEntryDecision {
        quickEntryDecision(
            writeJournalQuickEntry: writeJournalQuickEntry, media: .movie,
            outcome: outcome, hasInput: hasInput)
    }

    /// Media-aware decision (C5-iOS Task 5). Layers the MOVIE-ONLY gate over the
    /// re-rank wipe guard: a tv/book rank ALWAYS `.skip`s (no stage-a journal
    /// quick-write for non-movie media), so the movie-shaped quick-write / merge
    /// paths are unreachable cross-media. For a movie the table is unchanged.
    static func quickEntryDecision(
        writeJournalQuickEntry: Bool,
        media: RankMedia,
        outcome: RankingRepository.InsertOutcome,
        hasInput: Bool
    ) -> QuickEntryDecision {
        guard shouldWriteQuickEntry(writeJournalQuickEntry: writeJournalQuickEntry, media: media) else {
            return .skip
        }
        switch outcome {
        case .inserted:
            return .quickWrite
        case .moved:
            return hasInput ? .probedMerge : .skip
        }
    }

    /// Pure gate for the preview-mode fallback (tested —
    /// `MediaGenericCeremonyTests`). The `OnboardingQueue` is MOVIE-shaped and
    /// its flush inserts into `user_rankings` unconditionally, so only a movie
    /// rank may be queued when no session exists. A tv/book rank reaching the
    /// fallback (expired session mid-ceremony — every tv/book entry flow gates
    /// on live sign-in) fails the save instead, keeping `tv_…`/`ol_…` ids out
    /// of the movie table (the C5 cross-media corruption class).
    static func shouldQueuePreviewRanking(media: RankMedia) -> Bool {
        media == .movie
    }

    /// Did the ceremony capture any journal signal? True when EITHER the moods or
    /// the one-liner is present. Whitespace-only lines count as empty — a tap-through
    /// with accidental spaces must not trigger the wipe guard. On a re-rank with
    /// neither, there is nothing to merge and the write is skipped (the wipe guard).
    static func hasCeremonyInput(moods: [String], line: String) -> Bool {
        !moods.isEmpty || !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
