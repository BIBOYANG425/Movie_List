import Foundation

/// Models + pure aggregation for the social Discover screen (C3-iOS Part A,
/// Task 5). The network-free half of `DiscoverRepository`: the per-movie
/// aggregation, exclusion, sort, tie-break, and profile-capping logic that
/// ports `services/tasteService.ts` `getFriendRecommendations` (`:211-311`)
/// and `getTrendingAmongFriends` (`:316-398`).
///
/// Everything here is deterministic and injected-input only, so the whole of
/// the binding semantics is unit-tested with ZERO network
/// (`DiscoverContractTests`). The actor (`DiscoverRepository`) does the reads
/// and hands the rows to `DiscoverAggregation`.
///
/// Binding contract: C3 web audit §1.2. The known `updated_at` whole-tier
/// churn quirk (D13) is PRESERVED — trending keys on `updated_at`, matching
/// web; this file does not invent a different recency source.
///
/// Header last reviewed: 2026-07-09

// MARK: - Tier numerics (mirror tasteService.ts TIER_NUMERIC / NUMERIC_TIER)

/// Tier → numeric weight. `TIER_NUMERIC` in `tasteService.ts:24` (S..D = 5..1).
public let discoverTierNumeric: [String: Int] = ["S": 5, "A": 4, "B": 3, "C": 2, "D": 1]

/// Numeric → tier label. `NUMERIC_TIER` in `tasteService.ts:25`.
private let discoverNumericTier: [Int: String] = [5: "S", 4: "A", 3: "B", 2: "C", 1: "D"]

/// Rounds an average tier value to its nearest label, clamped to [1, 5].
/// Mirrors `tierLabel` (`tasteService.ts:27-30`) — `Math.round`, clamp, map,
/// default "C".
public func discoverTierLabel(_ numeric: Double) -> String {
    let rounded = Int(numeric.rounded())
    return discoverNumericTier[max(1, min(5, rounded))] ?? "C"
}

// MARK: - Input rows (what the repository reads and hands to aggregation)

/// One friend `user_rankings` row projected for Discover aggregation. Matches
/// the web select `tmdb_id, title, poster_url, year, genres, tier, user_id`
/// (`tasteService.ts:236, :332`).
public struct DiscoverRankingRow: Sendable, Hashable {
    public let tmdbId: String
    public let title: String
    public let posterUrl: String?
    public let year: String?
    public let genres: [String]
    public let tier: String
    public let userId: UUID

    public init(tmdbId: String, title: String, posterUrl: String?, year: String?,
                genres: [String], tier: String, userId: UUID) {
        self.tmdbId = tmdbId
        self.title = title
        self.posterUrl = posterUrl
        self.year = year
        self.genres = genres
        self.tier = tier
        self.userId = userId
    }
}

/// A friend profile row (`profiles.id, username, avatar_path`) for building the
/// ≤3 avatar/username chips a card carries (`tasteService.ts:272-278`).
public struct DiscoverProfileRow: Sendable, Hashable {
    public let id: UUID
    public let username: String
    public let avatarPath: String?

    public init(id: UUID, username: String, avatarPath: String?) {
        self.id = id
        self.username = username
        self.avatarPath = avatarPath
    }
}

// MARK: - Output card models (what the screen renders)

/// One friend profile chip on a card — a username + a loadable avatar URL. The
/// avatar URL is built through the same storage/dicebear chain the feed uses
/// (`FeedCards.avatarURL`); web hand-builds the public storage URL and leaves
/// it "" when there's no `avatar_path` (`tasteService.ts:285-289`), but iOS
/// carries the full fallback chain so a chip always has something to render.
public struct FriendProfileChip: Sendable, Hashable, Identifiable {
    public let userId: UUID
    public let username: String
    public let avatarUrl: String
    public var id: UUID { userId }

    public init(userId: UUID, username: String, avatarUrl: String) {
        self.userId = userId
        self.username = username
        self.avatarUrl = avatarUrl
    }
}

/// A "from your friends" recommendation card. Ports `FriendRecommendation`
/// (`tasteService.ts:294-306`): friendCount, avg/top tier, ≤3 friend chips.
public struct FriendRecommendation: Sendable, Hashable, Identifiable {
    public let tmdbId: String
    public let title: String
    public let posterUrl: String?
    public let year: String?
    public let genres: [String]
    /// Rounded-label of the average tier the friends gave this movie.
    public let avgTier: String
    /// Average tier as a 1-decimal numeric — the secondary sort key (S best).
    public let avgTierNumeric: Double
    /// Distinct friends who ranked this movie S/A.
    public let friendCount: Int
    /// Best (highest) tier any friend gave this movie.
    public let topTier: String
    /// ≤3 friend chips (avatars + usernames).
    public let friends: [FriendProfileChip]

    public var id: String { tmdbId }

    public init(tmdbId: String, title: String, posterUrl: String?, year: String?,
                genres: [String], avgTier: String, avgTierNumeric: Double,
                friendCount: Int, topTier: String, friends: [FriendProfileChip]) {
        self.tmdbId = tmdbId
        self.title = title
        self.posterUrl = posterUrl
        self.year = year
        self.genres = genres
        self.avgTier = avgTier
        self.avgTierNumeric = avgTierNumeric
        self.friendCount = friendCount
        self.topTier = topTier
        self.friends = friends
    }

    /// Up to the first two genres — the card's "top-2 genres" line (audit §1.2).
    public var topGenres: [String] { Array(genres.prefix(2)) }
}

/// A "trending with friends" card. Ports `TrendingMovie`
/// (`tasteService.ts:383-392`): rankerCount, avg tier, ≤3 recent ranker chips.
/// The `rank` (1-based #) is assigned by the aggregation after sorting.
public struct TrendingMovie: Sendable, Hashable, Identifiable {
    /// 1-based position in the trending list (the card's "rank #").
    public let rank: Int
    public let tmdbId: String
    public let title: String
    public let posterUrl: String?
    public let year: String?
    public let genres: [String]
    /// Distinct friends who ranked this movie in the window.
    public let rankerCount: Int
    public let avgTier: String
    public let avgTierNumeric: Double
    /// ≤3 recent ranker chips (avatars + usernames).
    public let recentRankers: [FriendProfileChip]

    public var id: String { tmdbId }

    public init(rank: Int, tmdbId: String, title: String, posterUrl: String?,
                year: String?, genres: [String], rankerCount: Int, avgTier: String,
                avgTierNumeric: Double, recentRankers: [FriendProfileChip]) {
        self.rank = rank
        self.tmdbId = tmdbId
        self.title = title
        self.posterUrl = posterUrl
        self.year = year
        self.genres = genres
        self.rankerCount = rankerCount
        self.avgTier = avgTier
        self.avgTierNumeric = avgTierNumeric
        self.recentRankers = recentRankers
    }

    public var topGenres: [String] { Array(genres.prefix(2)) }
}

// MARK: - Pure aggregation

/// The deterministic core of Discover. Both entry points take already-fetched
/// rows (friends' rankings, the viewer's owned-id exclusion set, and friend
/// profiles) and produce the sorted, capped card lists — no IO. This is where
/// the whole of the §1.2 binding contract lives and is tested.
public enum DiscoverAggregation {

    /// The largest number of friend chips a card carries. Web slices the
    /// distinct-user set to 5 internally (`tasteService.ts:284, :379`) but the
    /// card only shows ≤3 (audit §1.2); iOS caps at the display count directly.
    public static let maxChips = 3

    /// Insertion-ordered de-dup preserving first-seen order — the aggregation
    /// keys a movie by first appearance, and a friend's distinct set keeps the
    /// order they were first seen in the rows (Swift `Set` is unordered, so we
    /// track order explicitly to match web's `[...userIds]` insertion order).
    private struct OrderedMovie {
        let title: String
        let posterUrl: String?
        let year: String?
        let genres: [String]
        var tiers: [Int]
        var userIds: [UUID]        // distinct, first-seen order
        var seen: Set<UUID>
    }

    /// Build the "from your friends" recommendations.
    ///
    /// Ports `getFriendRecommendations` (`tasteService.ts:242-311`):
    ///  - aggregate friends' S/A rows per movie (`tmdb_id` verbatim — canonical
    ///    `tmdb_` compare, B1 applies), collecting tier weights + distinct
    ///    rankers,
    ///  - EXCLUDE any movie whose id is in `excludedIds` (the viewer's ranked ∪
    ///    watchlisted ids, `:253`),
    ///  - `avgTier` = mean tier weight → label; `topTier` = max tier weight →
    ///    label (`:300-305`),
    ///  - build ≤`limit` results sorted friendCount DESC then avgTierNumeric
    ///    DESC (S best, `:309`),
    ///  - ≤3 friend chips per card from `profiles` (`:284-292`).
    ///
    /// `rows` should already be filtered to S/A tier by the repository query
    /// (`.in("tier", ["S","A"])`), matching web's query-side filter.
    /// `avatarURL` maps a profile → a loadable avatar URL string (injected so
    /// tests stay deterministic; production passes `FeedCards.avatarURL`).
    public static func friendRecommendations(
        rows: [DiscoverRankingRow],
        excludedIds: Set<String>,
        profiles: [DiscoverProfileRow],
        limit: Int,
        avatarURL: (DiscoverProfileRow) -> String
    ) -> [FriendRecommendation] {
        let profileByID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Aggregate per movie, first-seen order (mirrors JS Map iteration).
        var order: [String] = []
        var byMovie: [String: OrderedMovie] = [:]
        for r in rows {
            if excludedIds.contains(r.tmdbId) { continue }
            let weight = discoverTierNumeric[r.tier] ?? 3
            if var existing = byMovie[r.tmdbId] {
                existing.tiers.append(weight)
                if existing.seen.insert(r.userId).inserted {
                    existing.userIds.append(r.userId)
                }
                byMovie[r.tmdbId] = existing
            } else {
                order.append(r.tmdbId)
                byMovie[r.tmdbId] = OrderedMovie(
                    title: r.title, posterUrl: r.posterUrl, year: r.year,
                    genres: r.genres, tiers: [weight],
                    userIds: [r.userId], seen: [r.userId]
                )
            }
        }

        var results: [FriendRecommendation] = []
        for tmdbId in order {
            guard let m = byMovie[tmdbId] else { continue }
            let avg = Double(m.tiers.reduce(0, +)) / Double(m.tiers.count)
            let chips = m.userIds.prefix(maxChips).map { id -> FriendProfileChip in
                let p = profileByID[id]
                return FriendProfileChip(
                    userId: id,
                    username: p?.username ?? "",
                    avatarUrl: p.map(avatarURL) ?? avatarURL(DiscoverProfileRow(id: id, username: "", avatarPath: nil))
                )
            }
            results.append(FriendRecommendation(
                tmdbId: tmdbId,
                title: m.title,
                posterUrl: m.posterUrl,
                year: m.year,
                genres: m.genres,
                avgTier: discoverTierLabel(avg),
                avgTierNumeric: (avg * 10).rounded() / 10,
                friendCount: m.userIds.count,
                topTier: discoverNumericTier[m.tiers.max() ?? 3] ?? "C",
                friends: Array(chips)
            ))
        }

        // Sort: friendCount DESC, then avgTierNumeric DESC (S best). A stable
        // sort keeps first-seen order for full ties, matching JS's stable sort.
        results = stableSorted(results) { a, b in
            if a.friendCount != b.friendCount { return a.friendCount > b.friendCount }
            return a.avgTierNumeric > b.avgTierNumeric
        }
        return Array(results.prefix(limit))
    }

    /// Build the "trending with friends" list.
    ///
    /// Ports `getTrendingAmongFriends` (`tasteService.ts:338-398`):
    ///  - aggregate friends' recent rows per movie (recency window is applied
    ///    by the repository's `updated_at >= cutoff` query — the D13 quirk is
    ///    preserved: whole-tier `updated_at` churn can float stale rankings),
    ///  - keep only movies with ≥2 DISTINCT rankers (`:377`),
    ///  - sort rankerCount DESC then avgTierNumeric DESC (`:396`),
    ///  - assign 1-based `rank`, cap at `limit`, ≤3 ranker chips per card.
    ///
    /// `rows` are already within the recency window (repository query).
    public static func trendingAmongFriends(
        rows: [DiscoverRankingRow],
        profiles: [DiscoverProfileRow],
        limit: Int,
        minRankers: Int = 2,
        avatarURL: (DiscoverProfileRow) -> String
    ) -> [TrendingMovie] {
        let profileByID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var order: [String] = []
        var byMovie: [String: OrderedMovie] = [:]
        for r in rows {
            let weight = discoverTierNumeric[r.tier] ?? 3
            if var existing = byMovie[r.tmdbId] {
                existing.tiers.append(weight)
                if existing.seen.insert(r.userId).inserted {
                    existing.userIds.append(r.userId)
                }
                byMovie[r.tmdbId] = existing
            } else {
                order.append(r.tmdbId)
                byMovie[r.tmdbId] = OrderedMovie(
                    title: r.title, posterUrl: r.posterUrl, year: r.year,
                    genres: r.genres, tiers: [weight],
                    userIds: [r.userId], seen: [r.userId]
                )
            }
        }

        var interim: [TrendingMovie] = []
        for tmdbId in order {
            guard let m = byMovie[tmdbId] else { continue }
            // Distinct-ranker threshold: web needs ≥2 friends (`:377`).
            if m.userIds.count < minRankers { continue }
            let avg = Double(m.tiers.reduce(0, +)) / Double(m.tiers.count)
            let chips = m.userIds.prefix(maxChips).map { id -> FriendProfileChip in
                let p = profileByID[id]
                return FriendProfileChip(
                    userId: id,
                    username: p?.username ?? "",
                    avatarUrl: p.map(avatarURL) ?? avatarURL(DiscoverProfileRow(id: id, username: "", avatarPath: nil))
                )
            }
            interim.append(TrendingMovie(
                rank: 0,  // assigned after sort
                tmdbId: tmdbId,
                title: m.title,
                posterUrl: m.posterUrl,
                year: m.year,
                genres: m.genres,
                rankerCount: m.userIds.count,
                avgTier: discoverTierLabel(avg),
                avgTierNumeric: (avg * 10).rounded() / 10,
                recentRankers: Array(chips)
            ))
        }

        interim = stableSorted(interim) { a, b in
            if a.rankerCount != b.rankerCount { return a.rankerCount > b.rankerCount }
            return a.avgTierNumeric > b.avgTierNumeric
        }

        return interim.prefix(limit).enumerated().map { idx, m in
            TrendingMovie(
                rank: idx + 1,
                tmdbId: m.tmdbId, title: m.title, posterUrl: m.posterUrl,
                year: m.year, genres: m.genres, rankerCount: m.rankerCount,
                avgTier: m.avgTier, avgTierNumeric: m.avgTierNumeric,
                recentRankers: m.recentRankers
            )
        }
    }

    /// A stable sort — Swift's `sort` is NOT guaranteed stable, and both web
    /// aggregations rely on JS `Array.sort` stability (V8) to keep first-seen
    /// order for full ties. Decorate-sort-undecorate on the original index.
    private static func stableSorted<T>(_ array: [T], by areInIncreasingOrder: (T, T) -> Bool) -> [T] {
        array.enumerated()
            .sorted { lhs, rhs in
                if areInIncreasingOrder(lhs.element, rhs.element) { return true }
                if areInIncreasingOrder(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
