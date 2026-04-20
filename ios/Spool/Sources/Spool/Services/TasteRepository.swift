import Foundation
import Supabase

/// Computes viewer↔target taste compatibility. Mirrors
/// `services/tasteService.ts`:
///
///  - `getTasteCompatibility(viewerID:targetID:)` — full breakdown for
///    TwinScreen (overall %, shared/you-only/them-only counts, top shared,
///    biggest fights).
///  - `getCompatibilityScores(viewerID:targetIDs:)` — batch score-only for
///    FriendsScreen (avoids N+1; replaces N single calls with one per
///    participant).
///  - `getRecommendationsForFriend(viewerID:targetID:limit:)` — viewer's
///    S/A rankings the target hasn't ranked or added to their watchlist.
///    Feeds the "recommend to @friend" row on TwinScreen.
///
/// Scoring mirrors the web exactly so an iOS twin % matches the web twin %
/// for the same pair.
///
/// Header last reviewed: 2026-04-19
public actor TasteRepository {

    public static let shared = TasteRepository()

    public enum RepoError: Error {
        case notConfigured
    }

    // MARK: single-pair

    /// Full compatibility breakdown. Returns `nil` only when reads fail;
    /// a pair with zero shared movies returns a populated object with
    /// `score = 0` and empty arrays.
    public func getTasteCompatibility(viewerID: UUID, targetID: UUID) async throws -> TasteCompatibility {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        async let viewerRows: [TasteRankingRow] = client
            .from("user_rankings")
            .select("tmdb_id, title, poster_url, tier")
            .eq("user_id", value: viewerID.uuidString)
            .execute()
            .value
        async let targetRows: [TasteRankingRow] = client
            .from("user_rankings")
            .select("tmdb_id, title, poster_url, tier")
            .eq("user_id", value: targetID.uuidString)
            .execute()
            .value

        let (viewer, target) = try await (viewerRows, targetRows)
        return Self.compute(viewer: viewer, target: target, targetID: targetID)
    }

    // MARK: batch

    /// One query over `viewer ∪ targetIDs`, grouped in Swift. Returns a
    /// score in [0, 100] keyed by target ID. Targets with zero shared
    /// rankings are present with score = 0.
    public func getCompatibilityScores(viewerID: UUID, targetIDs: [UUID]) async throws -> [UUID: Int] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard !targetIDs.isEmpty else { return [:] }

        let allIDs = ([viewerID] + targetIDs).map { $0.uuidString }
        let rows: [TasteBatchRow] = try await client
            .from("user_rankings")
            .select("user_id, tmdb_id, tier")
            .in("user_id", values: allIDs)
            .execute()
            .value

        // Bucket by user so we can cross the viewer's set against each target.
        var byUser: [UUID: [String: String]] = [:]  // userID → (tmdbID → tier)
        for row in rows {
            byUser[row.user_id, default: [:]][row.tmdb_id] = row.tier
        }
        let viewerMap = byUser[viewerID] ?? [:]

        var scores: [UUID: Int] = [:]
        scores.reserveCapacity(targetIDs.count)
        for targetID in targetIDs {
            let targetMap = byUser[targetID] ?? [:]
            scores[targetID] = Self.overallScore(viewer: viewerMap, target: targetMap)
        }
        return scores
    }

    // MARK: recs

    /// Viewer's S/A-tier picks the target hasn't ranked or watchlisted.
    /// Ordered by tier (S first) then rank_position, capped at `limit`.
    public func getRecommendationsForFriend(
        viewerID: UUID, targetID: UUID, limit: Int = 4
    ) async throws -> [RecommendedMovie] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        async let viewerPicks: [TasteRankingRow] = client
            .from("user_rankings")
            .select("tmdb_id, title, poster_url, tier, rank_position")
            .eq("user_id", value: viewerID.uuidString)
            .in("tier", values: ["S", "A"])
            .order("tier", ascending: true)            // S before A (dict order)
            .order("rank_position", ascending: true)
            .execute()
            .value
        async let targetRankedIDs: [TasteIDRow] = client
            .from("user_rankings")
            .select("tmdb_id")
            .eq("user_id", value: targetID.uuidString)
            .execute()
            .value
        async let targetWatchlistIDs: [TasteIDRow] = client
            .from("watchlist_items")
            .select("tmdb_id")
            .eq("user_id", value: targetID.uuidString)
            .execute()
            .value

        let (picks, ranked, watchlist) = try await (viewerPicks, targetRankedIDs, targetWatchlistIDs)
        var excluded = Set<String>()
        for row in ranked { excluded.insert(row.tmdb_id) }
        for row in watchlist { excluded.insert(row.tmdb_id) }

        var out: [RecommendedMovie] = []
        for pick in picks where !excluded.contains(pick.tmdb_id) {
            guard let tier = Tier(rawValue: pick.tier) else { continue }
            out.append(RecommendedMovie(
                tmdbId: pick.tmdb_id,
                title: pick.title,
                posterUrl: pick.poster_url,
                tier: tier
            ))
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: scoring

    /// Tier → numeric weight (matches `TIER_NUMERIC` in tasteService.ts).
    private static let tierScore: [String: Int] = ["S": 5, "A": 4, "B": 3, "C": 2, "D": 1]

    /// Build a full `TasteCompatibility` from already-fetched ranking arrays.
    private static func compute(
        viewer: [TasteRankingRow], target: [TasteRankingRow], targetID: UUID
    ) -> TasteCompatibility {
        var viewerMap: [String: TasteRankingRow] = [:]
        for r in viewer { viewerMap[r.tmdb_id] = r }
        var targetMap: [String: TasteRankingRow] = [:]
        for r in target { targetMap[r.tmdb_id] = r }

        let sharedIDs = viewerMap.keys.filter { targetMap[$0] != nil }

        if sharedIDs.isEmpty {
            return TasteCompatibility(
                targetUserId: targetID,
                score: 0,
                sharedCount: 0,
                viewerOnlyCount: viewer.count,
                targetOnlyCount: target.count,
                agreements: 0, nearAgreements: 0, disagreements: 0,
                topShared: [], biggestFights: []
            )
        }

        var agreements = 0
        var nearAgreements = 0
        var disagreements = 0
        var scores: [Int] = []
        var decorated: [(row: SharedMovie, distance: Int)] = []

        for id in sharedIDs {
            guard let v = viewerMap[id], let t = targetMap[id] else { continue }
            let vScore = tierScore[v.tier] ?? 3
            let tScore = tierScore[t.tier] ?? 3
            let distance = abs(vScore - tScore)

            switch distance {
            case 0: agreements += 1; scores.append(100)
            case 1: nearAgreements += 1; scores.append(60)
            case 2: disagreements += 1; scores.append(20)
            default: disagreements += 1; scores.append(0)
            }

            let viewerTier = Tier(rawValue: v.tier) ?? .B
            let targetTier = Tier(rawValue: t.tier) ?? .B
            decorated.append((
                row: SharedMovie(
                    tmdbId: id,
                    title: v.title,
                    posterUrl: v.poster_url,
                    viewerTier: viewerTier,
                    targetTier: targetTier,
                    tierDelta: vScore - tScore
                ),
                distance: distance
            ))
        }

        let overall = scores.isEmpty ? 0 : Int((Double(scores.reduce(0, +)) / Double(scores.count)).rounded())

        let topShared = decorated
            .filter { $0.distance == 0 }
            .sorted { (tierScore[$0.row.viewerTier.rawValue] ?? 0) > (tierScore[$1.row.viewerTier.rawValue] ?? 0) }
            .prefix(5)
            .map(\.row)

        let biggestFights = decorated
            .sorted { $0.distance > $1.distance }
            .prefix(5)
            .map(\.row)
            .filter { $0.tierDelta != 0 }

        let viewerOnly = viewerMap.count - sharedIDs.count
        let targetOnly = targetMap.count - sharedIDs.count

        return TasteCompatibility(
            targetUserId: targetID,
            score: overall,
            sharedCount: sharedIDs.count,
            viewerOnlyCount: viewerOnly,
            targetOnlyCount: targetOnly,
            agreements: agreements,
            nearAgreements: nearAgreements,
            disagreements: disagreements,
            topShared: Array(topShared),
            biggestFights: Array(biggestFights)
        )
    }

    /// Overall score for the batch path. Same math as `compute`, minus the
    /// per-row list building.
    private static func overallScore(viewer: [String: String], target: [String: String]) -> Int {
        var total = 0
        var count = 0
        for (id, vTier) in viewer {
            guard let tTier = target[id] else { continue }
            let v = tierScore[vTier] ?? 3
            let t = tierScore[tTier] ?? 3
            let distance = abs(v - t)
            let s: Int
            switch distance {
            case 0: s = 100
            case 1: s = 60
            case 2: s = 20
            default: s = 0
            }
            total += s
            count += 1
        }
        guard count > 0 else { return 0 }
        return Int((Double(total) / Double(count)).rounded())
    }
}

// MARK: - DTOs

private struct TasteRankingRow: Decodable, Sendable {
    let tmdb_id: String
    let title: String
    let poster_url: String?
    let tier: String
    let rank_position: Int?
}

private struct TasteBatchRow: Decodable, Sendable {
    let user_id: UUID
    let tmdb_id: String
    let tier: String
}

private struct TasteIDRow: Decodable, Sendable {
    let tmdb_id: String
}

// MARK: - Public result types

/// One movie both viewer and target have ranked.
public struct SharedMovie: Sendable, Hashable {
    public let tmdbId: String
    public let title: String
    public let posterUrl: String?
    public let viewerTier: Tier
    public let targetTier: Tier
    /// Signed difference: positive means viewer rates higher.
    public let tierDelta: Int
}

/// One movie the viewer ranked S/A that the target hasn't seen.
public struct RecommendedMovie: Sendable, Hashable, Identifiable {
    public var id: String { tmdbId }
    public let tmdbId: String
    public let title: String
    public let posterUrl: String?
    public let tier: Tier
}

/// Full viewer↔target taste comparison. Score is [0, 100].
public struct TasteCompatibility: Sendable, Hashable {
    public let targetUserId: UUID
    public let score: Int
    public let sharedCount: Int
    public let viewerOnlyCount: Int
    public let targetOnlyCount: Int
    public let agreements: Int
    public let nearAgreements: Int
    public let disagreements: Int
    public let topShared: [SharedMovie]
    public let biggestFights: [SharedMovie]
}
