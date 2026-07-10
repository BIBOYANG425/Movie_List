import Foundation
import Supabase

/// End-to-end ranking writes: `user_rankings` + `activity_events`, plus the
/// C4 management ops (reorder / cross-tier move / notes edit / delete). All
/// tier-position writes go through the `set_tier_order` RPC on a FULL intended
/// membership computed by the pure `TierOrder` helpers (source of truth:
/// `docs/contracts/shared-payloads.md` § `user_rankings ordering`; web
/// `services/tierOrder.ts`). (`movie_stubs` writes live in `StubWriter`; the
/// read side keeps `StubRow` defined below.) Actor so state (the client
/// reference) stays isolated. Reads/writes all go through supabase-swift, RLS
/// enforces scoping at the DB layer.
///
/// Event emission is NOT the C4 management ops' job: `reorderTier` /
/// `moveRanking` / `updateNotes` / `deleteRanking` are pure data ops and the
/// C4 UI wires their `ranking_move` / `ranking_remove` events on top.
/// `insertRanking` is the ONE exception — it owns the ceremony's
/// `ranking_add` / `ranking_move` emission because the fresh-vs-re-rank
/// decision is a DB fact only it observes (the pre-read of the existing
/// `(user_id, tmdb_id)` row). It pre-reads that row's tier, and on a re-rank
/// into a DIFFERENT tier ALSO compacts the source tier (membership minus the
/// id) so no gap is left, mirroring web `handleAddItem`'s source-tier
/// compaction (`pages/RankingAppPage.tsx`). The event type + metadata flow
/// from the pure `CeremonyEmission.decide` seam so the branch is unit-tested
/// with zero network; the method returns an `InsertOutcome` (`.inserted` vs
/// `.moved(fromTier:)`) so callers can observe what happened.
///
/// When `SpoolClient.shared` is nil (no credentials configured) every method
/// throws `.notConfigured` and the caller is expected to fall back to fixtures.
///
/// Header last reviewed: 2026-07-09
public actor RankingRepository {

    public static let shared = RankingRepository()

    public enum RepoError: Error {
        case notConfigured
        case notAuthenticated
    }

    /// What `insertRanking` actually did, observable by the caller.
    /// - `.inserted`: no prior `(user_id, tmdb_id)` row existed — a FRESH rank,
    ///   emitted as `ranking_add`.
    /// - `.moved(fromTier:)`: a row already existed — a RE-RANK, emitted as
    ///   `ranking_move`. `fromTier` is the row's tier BEFORE this write; when it
    ///   differs from the target tier the source tier was compacted.
    public enum InsertOutcome: Sendable, Equatable {
        case inserted
        case moved(fromTier: String)
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
    /// accompanying `activity_events` row. Returns an `InsertOutcome` so the
    /// caller can observe whether this was a fresh add or a re-rank.
    ///
    /// B5 fix (audit): the old path wrote the new row at `ranking.rankPosition`
    /// WITHOUT renumbering the rest of the tier, so every iOS rank minted a
    /// duplicate position and the tier's `rank_position` column drifted out of
    /// the contiguous-0..n-1 invariant. The flow splices the tier through the
    /// `set_tier_order` RPC:
    ///   0. PRE-READ the existing `(user_id, tmdb_id)` row (its tier). Its
    ///      presence is the fresh-vs-re-rank fact that drives the emission and
    ///      the source-tier compaction below — nothing else can observe it.
    ///   1. fetch the target tier's ordered `tmdb_id`s (existing membership),
    ///   2. pure-splice the new id at the clamped `rankPosition`
    ///      (`spliceTierOrder` — re-ranks move the existing id, no duplicate),
    ///   3. UPSERT the new/re-ranked row on `(user_id, tmdb_id)` — the row must
    ///      exist BEFORE the RPC, which is UPDATE-only and skips unknown ids,
    ///   4. `rpc('set_tier_order', p_media, tier, splicedIds)` to renumber the
    ///      WHOLE tier to a gap-free, dup-free 0..n-1,
    ///   5. RE-RANK CROSS-TIER ONLY: compact the SOURCE tier (its full
    ///      membership minus the departed id) via a second `set_tier_order`, so
    ///      the old tier is left gap-free instead of self-healing later. This
    ///      closes the ledgered C4 deviation (source-gap + wrong event type);
    ///      mirrors web `handleAddItem` (`pages/RankingAppPage.tsx`).
    ///   6. emit ONE activity event: `ranking_move` on a re-rank (metadata
    ///      `{notes?, year?}`, NEVER watched-with), `ranking_add` on a fresh
    ///      insert (metadata may carry watched-with). The event type + metadata
    ///      come from the pure `CeremonyEmission.decide` seam.
    ///
    /// Failure posture: a failed RPC AFTER a successful upsert logs loudly but
    /// does NOT throw the ceremony into failure — the row landed, so the rank
    /// is saved; the tier's positions self-heal on the next tier write (any
    /// add/re-rank re-splices the whole membership). Throwing here would surface
    /// a "save failed" toast for a rank that actually persisted. Same posture on
    /// the source-tier compaction (step 5) and the pre-read (step 0): a pre-read
    /// hiccup degrades to "treat as fresh" — worst case an over-broad
    /// `ranking_add` and a self-healing source gap, never a lost save.
    ///
    /// All writes run sequentially, not in a transaction — the DB considers
    /// them independent. RLS enforces `auth.uid() = user_id` on every table.
    @discardableResult
    public func insertRanking(_ ranking: RankingInsert) async throws -> InsertOutcome {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }

        let table = Self.rankingsTable(forType: ranking.type)
        let pMedia = Self.pMedia(forType: ranking.type)

        // Step 0: PRE-READ the existing row for (user_id, tmdb_id). Its tier (if
        // any) is the fresh-vs-re-rank fact that drives BOTH the emission
        // (add vs move) and the source-tier compaction. A read hiccup degrades
        // to nil = "treat as fresh" — never blocks the save.
        let existingTier: String?
        do {
            let priorRows: [TierIdRow] = try await client
                .from(table)
                .select("tmdb_id,tier")
                .eq("user_id", value: userID.uuidString)
                .eq("tmdb_id", value: ranking.tmdbId)
                .limit(1)
                .execute()
                .value
            existingTier = priorRows.first?.tier
        } catch {
            print("[RankingRepository] prior-row read failed for \(pMedia)/\(ranking.tmdbId); treating as fresh insert: \(error)")
            existingTier = nil
        }

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

        // Step 5: RE-RANK CROSS-TIER — compact the SOURCE tier so it is left
        // gap-free (full membership minus the departed id). Only when a prior
        // row existed in a DIFFERENT tier; a same-tier re-rank was already
        // fully compacted by step 4, and a fresh insert has no source tier.
        // Reads the source tier's LIVE membership (best-first) so a stale caller
        // snapshot can't orphan rows. Same fire-and-forget posture as step 4.
        if let fromTier = existingTier, fromTier != ranking.tier.rawValue {
            do {
                let sourceIds = try await Self.tierMembership(
                    client: client, table: table, userID: userID, tier: fromTier
                )
                let compacted = TierOrder.tierOrderAfterRemoval(sourceIds, removedId: ranking.tmdbId)
                _ = try await Self.callSetTierOrder(
                    client: client, media: pMedia, tier: fromTier, ids: compacted
                )
            } catch {
                print("[RankingRepository] source-tier compaction failed after re-rank (\(pMedia)/\(fromTier)); positions self-heal on next tier write: \(error)")
            }
        }

        // Step 6: emit ONE activity event. `CeremonyEmission.decide` is the pure
        // fresh-vs-re-rank seam: a re-rank (prior row existed) emits
        // `ranking_move` with `{notes?, year?}` (watched-with STRIPPED, matching
        // web's move sites); a fresh insert emits `ranking_add` and may carry
        // watched-with. The event type flows solely from the pre-read.
        let outcome: InsertOutcome = existingTier.map(InsertOutcome.moved) ?? .inserted
        let emission = CeremonyEmission.decide(
            outcome: outcome,
            notes: ranking.notes,
            year: ranking.year,
            watchedWithUserIds: ranking.watchedWithUserIds
        )
        let event = ActivityEventPayload(
            actor_id: userID,
            event_type: emission.eventType,
            target_user_id: nil,
            media_tmdb_id: ranking.tmdbId,
            media_title: ranking.title,
            media_tier: ranking.tier.rawValue,
            media_poster_url: ranking.posterURL,
            metadata: emission.metadata
        )
        // Fire-and-forget telemetry — the ranking itself already landed, so
        // we don't want a feed-insert hiccup to surface a user-facing toast.
        // Log so failures show up in device logs for triage.
        do {
            _ = try await client.from("activity_events").insert(event).execute()
        } catch {
            print("activity_events insert failed: \(error)")
        }

        _ = inserted   // row landed (upsert return); outcome captures add-vs-move
        return outcome
    }

    // MARK: management ops (C4)

    // These four ops are PURE DATA ops — they persist positions/notes/deletion
    // and never emit activity events (callers own emission, per this file's
    // header). Every position write obeys the FULL-MEMBERSHIP rule: it sends the
    // tier's ENTIRE intended membership to `set_tier_order`, computed by the
    // `TierOrder` helpers. A partial array would orphan unlisted rows.

    /// Persist a same-tier reorder. `ids` MUST be the tier's ENTIRE intended
    /// membership in the desired order (the caller computes it with
    /// `TierOrder.tierOrderAfterReorder` over the current UI order). Thin: one
    /// `set_tier_order` RPC, whose return value (rows actually renumbered) is
    /// passed straight back. The row already exists — this is UPDATE-only.
    ///
    /// `tier` is passed as the RPC's `p_tier`; `media` selects the media branch
    /// (`"movie" | "tv" | "book"`). Errors throw so the caller can revert the
    /// optimistic UI and toast.
    @discardableResult
    public func reorderTier(media: String = "movie", tier: String, ids: [String]) async throws -> Int {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard await SpoolClient.currentUserID() != nil else { throw RepoError.notAuthenticated }

        return try await Self.callSetTierOrder(
            client: client, media: Self.pMedia(forType: media), tier: tier, ids: ids
        )
    }

    /// Move a ranking from `fromTier` to `toTier`. The row's `tier` column is
    /// re-tiered by the TARGET `set_tier_order` call: that RPC UPDATEs every
    /// listed row's `tier` to `p_tier` (and its position), so listing `tmdbId`
    /// in the target array both re-tiers the row and slots it. Two RPCs, TARGET
    /// FIRST (mirroring `insertRanking`'s target-then-source order): the id must
    /// be re-tiered/positioned in the destination before the source tier is
    /// compacted without it. Full-membership on both sides — the caller passes
    /// the current UI order for each tier via `TierOrder.ordersAfterCrossTierMove`,
    /// but this op reads the live membership itself so a stale UI snapshot cannot
    /// orphan rows.
    ///
    /// `atIndex` nil ⇒ append to the target tier's tail. A same-tier call
    /// (`fromTier == toTier`) degenerates to a single reorder.
    public func moveRanking(
        tmdbId: String, fromTier: String, toTier: String, atIndex: Int?, media: String = "movie"
    ) async throws {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }
        let table = Self.rankingsTable(forType: media)
        let pMedia = Self.pMedia(forType: media)

        // Read BOTH tiers' live membership (best-first) so the persisted order
        // is authoritative regardless of a stale UI snapshot.
        let sourceIds = try await Self.tierMembership(
            client: client, table: table, userID: userID, tier: fromTier
        )

        // Same-tier "move" is just a reorder within one membership.
        if fromTier == toTier {
            let clamped = atIndex ?? sourceIds.count
            let reordered = Self.reindexWithinTier(sourceIds, movedId: tmdbId, to: clamped)
            _ = try await Self.callSetTierOrder(
                client: client, media: pMedia, tier: toTier, ids: reordered
            )
            return
        }

        let targetIds = try await Self.tierMembership(
            client: client, table: table, userID: userID, tier: toTier
        )
        let index = atIndex ?? targetIds.filter { $0 != tmdbId }.count
        let orders = TierOrder.ordersAfterCrossTierMove(
            source: sourceIds, target: targetIds, movedId: tmdbId, targetIndex: index
        )

        // TARGET FIRST — re-tiers + positions the row in the destination (the
        // RPC sets `tier = p_tier` for every listed id), THEN compact the source
        // minus the departed id. Both are full-membership calls.
        _ = try await Self.callSetTierOrder(
            client: client, media: pMedia, tier: toTier, ids: orders.target
        )
        _ = try await Self.callSetTierOrder(
            client: client, media: pMedia, tier: fromTier, ids: orders.source
        )
    }

    /// Edit a ranking's freeform `notes`. SINGLE-COLUMN update keyed on
    /// `(user_id, tmdb_id)` — nothing else on the row is touched, no RPC, no
    /// event. `notes == nil` clears the column (the payload encodes an EXPLICIT
    /// JSON null; PostgREST treats a missing key as "don't touch", so omission
    /// would silently preserve the old note). Throws on failure so the caller
    /// can surface a save error.
    public func updateNotes(tmdbId: String, notes: String?, media: String = "movie") async throws {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }
        let table = Self.rankingsTable(forType: media)

        _ = try await client
            .from(table)
            .update(NotesUpdatePayload(notes: notes))
            .eq("user_id", value: userID.uuidString)
            .eq("tmdb_id", value: tmdbId)
            .execute()
    }

    /// Delete a ranking, then compact its tier. Sequence:
    ///   1. DELETE the row by `(user_id, tmdb_id)` — this THROWS on failure
    ///      (nothing was removed; the caller reverts + toasts).
    ///   2. Read the tier's surviving membership and `set_tier_order` it so the
    ///      remaining rows compact to a contiguous `0..k-1`.
    /// A `set_tier_order` failure AFTER a successful DELETE logs LOUDLY but does
    /// NOT throw — the row is gone, so the delete succeeded; positions self-heal
    /// on the next tier write. (The RPC is delete-aware anyway: even a
    /// membership snapshot that still names the deleted id compacts correctly,
    /// since a missing row is silently skipped.)
    ///
    /// Orphan semantics (contract): ONLY the ranking row + compaction. Stubs,
    /// journal, activity history, comparison logs, and watchlist are NOT touched.
    public func deleteRanking(tmdbId: String, tier: String, media: String = "movie") async throws {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }
        let table = Self.rankingsTable(forType: media)
        let pMedia = Self.pMedia(forType: media)

        // Step 1: DELETE the ranking row. Throws on failure — nothing removed.
        _ = try await client
            .from(table)
            .delete()
            .eq("user_id", value: userID.uuidString)
            .eq("tmdb_id", value: tmdbId)
            .execute()

        // Step 2: compact the tier via the surviving membership (minus the
        // deleted id, defensively — the RPC skips a missing id regardless). A
        // failure here self-heals on the next tier write; do NOT throw.
        do {
            let survivors: [String]
            do {
                survivors = try await Self.tierMembership(
                    client: client, table: table, userID: userID, tier: tier
                )
            } catch {
                // A read hiccup falls back to an empty membership: the RPC then
                // renumbers nothing (no-op), and the tier self-heals on the next
                // successful tier write. Still logged for triage.
                print("[RankingRepository] tier membership read failed after delete (\(pMedia)/\(tier)); positions self-heal on next tier write: \(error)")
                return
            }
            let compacted = TierOrder.tierOrderAfterRemoval(survivors, removedId: tmdbId)
            _ = try await Self.callSetTierOrder(
                client: client, media: pMedia, tier: tier, ids: compacted
            )
        } catch {
            print("[RankingRepository] set_tier_order failed after delete (\(pMedia)/\(tier)); positions self-heal on next tier write: \(error)")
        }
    }

    // MARK: - management-op helpers (I/O seams, private)

    /// Read a tier's current membership as an ordered `tmdb_id[]` (best-first).
    /// Mirrors `insertRanking`'s membership read; throws so callers decide how
    /// to degrade.
    private static func tierMembership(
        client: SupabaseClient, table: String, userID: UUID, tier: String
    ) async throws -> [String] {
        let rows: [TierIdRow] = try await client
            .from(table)
            .select("tmdb_id")
            .eq("user_id", value: userID.uuidString)
            .eq("tier", value: tier)
            .order("rank_position", ascending: true)
            .execute()
            .value
        return rows.map(\.tmdb_id)
    }

    /// The single `set_tier_order` RPC call shape shared by every management op.
    /// Returns the RPC's updated-row count. Errors propagate to the caller.
    @discardableResult
    private static func callSetTierOrder(
        client: SupabaseClient, media: String, tier: String, ids: [String]
    ) async throws -> Int {
        let count: Int = try await client
            .rpc("set_tier_order", params: SetTierOrderParams(
                p_media: media, p_tier: tier, p_tmdb_ids: ids
            ))
            .execute()
            .value
        return count
    }

    /// Same-tier reindex: move `movedId` to the clamped `to` index within the
    /// tier's own membership. Wraps `TierOrder.tierOrderAfterReorder` by first
    /// resolving the id's current index (absent id ⇒ unchanged copy).
    static func reindexWithinTier(_ ids: [String], movedId: String, to: Int) -> [String] {
        guard let from = ids.firstIndex(of: movedId) else { return ids }
        return TierOrder.tierOrderAfterReorder(ids, from: from, to: to)
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

/// Projection used by two reads: `insertRanking`'s tier-membership read
/// (`select("tmdb_id")` — `tier` absent, decodes nil) and its prior-row
/// pre-read (`select("tmdb_id,tier")` — `tier` present). `tier` is optional so
/// one struct serves both without a second DTO.
private struct TierIdRow: Decodable {
    let tmdb_id: String
    let tier: String?
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

/// Single-column `user_rankings.notes` UPDATE body. `notes` encodes an
/// EXPLICIT JSON null when nil (parity with the web `notes ?? null`) so the
/// update CLEARS the column rather than leaving a stale value; synthesized
/// Encodable omits nil, and PostgREST reads a missing key as "don't touch",
/// hence the custom `encode(to:)`.
struct NotesUpdatePayload: Encodable, Equatable {
    let notes: String?

    enum CodingKeys: String, CodingKey { case notes }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(notes, forKey: .notes)   // explicit null when nil
    }
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

/// Pure fresh-vs-re-rank emission seam for `insertRanking` (tested —
/// `CeremonyEmissionTests`). Given the `InsertOutcome` (whether a prior
/// `(user_id, tmdb_id)` row existed) it picks the ONE activity event a ceremony
/// completion may fire and its metadata, mirroring web `handleAddItem`
/// (`pages/RankingAppPage.tsx`): a re-rank emits `ranking_move` with
/// `{notes?, year?}` and NEVER `watched_with_user_ids` (the move sites strip
/// it, per `docs/contracts/shared-payloads.md` `## activity_events`); a fresh
/// insert emits `ranking_add` and may carry watched-with. Contract-shaped
/// omit-empty is `ActivityMetadata`'s job — this seam only decides the KEYS
/// that flow in (nils watched-with on a move).
public enum CeremonyEmission {

    public struct Decision: Equatable {
        public let eventType: String
        public let metadata: ActivityMetadata
    }

    public static func decide(
        outcome: RankingRepository.InsertOutcome,
        notes: String?,
        year: String?,
        watchedWithUserIds: [UUID]?
    ) -> Decision {
        switch outcome {
        case .inserted:
            return Decision(
                eventType: "ranking_add",
                metadata: ActivityMetadata(
                    notes: notes, year: year, watchedWithUserIds: watchedWithUserIds
                )
            )
        case .moved:
            // Re-rank = MOVE: `{notes?, year?}` only; watched-with STRIPPED
            // (contract — the move sites never carry it).
            return Decision(
                eventType: "ranking_move",
                metadata: ActivityMetadata(
                    notes: notes, year: year, watchedWithUserIds: nil
                )
            )
        }
    }
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
