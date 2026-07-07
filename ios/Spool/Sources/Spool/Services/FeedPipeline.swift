import Foundation
import Supabase

/// Pure, client-side half of the C1 feed contract — the Swift mirror of the
/// filtering/throttle/cursor logic web runs in `services/feedService.ts`
/// post-#32. No network, no clocks, no globals: everything here is a pure
/// function over `get_feed_page` rows, XCTest-covered in FeedPipelineTests.
///
/// Contract source: docs/plans/2026-07-08-c1-ios-feed-data-plan.md
/// (Global Constraints), quoting docs/contracts/shared-payloads.md on
/// branch fix/c1-feed-web-blocking @ e57850c.

// MARK: - Wire types

/// Keyset cursor into the boosted feed ordering: the last consumed row's
/// `(boosted_ts, id)`. `boostedTs` is the SERVER-computed ordering key
/// echoed VERBATIM (byte-exact, Postgres µs precision preserved) — it stays
/// a String end-to-end and is NEVER recomputed or re-parsed-and-reformatted
/// client-side. First page = nil cursor (both RPC params null).
public struct FeedCursor: Equatable, Sendable {
    public let boostedTs: String
    public let id: UUID

    public init(boostedTs: String, id: UUID) {
        self.boostedTs = boostedTs
        self.id = id
    }
}

/// One `get_feed_page` row: the `activity_events` columns plus the
/// server-computed `boosted_ts` ordering key
/// (`created_at + 2h × (event_type='review')`, windowless).
/// Property names are snake_case on purpose — they ARE the wire format.
/// Timestamps stay Strings so the cursor echo can be byte-verbatim.
/// `metadata` uses supabase-swift's `JSONObject` (`[String: AnyJSON]`,
/// re-exported by the `Supabase` umbrella module) — Codable/Hashable/
/// Sendable out of the box, no bespoke JSON enum needed.
public struct FeedEventRow: Codable, Sendable, Hashable {
    public let id: UUID
    public let actor_id: UUID
    public let event_type: String
    public let media_tmdb_id: String?
    public let media_title: String?
    public let media_tier: String?
    public let media_poster_url: String?
    public let metadata: JSONObject?
    public let created_at: String
    public let boosted_ts: String

    public init(id: UUID, actor_id: UUID, event_type: String,
                media_tmdb_id: String?, media_title: String?,
                media_tier: String?, media_poster_url: String?,
                metadata: JSONObject?, created_at: String, boosted_ts: String) {
        self.id = id
        self.actor_id = actor_id
        self.event_type = event_type
        self.media_tmdb_id = media_tmdb_id
        self.media_title = media_title
        self.media_tier = media_tier
        self.media_poster_url = media_poster_url
        self.metadata = metadata
        self.created_at = created_at
        self.boosted_ts = boosted_ts
    }
}

/// `get_feed_page` mode. The RPC raises (22023) on anything else, so the
/// enum is the whole validation story client-side.
public enum FeedMode: String, Sendable {
    case friends
    case explore
}

// MARK: - Pipeline

public enum FeedPipeline {

    /// Max milestone cards per actor per LOCAL calendar day within one
    /// consumed page-stream (resume-session).
    public static let milestoneDailyCap = 3

    // MARK: cursor

    /// Build the next-page cursor from the last CONSUMED row (kept or
    /// dropped — the keyset advances over every row the client saw).
    /// Verbatim echo of the server's `boosted_ts` column; see `FeedCursor`.
    public static func cursor(fromLastConsumed row: FeedEventRow) -> FeedCursor {
        FeedCursor(boostedTs: row.boosted_ts, id: row.id)
    }

    // MARK: mutes

    /// Client-side mute pass (`feed_mutes` is applied at read time in BOTH
    /// modes): drop rows whose actor is user-muted or whose `media_tmdb_id`
    /// is movie-muted. Rows without media are untouchable by media mutes.
    public static func applyMutes(_ rows: [FeedEventRow],
                                  mutedUsers: Set<UUID>,
                                  mutedMedia: Set<String>) -> [FeedEventRow] {
        rows.filter { row in
            if mutedUsers.contains(row.actor_id) { return false }
            if let tmdbID = row.media_tmdb_id, mutedMedia.contains(tmdbID) { return false }
            return true
        }
    }

    // MARK: event-type filter

    /// Keep only rows whose `event_type` is in `allowed`.
    public static func applyTypeFilter(_ rows: [FeedEventRow],
                                       allowed: Set<String>) -> [FeedEventRow] {
        rows.filter { allowed.contains($0.event_type) }
    }

    /// The default ("all") card set — web `getEventTypesForFilter('all')`.
    /// Identical in friends and explore; `ranking_remove` is excluded in
    /// BOTH (removals never render as cards).
    public static func defaultEventTypes(explore: Bool) -> Set<String> {
        _ = explore // same set either way; parameter kept for call-site clarity
        return ["ranking_add", "ranking_move", "review", "list_create", "milestone"]
    }

    // MARK: milestone throttle

    /// Cap milestone cards at `milestoneDailyCap` per actor per LOCAL
    /// calendar day (the day `created_at` falls on in `calendar`'s time
    /// zone). Counted per resume-session over the consumed page-stream —
    /// web post-#32 semantics, NOT the legacy whole-prefix recount: the
    /// CALLER owns `counts` (key `"<lowercase actor uuid>|yyyy-MM-dd"`),
    /// passes the same dict for every page of one session so counts carry
    /// across pages, and starts a fresh dict on a new session.
    /// Non-milestone rows pass through and never count.
    public static func throttleMilestones(_ rows: [FeedEventRow],
                                          counts: inout [String: Int],
                                          calendar: Calendar) -> [FeedEventRow] {
        var kept: [FeedEventRow] = []
        kept.reserveCapacity(rows.count)
        for row in rows {
            guard row.event_type == "milestone" else {
                kept.append(row)
                continue
            }
            let key = milestoneCountKey(actorID: row.actor_id,
                                        createdAt: row.created_at,
                                        calendar: calendar)
            let seen = counts[key, default: 0]
            guard seen < milestoneDailyCap else { continue }
            counts[key] = seen + 1
            kept.append(row)
        }
        return kept
    }

    // MARK: score-map key

    /// Key for the `get_feed_ranking_scores` result map — MUST be
    /// byte-identical to web's `${userId}:${tmdbId}`. DB uuid strings are
    /// lowercase while Swift's `UUID.uuidString` uppercases, so the Swift
    /// side canonicalizes to lowercase; without this every lookup misses
    /// and the score badge silently never renders.
    public static func scoreKey(userID: UUID, tmdbID: String) -> String {
        "\(userID.uuidString.lowercased()):\(tmdbID)"
    }

    // MARK: - Internals

    static func milestoneCountKey(actorID: UUID,
                                  createdAt: String,
                                  calendar: Calendar) -> String {
        "\(actorID.uuidString.lowercased())|\(localDayKey(createdAt: createdAt, calendar: calendar))"
    }

    /// `yyyy-MM-dd` of `createdAt` in `calendar`'s time zone. If the
    /// timestamp is unparseable (should never happen for PostgREST output),
    /// fall back to the raw date prefix — the UTC day slice web uses
    /// (`created_at.slice(0, 10)`) — rather than dropping the throttle.
    static func localDayKey(createdAt: String, calendar: Calendar) -> String {
        guard let date = parseTimestamp(createdAt) else {
            return String(createdAt.prefix(10))
        }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Parse a PostgREST timestamptz string (`2026-07-07T10:00:00.123456+00:00`,
    /// fraction optional). Used ONLY for local-day bucketing — never to build
    /// cursors, which stay verbatim Strings. `ISO8601DateFormatter` with
    /// `.withFractionalSeconds` rejects Postgres's 6-digit fractions on some
    /// OS versions, so the fallback strips the fraction (sub-second precision
    /// is irrelevant to a day bucket).
    static func parseTimestamp(_ raw: String) -> Date? {
        if let d = isoFractional.date(from: raw) { return d }
        if let d = isoPlain.date(from: raw) { return d }
        if let dot = raw.firstIndex(of: ".") {
            let tail = raw[raw.index(after: dot)...].drop(while: \.isNumber)
            return isoPlain.date(from: String(raw[..<dot]) + tail)
        }
        return nil
    }

    // ISO8601DateFormatter is documented thread-safe; share instances.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
