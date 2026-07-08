import Foundation

/// Journal tag/photo constants, mirroring web `constants.ts` verbatim.
///
/// The IDs MUST match web (they persist into `journal_entries.mood_tags` /
/// `vibe_tags` / `watched_platform` and are read cross-platform); iOS owns the
/// display labels for its own UI, but never invents or renames an ID. Web
/// source: `constants.ts` — `MOOD_TAGS` (L192), `VIBE_TAGS` (L222),
/// `PLATFORM_OPTIONS` (L236), `JOURNAL_MAX_MOMENTS`/`JOURNAL_MAX_PHOTOS`
/// (L270-271). Signed-URL TTL from the contract's Photos section (30 days).
public enum JournalConstants {

    /// `MOOD_TAGS` ids in web declaration order (positive → reflective →
    /// intense → light). 23 ids.
    public static let moodTagIDs: [String] = [
        "inspired", "joyful", "thrilled", "moved", "amazed", "comforted", "hopeful",
        "thoughtful", "nostalgic", "melancholy", "haunted", "contemplative",
        "tense", "disturbed", "heartbroken", "angry", "overwhelmed", "exhausted",
        "amused", "charmed", "entertained", "relaxed", "satisfied",
    ]

    /// `VIBE_TAGS` ids in web declaration order. 11 ids.
    public static let vibeTagIDs: [String] = [
        "solo_watch", "date_night", "movie_night", "family_time", "theater",
        "cozy_night", "binge", "rewatch", "blind_watch", "late_night", "travel",
    ]

    /// `PLATFORM_OPTIONS` ids in web declaration order. 13 ids (the contract's
    /// "14 ids" counts the `{ id: string; ... }` type annotation line — the
    /// actual option list is 13; mirrored verbatim from the source array).
    public static let platformIDs: [String] = [
        "theater", "netflix", "apple_tv", "max", "hulu", "prime", "disney",
        "peacock", "paramount", "mubi", "criterion", "physical", "other",
    ]

    /// `JOURNAL_MAX_MOMENTS` — max free-text favorite moments.
    public static let journalMaxMoments = 5

    /// `JOURNAL_MAX_PHOTOS` — max journal photos per entry.
    public static let journalMaxPhotos = 6

    /// `JOURNAL_PHOTO_SIGNED_URL_TTL_SECONDS` — 30 days. Signed URLs are minted
    /// fresh on every render and never persisted.
    public static let journalPhotoSignedURLTTL = 2_592_000
}
