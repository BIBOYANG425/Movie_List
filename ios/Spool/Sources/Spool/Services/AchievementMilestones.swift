import Foundation
import Supabase

/// The post-write achievement hook + its milestone-feed emitter (C7-iOS Task 2).
///
/// `grant_achievements()` is called FIRE-AND-FORGET after a confirmed primary
/// write (rank / journal / follow). This enum owns the ONE grant-then-emit
/// sequence every hook site runs, so the milestone-per-new-key behaviour is
/// written once and tested once:
///
///   1. call `AchievementsClient.grant()` → the `text[]` of badge keys newly
///      granted in THIS call (empty when nothing crossed a threshold);
///   2. for EACH new key, emit ONE `milestone` activity event
///      (`event_type: 'milestone'`, metadata `{ badgeKey, badgeIcon,
///      milestoneDescription }`) — mirroring web `achievementService.checkAndGrantBadges`'s
///      post-RPC loop (`services/achievementService.ts:64-71`) + `feedService.logMilestoneEvent`
///      (`services/feedService.ts:722-745`).
///
/// This is the RECOMMENDED post-write pattern the contract documents for iOS —
/// an intentional, ledgered improvement over web's tab-mount-only grant call
/// (`docs/contracts/shared-payloads.md` § achievements, "Client call rule").
/// The web milestone loop is CLIENT-SIDE + one-shot-lossy; iOS mirrors that
/// exactly (a failed emit is logged, never retried, never surfaced).
///
/// Contract invariants enforced here:
///   - Uses `grant()` (NOT `grantQuietly()`) because it needs the NEW-key list
///     to emit one milestone per new badge. Every error is swallowed with a log
///     (never thrown) — a grant/emit failure must never affect the triggering
///     action's UX. The whole sequence is meant to run in a DETACHED task at the
///     hook sites so it never gates or delays the primary write.
///   - iOS MUST NOT emit a milestone for a badge key that was already held
///     before the call — the loop iterates ONLY the RPC's returned new keys, so
///     a re-held badge (idempotent `ON CONFLICT DO NOTHING` returns nothing)
///     never emits. Empty return → zero events.
///   - Clients NEVER write `badge_unlock` notification rows — the RPC does that
///     server-side atomically. This emitter writes ONLY `activity_events`
///     milestone rows; the bell renders the `badge_unlock` rows the RPC wrote
///     (`NotificationBellView` already maps that type — verified, no change).
///
/// The milestone copy map (`BADGE_MILESTONE_COPY`) is ported VERBATIM from web
/// `services/achievementService.ts:17-33` — the copy source the contract pins
/// ("Milestone copy map: `services/achievementService.ts` `BADGE_MILESTONE_COPY`").
/// It is DISTINCT from `BadgeCatalog` (the catalog's icons/descriptions differ,
/// e.g. `first_rank` icon 🎬/🎯, `rank_10` icon 🎞️/🎯): the milestone feed card
/// uses THIS map, the profile badge grid uses `BadgeCatalog`. The unknown-key
/// fallback matches web's `{ icon: '🏅', description: 'Unlocked: <key>' }`.
///
/// Header last reviewed: 2026-07-10
public enum AchievementMilestones {

    // MARK: - Milestone copy (verbatim web BADGE_MILESTONE_COPY)

    /// icon + human description per badge key, ported byte-for-byte from web
    /// `services/achievementService.ts:17-33`. EN-only (web keeps it client-side,
    /// out of the i18n tables) so it stays EN here, matching `BadgeCatalog`.
    /// 15 grantable keys (`early_adopter` has no RPC rule so never appears in a
    /// grant return, hence no entry — same as web).
    public static let milestoneCopy: [String: (icon: String, description: String)] = [
        "first_rank": ("🎬", "Ranked their first movie"),
        "rank_10": ("🎯", "Ranked 10 movies"),
        "rank_25": ("🏅", "Ranked 25 movies"),
        "rank_50": ("🏆", "Ranked 50 movies"),
        "rank_100": ("👑", "Ranked 100 movies"),
        "first_review": ("✍️", "Wrote their first review"),
        "review_10": ("📝", "Wrote 10 reviews"),
        "first_follow": ("🤝", "Followed their first friend"),
        "followers_10": ("⭐", "Reached 10 followers"),
        "followers_50": ("🌟", "Reached 50 followers"),
        "first_list": ("📋", "Created their first list"),
        "genre_5": ("🎭", "Explored 5 genres"),
        "genre_10": ("🌈", "Explored 10 genres"),
        "s_tier_10": ("💎", "10 movies in S tier"),
        "d_tier_5": ("🗑️", "5 movies in D tier"),
    ]

    /// The milestone-card copy for a badge key, falling back to web's
    /// `{ icon: '🏅', description: 'Unlocked: <key>' }` for an unknown key
    /// (a newer server badge this build doesn't map) — never drop the event.
    public static func copy(for key: String) -> (icon: String, description: String) {
        milestoneCopy[key] ?? ("🏅", "Unlocked: \(key)")
    }

    // MARK: - Pure wire-payload builder (tested)

    /// The `activity_events` row for ONE `milestone` event. `event_type` is
    /// `'milestone'`; there are NO media columns (web `logMilestoneEvent` writes
    /// only `actor_id` + `event_type` + `metadata`). `metadata` is exactly
    /// `{ badgeKey, badgeIcon, milestoneDescription }` — the shape the feed card
    /// reads (`feedService.ts:410-412`) and web writes (`feedService.ts:733-737`).
    /// `actor_id` is the earner (their own id; the milestone is self-authored,
    /// and `activity_events` INSERT RLS requires `auth.uid() = actor_id`). UUID
    /// lowercased on the wire (web parity — Swift UUIDs uppercase).
    public static func milestoneEventPayload(actorID: UUID, key: String) -> MilestoneEventPayload {
        let info = copy(for: key)
        return MilestoneEventPayload(
            actor_id: actorID.uuidString.lowercased(),
            event_type: "milestone",
            metadata: MilestoneMetadata(
                badgeKey: key,
                badgeIcon: info.icon,
                milestoneDescription: info.description
            )
        )
    }

    /// The milestone `activity_events` payloads for a batch of granted keys —
    /// ONE per key, in order. Pure (no IO) so the "one event per NEW key, empty
    /// return → zero events, unknown-key fallback" behaviour is tested with zero
    /// network. `grantAndEmitMilestones` feeds this the RPC's returned NEW keys
    /// only, so a re-held badge (never in the return array) yields no payload.
    public static func milestonePayloads(actorID: UUID, newKeys: [String]) -> [MilestoneEventPayload] {
        newKeys.map { milestoneEventPayload(actorID: actorID, key: $0) }
    }

    // MARK: - Grant + emit (fire-and-forget hook)

    /// Call `grant_achievements()` and emit one `milestone` activity event per
    /// NEWLY granted badge key. The single post-write sequence every hook site
    /// runs (detached, so it never gates the primary write).
    ///
    /// Never throws — a grant failure is swallowed (`AchievementsClient.grant`'s
    /// error is caught here and logged), an empty return emits nothing, and each
    /// per-key emit is best-effort. Mirrors web `checkAndGrantBadges`: emit ONLY
    /// for the RPC's returned new keys (a re-held badge never re-emits).
    public static func grantAndEmitMilestones() async {
        let newKeys: [String]
        do {
            newKeys = try await AchievementsClient.grant()
        } catch {
            NSLog("[AchievementMilestones] grant failed (suppressed): \(error)")
            return
        }
        guard !newKeys.isEmpty else { return }

        // The earner == the caller (auth.uid()); resolved once for the whole
        // batch. No session → nothing to author (should not happen post-write,
        // but stays a silent no-op like every other emitter).
        guard let actorID = await SpoolClient.currentUserID() else {
            NSLog("[AchievementMilestones] \(newKeys.count) new badge(s) but no session — skipping milestone emit")
            return
        }
        for payload in milestonePayloads(actorID: actorID, newKeys: newKeys) {
            await emit(payload)
        }
    }

    /// Insert ONE `milestone` activity event. Fire-and-forget best-effort — a
    /// feed-insert hiccup never surfaces (the badge already granted server-side);
    /// logged for device-log triage, exactly like `RankMoveEmitter` /
    /// `JournalEmitters`. No client → silent no-op.
    public static func emit(_ payload: MilestoneEventPayload) async {
        guard let client = SpoolClient.shared else { return }
        do {
            _ = try await client.from("activity_events").insert(payload).execute()
        } catch {
            NSLog("[AchievementMilestones] milestone activity_events insert failed (\(payload.metadata.badgeKey)): \(error)")
        }
    }
}

// MARK: - Wire payloads (snake_case for PostgREST)

/// `activity_events` insert for `event_type: 'milestone'`. Only three top-level
/// keys — web `logMilestoneEvent` writes NO media columns for a milestone row,
/// so (unlike the review / ranking_move payloads) there are no nullable media
/// fields to encode. Synthesized `Encodable` is fine: every field is always
/// present.
public struct MilestoneEventPayload: Encodable, Equatable {
    let actor_id: String
    let event_type: String
    let metadata: MilestoneMetadata
}

/// `activity_events.metadata` for a `milestone` — exactly
/// `{ badgeKey, badgeIcon, milestoneDescription }`, all three keys ALWAYS present
/// (web `feedService.ts:733-737`). camelCase — jsonb is stored verbatim.
public struct MilestoneMetadata: Encodable, Equatable {
    let badgeKey: String
    let badgeIcon: String
    let milestoneDescription: String
}
