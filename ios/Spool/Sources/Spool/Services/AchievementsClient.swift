import Foundation
import Supabase

/// Client + catalog for the server-side achievements feature (C7-iOS Task 1).
///
/// Achievements are GRANTED server-side by the `grant_achievements()` Postgres
/// RPC (SECURITY DEFINER; migration `20260711_achievements_server_grant.sql`,
/// live in prod). The RPC takes NO arguments — it evaluates every rule for the
/// caller identified by `auth.uid()`, inserts only newly-earned badges
/// (`ON CONFLICT (user_id, badge_key) DO NOTHING`, idempotent), writes the
/// `badge_unlock` notification atomically, and RETURNS `text[]` of the badge
/// keys granted in THIS call. See `docs/contracts/shared-payloads.md`
/// § `achievements`.
///
/// Client rules the contract pins (all enforced here):
///   - Clients NEVER INSERT `user_achievements` rows — RLS revokes INSERT; the
///     RPC is the sole write path. This enum offers no write beyond the RPC.
///   - Clients NEVER write `badge_unlock` notifications — the RPC does that
///     inside the same call. There is no notification write here.
///   - The RPC is called fire-and-forget AFTER a confirmed write (Task 2 wires
///     the post-write hooks via `AchievementMilestones.grantAndEmitMilestones()`
///     in a detached task — see `JournalDraftModel`'s default binding).
///   - `earnedBadges(for:)` is a plain SELECT on `user_achievements`
///     (`badge_key`, `unlocked_at`); RLS SELECT is public, so it works for the
///     viewer's own id and any other user's id (the profile badge surface reads
///     both). `unlocked_at` is decoded as a raw ISO string, matching every
///     other timestamp DTO in this codebase (`RankingRow.created_at`,
///     `StubRow.watched_date`), so no bespoke `Date` decoder is introduced.
///
/// The 16-badge catalog (`BadgeCatalog.all`) is a pure Swift table ported
/// VERBATIM from web `components/social/AchievementsView.tsx` `BADGE_CATALOG`
/// (lines 8-32): 15 grantable badges + `early_adopter` (no RPC rule, never
/// granted). Key/name/description/icon/category are byte-for-byte the web copy;
/// `grantable` marks the one non-grantable entry. The catalog is EN-only on web
/// (the copy lives in `BADGE_CATALOG`, NOT in the i18n tables), so badge names
/// and descriptions stay English proper nouns on iOS too — see the L10n note in
/// `c7i-task-1-report.md`. `requirement` (web's unlock-hint string) is ported so
/// the locked-badge hint on the own-profile surface mirrors web exactly.
///
/// Header last reviewed: 2026-07-10
public enum AchievementsClient {

    // MARK: - Grant (server RPC)

    /// Call the `grant_achievements()` RPC and return the badge keys newly
    /// granted in THIS call (empty when nothing crossed a threshold this call).
    ///
    /// No arguments: the RPC keys off `auth.uid()` by design. Decodes the
    /// function's `text[]` return directly into `[String]`.
    ///
    /// - Throws: `AchievementsError.notConfigured` when the client is missing;
    ///   any transport/decode/HTTP error from the RPC (the caller decides
    ///   whether to swallow — callers run this via `AchievementMilestones.grantAndEmitMilestones()`
    ///   in a `Task.detached`, which swallows errors internally).
    public static func grant() async throws -> [String] {
        guard let client = SpoolClient.shared else {
            NSLog("[AchievementsClient] grant: no client (not configured)")
            throw AchievementsError.notConfigured
        }

        let granted: [String] = try await client
            .rpc("grant_achievements")
            .execute()
            .value
        return granted
    }

    // MARK: - Read (public SELECT)

    /// Earned badges for `userId`, newest-unlocked first. Plain SELECT of
    /// `badge_key, unlocked_at` from `user_achievements`; RLS SELECT is public,
    /// so this reads the viewer's own rows AND any other user's (the friend
    /// profile badge surface). Throws on a missing client or a read failure —
    /// the profile surfaces catch and render an empty badge state, matching the
    /// per-read fail-soft posture of `ProfileScreen.reload`.
    public static func earnedBadges(for userId: UUID) async throws -> [EarnedBadge] {
        guard let client = SpoolClient.shared else {
            NSLog("[AchievementsClient] earnedBadges: no client (not configured)")
            throw AchievementsError.notConfigured
        }

        let rows: [EarnedBadge] = try await client
            .from("user_achievements")
            .select("badge_key,unlocked_at")
            .eq("user_id", value: userId.uuidString)
            .order("unlocked_at", ascending: false)
            .execute()
            .value
        return rows
    }

    // MARK: - Errors

    public enum AchievementsError: Error {
        /// No client configured (missing SUPABASE_URL / anon key).
        case notConfigured
    }
}

// MARK: - Row / model types

/// One row of `user_achievements` as the badge surfaces read it. `unlockedAt`
/// is the raw ISO-8601 timestamp string PostgREST returns (no bespoke `Date`
/// decoder — parity with `RankingRow.created_at` / `StubRow.watched_date`).
/// The CodingKeys map the snake_case DB columns to camelCase Swift fields
/// explicitly, matching web's `getUserAchievements` mapping
/// (`services/friendsService.ts`: `badgeKey: a.badge_key, unlockedAt: a.unlocked_at`).
public struct EarnedBadge: Codable, Sendable, Hashable, Identifiable {
    public let badgeKey: String
    public let unlockedAt: String

    public var id: String { badgeKey }

    enum CodingKeys: String, CodingKey {
        case badgeKey = "badge_key"
        case unlockedAt = "unlocked_at"
    }

    public init(badgeKey: String, unlockedAt: String) {
        self.badgeKey = badgeKey
        self.unlockedAt = unlockedAt
    }
}

/// A badge definition in the pure catalog. Mirrors web's `BadgeDefinition`
/// (`types.ts`) / the `BADGE_CATALOG` entries: `key`, `name`, `description`,
/// `icon` (emoji), `category`, `requirement` (locked-badge hint). `grantable`
/// is the iOS-side flag distinguishing the 15 RPC-granted badges from
/// `early_adopter` (no rule; never granted).
public struct BadgeDefinition: Sendable, Hashable, Identifiable {
    public let key: String
    public let name: String
    public let description: String
    public let icon: String
    public let category: BadgeCategory
    public let requirement: String
    /// Whether `grant_achievements()` can ever grant this badge. Exactly one
    /// catalog entry (`early_adopter`) is non-grantable.
    public let grantable: Bool

    public var id: String { key }

    public init(
        key: String, name: String, description: String, icon: String,
        category: BadgeCategory, requirement: String, grantable: Bool
    ) {
        self.key = key
        self.name = name
        self.description = description
        self.icon = icon
        self.category = category
        self.requirement = requirement
        self.grantable = grantable
    }
}

/// Badge category groupings, matching web's `category` field + `CATEGORY_STYLES`
/// section order (`AchievementsView.tsx:34-39,66`): milestone → social → taste →
/// special.
public enum BadgeCategory: String, Sendable, Hashable, CaseIterable {
    case milestone
    case social
    case taste
    case special
}

// MARK: - Badge catalog (verbatim port of web BADGE_CATALOG)

/// The 16-badge catalog, a pure table ported VERBATIM from web
/// `components/social/AchievementsView.tsx` `BADGE_CATALOG` (lines 8-32).
/// key/name/description/icon/category are byte-for-byte the web copy; the copy
/// is EN-only on web (not in the i18n tables), so it stays EN here — badge
/// names are proper nouns. 15 grantable + `early_adopter` (line 31, no RPC
/// rule).
public enum BadgeCatalog {

    /// All 16 badges in web catalog order (milestone → social → taste →
    /// special). Order matters: the own-profile surface renders category
    /// sections in this order and within-category in this order, mirroring web.
    public static let all: [BadgeDefinition] = [
        // ── Milestones (AchievementsView.tsx:10-16) ──
        BadgeDefinition(key: "first_rank", name: "First Pick", description: "Ranked your first movie", icon: "🎬", category: .milestone, requirement: "1 ranking", grantable: true),
        BadgeDefinition(key: "rank_10", name: "Cinephile", description: "Ranked 10 movies", icon: "🎞️", category: .milestone, requirement: "10 rankings", grantable: true),
        BadgeDefinition(key: "rank_25", name: "Film Buff", description: "Ranked 25 movies", icon: "🍿", category: .milestone, requirement: "25 rankings", grantable: true),
        BadgeDefinition(key: "rank_50", name: "Movie Maven", description: "Ranked 50 movies", icon: "🏆", category: .milestone, requirement: "50 rankings", grantable: true),
        BadgeDefinition(key: "rank_100", name: "Century Club", description: "Ranked 100 movies", icon: "💯", category: .milestone, requirement: "100 rankings", grantable: true),
        BadgeDefinition(key: "first_review", name: "First Words", description: "Wrote your first review", icon: "✍️", category: .milestone, requirement: "1 review", grantable: true),
        BadgeDefinition(key: "review_10", name: "Critic", description: "Wrote 10 reviews", icon: "📝", category: .milestone, requirement: "10 reviews", grantable: true),

        // ── Social (AchievementsView.tsx:19-22) ──
        BadgeDefinition(key: "first_follow", name: "Social Butterfly", description: "Followed your first person", icon: "🦋", category: .social, requirement: "1 follow", grantable: true),
        BadgeDefinition(key: "followers_10", name: "Rising Star", description: "Gained 10 followers", icon: "⭐", category: .social, requirement: "10 followers", grantable: true),
        BadgeDefinition(key: "followers_50", name: "Influencer", description: "Gained 50 followers", icon: "🌟", category: .social, requirement: "50 followers", grantable: true),
        BadgeDefinition(key: "first_list", name: "Curator", description: "Created a movie list", icon: "📋", category: .social, requirement: "1 list", grantable: true),

        // ── Taste (AchievementsView.tsx:25-28) ──
        BadgeDefinition(key: "genre_5", name: "Versatile", description: "Ranked movies in 5+ genres", icon: "🎨", category: .taste, requirement: "5 genres", grantable: true),
        BadgeDefinition(key: "genre_10", name: "Eclectic", description: "Ranked movies in 10+ genres", icon: "🌈", category: .taste, requirement: "10 genres", grantable: true),
        BadgeDefinition(key: "s_tier_10", name: "Elite Eye", description: "Gave 10 movies S-tier", icon: "👑", category: .taste, requirement: "10 S-tier", grantable: true),
        BadgeDefinition(key: "d_tier_5", name: "Honest Critic", description: "Gave 5 movies D-tier — not everything's great", icon: "💀", category: .taste, requirement: "5 D-tier", grantable: true),

        // ── Special (AchievementsView.tsx:31) — NOT grantable (no RPC rule) ──
        BadgeDefinition(key: "early_adopter", name: "Early Adopter", description: "Joined during beta", icon: "🚀", category: .special, requirement: "Beta signup", grantable: false),
    ]

    /// Fast key → definition lookup for the surfaces (earned-key set → render).
    public static let byKey: [String: BadgeDefinition] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.key, $0) }
    )

    /// Badges in `category`, in catalog order.
    public static func inCategory(_ category: BadgeCategory) -> [BadgeDefinition] {
        all.filter { $0.category == category }
    }

    /// The 15 keys the RPC can grant (everything except `early_adopter`).
    public static var grantableKeys: [String] { all.filter(\.grantable).map(\.key) }
}
