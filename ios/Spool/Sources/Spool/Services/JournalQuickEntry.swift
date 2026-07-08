import Foundation

/// STAGE-A quick journal write (plan Task 6 / audit stage-a). Every rank
/// ceremony — including a plain "post to feed" with NO "write more" — must
/// produce a real `journal_entries` row from the ceremony's moods + one-liner,
/// so ranking and journaling never drift apart. Today the ceremony only writes
/// the line to `user_rankings.notes`; `RankPersistence.save` now ALSO calls
/// `JournalQuickEntry.write` (the notes write is untouched).
///
/// The full-replace upsert is authoritative, so a quick entry followed by a
/// later "write more" edit round-trips through the SAME `(user_id, tmdb_id)`
/// conflict key — the composer's probe-before-edit picks up the quick row and
/// the user fleshes it out.
///
/// This is a fire-and-forget best-effort write (like the stub write in
/// `RankPersistence`): a journal-row hiccup never fails the rank. The pure
/// `draft(...)` builder is unit-tested (`JournalQuickEntryTests`); the upsert is
/// covered by build + the repository's own tests.
///
/// Header last reviewed: 2026-07-07
public enum JournalQuickEntry {

    /// The minimal ceremony draft: the one-liner folds into `review_text` (there
    /// is NO separate one-liner column — plan note), moods carry as `mood_tags`,
    /// `watched_date` defaults to the local `yyyy-MM-dd` (the stubs helper, never
    /// GMT). Everything else stays a blank default.
    public static func draft(
        tmdbId: String, title: String, posterUrl: String?,
        line: String, moods: [String]
    ) -> JournalDraft {
        JournalDraft(
            tmdbId: tmdbId, title: title, posterUrl: posterUrl,
            reviewText: line, containsSpoilers: false,
            moodTags: moods, vibeTags: [], favoriteMoments: [],
            standoutPerformances: [], watchedDate: StubWriteContract.localDateString(),
            watchedLocation: "", watchedWithUserIds: [], watchedPlatform: nil,
            isRewatch: false, rewatchNote: "", personalTakeaway: "",
            photoPaths: [], visibilityOverride: nil
        )
    }

    /// Resolve `rating_tier` (`user_rankings.tier`, never the form), build the
    /// full-replace payload from the quick draft, and upsert. Best-effort — logs
    /// and swallows on failure so a journal hiccup never fails the rank save.
    ///
    /// NOTE: no review-event / journal_tag side effects fire here — a quick entry
    /// has no tagged friends, and the review event is the composer/model's job on
    /// an explicit public save. Stage-a just guarantees the ROW exists.
    public static func write(
        tmdbId: String, title: String, posterUrl: String?,
        line: String, moods: [String]
    ) async {
        guard SpoolClient.shared != nil else { return }
        guard let userID = await SpoolClient.currentUserID() else { return }

        let tier = try? await JournalRepository.shared.ratingTier(tmdbId: tmdbId)
        let quick = draft(tmdbId: tmdbId, title: title, posterUrl: posterUrl, line: line, moods: moods)
        let payload = JournalEntryContract.upsertPayload(
            userID: userID, ratingTier: tier ?? nil, from: quick
        )
        do {
            _ = try await JournalRepository.shared.upsert(payload)
        } catch {
            NSLog("[JournalQuickEntry] quick journal upsert failed: \(error)")
        }
    }
}
