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

    /// Full compatibility breakdown. Read failures are thrown (the signature
    /// already requires `throws`) — this method never returns nil. A pair
    /// with zero shared movies returns a populated `TasteCompatibility`
    /// with `score = 0` and empty arrays, so callers can render a
    /// "no overlap yet" state without nil-handling the result itself.
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

        // PostgREST encodes `.in(...)` as a URL query param — a large
        // targetIDs list can blow past URL-length limits around 2KB. Chunk
        // the set into batches; include the viewer in every batch so the
        // viewer's rankings are always available in-memory when the last
        // batch resolves, no matter which one finishes first.
        let targetChunks = targetIDs.chunked(into: 200)
        var byUser: [UUID: [String: String]] = [:]  // userID → (tmdbID → tier)

        for chunk in targetChunks {
            let ids = ([viewerID] + chunk).map { $0.uuidString }
            let rows: [TasteBatchRow] = try await client
                .from("user_rankings")
                .select("user_id, tmdb_id, tier")
                .in("user_id", values: ids)
                .execute()
                .value
            for row in rows {
                byUser[row.user_id, default: [:]][row.tmdb_id] = row.tier
            }
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

        // Previously used `.order("tier", ascending: true)` expecting
        // "S before A", but lexicographic sort puts A first ('A' < 'S').
        // Drop DB-side tier ordering and sort in Swift below with the
        // numeric tier weights so S genuinely outranks A.
        async let viewerPicks: [TasteRankingRow] = client
            .from("user_rankings")
            .select("tmdb_id, title, poster_url, tier, rank_position")
            .eq("user_id", value: viewerID.uuidString)
            .in("tier", values: ["S", "A"])
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

        // Sort client-side: tier score descending (S > A), break ties on
        // rank_position ascending (best rank first). Drops picks whose tier
        // string doesn't decode.
        let sorted = picks
            .filter { Tier(rawValue: $0.tier) != nil }
            .sorted { lhs, rhs in
                let ls = Self.tierScore[lhs.tier] ?? 0
                let rs = Self.tierScore[rhs.tier] ?? 0
                if ls != rs { return ls > rs }
                return (lhs.rank_position ?? 0) < (rhs.rank_position ?? 0)
            }

        var out: [RecommendedMovie] = []
        for pick in sorted where !excluded.contains(pick.tmdb_id) {
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

            let s = distanceScore(distance)
            scores.append(s)
            switch distance {
            case 0:  agreements += 1
            case 1:  nearAgreements += 1
            default: disagreements += 1
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

        // Filter zero-delta "non-fights" BEFORE taking the top 5 — otherwise
        // a compat pair with lots of perfect agreements and a few real
        // fights could end up showing fewer than 5 actual fights because
        // the prefix slot got consumed by tier-matching rows.
        let biggestFights = decorated
            .filter { $0.row.tierDelta != 0 }
            .sorted { $0.distance > $1.distance }
            .prefix(5)
            .map(\.row)

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
            total += distanceScore(abs(v - t))
            count += 1
        }
        guard count > 0 else { return 0 }
        return Int((Double(total) / Double(count)).rounded())
    }

    /// Tier-distance → 0-100 compatibility weight. Same mapping used by
    /// both `overallScore` (batch path) and `compute` (full-breakdown
    /// path) — lifted out so the two can't drift. Mirrors web's
    /// distance weighting in `tasteService.ts`.
    private static func distanceScore(_ distance: Int) -> Int {
        switch distance {
        case 0:  return 100   // tier match
        case 1:  return 60    // one tier apart
        case 2:  return 20    // two tiers apart
        default: return 0     // tiers or more apart
        }
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

// MARK: - Array chunking

private extension Array {
    /// Split into consecutive chunks of at most `size` elements. Used to
    /// keep PostgREST `.in()` params under URL-length limits.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
