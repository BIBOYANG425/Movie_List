import Foundation
import Supabase

/// Pure FeedCard layer — the Swift mirror of web's card-build step in
/// `services/feedService.ts` (post-#32) plus `utils/relativeDate.ts`. No
/// network, no globals in the logic paths: everything is a pure function
/// over `FeedEventRow`, XCTest-covered in FeedCardsTests.
///
///  - `card(from:)` — kind coercion (`toFeedCardType ?? 'ranking'`,
///    feedService.ts L105–111 + L375) and the S–D tier guard (`toTier`,
///    feedService.ts L112–115).
///  - `avatarURL(...)` — the 3-step fallback chain (feedService.ts L57–59);
///    the storage step renders notificationService.ts L52's exact string:
///    `${SUPABASE_URL}/storage/v1/object/public/avatars/${avatar_path}`.
///    No prior Swift builder existed (grep `avatar_path` in Sources: raw
///    fields only), so this IS the app's avatar URL builder now.
///  - `scorePairs(for:)` — the `get_feed_ranking_scores` collection rule
///    (feedService.ts L358–361): ranking/review cards with a tmdb id only.
///  - `relativeTime(from:now:)` — web's bucket boundaries
///    (utils/relativeDate.ts L13–21) in the stub's compact form
///    (`now`/`2m`/`2h`/`3d`/`jun 28` — spec header `ADMIT ONE · @HANDLE · 2H`).
///
/// Contract source: docs/plans/2026-07-08-c1-ios-feed-ui-plan.md (Task 1),
/// spec docs/plans/2026-07-08-c1-ios-feed-ui-design.md.

// MARK: - Card model

/// Presentation kind — web's `FeedCardType`. Unknown event types coerce to
/// `.ranking` (web feedService.ts L375), so this enum is total over input.
public enum FeedCardKind: String, Sendable {
    case ranking, review, list, milestone
}

/// One feed ticket's worth of data: the mapped `activity_events` row plus
/// the hydration fields the assembler fills in (profile, avatar, score).
/// Timestamps stay verbatim Strings end-to-end (FeedPipeline cursor rule).
public struct FeedCard: Identifiable, Hashable, Sendable {
    public let id: UUID                    // event id
    public let kind: FeedCardKind
    public let actorID: UUID
    public let eventType: String           // raw, for context menus/analytics
    public let mediaTmdbID: String?
    public let title: String?              // media_title
    public let tier: Tier?                 // nil when outside S–D (guard)
    public let posterURL: String?
    public let metadata: JSONObject?
    public let createdAt: String           // raw timestamptz
    public let boostedTs: String
    // hydration (filled by assembler):
    public var actorUsername: String?
    public var actorAvatarURL: String?     // post-fallback-chain, ready to load
    public var score: Double?              // ranking/review only, when RPC returned a row

    public init(id: UUID, kind: FeedCardKind, actorID: UUID, eventType: String,
                mediaTmdbID: String?, title: String?, tier: Tier?,
                posterURL: String?, metadata: JSONObject?,
                createdAt: String, boostedTs: String,
                actorUsername: String? = nil, actorAvatarURL: String? = nil,
                score: Double? = nil) {
        self.id = id
        self.kind = kind
        self.actorID = actorID
        self.eventType = eventType
        self.mediaTmdbID = mediaTmdbID
        self.title = title
        self.tier = tier
        self.posterURL = posterURL
        self.metadata = metadata
        self.createdAt = createdAt
        self.boostedTs = boostedTs
        self.actorUsername = actorUsername
        self.actorAvatarURL = actorAvatarURL
        self.score = score
    }
}

// MARK: - Pure helpers

public enum FeedCards {

    // MARK: card mapping

    /// Map a `get_feed_page` row to its card: kind coercion + tier guard,
    /// every other field copied verbatim. Hydration fields start nil — the
    /// assembler fills them.
    public static func card(from row: FeedEventRow) -> FeedCard {
        FeedCard(
            id: row.id,
            kind: kind(forEventType: row.event_type),
            actorID: row.actor_id,
            eventType: row.event_type,
            mediaTmdbID: row.media_tmdb_id,
            title: row.media_title,
            // Web toTier (feedService.ts L112–115): case-sensitive S–D
            // whitelist, everything else nil. `Tier(rawValue:)` is exactly
            // that membership test — guard, don't crash.
            tier: row.media_tier.flatMap(Tier.init(rawValue:)),
            posterURL: row.media_poster_url,
            metadata: row.metadata,
            createdAt: row.created_at,
            boostedTs: row.boosted_ts
        )
    }

    /// Web `toFeedCardType` (feedService.ts L105–111) with the card-build
    /// coercion `?? 'ranking'` (L375) folded in: unknown event types render
    /// as ranking cards instead of crashing or vanishing.
    static func kind(forEventType eventType: String) -> FeedCardKind {
        switch eventType {
        case "ranking_add", "ranking_move": return .ranking
        case "review": return .review
        case "milestone": return .milestone
        case "list_create": return .list
        default: return .ranking
        }
    }

    // MARK: avatar chain

    /// 3-step avatar fallback (web feedService.ts L57–59):
    ///  1. non-empty `avatar_url` (trimmed) — iOS hardens web's nullish `??`
    ///     to a non-empty check per plan Task 1;
    ///  2. storage public URL from `avatar_path` — the string format web
    ///     hand-builds in notificationService.ts L52 and getPublicUrl
    ///     renders identically;
    ///  3. dicebear (exact web format, feedService.ts L59).
    /// Always returns a loadable URL string.
    public static func avatarURL(avatarUrl: String?, avatarPath: String?,
                                 username: String?) -> String {
        avatarURL(avatarUrl: avatarUrl, avatarPath: avatarPath,
                  username: username, supabaseURL: configuredSupabaseURL)
    }

    /// Testable seam: same chain with the storage base injected. A nil/empty
    /// base (fixture/preview mode — no `SUPABASE_URL` in Info.plist) skips
    /// the storage step and degrades to dicebear.
    static func avatarURL(avatarUrl: String?, avatarPath: String?,
                          username: String?, supabaseURL: String?) -> String {
        if let url = avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty {
            return url
        }
        if let path = avatarPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           var base = supabaseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !base.isEmpty {
            while base.hasSuffix("/") { base.removeLast() }
            // notificationService.ts L52:
            // `${SUPABASE_URL}/storage/v1/object/public/avatars/${avatar_path}`
            return "\(base)/storage/v1/object/public/avatars/\(path)"
        }
        let seed = (username ?? "")
            .addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? ""
        // Exact web format (feedService.ts L59) — 8.x/thumbs/svg, verified
        // against main; the plan prose's 7.x/initials/png was a placeholder.
        return "https://api.dicebear.com/8.x/thumbs/svg?seed=\(seed)"
    }

    /// Same config source SpoolClient reads (SpoolClient.swift `makeClient`).
    /// `SupabaseClient.supabaseURL` is internal to supabase-swift, so the
    /// plist is the only shared source of truth.
    static let configuredSupabaseURL: String? =
        Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String

    /// JS `encodeURIComponent` allowed set: ASCII alphanumerics + `-_.!~*'()`.
    /// (`CharacterSet.alphanumerics` would wrongly pass non-ASCII letters,
    /// which encodeURIComponent escapes.)
    private static let uriComponentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            + "abcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )

    // MARK: score pairs

    /// Collection rule for the `get_feed_ranking_scores` RPC (web
    /// feedService.ts L358–361): ranking/review cards carrying a tmdb id.
    /// Order-preserving, no dedupe — web dedupes inside getRankingScores
    /// (feedService.ts L82–90), iOS inside `FeedRepository.rankingScores`.
    public static func scorePairs(for cards: [FeedCard]) -> [(userID: UUID, tmdbID: String)] {
        cards.compactMap { card -> (userID: UUID, tmdbID: String)? in
            guard card.kind == .ranking || card.kind == .review,
                  let tmdbID = card.mediaTmdbID else { return nil }
            return (userID: card.actorID, tmdbID: tmdbID)
        }
    }

    // MARK: relative time

    /// Compact stub-header form of web's relativeDate buckets
    /// (utils/relativeDate.ts L13–21; strings i18n/en.ts L86–89):
    ///   mins < 1 → `now` · mins < 60 → `Nm` · hrs < 24 → `Nh` ·
    ///   days < 7 → `Nd` · else short date (`jun 28`, lowercase per app
    ///   copy voice — web renders locale `month:'short', day:'numeric'`).
    /// Unparseable input echoes the raw string, empty renders `now` —
    /// web's catch: `return iso || t('feed.justNow')` (relativeDate.ts
    /// L22–23).
    public static func relativeTime(from createdAt: String, now: Date) -> String {
        relativeTime(from: createdAt, now: now, timeZone: .current)
    }

    /// Testable seam: the ≥7-day date form renders in the viewer's zone
    /// like web's toLocaleDateString; tests inject UTC for determinism.
    static func relativeTime(from createdAt: String, now: Date,
                             timeZone: TimeZone) -> String {
        guard !createdAt.isEmpty else { return "now" }
        guard let date = parseTimestamp(createdAt) else { return createdAt }
        // Web: mins = Math.floor(diff / 60000) — floor, so future
        // timestamps (negative diff) land below 1 and render `now`.
        let mins = Int(floor(now.timeIntervalSince(date) / 60))
        if mins < 1 { return "now" }
        if mins < 60 { return "\(mins)m" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs)h" }
        let days = hrs / 24
        if days < 7 { return "\(days)d" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MMM d"
        return f.string(from: date).lowercased()
    }

    /// PostgREST timestamptz: ISO 8601, with or without fractional seconds
    /// (Postgres emits µs; ISO8601DateFormatter needs the fractional option
    /// ON to accept fractions and OFF to accept none — try both).
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseTimestamp(_ raw: String) -> Date? {
        isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
    }
}
