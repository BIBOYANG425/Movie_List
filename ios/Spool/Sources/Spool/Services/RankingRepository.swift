import Foundation
import Supabase

/// End-to-end ranking writes: the three vertical tables (`user_rankings` /
/// `tv_rankings` / `book_rankings`) + `activity_events`, plus the C4 management
/// ops (reorder / cross-tier move / notes edit / delete) and the `getNotes`
/// fetch-before-edit read the long-press "edit notes" sheet probes (the shelf's
/// `RankedItem` projection carries no notes column). C5 Task 2 media-parameterized
/// the READS: `getTierItems(tier:media:)` / `getAllRankedItems(media:)` route by
/// the same `rankingsTable(forType:)` mapping the writes use, so the H2H engine
/// walk, the shelf, and the management layer all operate on ONE selected vertical.
/// Rows map to per-media `RankedItem`s via `rankedItem(from:)` (attribution +
/// season line). All
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
/// Header last reviewed: 2026-07-10
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

    /// The ordered rows in one tier for the given media. `media` routes the read
    /// to the SAME table `insertRanking` writes (`rankingsTable(forType:)`), so a
    /// read and a write for one vertical can never disagree. Defaults to `"movie"`
    /// (the `user_rankings` surface) so existing movie callers are unchanged.
    public func getTierItems(tier: Tier, media: String = "movie") async throws -> [RankingRow] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }
        let table = Self.rankingsTable(forType: media)

        let rows: [RankingRow] = try await client
            .from(table)
            .select()
            .eq("user_id", value: userID.uuidString)
            .eq("tier", value: tier.rawValue)
            .order("rank_position", ascending: true)
            .execute()
            .value
        return rows
    }

    /// Search TMDB for movies matching `query`, routed through the authenticated
    /// `tmdb-proxy` edge function (`TMDBService`). Returns `[]` when the proxy is
    /// unreachable (unconfigured client) or the caller is signed out (synthetic
    /// 401) — the key no longer lives in the bundle.
    public func searchMovies(query: String) async -> [TMDBMovie] {
        await TMDBService.searchMovies(query: query)
    }

    /// All rankings for the signed-in user in one vertical, across every tier.
    /// Used by the `SpoolRankingEngine` (prediction signals + in-tier comparison
    /// walk) and the shelf (`FullListScreen`). `media` routes to the matching
    /// table (`rankingsTable(forType:)`), so the engine walk / shelf / management
    /// layer all operate on the SAME vertical the caller selected. Defaults to
    /// `"movie"` for the unchanged movie callers. Rows map to per-media
    /// `RankedItem`s via `rankedItem(from:)` — `attribution` fills the subtitle
    /// slot (director/creator/author) and a tv row's `season_title` rides along.
    public func getAllRankedItems(media: String = "movie") async throws -> [RankedItem] {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }
        let table = Self.rankingsTable(forType: media)

        let rows: [RankingRow] = try await client
            .from(table)
            .select()
            .eq("user_id", value: userID.uuidString)
            .order("rank_position", ascending: true)
            .execute()
            .value
        return rows.compactMap(Self.rankedItem)
    }

    /// Read the freeform `notes` currently stored on a ranking row, keyed on
    /// `(user_id, tmdb_id)`. The fetch-before-edit seam for the long-press
    /// "edit notes" sheet (C4 Task 4): the shelf's `RankedItem` projection has
    /// NO notes column, so the sheet MUST probe the live row first, or a save
    /// after an empty-seeded editor would blank an existing note (the journal
    /// probe-before-edit lesson). Returns nil when the row is absent OR its
    /// notes column is null. Throws on a genuine I/O failure so the caller can
    /// decide whether to open the editor blank or toast.
    public func getNotes(tmdbId: String, media: String = "movie") async throws -> String? {
        guard let client = SpoolClient.shared else { throw RepoError.notConfigured }
        guard let userID = await SpoolClient.currentUserID() else { throw RepoError.notAuthenticated }
        let table = Self.rankingsTable(forType: media)

        let rows: [NotesRow] = try await client
            .from(table)
            .select("notes")
            .eq("user_id", value: userID.uuidString)
            .eq("tmdb_id", value: tmdbId)
            .limit(1)
            .execute()
            .value
        return rows.first?.notes
    }

    /// Map a decoded `RankingRow` (from ANY of the three tables) into the shelf +
    /// engine `RankedItem`. MEDIA-GENERIC by construction: `attribution`
    /// (`director ?? creator ?? author`) fills the subtitle slot so a movie shows
    /// its director, a tv season its creator, a book its author — no media branch
    /// needed, the `RankingRow` already carries all three columns (only one is
    /// non-nil per table). A tv row's `season_title` rides through as
    /// `seasonTitle` for the season line (`title` stays the SHOW name); movie/book
    /// rows leave it nil. A row whose `tier` isn't a valid `Tier` is DROPPED
    /// (returns nil — the `compactMap` contract), matching the movie behaviour.
    /// Internal (not private) so Task 2's read-routing tests can pin the mapping
    /// without a live client.
    static func rankedItem(from row: RankingRow) -> RankedItem? {
        guard let tier = Tier(rawValue: row.tier) else { return nil }
        let yearInt = row.year.flatMap { Int($0) }
        let bracket = RankingAlgorithm.classifyBracket(genres: row.genres)
        return RankedItem(
            id: row.tmdb_id, title: row.title, year: yearInt,
            director: row.attribution ?? "—",
            genres: row.genres, tier: tier, rank: row.rank_position,
            bracket: bracket, globalScore: nil, seed: 0,
            posterUrl: row.poster_url, seasonTitle: row.season_title
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

        // Step 3: UPSERT on (user_id, tmdb_id) so an iOS re-rank of an already-
        // ranked item replaces its row instead of failing the unique key. The
        // row MUST exist before the RPC (UPDATE-only) — this is that insert.
        // The payload is PER-MEDIA (`RankingPayload.make`): the movie body is
        // byte-for-byte the historical shape (director, no vertical columns);
        // the tv/book bodies carry ONLY their own table's columns and NEVER a
        // director key (those tables have no such column — a stray director
        // 400s). `.single()` still round-trips the full `RankingRow`.
        let payload = RankingPayload.make(from: ranking, userID: userID)
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

/// The per-media "vertical" fields a `RankingInsert` carries, one case per
/// backing table. Makes illegal states unrepresentable: a `.tv` insert MUST
/// supply `showTmdbId` + `season` (both are `tv_rankings NOT NULL` columns —
/// `supabase_tv_rankings.sql:10-11`), so a TV rank without them cannot compile;
/// and `director` only exists on the `.movie` case, so it can never leak onto
/// the tv/book tables (which have no `director` column — a non-nil director key
/// 400s there). The vertical fields map straight to `tv_rankings` /
/// `book_rankings` columns; see the per-media payload structs below.
public enum RankingMedia: Sendable, Equatable {
    /// `user_rankings` — the movie table. `director` is the ONLY vertical
    /// column and lives ONLY here.
    case movie(director: String?)
    /// `tv_rankings`. `showTmdbId`/`season` are NON-OPTIONAL (NOT NULL in the
    /// DDL); `seasonTitle`/`creator`/`episodeCount` are nullable columns.
    case tv(showTmdbId: Int, season: Int, seasonTitle: String? = nil,
            creator: String? = nil, episodeCount: Int? = nil)
    /// `book_rankings`. All five OpenLibrary-derived columns are nullable.
    case book(author: String? = nil, pageCount: Int? = nil, isbn: String? = nil,
              olWorkKey: String? = nil, olRatingsAverage: Double? = nil)

    /// The `type`/`p_media` discriminator: `"movie" | "tv" | "book"`. Drives
    /// `rankingsTable`/`pMedia` and the persisted `type` column.
    var typeString: String {
        switch self {
        case .movie: return "movie"
        case .tv:    return "tv"
        case .book:  return "book"
        }
    }
}

public struct RankingInsert: Sendable {
    public let tmdbId: String
    public let title: String
    public let year: String?
    public let posterURL: String?
    public let genres: [String]
    public let media: RankingMedia
    public let tier: Tier
    public let rankPosition: Int
    public let notes: String?
    /// Ceremony friends for the activity-event metadata. Defaults nil.
    /// Persisted on tv/book rows (both tables carry `watched_with_user_ids`),
    /// and — per the emission contract — carried on a fresh `ranking_add` but
    /// STRIPPED on a re-rank `ranking_move` (`CeremonyEmission.decide`).
    public let watchedWithUserIds: [UUID]?

    /// `"movie" | "tv" | "book"` — derived from `media`, so the discriminator
    /// and the vertical payload can never disagree. Kept as a property (not a
    /// stored field) for `rankingsTable`/`pMedia` and callers that log it.
    public var type: String { media.typeString }

    /// The movie director, when this is a movie insert; nil otherwise. Present
    /// for the movie payload build (and callers that still read `.director`).
    public var director: String? {
        if case let .movie(director) = media { return director }
        return nil
    }

    /// Media-generic designated init. Prefer the `.movie`/`.tv`/`.book`
    /// factories for new call sites — they make the required vertical fields
    /// explicit at the call.
    public init(tmdbId: String, title: String, year: String?, posterURL: String?,
                genres: [String] = [], media: RankingMedia,
                tier: Tier, rankPosition: Int, notes: String? = nil,
                watchedWithUserIds: [UUID]? = nil) {
        self.tmdbId = tmdbId
        self.title = title
        self.year = year
        self.posterURL = posterURL
        self.genres = genres
        self.media = media
        self.tier = tier
        self.rankPosition = rankPosition
        self.notes = notes
        self.watchedWithUserIds = watchedWithUserIds
    }

    /// Back-compat movie init — the historical shape (`type:` + `director:`).
    /// Existing movie call sites (`RankPersistence`, onboarding) compile
    /// unchanged; `type` is accepted for source compatibility but the media is
    /// always `.movie`, so a stray `type:"tv"` here can't mint a movie-shaped
    /// tv row.
    public init(tmdbId: String, title: String, year: String?, posterURL: String?,
                type: String = "movie", genres: [String] = [], director: String? = nil,
                tier: Tier, rankPosition: Int, notes: String? = nil,
                watchedWithUserIds: [UUID]? = nil) {
        self.init(tmdbId: tmdbId, title: title, year: year, posterURL: posterURL,
                  genres: genres, media: .movie(director: director),
                  tier: tier, rankPosition: rankPosition, notes: notes,
                  watchedWithUserIds: watchedWithUserIds)
    }

    // MARK: per-media factories (make required vertical fields explicit)

    public static func movie(
        tmdbId: String, title: String, year: String?, posterURL: String?,
        genres: [String] = [], director: String? = nil, tier: Tier,
        rankPosition: Int, notes: String? = nil, watchedWithUserIds: [UUID]? = nil
    ) -> RankingInsert {
        RankingInsert(tmdbId: tmdbId, title: title, year: year, posterURL: posterURL,
                      genres: genres, media: .movie(director: director),
                      tier: tier, rankPosition: rankPosition, notes: notes,
                      watchedWithUserIds: watchedWithUserIds)
    }

    public static func tv(
        tmdbId: String, title: String, year: String?, posterURL: String?,
        genres: [String] = [], showTmdbId: Int, season: Int,
        seasonTitle: String? = nil, creator: String? = nil, episodeCount: Int? = nil,
        tier: Tier, rankPosition: Int, notes: String? = nil,
        watchedWithUserIds: [UUID]? = nil
    ) -> RankingInsert {
        RankingInsert(
            tmdbId: tmdbId, title: title, year: year, posterURL: posterURL,
            genres: genres,
            media: .tv(showTmdbId: showTmdbId, season: season, seasonTitle: seasonTitle,
                       creator: creator, episodeCount: episodeCount),
            tier: tier, rankPosition: rankPosition, notes: notes,
            watchedWithUserIds: watchedWithUserIds
        )
    }

    public static func book(
        tmdbId: String, title: String, year: String?, posterURL: String?,
        genres: [String] = [], author: String? = nil, pageCount: Int? = nil,
        isbn: String? = nil, olWorkKey: String? = nil, olRatingsAverage: Double? = nil,
        tier: Tier, rankPosition: Int, notes: String? = nil,
        watchedWithUserIds: [UUID]? = nil
    ) -> RankingInsert {
        RankingInsert(
            tmdbId: tmdbId, title: title, year: year, posterURL: posterURL,
            genres: genres,
            media: .book(author: author, pageCount: pageCount, isbn: isbn,
                         olWorkKey: olWorkKey, olRatingsAverage: olRatingsAverage),
            tier: tier, rankPosition: rankPosition, notes: notes,
            watchedWithUserIds: watchedWithUserIds
        )
    }
}

/// A ranking row read back from ANY of the three tables. The shared columns are
/// non-optional; every VERTICAL column is optional so ONE struct decodes rows
/// from all three tables (a movie row lacks the tv/book columns, a tv row lacks
/// book columns, etc. — the missing keys decode nil via `decodeIfPresent`).
/// This is what Task 2's media-parameterized reads (`getTierItems(media:)` /
/// `getAllRankedItems(media:)`) map into per-media `RankedItem`s: `creator`
/// (tv) and `author` (book) both feed `RankedItem.director` (the shelf's
/// subtitle slot), while `show_tmdb_id`/`season_number`/`season_title`/
/// `episode_count` and `page_count`/`isbn`/`ol_work_key`/`ol_ratings_average`
/// give Task 2 the identity + detail fields for its per-media projections.
public struct RankingRow: Codable, Sendable, Hashable {
    public let id: UUID
    public let user_id: UUID
    public let tmdb_id: String
    public let title: String
    public let year: String?
    public let poster_url: String?
    public let type: String
    public let genres: [String]
    // movie
    public let director: String?
    // tv (nil on movie/book rows)
    public let show_tmdb_id: Int?
    public let season_number: Int?
    public let season_title: String?
    public let creator: String?
    public let episode_count: Int?
    // book (nil on movie/tv rows)
    public let author: String?
    public let page_count: Int?
    public let isbn: String?
    public let ol_work_key: String?
    public let ol_ratings_average: Double?
    // shared
    public let tier: String
    public let rank_position: Int
    public let notes: String?

    /// The per-media "subtitle" attribution the shelf shows under a title:
    /// director for movies, creator for TV, author for books (web
    /// `WatchlistCard` uses the same `director ?? author ?? creator` fallback).
    public var attribution: String? {
        director ?? creator ?? author
    }

    public init(
        id: UUID, user_id: UUID, tmdb_id: String, title: String,
        year: String?, poster_url: String?, type: String, genres: [String],
        director: String? = nil,
        show_tmdb_id: Int? = nil, season_number: Int? = nil,
        season_title: String? = nil, creator: String? = nil, episode_count: Int? = nil,
        author: String? = nil, page_count: Int? = nil, isbn: String? = nil,
        ol_work_key: String? = nil, ol_ratings_average: Double? = nil,
        tier: String, rank_position: Int, notes: String?
    ) {
        self.id = id
        self.user_id = user_id
        self.tmdb_id = tmdb_id
        self.title = title
        self.year = year
        self.poster_url = poster_url
        self.type = type
        self.genres = genres
        self.director = director
        self.show_tmdb_id = show_tmdb_id
        self.season_number = season_number
        self.season_title = season_title
        self.creator = creator
        self.episode_count = episode_count
        self.author = author
        self.page_count = page_count
        self.isbn = isbn
        self.ol_work_key = ol_work_key
        self.ol_ratings_average = ol_ratings_average
        self.tier = tier
        self.rank_position = rank_position
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        user_id = try c.decode(UUID.self, forKey: .user_id)
        tmdb_id = try c.decode(String.self, forKey: .tmdb_id)
        title = try c.decode(String.self, forKey: .title)
        year = try c.decodeIfPresent(String.self, forKey: .year)
        poster_url = try c.decodeIfPresent(String.self, forKey: .poster_url)
        type = try c.decode(String.self, forKey: .type)
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        director = try c.decodeIfPresent(String.self, forKey: .director)
        show_tmdb_id = try c.decodeIfPresent(Int.self, forKey: .show_tmdb_id)
        season_number = try c.decodeIfPresent(Int.self, forKey: .season_number)
        season_title = try c.decodeIfPresent(String.self, forKey: .season_title)
        creator = try c.decodeIfPresent(String.self, forKey: .creator)
        episode_count = try c.decodeIfPresent(Int.self, forKey: .episode_count)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        page_count = try c.decodeIfPresent(Int.self, forKey: .page_count)
        isbn = try c.decodeIfPresent(String.self, forKey: .isbn)
        ol_work_key = try c.decodeIfPresent(String.self, forKey: .ol_work_key)
        ol_ratings_average = try c.decodeIfPresent(Double.self, forKey: .ol_ratings_average)
        tier = try c.decode(String.self, forKey: .tier)
        rank_position = try c.decode(Int.self, forKey: .rank_position)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
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

/// Projection for the fetch-before-edit notes probe (`getNotes`,
/// `select("notes")`). `notes` is nullable — an absent row decodes to `[]`
/// (caller reads nil), a present row with a null column decodes `notes: nil`.
private struct NotesRow: Decodable {
    let notes: String?
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

/// Per-media upsert body dispatcher. ONE `Encodable` type so `insertRanking`'s
/// `.upsert(_:)` stays media-generic, but each case encodes ONLY the columns
/// that exist on its backing table:
///   - `.movie` → `user_rankings`: the historical shape (director, NO vertical
///     columns) — encoded BYTE-FOR-BYTE by `MoviePayloadBody` so the movie pins
///     stay green and no re-rank regresses.
///   - `.tv` → `tv_rankings`: adds `show_tmdb_id`/`season_number` (NOT NULL),
///     `season_title?`/`creator?`/`episode_count?`, `watched_with_user_ids`.
///     NO `director` key (the table has no such column).
///   - `.book` → `book_rankings`: adds `author?`/`page_count?`/`isbn?`/
///     `ol_work_key?`/`ol_ratings_average?`, `watched_with_user_ids`. NO
///     `director`, NO show/season keys.
/// Nil-omission is UNIFORM across all three bodies: a nil optional OMITS its key
/// so PostgREST preserves the existing column on a re-rank (the `notes`
/// omission pin, `TierSpliceTests.testRankingPayloadNilNotesOmitsKey`, applies
/// to every media). `watched_with_user_ids` is ALWAYS present on tv/book
/// (defaulting to `[]`), matching web `?? []`.
enum RankingPayload: Encodable {
    case movie(MoviePayloadBody)
    case tv(TVPayloadBody)
    case book(BookPayloadBody)

    /// Build the correct per-media body from a `RankingInsert`. The vertical
    /// enum drives the branch, so a movie insert can NEVER produce a tv/book
    /// body (or vice-versa) and `director` can only reach the movie body.
    static func make(from ranking: RankingInsert, userID: UUID) -> RankingPayload {
        switch ranking.media {
        case let .movie(director):
            return .movie(MoviePayloadBody(
                user_id: userID, tmdb_id: ranking.tmdbId, title: ranking.title,
                year: ranking.year, poster_url: ranking.posterURL, type: "movie",
                genres: ranking.genres, director: director,
                tier: ranking.tier.rawValue, rank_position: ranking.rankPosition,
                notes: ranking.notes
            ))
        case let .tv(showTmdbId, season, seasonTitle, creator, episodeCount):
            return .tv(TVPayloadBody(
                user_id: userID, tmdb_id: ranking.tmdbId,
                show_tmdb_id: showTmdbId, season_number: season,
                title: ranking.title, season_title: seasonTitle,
                year: ranking.year, poster_url: ranking.posterURL, type: "tv_season",
                genres: ranking.genres, creator: creator,
                tier: ranking.tier.rawValue, rank_position: ranking.rankPosition,
                notes: ranking.notes, episode_count: episodeCount,
                watched_with_user_ids: ranking.watchedWithUserIds ?? []
            ))
        case let .book(author, pageCount, isbn, olWorkKey, olRatingsAverage):
            return .book(BookPayloadBody(
                user_id: userID, tmdb_id: ranking.tmdbId, title: ranking.title,
                year: ranking.year, poster_url: ranking.posterURL, type: "book",
                genres: ranking.genres, author: author,
                tier: ranking.tier.rawValue, rank_position: ranking.rankPosition,
                notes: ranking.notes, page_count: pageCount, isbn: isbn,
                ol_work_key: olWorkKey, ol_ratings_average: olRatingsAverage,
                watched_with_user_ids: ranking.watchedWithUserIds ?? []
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .movie(body): try body.encode(to: encoder)
        case let .tv(body):    try body.encode(to: encoder)
        case let .book(body):  try body.encode(to: encoder)
        }
    }
}

/// `user_rankings` upsert body — the historical `RankingPayload` shape, kept
/// UNCHANGED. Synthesized `Encodable` uses `encodeIfPresent`, so a nil `notes`
/// (and nil `year`/`poster_url`/`director`) OMITS the key and PostgREST
/// preserves the existing column on a re-rank. Pinned by
/// `TierSpliceTests.testRankingPayloadNilNotesOmitsKey`.
struct MoviePayloadBody: Encodable {
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

/// `tv_rankings` upsert body (`supabase_tv_rankings.sql:6-28`, +
/// `supabase_watched_with.sql`). `show_tmdb_id`/`season_number` are NON-optional
/// (NOT NULL columns). Optionals (`season_title`/`creator`/`episode_count`/
/// `year`/`poster_url`/`notes`) OMIT on nil via synthesized `encodeIfPresent`,
/// preserving the column on re-rank. There is NO `director` key. `type` is
/// `"tv_season"`. Key-set pinned by `PerMediaPayloadTests`.
struct TVPayloadBody: Encodable {
    let user_id: UUID
    let tmdb_id: String
    let show_tmdb_id: Int
    let season_number: Int
    let title: String
    let season_title: String?
    let year: String?
    let poster_url: String?
    let type: String
    let genres: [String]
    let creator: String?
    let tier: String
    let rank_position: Int
    let notes: String?
    let episode_count: Int?
    let watched_with_user_ids: [UUID]
}

/// `book_rankings` upsert body (`supabase_book_rankings.sql:6-29`). All five
/// OpenLibrary columns (`author`/`page_count`/`isbn`/`ol_work_key`/
/// `ol_ratings_average`) plus `year`/`poster_url`/`notes` OMIT on nil via
/// synthesized `encodeIfPresent`. NO `director`, NO show/season keys. `type`
/// is `"book"`. Key-set pinned by `PerMediaPayloadTests`.
struct BookPayloadBody: Encodable {
    let user_id: UUID
    let tmdb_id: String
    let title: String
    let year: String?
    let poster_url: String?
    let type: String
    let genres: [String]
    let author: String?
    let tier: String
    let rank_position: Int
    let notes: String?
    let page_count: Int?
    let isbn: String?
    let ol_work_key: String?
    let ol_ratings_average: Double?
    let watched_with_user_ids: [UUID]
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
