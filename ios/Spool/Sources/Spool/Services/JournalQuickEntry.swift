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
/// RE-RANK MERGE (C3 Part B Task 0 — the wipe fix): a re-rank of a movie whose
/// entry is already rich must NOT full-replace it with a blank quick draft.
/// `writeMergingReRank` (prod) binds the real repo to `writeMerging` (injected
/// IO, fully XCTest-covered): probe the full owner row, and either merge only
/// the new moods + one-liner onto it (`JournalEntryContract.merge`), plain
/// quick-write when there is no existing row, or — on a probe FAILURE — skip the
/// write entirely and log loudly (never blind-replace).
///
/// Header last reviewed: 2026-07-10
public enum JournalQuickEntry {

    /// The minimal ceremony draft: the one-liner folds into `review_text` (there
    /// is NO separate one-liner column — plan note), moods carry as `mood_tags`,
    /// `watched_date` defaults to the local `yyyy-MM-dd` (the stubs helper, never
    /// GMT). Everything else stays a blank default.
    public static func draft(
        tmdbId: String, title: String, posterUrl: String?,
        line: String, moods: [String]
    ) -> JournalDraft {
        // Trim whitespace so a whitespace-only one-liner stores "" → nil via
        // JournalEntryContract.upsertPayload's nilIfEmpty, not "   ".
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return JournalDraft(
            tmdbId: tmdbId, title: title, posterUrl: posterUrl,
            reviewText: trimmedLine, containsSpoilers: false,
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

    /// Production entry for the RE-RANK merge path (C3 Part B Task 0). Binds the
    /// real repository IO to `writeMerging`: probe the FULL owner row
    /// (`getOwnEntry`, the only `select('*')` path — the probe-before-edit
    /// primitive), resolve `rating_tier` from `user_rankings.tier`, and merge.
    /// Best-effort like `write` — a journal hiccup never fails the rank save.
    public static func writeMergingReRank(
        tmdbId: String, title: String, posterUrl: String?,
        line: String, moods: [String]
    ) async {
        guard SpoolClient.shared != nil else { return }
        guard let userID = await SpoolClient.currentUserID() else { return }
        let tier = try? await JournalRepository.shared.ratingTier(tmdbId: tmdbId)

        await writeMerging(
            userID: userID, tmdbId: tmdbId, title: title, posterUrl: posterUrl,
            line: line, moods: moods, ratingTier: tier ?? nil,
            probe: { try await JournalRepository.shared.getOwnEntry(tmdbId: $0) },
            upsert: { try await JournalRepository.shared.upsert($0) }
        )
    }

    /// The testable RE-RANK merge core (injected `probe`/`upsert` so the whole
    /// flow is XCTest-covered with ZERO network — `JournalQuickEntryTests`).
    ///
    /// Reuses the C2 probe-before-edit primitives so the merge NEVER diverges from
    /// the journal contract's full-replace semantics:
    ///  - PROBE the full owner row. A probe THROW → skip the write ENTIRELY and
    ///    log loudly (the wipe-guard posture from PR #44's notes sheet): a read
    ///    hiccup must never let a near-blank draft clobber a rich row.
    ///  - NO existing row (`nil`) → there is nothing to wipe, so fall back to a
    ///    plain quick-write full-replace (identical to a fresh rank).
    ///  - An existing row → `JournalEntryContract.merge` folds ONLY the new moods
    ///    + one-liner onto the FULL draft (every other field, incl. the existing
    ///    watched_date, preserved), then a full-replace upsert of the MERGED row.
    ///
    /// No review-event / journal_tag side effects fire here (same as `write`) —
    /// the merge is ROW-only, preserving C2's emission exclusivity.
    static func writeMerging(
        userID: UUID,
        tmdbId: String, title: String, posterUrl: String?,
        line: String, moods: [String], ratingTier: String?,
        probe: (String) async throws -> JournalRow?,
        upsert: (JournalUpsertPayload) async throws -> JournalRow
    ) async {
        let existing: JournalRow?
        do {
            existing = try await probe(tmdbId)
        } catch {
            // Probe FAILURE: never blind-replace. Skip the write entirely and log
            // loudly so the rich entry survives a transient read hiccup.
            NSLog("[JournalQuickEntry] re-rank merge probe FAILED for tmdb=\(tmdbId) — skipping journal write to avoid wiping a rich entry: \(error)")
            return
        }

        let draft: JournalDraft
        if let row = existing {
            // Merge only moods + one-liner onto the full owner row.
            draft = JournalEntryContract.merge(newMoods: moods, newLine: line, onto: row)
        } else {
            // No existing entry — nothing to wipe; plain quick draft.
            draft = self.draft(tmdbId: tmdbId, title: title, posterUrl: posterUrl, line: line, moods: moods)
        }

        let payload = JournalEntryContract.upsertPayload(
            userID: userID, ratingTier: ratingTier, from: draft
        )
        do {
            _ = try await upsert(payload)
        } catch {
            NSLog("[JournalQuickEntry] re-rank merge upsert failed: \(error)")
        }
    }
}
