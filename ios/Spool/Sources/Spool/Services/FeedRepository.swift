import Foundation
import Supabase

/// Network half of the C1 feed data layer: the two feed RPCs.
///
///  - `fetchPage(mode:cursor:pageSize:)` — `get_feed_page` keyset pagination
///  - `rankingScores(pairs:)` — `get_feed_ranking_scores` batch score lookup
///
/// ⚠️ NOT CALLABLE IN PROD YET: both RPCs ship with web PR #32's migrations
/// (`20260707_feed_page_rpc.sql`, `20260707_feed_ranking_scores_rpc.sql`).
/// Until #32 merges and those migrations are applied, every call here fails
/// server-side. Unit tests therefore cover the pure layer only
/// (FeedPipeline / FeedPipelineTests); this actor's paths are exercised
/// against a real backend once #32 lands.
///
/// All client-side feed logic (mutes, type filter, milestone throttle,
/// cursor construction) lives in `FeedPipeline` — this actor only moves
/// bytes. Follows the existing repository pattern: actor + `SpoolClient.shared`
/// guard, `[FeedRepository]`-prefixed logs, errors rethrown to callers
/// (`fetchPage` propagates the RPC's raise-classified errors, e.g. 22023
/// for bad mode/cursor/page_size, so bugs fail loud instead of rendering
/// an empty feed).
public actor FeedRepository {

    public static let shared = FeedRepository()

    public enum RepoError: Error {
        case notConfigured
    }

    // MARK: - get_feed_page

    /// Fetch one raw keyset page of the boosted feed stream.
    ///
    /// Cursor contract (see FeedCursor): pass nil for the first page — both
    /// `cursor_rank` and `cursor_id` go up as EXPLICIT JSON nulls (the
    /// 4-parameter function has no argument defaults, so the keys must be
    /// present; `AnyJSON.null` encodes `encodeNil()`). Next pages echo the
    /// last consumed row's server-returned `(boosted_ts, id)` verbatim.
    /// `pageSize` is forwarded untouched; the RPC raises 22023 outside 1...100.
    public func fetchPage(mode: FeedMode,
                          cursor: FeedCursor?,
                          pageSize: Int = 20) async throws -> [FeedEventRow] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        let params: [String: AnyJSON] = [
            "mode": .string(mode.rawValue),
            "cursor_rank": cursor.map { .string($0.boostedTs) } ?? .null,
            "cursor_id": cursor.map { .string($0.id.uuidString.lowercased()) } ?? .null,
            "page_size": .integer(pageSize),
        ]

        do {
            return try await client
                .rpc("get_feed_page", params: params)
                .execute()
                .value
        } catch {
            NSLog("[FeedRepository] fetchPage(\(mode.rawValue)) failed: \(error)")
            throw error
        }
    }

    // MARK: - get_feed_ranking_scores

    /// Batch live-score lookup for ranking/review cards. One round trip for
    /// the whole page. Returns a map keyed `"<lowercase uuid>:<tmdbId>"`
    /// (`FeedPipeline.scoreKey` — web's `${userId}:${tmdbId}`); a pair with
    /// no visible ranking returns no row, so a missing key means "no score,
    /// hide the badge". Pairs are deduped before the call (web parity).
    public func rankingScores(pairs: [(userID: UUID, tmdbID: String)]) async throws -> [String: Double] {
        guard !pairs.isEmpty else { return [:] }
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }

        var seen = Set<String>()
        var rpcPairs: [ScorePairPayload] = []
        for pair in pairs {
            let key = FeedPipeline.scoreKey(userID: pair.userID, tmdbID: pair.tmdbID)
            guard seen.insert(key).inserted else { continue }
            // Lowercase uuid strings on the wire — same bytes web sends.
            rpcPairs.append(ScorePairPayload(user_id: pair.userID.uuidString.lowercased(),
                                             tmdb_id: pair.tmdbID))
        }

        do {
            let rows: [ScoreRow] = try await client
                .rpc("get_feed_ranking_scores", params: ScoresParams(pairs: rpcPairs))
                .execute()
                .value
            var map: [String: Double] = [:]
            map.reserveCapacity(rows.count)
            for row in rows {
                map[FeedPipeline.scoreKey(userID: row.user_id, tmdbID: row.tmdb_id)] = row.score
            }
            return map
        } catch {
            NSLog("[FeedRepository] rankingScores failed: \(error)")
            throw error
        }
    }
}

// MARK: - Wire payloads (snake_case = wire format)

private struct ScoresParams: Encodable {
    let pairs: [ScorePairPayload]
}

private struct ScorePairPayload: Encodable {
    let user_id: String
    let tmdb_id: String
}

/// One `get_feed_ranking_scores` result row.
private struct ScoreRow: Decodable {
    let user_id: UUID
    let tmdb_id: String
    let score: Double
}
