import Foundation
import Supabase

/// Binds the `JournalDraftModel`'s injected side-effect closures to the REAL
/// `activity_events` / `notifications` inserts (plan Task 6). The GATE logic —
/// "emit a review event only when the review is non-empty AND resolves to
/// public", "one journal_tag per tagged friend, body = first 100 chars" — lives
/// in the MODEL (`JournalDraftModel`, tested in `JournalDraftModelTests`). This
/// file owns only the WRITES: the pure wire-payload builders (tested in
/// `JournalEmittersTests`) plus the thin `SpoolClient` inserts that fire them.
///
/// Wire parity (both fire-and-forget, mirroring the existing repos):
///  - `emitReviewEvent` → `activity_events` insert, `event_type: 'review'`,
///    `metadata: { reviewBody, containsSpoilers }` — mirrors
///    `RankingRepository.insertRanking`'s `activity_events` write
///    (`services/feedService.ts:664-693` `logReviewActivityEvent`).
///  - `emitJournalTag` → one `notifications` row, `type: 'journal_tag'` —
///    mirrors `FollowRepository.follow`'s `NotificationInsertPayload`
///    (`services/journalService.ts:268-279`).
///
/// Also exposes `makeDraftModel(...)` — the single factory that constructs a
/// fully-bound `JournalDraftModel` (repo probe/tier/upsert, PhotoStore upload,
/// ProfileRepository visibility, these emitters, current user) for the composer
/// host + ceremony write-more.
///
/// Header last reviewed: 2026-07-07
public enum JournalEmitters {

    // MARK: - Pure wire-payload builders (tested)

    /// `activity_events` row for a `review` event. Media columns come straight
    /// from the entry; `metadata` is the contract object `{ reviewBody,
    /// containsSpoilers }` (both ALWAYS present — web C1 activity_events
    /// `review` row). `actor_id` is the signed-in author. UUIDs lowercased on
    /// the wire (web parity; Swift's UUID uppercases).
    public static func reviewEventPayload(
        actorID: UUID, input: JournalDraftModel.ReviewEventInput
    ) -> ReviewEventPayload {
        ReviewEventPayload(
            actor_id: actorID.uuidString.lowercased(),
            event_type: "review",
            media_tmdb_id: input.tmdbId,
            media_title: input.title,
            media_tier: input.tier,
            media_poster_url: input.posterUrl,
            metadata: ReviewMetadata(
                reviewBody: input.body,
                containsSpoilers: input.containsSpoilers
            )
        )
    }

    /// One `notifications` row for a `journal_tag`. `user_id` = the tagged
    /// friend, `actor_id` = the journal author, `reference_id` = the journal
    /// entry id (deep-link target). `body` (already truncated to 100 chars by
    /// the model) is OMITTED when nil (web `body: … ? … : undefined`), never
    /// null. UUIDs lowercased on the wire.
    public static func journalTagPayload(
        input: JournalDraftModel.JournalTagInput
    ) -> JournalTagPayload {
        JournalTagPayload(
            user_id: input.friendID.uuidString.lowercased(),
            type: "journal_tag",
            title: input.title,
            body: input.body,
            actor_id: input.actorID.uuidString.lowercased(),
            reference_id: input.referenceID.uuidString.lowercased()
        )
    }

    // MARK: - Real inserts (fire-and-forget)

    /// Insert the `review` activity event. Fire-and-forget: a feed-insert hiccup
    /// never surfaces a user-facing toast (the entry already saved) — logged for
    /// device-log triage, exactly like `RankingRepository`'s activity insert.
    public static func writeReviewEvent(actorID: UUID, input: JournalDraftModel.ReviewEventInput) async {
        guard let client = SpoolClient.shared else { return }
        let payload = reviewEventPayload(actorID: actorID, input: input)
        do {
            _ = try await client.from("activity_events").insert(payload).execute()
        } catch {
            NSLog("[JournalEmitters] review activity_events insert failed: \(error)")
        }
    }

    /// Insert one `journal_tag` notification. Fire-and-forget best-effort, same
    /// as `FollowRepository`'s new_follower notification.
    public static func writeJournalTag(input: JournalDraftModel.JournalTagInput) async {
        guard let client = SpoolClient.shared else { return }
        let payload = journalTagPayload(input: input)
        do {
            _ = try await client.from("notifications").insert(payload).execute()
        } catch {
            NSLog("[JournalEmitters] journal_tag notifications insert failed: \(error)")
        }
    }

    // MARK: - Draft-model factory

    /// Construct a fully-bound `JournalDraftModel` for the composer host + the
    /// ceremony write-more. All IO closures are bound to the real services here
    /// (the ONE production wiring site) so the model stays pure-injectable for
    /// tests. `seed` carries a ceremony/list row; a nil seed opens fresh.
    @MainActor
    public static func makeDraftModel(seed: JournalRow? = nil) -> JournalDraftModel {
        JournalDraftModel(
            probeOwnEntry: { tmdbId in
                try await JournalRepository.shared.getOwnEntry(tmdbId: tmdbId)
            },
            seed: seed,
            resolveRatingTier: { tmdbId in
                try await JournalRepository.shared.ratingTier(tmdbId: tmdbId)
            },
            upsert: { payload in
                try await JournalRepository.shared.upsert(payload)
            },
            uploadPhoto: { data, entryID, index, ext in
                guard let userID = await SpoolClient.currentUserID() else {
                    throw EmitterError.notAuthenticated
                }
                return try await PhotoStore.shared.upload(
                    data: data, userID: userID, entryID: entryID, index: index, ext: ext
                )
            },
            fetchProfileVisibility: {
                await ProfileRepository.shared.currentVisibility()
            },
            emitReviewEvent: { input in
                guard let actorID = await SpoolClient.currentUserID() else { return }
                await writeReviewEvent(actorID: actorID, input: input)
            },
            emitJournalTag: { input in
                await writeJournalTag(input: input)
            },
            currentUserID: { await SpoolClient.currentUserID() }
        )
    }

    enum EmitterError: Error { case notAuthenticated }
}

// MARK: - Wire payloads (snake_case for PostgREST)

/// `activity_events` insert for `event_type: 'review'`. Media columns encode as
/// explicit null when nil (web `logReviewActivityEvent`: `tier ?? null`,
/// `posterUrl ?? null`); `metadata` always present. A custom `encode(to:)` is
/// required because synthesized Encodable OMITS nil optionals, but the web
/// always writes the key with a null value.
public struct ReviewEventPayload: Encodable, Equatable {
    let actor_id: String
    let event_type: String
    let media_tmdb_id: String?
    let media_title: String?
    let media_tier: String?
    let media_poster_url: String?
    let metadata: ReviewMetadata

    private enum CodingKeys: String, CodingKey {
        case actor_id, event_type, media_tmdb_id, media_title
        case media_tier, media_poster_url, metadata
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(actor_id, forKey: .actor_id)
        try c.encode(event_type, forKey: .event_type)
        try c.encode(media_tmdb_id, forKey: .media_tmdb_id)         // explicit null
        try c.encode(media_title, forKey: .media_title)             // explicit null
        try c.encode(media_tier, forKey: .media_tier)               // explicit null
        try c.encode(media_poster_url, forKey: .media_poster_url)   // explicit null
        try c.encode(metadata, forKey: .metadata)
    }
}

/// `activity_events.metadata` for a `review` — the contract object
/// `{ reviewBody, containsSpoilers }`, both keys ALWAYS present (web C1
/// activity_events `review` row). camelCase — jsonb is stored verbatim.
public struct ReviewMetadata: Encodable, Equatable {
    let reviewBody: String
    let containsSpoilers: Bool
}

/// `notifications` insert for `type: 'journal_tag'`. `body` is OMITTED when nil
/// (web `undefined`), so a custom `encode(to:)` is required — synthesized
/// Encodable would emit `null`, which the web never does. Every other key is
/// always present.
public struct JournalTagPayload: Encodable, Equatable {
    let user_id: String
    let type: String
    let title: String
    let body: String?
    let actor_id: String
    let reference_id: String

    private enum CodingKeys: String, CodingKey {
        case user_id, type, title, body, actor_id, reference_id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(user_id, forKey: .user_id)
        try c.encode(type, forKey: .type)
        try c.encode(title, forKey: .title)
        // Omit the key entirely when there's no review body (web `undefined`),
        // never encode null.
        if let body { try c.encode(body, forKey: .body) }
        try c.encode(actor_id, forKey: .actor_id)
        try c.encode(reference_id, forKey: .reference_id)
    }
}
