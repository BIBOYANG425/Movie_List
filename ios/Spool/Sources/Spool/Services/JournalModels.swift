import Foundation

// Journal domain models + the full-replace upsert wire payload, mirroring the
// binding `journal_entries` contract in docs/contracts/shared-payloads.md.
//
// The 25-column prod table splits into:
//  - 20 client-written columns (the `JournalUpsertPayload` — full replace,
//    any omitted field WIPES it, so nil optionals encode as explicit JSON
//    null and never a missing key);
//  - 5 server-owned columns never written by a client (`id`, `created_at`,
//    `updated_at`, `like_count`, `search_vector`).
// `JournalRow` decodes the owner-only `select('*')` row (server cols optional-
// decoded, `search_vector` never surfaced); `JournalDraft` is the editable
// composer model.

/// Resolved/stored journal visibility. Raw values match the DB CHECK + the
/// `profiles.profile_visibility` domain.
public enum JournalVisibility: String, Sendable, Codable {
    case pub = "public"
    case friends
    case priv = "private"
}

/// A `standout_performances` jsonb element — camelCase keys mirror the web
/// shape `{personId, name, character?}` exactly (jsonb is stored verbatim, so
/// no snake_case conversion here).
public struct StandoutPerformance: Codable, Equatable, Sendable, Hashable {
    public let personId: Int
    public let name: String
    public let character: String?

    public init(personId: Int, name: String, character: String?) {
        self.personId = personId
        self.name = name
        self.character = character
    }
}

/// Full owner-row DTO for the `getOwnEntry` / `listOwnEntries` `select('*')`
/// path (all 24 non-`search_vector` columns; server-owned optionals decode
/// leniently). `personal_takeaway` is present because this cycle only ever
/// reads the owner's OWN entries — a cross-user read must use the 23-column
/// shared shape instead (Task 2), never this type.
public struct JournalRow: Codable, Sendable, Hashable {
    public let id: UUID
    public let user_id: UUID
    public let tmdb_id: String
    public let title: String
    public let poster_url: String?
    public let rating_tier: String?
    public let review_text: String?
    public let contains_spoilers: Bool
    public let mood_tags: [String]?
    public let vibe_tags: [String]?
    public let favorite_moments: [String]?
    public let standout_performances: [StandoutPerformance]?
    public let watched_date: String?
    public let watched_location: String?
    public let watched_with_user_ids: [UUID]?
    public let watched_platform: String?
    public let is_rewatch: Bool
    public let rewatch_note: String?
    public let personal_takeaway: String?
    public let photo_paths: [String]?
    public let visibility_override: String?
    public let like_count: Int
    public let created_at: String

    public init(
        id: UUID, user_id: UUID, tmdb_id: String, title: String,
        poster_url: String?, rating_tier: String?, review_text: String?,
        contains_spoilers: Bool, mood_tags: [String]?, vibe_tags: [String]?,
        favorite_moments: [String]?, standout_performances: [StandoutPerformance]?,
        watched_date: String?, watched_location: String?, watched_with_user_ids: [UUID]?,
        watched_platform: String?, is_rewatch: Bool, rewatch_note: String?,
        personal_takeaway: String?, photo_paths: [String]?, visibility_override: String?,
        like_count: Int, created_at: String
    ) {
        self.id = id
        self.user_id = user_id
        self.tmdb_id = tmdb_id
        self.title = title
        self.poster_url = poster_url
        self.rating_tier = rating_tier
        self.review_text = review_text
        self.contains_spoilers = contains_spoilers
        self.mood_tags = mood_tags
        self.vibe_tags = vibe_tags
        self.favorite_moments = favorite_moments
        self.standout_performances = standout_performances
        self.watched_date = watched_date
        self.watched_location = watched_location
        self.watched_with_user_ids = watched_with_user_ids
        self.watched_platform = watched_platform
        self.is_rewatch = is_rewatch
        self.rewatch_note = rewatch_note
        self.personal_takeaway = personal_takeaway
        self.photo_paths = photo_paths
        self.visibility_override = visibility_override
        self.like_count = like_count
        self.created_at = created_at
    }
}

/// The editable composer model. All text fields are non-optional Strings (the
/// composer binds directly; the contract coerces empty → null at upsert), and
/// the tag/moment/photo/friend arrays default `[]`. Per the plan there is NO
/// separate `oneLiner` field: the ceremony's one-liner is folded directly into
/// `reviewText` by the caller (Task 6).
public struct JournalDraft: Equatable, Sendable {
    public var tmdbId: String
    public var title: String
    public var posterUrl: String?
    public var reviewText: String
    public var containsSpoilers: Bool
    public var moodTags: [String]
    public var vibeTags: [String]
    public var favoriteMoments: [String]
    public var standoutPerformances: [StandoutPerformance]
    public var watchedDate: String
    public var watchedLocation: String
    public var watchedWithUserIds: [UUID]
    public var watchedPlatform: String?
    public var isRewatch: Bool
    public var rewatchNote: String
    public var personalTakeaway: String
    public var photoPaths: [String]
    public var visibilityOverride: JournalVisibility?

    public init(
        tmdbId: String, title: String, posterUrl: String?,
        reviewText: String, containsSpoilers: Bool,
        moodTags: [String], vibeTags: [String], favoriteMoments: [String],
        standoutPerformances: [StandoutPerformance], watchedDate: String,
        watchedLocation: String, watchedWithUserIds: [UUID], watchedPlatform: String?,
        isRewatch: Bool, rewatchNote: String, personalTakeaway: String,
        photoPaths: [String], visibilityOverride: JournalVisibility?
    ) {
        self.tmdbId = tmdbId
        self.title = title
        self.posterUrl = posterUrl
        self.reviewText = reviewText
        self.containsSpoilers = containsSpoilers
        self.moodTags = moodTags
        self.vibeTags = vibeTags
        self.favoriteMoments = favoriteMoments
        self.standoutPerformances = standoutPerformances
        self.watchedDate = watchedDate
        self.watchedLocation = watchedLocation
        self.watchedWithUserIds = watchedWithUserIds
        self.watchedPlatform = watchedPlatform
        self.isRewatch = isRewatch
        self.rewatchNote = rewatchNote
        self.personalTakeaway = personalTakeaway
        self.photoPaths = photoPaths
        self.visibilityOverride = visibilityOverride
    }
}

/// The full-replace upsert wire payload — EXACTLY the 20 client columns in
/// snake_case. A custom `encode(to:)` (like `StubInsertPayload`) is mandatory:
/// synthesized Encodable OMITS nil optionals, and PostgREST treats a missing
/// key as "don't touch", so a cleared field would never wipe on a full
/// replace. Every optional therefore encodes as an explicit JSON null.
public struct JournalUpsertPayload: Encodable, Equatable {
    let user_id: UUID
    let tmdb_id: String
    let title: String
    let poster_url: String?
    let rating_tier: String?
    let review_text: String?
    let contains_spoilers: Bool
    let mood_tags: [String]
    let vibe_tags: [String]
    let favorite_moments: [String]
    let standout_performances: [StandoutPerformance]
    let watched_date: String
    let watched_location: String?
    let watched_with_user_ids: [UUID]
    let watched_platform: String?
    let is_rewatch: Bool
    let rewatch_note: String?
    let personal_takeaway: String?
    let photo_paths: [String]
    let visibility_override: String?

    private enum CodingKeys: String, CodingKey {
        case user_id, tmdb_id, title, poster_url, rating_tier, review_text
        case contains_spoilers, mood_tags, vibe_tags, favorite_moments
        case standout_performances, watched_date, watched_location
        case watched_with_user_ids, watched_platform, is_rewatch
        case rewatch_note, personal_takeaway, photo_paths, visibility_override
    }

    /// Explicit-null encoding for every optional so the full replace clears a
    /// vanished field. Arrays/bools always encode (never omitted). This is the
    /// load-bearing reason a synthesized Encodable is NOT used.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(user_id, forKey: .user_id)
        try c.encode(tmdb_id, forKey: .tmdb_id)
        try c.encode(title, forKey: .title)
        try c.encode(poster_url, forKey: .poster_url)                 // explicit null
        try c.encode(rating_tier, forKey: .rating_tier)               // explicit null
        try c.encode(review_text, forKey: .review_text)               // explicit null
        try c.encode(contains_spoilers, forKey: .contains_spoilers)
        try c.encode(mood_tags, forKey: .mood_tags)
        try c.encode(vibe_tags, forKey: .vibe_tags)
        try c.encode(favorite_moments, forKey: .favorite_moments)
        try c.encode(standout_performances, forKey: .standout_performances)
        try c.encode(watched_date, forKey: .watched_date)
        try c.encode(watched_location, forKey: .watched_location)     // explicit null
        try c.encode(watched_with_user_ids, forKey: .watched_with_user_ids)
        try c.encode(watched_platform, forKey: .watched_platform)     // explicit null
        try c.encode(is_rewatch, forKey: .is_rewatch)
        try c.encode(rewatch_note, forKey: .rewatch_note)             // explicit null
        try c.encode(personal_takeaway, forKey: .personal_takeaway)   // explicit null
        try c.encode(photo_paths, forKey: .photo_paths)
        try c.encode(visibility_override, forKey: .visibility_override) // explicit null
    }
}
