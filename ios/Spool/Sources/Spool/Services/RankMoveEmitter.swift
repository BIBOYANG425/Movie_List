import Foundation
import Supabase

/// Binds `RankManageModel`'s injected `emit` closure to the REAL `activity_events`
/// insert for a MANAGEMENT (edit-mode drag) reorder — C4 iOS management-UI Task 3.
///
/// This is the emitter shape the plan says to reuse: the pure wire-payload
/// builder + a thin fire-and-forget `SpoolClient` insert, mirroring
/// `JournalEmitters.writeReviewEvent` and `RankingRepository.insertRanking`'s
/// own `activity_events` write. The NO-OP suppression and the "emit only on a
/// confirmed change" gate live in the MODEL (`RankManageModel`, tested in
/// `RankManageModelTests`); this file owns only the WRITE.
///
/// A drag reorder is a MOVE, so the event type is `ranking_move` with metadata
/// `{notes?, year?}` and NEVER `watched_with_user_ids` (the move sites strip it,
/// per `docs/contracts/shared-payloads.md` `## activity_events`). `notes` flows
/// from the moved item's projected `RankedItem.notes` (C7-iOS Task 4 — the
/// projection now carries the row's notes), nil when the column is empty; `year`
/// flows from the moved item. Metadata omit-empty is `ActivityMetadata`'s
/// existing job — an all-nil metadata encodes `{}`.
///
/// Header last reviewed: 2026-07-10
public enum RankMoveEmitter {

    /// The `activity_events` row for a management reorder `ranking_move`. Media
    /// columns come from the moved item; `metadata` is `{notes?, year?}`
    /// (watched-with nil). `actor_id` is the signed-in user (resolved at insert
    /// time). Reuses `ActivityMetadata` (the same omit-empty encoder the
    /// ceremony uses) so the wire shape matches web's `ranking_move` sites.
    public static func payload(
        actorID: UUID, event: RankManageModel.MoveEvent
    ) -> RankMoveEventPayload {
        RankMoveEventPayload(
            actor_id: actorID.uuidString.lowercased(),
            event_type: "ranking_move",
            media_tmdb_id: event.tmdbId,
            media_title: event.title,
            media_tier: event.tier,
            media_poster_url: event.posterUrl,
            metadata: ActivityMetadata(
                notes: event.notes, year: event.year, watchedWithUserIds: nil
            )
        )
    }

    /// Insert the `ranking_move` activity event. Fire-and-forget: a feed-insert
    /// hiccup never surfaces a user-facing toast (the reorder already persisted)
    /// — logged for device-log triage, exactly like `RankingRepository`'s and
    /// `JournalEmitters`' activity inserts. No session (no client / no user) is a
    /// silent no-op.
    public static func emit(_ event: RankManageModel.MoveEvent) async {
        guard let client = SpoolClient.shared else { return }
        guard let actorID = await SpoolClient.currentUserID() else { return }
        let payload = payload(actorID: actorID, event: event)
        do {
            _ = try await client.from("activity_events").insert(payload).execute()
        } catch {
            NSLog("[RankMoveEmitter] ranking_move activity_events insert failed: \(error)")
        }
    }
}

/// `activity_events` insert for a management-reorder `ranking_move`. Media
/// columns encode as explicit null when nil (web/`ranking_move` sites write the
/// key; PostgREST treats a missing key as "don't touch"), so a custom
/// `encode(to:)` is required — synthesized Encodable OMITS nil optionals.
/// `metadata` (an `ActivityMetadata`) always present.
public struct RankMoveEventPayload: Encodable, Equatable {
    let actor_id: String
    let event_type: String
    let media_tmdb_id: String?
    let media_title: String?
    let media_tier: String?
    let media_poster_url: String?
    let metadata: ActivityMetadata

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
