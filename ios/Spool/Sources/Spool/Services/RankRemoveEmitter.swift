import Foundation
import Supabase

/// Binds `RankManageModel`'s injected `emitRemove` closure to the REAL
/// `activity_events` insert for a ranking DELETE — C4 iOS management-UI Task 4
/// (the long-press context menu). Sibling of `RankMoveEmitter`: same pure
/// wire-payload builder + thin fire-and-forget `SpoolClient` insert.
///
/// A delete is a `ranking_remove` event with metadata `{notes?, year?}` and
/// NEVER `watched_with_user_ids` — the web writes it through the SAME
/// `logRankingActivityEvent` writer as `ranking_move`, passing only
/// `{ notes, year }` (`services/activityService.ts:20-45`, called from
/// `pages/RankingAppPage.tsx:618` with the removed item's `notes`/`year`; the
/// call omits `watchedWithUserIds`). `media_tier` carries the tier the row was
/// removed FROM (web passes `removedItem.tier`). Per
/// `docs/contracts/shared-payloads.md` `## activity_events`, `ranking_remove`
/// shares the `{notes?, year?}` shape and is rendered only by the FriendsView
/// mini-feed (never the social feed). Metadata omit-empty is
/// `ActivityMetadata`'s job — an all-nil metadata encodes `{}`.
///
/// The optimistic-removal + revert + "emit only after a confirmed delete" gate
/// live in the MODEL (`RankManageModel.delete`, tested in
/// `RankManageModelTests`); this file owns only the WRITE and the payload shape.
///
/// Header last reviewed: 2026-07-09
public enum RankRemoveEmitter {

    /// The `activity_events` row for a management delete `ranking_remove`. Media
    /// columns come from the removed item; `metadata` is `{notes?, year?}`
    /// (watched-with nil). `media_tier` is the tier the row was removed from.
    /// `actor_id` is the signed-in user (resolved at insert time). Reuses
    /// `ActivityMetadata` so the wire shape matches web's `ranking_remove` site.
    public static func payload(
        actorID: UUID, event: RankManageModel.RemoveEvent
    ) -> RankMoveEventPayload {
        RankMoveEventPayload(
            actor_id: actorID.uuidString.lowercased(),
            event_type: "ranking_remove",
            media_tmdb_id: event.tmdbId,
            media_title: event.title,
            media_tier: event.tier,
            media_poster_url: event.posterUrl,
            metadata: ActivityMetadata(
                notes: event.notes, year: event.year, watchedWithUserIds: nil
            )
        )
    }

    /// Insert the `ranking_remove` activity event. Fire-and-forget: a feed-insert
    /// hiccup never surfaces a user-facing toast (the row is already deleted) —
    /// logged for device-log triage, exactly like `RankMoveEmitter`. No session
    /// (no client / no user) is a silent no-op.
    public static func emit(_ event: RankManageModel.RemoveEvent) async {
        guard let client = SpoolClient.shared else { return }
        guard let actorID = await SpoolClient.currentUserID() else { return }
        let payload = payload(actorID: actorID, event: event)
        do {
            _ = try await client.from("activity_events").insert(payload).execute()
        } catch {
            NSLog("[RankRemoveEmitter] ranking_remove activity_events insert failed: \(error)")
        }
    }
}
