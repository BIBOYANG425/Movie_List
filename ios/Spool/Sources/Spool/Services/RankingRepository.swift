import Foundation
import Supabase

/// End-to-end ranking writes: `user_rankings` + `activity_events`.
/// (`movie_stubs` writes live in `StubWriter`; the read side keeps `StubRow`
/// defined below.) Actor so state (the client reference) stays isolated.
/// Reads/writes all go through supabase-swift, RLS enforces scoping at the
/// DB layer.
///
/// When `SpoolClient.shared` is nil (no credentials configured) every method
/// throws `.notConfigured` and the caller is expected to fall back to fixtures.
public actor RankingRepository {

    public static let shared = RankingRepository()

    public enum RepoError: Error {
        case notConfigured
        case notAuthenticated
    }

    // MARK: reads

    public func getTierItems(tier: Tier) async throws -> [RankingRow] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let rows: [RankingRow] = try await client
            .from("user_rankings")
            .select()
            .eq("user_id", value: userID.uuidString)
            .eq("tier", value: tier.rawValue)
            .order("rank_position", ascending: true)
            .execute()
            .value
        return rows
    }

    /// Search TMDB for movies matching `query`. Returns `[]` when `TMDB_API_KEY`
    /// is missing. Does not require a Supabase session — this is a pure API call.
    public func searchMovies(query: String) async -> [TMDBMovie] {
        await TMDBService.searchMovies(query: query)
    }

    /// All rankings for the signed-in user, across every tier. Used by the
    /// `SpoolRankingEngine` so it can compute prediction signals (genre +
    /// bracket averages) and walk the in-tier comparison graph.
    public func getAllRankedItems() async throws -> [RankedItem] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let rows: [RankingRow] = try await client
            .from("user_rankings")
            .select()
            .eq("user_id", value: userID.uuidString)
            .order("rank_position", ascending: true)
            .execute()
            .value
        return rows.compactMap(Self.rowToRankedItem)
    }

    private static func rowToRankedItem(_ row: RankingRow) -> RankedItem? {
        guard let tier = Tier(rawValue: row.tier) else { return nil }
        let yearInt = row.year.flatMap { Int($0) }
        let bracket = RankingAlgorithm.classifyBracket(genres: row.genres)
        return RankedItem(
            id: row.tmdb_id, title: row.title, year: yearInt,
            director: row.director ?? "—",
            genres: row.genres, tier: tier, rank: row.rank_position,
            bracket: bracket, globalScore: nil, seed: 0,
            posterUrl: row.poster_url
        )
    }

    // MARK: feed

    /// Returns the current user's most recent activity events (rankings they
    /// added) — newest first, up to `limit`. Used by the main feed when a
    /// Supabase session is active; otherwise the feed renders fixtures.
    public func getRecentActivity(limit: Int = 40) async throws -> [ActivityEventRow] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let rows: [ActivityEventRow] = try await client
            .from("activity_events")
            .select()
            .eq("actor_id", value: userID.uuidString)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows
    }

    // MARK: writes

    // REVIEW FOLLOW-UP: insert serialization relies on callers' sequential await loops
    // (OnboardingQueue flush / OnboardingFlow) — this actor is REENTRANT and does NOT
    // itself serialize the read-splice-upsert-RPC sequence. Do not parallelize flush.

    /// Insert (or re-rank) a `user_rankings` row with SPLICE semantics, then an
    /// accompanying `activity_events` row.
    ///
    /// B5 fix (audit): the old path wrote the new row at `ranking.rankPosition`
    /// WITHOUT renumbering the rest of the tier, so every iOS rank minted a
    /// duplicate position and the tier's `rank_position` column drifted out of
    /// the contiguous-0..n-1 invariant. The new flow splices the tier through
    /// the `set_tier_order` RPC:
    ///   1. fetch the target tier's ordered `tmdb_id`s (existing membership),
    ///   2. pure-splice the new id at the clamped `rankPosition`
    ///      (`spliceTierOrder` — re-ranks move the existing id, no duplicate),
    ///   3. UPSERT the new/re-ranked row on `(user_id, tmdb_id)` — the row must
    ///      exist BEFORE the RPC, which is UPDATE-only and skips unknown ids,
    ///   4. `rpc('set_tier_order', p_media, tier, splicedIds)` to renumber the
    ///      WHOLE tier to a gap-free, dup-free 0..n-1.
    ///
    /// Failure posture: a failed RPC AFTER a successful upsert logs loudly but
    /// does NOT throw the ceremony into failure — the row landed, so the rank
    /// is saved; the tier's positions self-heal on the next tier write (any
    /// add/re-rank re-splices the whole membership). Throwing here would surface
    /// a "save failed" toast for a rank that actually persisted.
    ///
    /// Both writes run sequentially, not in a transaction — the DB considers
    /// them independent. RLS enforces `auth.uid() = user_id` on every table.
    public func insertRanking(_ ranking: RankingInsert) async throws -> RankingRow {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let table = Self.rankingsTable(forType: ranking.type)
        let pMedia = Self.pMedia(forType: ranking.type)

        // Step 1: read the target tier's current membership (best-first). Empty
        // when the tier is fresh or on a read hiccup — the splice then yields a
        // single-element list, which is exactly right for a first-in-tier add.
        let existingIds: [String]
        do {
            let rows: [TierIdRow] = try await client
                .from(table)
                .select("tmdb_id")
                .eq("user_id", value: userID.uuidString)
                .eq("tier", value: ranking.tier.rawValue)
                .order("rank_position", ascending: true)
                .execute()
                .value
            existingIds = rows.map(\.tmdb_id)
        } catch {
            // A failed membership read must not block the save. Fall back to an
            // empty membership: the row still upserts and the RPC compacts what
            // it can; the tier fully self-heals on the next successful write.
            print("[RankingRepository] tier membership read failed for \(pMedia)/\(ranking.tier.rawValue): \(error)")
            existingIds = []
        }

        // Step 2: pure splice — new id at the clamped position, re-ranks move
        // the existing id rather than duplicating it.
        let splicedIds = Self.spliceTierOrder(
            existingIds, newId: ranking.tmdbId, at: ranking.rankPosition
        )

        let payload = RankingPayload(
            user_id: userID,
            tmdb_id: ranking.tmdbId,
            title: ranking.title,
            year: ranking.year,
            poster_url: ranking.posterURL,
            type: ranking.type,
            genres: ranking.genres,
            director: ranking.director,
            tier: ranking.tier.rawValue,
            rank_position: ranking.rankPosition,
            notes: ranking.notes
        )

        // Step 3: UPSERT on (user_id, tmdb_id) so an iOS re-rank of an already-
        // ranked item replaces its row instead of failing the unique key. The
        // row MUST exist before the RPC (UPDATE-only) — this is that insert.
        let inserted: RankingRow = try await client
            .from(table)
            .upsert(payload, onConflict: "user_id,tmdb_id")
            .select()
            .single()
            .execute()
            .value

        // Step 4: renumber the WHOLE tier to contiguous 0..n-1 via the RPC. A
        // failure here logs loudly but does NOT throw — the row already landed;
        // positions self-heal on the next tier write (see method doc).
        do {
            _ = try await client
                .rpc("set_tier_order", params: SetTierOrderParams(
                    p_media: pMedia, p_tier: ranking.tier.rawValue, p_tmdb_ids: splicedIds
                ))
                .execute()
        } catch {
            print("[RankingRepository] set_tier_order failed after insert (\(pMedia)/\(ranking.tier.rawValue)); positions self-heal on next tier write: \(error)")
        }

        let event = ActivityEventPayload(
            actor_id: userID,
            event_type: "ranking_add",
            target_user_id: nil,
            media_tmdb_id: ranking.tmdbId,
            media_title: ranking.title,
            media_tier: ranking.tier.rawValue,
            media_poster_url: ranking.posterURL,
            metadata: ActivityMetadata(
                notes: ranking.notes,
                year: ranking.year,
                watchedWithUserIds: ranking.watchedWithUserIds
            )
        )
        // Fire-and-forget telemetry — the ranking itself already landed, so
        // we don't want a feed-insert hiccup to surface a user-facing toast.
        // Log so failures show up in device logs for triage.
        do {
            _ = try await client.from("activity_events").insert(event).execute()
        } catch {
            print("activity_events insert failed: \(error)")
        }

        return inserted
    }

    // MARK: - splice + media mapping (pure, testable — no client, no I/O)

    /// Compute the target tier's FULL intended membership after inserting (or
    /// re-ranking) `newId` at `at`. Pure + total: the result is what the
    /// `set_tier_order` RPC needs (an ordered id list it compacts to 0..n-1).
    ///
    /// Semantics:
    ///  - `at` is CLAMPED to `0...ids.count` (of the list with `newId` removed),
    ///    so a stale/out-of-range `rankPosition` can never gap or crash.
    ///  - Re-rank (id already present): the existing occurrence is REMOVED first,
    ///    then the id is spliced at the clamped index — the id moves, it never
    ///    duplicates. (The RPC also dedups on first occurrence as a backstop, but
    ///    de-duping here keeps the array itself honest and the tests explicit.)
    public static func spliceTierOrder(_ ids: [String], newId: String, at: Int) -> [String] {
        var out = ids.filter { $0 != newId }
        let index = min(max(at, 0), out.count)
        out.insert(newId, at: index)
        return out
    }

    /// `p_media` value for the `set_tier_order` RPC, derived from a
    /// `RankingInsert.type` (`"movie" | "tv" | "book"`). Unknown types fall back
    /// to `"movie"` (the movie table is the default ranking surface); the RPC
    /// itself RAISEs on a genuinely invalid value, so a bad type surfaces as a
    /// logged RPC failure rather than silent corruption.
    static func pMedia(forType type: String) -> String {
        switch type {
        case "tv": return "tv"
        case "book": return "book"
        default: return "movie"
        }
    }

    /// Postgres table backing each media type. Mirrors `pMedia`'s branches so
    /// the tier-membership read and the RPC always target the same table.
    static func rankingsTable(forType type: String) -> String {
        switch type {
        case "tv": return "tv_rankings"
        case "book": return "book_rankings"
        default: return "user_rankings"
        }
    }
}

// MARK: - DTOs (wire format, snake_case to match Postgres)

public struct RankingInsert: Sendable {
    public let tmdbId: String
    public let title: String
    public let year: String?
    public let posterURL: String?
    public let type: String            // "movie" | "tv" | "book"
    public let genres: [String]
    public let director: String?
    public let tier: Tier
    public let rankPosition: Int
    public let notes: String?
    /// Ceremony friends for the activity-event metadata. Defaults nil —
    /// no caller wires this yet (C-later plumbs the picker through).
    public let watchedWithUserIds: [UUID]?

    public init(tmdbId: String, title: String, year: String?, posterURL: String?,
                type: String = "movie", genres: [String] = [], director: String? = nil,
                tier: Tier, rankPosition: Int, notes: String? = nil,
                watchedWithUserIds: [UUID]? = nil) {
        self.tmdbId = tmdbId
        self.title = title
        self.year = year
        self.posterURL = posterURL
        self.type = type
        self.genres = genres
        self.director = director
        self.tier = tier
        self.rankPosition = rankPosition
        self.notes = notes
        self.watchedWithUserIds = watchedWithUserIds
    }
}

public struct RankingRow: Codable, Sendable, Hashable {
    public let id: UUID
    public let user_id: UUID
    public let tmdb_id: String
    public let title: String
    public let year: String?
    public let poster_url: String?
    public let type: String
    public let genres: [String]
    public let director: String?
    public let tier: String
    public let rank_position: Int
    public let notes: String?
}

public struct ActivityEventRow: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let actor_id: UUID
    public let event_type: String
    public let media_tmdb_id: String?
    public let media_title: String?
    public let media_tier: String?
    public let media_poster_url: String?
    public let created_at: String
}

public struct StubRow: Codable, Sendable, Hashable {
    public let id: UUID
    public let user_id: UUID
    public let media_type: String
    public let tmdb_id: String
    public let title: String
    public let poster_path: String?
    public let tier: String
    public let watched_date: String
    public let mood_tags: [String]
    public let stub_line: String?
    public let palette: [String]
    public let template_id: String
}

// MARK: - Decodable helper rows

/// Projection of a single `tmdb_id` cell — used by `insertRanking`'s
/// tier-membership read (`select("tmdb_id")`).
private struct TierIdRow: Decodable {
    let tmdb_id: String
}

// MARK: - Encodable payloads (snake_case fields for PostgREST)

/// `set_tier_order(p_media text, p_tier text, p_tmdb_ids text[])` params.
/// Keys are the RPC's exact parameter names (PostgREST maps JSON keys →
/// function args by name). Ids are passed VERBATIM — composite TV ids
/// (`tv_{id}_s{n}`) are matched as text by the RPC, so no transformation.
private struct SetTierOrderParams: Encodable {
    let p_media: String
    let p_tier: String
    let p_tmdb_ids: [String]
}

private struct RankingPayload: Encodable {
    let user_id: UUID
    let tmdb_id: String
    let title: String
    let year: String?
    let poster_url: String?
    let type: String
    let genres: [String]
    let director: String?
    let tier: String
    let rank_position: Int
    let notes: String?
}

private struct ActivityEventPayload: Encodable {
    let actor_id: UUID
    let event_type: String
    let target_user_id: UUID?
    let media_tmdb_id: String?
    let media_title: String?
    let media_tier: String?
    let media_poster_url: String?
    let metadata: ActivityMetadata
}

/// `activity_events.metadata` for `ranking_add` — contract object
/// `{ notes?, year?, watched_with_user_ids? }`. Every key is OMITTED
/// entirely when its member is nil/empty (never null-valued, never an
/// empty string/array); an all-falsy value encodes `{}`. Synthesized
/// Encodable can't omit-empty, hence the custom `encode(to:)`. UUIDs
/// encode as lowercase strings (web parity; Swift's UUID uppercases).
public struct ActivityMetadata: Encodable, Equatable {
    public let notes: String?
    public let year: String?
    public let watchedWithUserIds: [UUID]?

    public init(notes: String? = nil, year: String? = nil,
                watchedWithUserIds: [UUID]? = nil) {
        self.notes = notes
        self.year = year
        self.watchedWithUserIds = watchedWithUserIds
    }

    private enum CodingKeys: String, CodingKey {
        case notes
        case year
        case watchedWithUserIds = "watched_with_user_ids"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let notes, !notes.isEmpty {
            try container.encode(notes, forKey: .notes)
        }
        if let year, !year.isEmpty {
            try container.encode(year, forKey: .year)
        }
        if let ids = watchedWithUserIds, !ids.isEmpty {
            try container.encode(ids.map { $0.uuidString.lowercased() },
                                 forKey: .watchedWithUserIds)
        }
    }
}
