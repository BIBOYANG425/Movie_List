import Foundation

/// Pure marshalling + policy seam for `journal_entries`, mirroring web
/// `services/journalService.ts` 1:1 (docs/contracts/shared-payloads.md).
/// Everything here is deterministic and network-free so Tasks 2-6 layer I/O on
/// top without re-deriving policy. The load-bearing invariants — full-replace
/// upsert, COALESCE visibility with fail-closed edges, probe-before-edit,
/// review-event gate — all live here and are truth-tabled in
/// `JournalContractTests`.
public enum JournalEntryContract {

    /// `RESOLVED = COALESCE(visibility_override, profiles.profile_visibility)`.
    /// An explicit override always wins. A nil override inherits the profile
    /// default. Fail-closed edges: an unknown/nil profile visibility (with a
    /// nil override) resolves to `.friends`, never `.pub`. An override string
    /// can only be a valid `JournalVisibility` here (the type enforces it); a
    /// garbage STORED override is handled at decode time by `draft(from:)`
    /// mapping it to nil, so a corrupt row reads as inherit-then-friends.
    public static func resolveVisibility(override: JournalVisibility?, profileVisibility: String?) -> JournalVisibility {
        if let override { return override }
        switch profileVisibility {
        case "public": return .pub
        case "friends": return .friends
        case "private": return .priv
        default: return .friends   // unknown/nil profile → friends, never public
        }
    }

    /// Build the full-replace upsert payload from the editable draft. The
    /// `rating_tier` is passed in (looked up from `user_rankings.tier` by the
    /// caller — NEVER from the form). Empty text coerces to nil so the payload
    /// encodes JSON null; arrays/bools pass through with their draft defaults.
    public static func upsertPayload(userID: UUID, ratingTier: String?, from draft: JournalDraft) -> JournalUpsertPayload {
        JournalUpsertPayload(
            user_id: userID,
            tmdb_id: draft.tmdbId,
            title: draft.title,
            poster_url: draft.posterUrl,
            rating_tier: ratingTier,
            review_text: nilIfEmpty(draft.reviewText),
            contains_spoilers: draft.containsSpoilers,
            mood_tags: draft.moodTags,
            vibe_tags: draft.vibeTags,
            favorite_moments: draft.favoriteMoments,
            standout_performances: draft.standoutPerformances,
            watched_date: draft.watchedDate,
            watched_location: nilIfEmpty(draft.watchedLocation),
            watched_with_user_ids: draft.watchedWithUserIds,
            watched_platform: draft.watchedPlatform,
            is_rewatch: draft.isRewatch,
            rewatch_note: nilIfEmpty(draft.rewatchNote),
            personal_takeaway: nilIfEmpty(draft.personalTakeaway),
            photo_paths: draft.photoPaths,
            visibility_override: draft.visibilityOverride?.rawValue
        )
    }

    /// Hydrate the editable draft from a freshly-probed owner row. Nil server
    /// optionals become empty editable defaults (the composer binds to
    /// non-optional String/[T]); a garbage stored `visibility_override` maps to
    /// nil (Default) rather than fabricating a case.
    public static func draft(from row: JournalRow) -> JournalDraft {
        JournalDraft(
            tmdbId: row.tmdb_id,
            title: row.title,
            posterUrl: row.poster_url,
            reviewText: row.review_text ?? "",
            containsSpoilers: row.contains_spoilers,
            moodTags: row.mood_tags ?? [],
            vibeTags: row.vibe_tags ?? [],
            favoriteMoments: row.favorite_moments ?? [],
            standoutPerformances: row.standout_performances ?? [],
            watchedDate: row.watched_date ?? "",
            watchedLocation: row.watched_location ?? "",
            watchedWithUserIds: row.watched_with_user_ids ?? [],
            watchedPlatform: row.watched_platform,
            isRewatch: row.is_rewatch,
            rewatchNote: row.rewatch_note ?? "",
            personalTakeaway: row.personal_takeaway ?? "",
            photoPaths: row.photo_paths ?? [],
            visibilityOverride: row.visibility_override.flatMap(JournalVisibility.init(rawValue:))
        )
    }

    /// Probe-before-edit seam: the freshly-probed owner row (full `select('*')`,
    /// keeps `personal_takeaway`) always wins over a row passed in from a
    /// takeaway-less list/search read — populating a form from the passed row
    /// and saving would silently null the takeaway. A nil probe falls back to
    /// the passed row; both nil = brand-new entry.
    public static func pickEntryForEdit(probed: JournalRow?, passed: JournalRow?) -> JournalRow? {
        probed ?? passed
    }

    /// Emit a `review` activity event ONLY when the review is non-empty AND the
    /// resolved visibility is public. Friends-only review bodies must never
    /// leak into explore (the old `!== 'private'` gate regression).
    public static func shouldEmitReviewEvent(reviewText: String, resolved: JournalVisibility) -> Bool {
        !reviewText.isEmpty && resolved == .pub
    }

    /// Contract rule: empty string coerces to null so a cleared text field
    /// wipes on the full replace.
    private static func nilIfEmpty(_ s: String) -> String? {
        s.isEmpty ? nil : s
    }
}
