# C1 iOS Feed Data Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The complete iOS data layer for the social feed and notifications — repositories, DTOs, cursor pagination, engagement, mutes, and activity-event metadata alignment — against the contracts locked by the C1 web PR (#32). UI screens are a separate plan (owner design input pending).

**Architecture:** `FeedRepository` (actor) speaks the two C1 RPCs (`get_feed_page` keyset pagination with server-returned `boosted_ts` cursors; `get_feed_ranking_scores` batch scores) and the engagement tables; pure, unit-tested helpers mirror web's client-side logic (mute filtering, milestone throttle, filters, card mapping) exactly as `services/feedService.ts` does post-#32. `NotificationRepository` implements the bell contract. `RankingRepository`'s event insert gains the contract `metadata`. All network calls follow the existing repository actor pattern; everything pure is XCTest-covered; network paths are exercised only after PR #32's migrations exist in prod.

**Tech Stack:** Swift 5.9 (SwiftPM `ios/Spool`), supabase-swift, XCTest.

## Global Constraints

- **Branch** `feat/ios-parity-c1-feed-data` off current `main` (4c4dacf). The PR is HELD behind PR #32's merge (the RPCs don't exist in prod until then) — code + pure tests only must be green standalone.
- **Binding contracts (quoted inline below; source: `docs/contracts/shared-payloads.md` on branch `fix/c1-feed-web-blocking` @ e57850c and audit §1/§4):**
  - Feed ordering: `boosted_ts = created_at + 2h × (event_type='review')`, WINDOWLESS, computed server-side by `get_feed_page(mode text, cursor_rank timestamptz, cursor_id uuid, page_size int)` which returns each `activity_events` row PLUS a `boosted_ts` column. Clients echo `(boosted_ts, id)` verbatim into the next call's cursor — NEVER recompute. First page: null cursor pair. `mode` ∈ {'friends','explore'}; unknown raises. `page_size` ≤ 100.
  - Scores: `get_feed_ranking_scores(pairs jsonb)` with `pairs = [{"user_id","tmdb_id"}]` → rows `(user_id, tmdb_id, score)`; missing pair = no row = hide badge.
  - `activity_events` INSERT (both clients): `actor_id, event_type, media_tmdb_id, media_title, media_tier, media_poster_url, metadata`; never `id/created_at/target_user_id`. iOS writes `ranking_add` metadata `{ notes?, year?, watched_with_user_ids? }` — keys OMITTED when falsy/empty (not null-valued).
  - Reactions: `activity_reactions(event_id, user_id, reaction)` PK-triple; toggle = insert / delete own row; duplicate-key (23505) on insert = treat as success. Comments: `activity_comments`, list asc limit 100, 1-level reply nesting via `parent_comment_id`, body trimmed ≤ 500, delete own only.
  - Mutes: `feed_mutes` CRUD (user-mutes and movie-mutes), applied client-side at read time.
  - Notifications: row `{id, user_id, type, title, body?, actor_id?, reference_id?, is_read, created_at}`; badge = head-count of `is_read=false` (15 s poll); open = fetch newest 30 with actor profiles batch-joined (avatar from `avatar_path` only), then bulk mark exactly the fetched unread ids read. Types: `new_follower, review_like, list_like, badge_unlock, ranking_comment, journal_tag`; unknown types render with the `new_follower` fallback. Titles are baked English strings — iOS writes identical strings. `new_follower` write on follow ALREADY exists on iOS (`FollowRepository.follow` — verify, do not duplicate).
- Milestone throttle: max 3 milestone cards per actor per LOCAL calendar day within the consumed page-stream (web post-#32 semantics: counted per resume-session from the cursor onward — mirror THAT, not the old prefix semantics).
- Event-type filter parity: explore/friends card sets exclude `ranking_remove` (web `getEventTypesForFilter`).
- All repositories follow the existing actor + `SpoolClient.shared` guard pattern; errors log with a `[FeedRepository]`/`[NotificationRepository]` prefix; reads fail soft to empty (screens render empty states), writes surface errors to callers.
- No UIKit. Test command: `swift test --package-path ios/Spool`; suite currently 84 tests — all stay green; every pure helper below ships RED-first tests.
- Conventional commits ending `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Activity-event metadata alignment

**Files:** Modify `ios/Spool/Sources/Spool/Services/RankingRepository.swift` (ActivityEventPayload + the insert call in `insertRanking`); Test `ios/Spool/Tests/SpoolTests/ActivityMetadataTests.swift` (new).
**Interfaces — Produces:**
```swift
public struct ActivityMetadata: Encodable, Equatable {
    public let notes: String?
    public let year: String?
    public let watchedWithUserIds: [UUID]?
    // encodes snake_case keys; OMITS nil/empty members entirely (contract: keys absent when falsy)
}
```
- `ActivityEventPayload` gains `metadata: ActivityMetadata` encoded as a jsonb object (`{}` when all members omitted). `insertRanking` populates it from the `RankingInsert` it already receives (`notes`, `year`; `watchedWithUserIds` plumbed as a new optional `RankingInsert` field defaulting nil — RankPersistence passes nil today, C-later wires ceremony friends).
- Tests (RED first): full metadata → exact key set `{notes, year, watched_with_user_ids}`; empty strings/empty array/nils → encoded object is `{}` (keys ABSENT, verified via JSONSerialization); UUID array encodes lowercase uuid strings.
- Commit `feat(ios): ranking activity events carry contract metadata`.

### Task 2: FeedRepository — pagination + scores + pure feed pipeline

**Files:** Create `ios/Spool/Sources/Spool/Services/FeedRepository.swift` (actor: network) and `ios/Spool/Sources/Spool/Services/FeedPipeline.swift` (pure enum: filtering/throttle/mapping/cursor); Test `ios/Spool/Tests/SpoolTests/FeedPipelineTests.swift`.
**Interfaces — Produces:**
```swift
public struct FeedCursor: Equatable, Sendable { public let boostedTs: String; public let id: UUID }
public struct FeedEventRow: Codable, Sendable, Hashable {   // get_feed_page row incl. boosted_ts
    public let id: UUID; public let actor_id: UUID; public let event_type: String
    public let media_tmdb_id: String?; public let media_title: String?
    public let media_tier: String?; public let media_poster_url: String?
    public let metadata: JSONObject?; public let created_at: String; public let boosted_ts: String
}
public enum FeedMode: String, Sendable { case friends, explore }
public actor FeedRepository {
    public static let shared: FeedRepository
    public func fetchPage(mode: FeedMode, cursor: FeedCursor?, pageSize: Int = 20) async throws -> [FeedEventRow]
    public func rankingScores(pairs: [(userID: UUID, tmdbID: String)]) async throws -> [String: Double] // "uid:tmdb" keys
}
public enum FeedPipeline {  // pure, Swift mirror of web's post-#32 client logic
    public static func cursor(fromLastConsumed row: FeedEventRow) -> FeedCursor          // verbatim echo
    public static func applyMutes(_ rows: [FeedEventRow], mutedUsers: Set<UUID>, mutedMedia: Set<String>) -> [FeedEventRow]
    public static func applyTypeFilter(_ rows: [FeedEventRow], allowed: Set<String>) -> [FeedEventRow]
    public static func throttleMilestones(_ rows: [FeedEventRow], counts: inout [String: Int], calendar: Calendar) -> [FeedEventRow]
        // key "actorId|yyyy-MM-dd(local)", cap 3 — per-resume counts, caller owns the dict per session
    public static func defaultEventTypes(explore: Bool) -> Set<String>   // both exclude ranking_remove
}
```
- `JSONObject` = the minimal `Codable` jsonb wrapper — check whether supabase-swift's `AnyJSON` is already available and idiomatic in this package; use it if so (verify, document choice).
- `fetchPage` decodes the RPC result; on the raise-classified errors (22023 etc.) rethrows; cursor params `cursor_rank`/`cursor_id` null on first page. NOTE in the actor's header: callable only once PR #32's migrations exist in prod; unit tests cover the pure layer only.
- Tests (RED first): cursor echo is byte-verbatim (µs string preserved); mute filtering (user + media, media key from `media_tmdb_id`); type filter excludes `ranking_remove` in both defaults; milestone throttle truth table (3 cap, per-actor, per-local-day via named-timezone calendars, counts carry across pages within a session, reset with a fresh dict); score-map key format `"\(uid):\(tmdb)"`.
- Commit `feat(ios): FeedRepository pagination + scores with pure feed pipeline`.

### Task 3: Engagement — reactions + comments

**Files:** Extend `FeedRepository.swift`; Test `ios/Spool/Tests/SpoolTests/FeedEngagementTests.swift` (pure parts).
**Interfaces — Produces:**
```swift
public struct EngagementCounts: Sendable, Equatable { public let reactions: [String: Int]; public let comments: Int; public let myReactions: Set<String> }
extension FeedRepository {
    public func engagement(for eventIDs: [UUID]) async throws -> [UUID: EngagementCounts]   // batched per page
    public func toggleReaction(eventID: UUID, reaction: String, currentlyMine: Bool) async throws -> Bool // returns new state; 23505 → true (PostgresErrors.isUniqueViolation)
    public func comments(for eventID: UUID) async throws -> [FeedComment]                   // asc, limit 100
    public func addComment(eventID: UUID, body: String, parentID: UUID?) async throws -> FeedComment // trims, rejects empty/&gt;500 (thrown CommentError)
    public func deleteComment(id: UUID) async throws
}
public struct FeedComment: Codable, Sendable, Hashable { /* id, event_id, user_id, body, parent_comment_id, created_at */ }
public enum FeedPipelineComments { public static func nest(_ flat: [FeedComment]) -> [(FeedComment, [FeedComment])] } // 1-level nesting, orphans surface as top-level
```
- Pure tests (RED first): comment body validation (trim, empty rejected, 500 boundary), 1-level nesting incl. orphaned-parent case, engagement-count aggregation from raw rows (pure reducer `EngagementReducer.aggregate(rows:myUserID:)` — extract it so it's testable), toggle-state truth table incl. 23505-as-success.
- Commit `feat(ios): feed reactions and comments`.

### Task 4: Mutes + NotificationRepository

**Files:** Extend `FeedRepository.swift` (mutes CRUD); Create `ios/Spool/Sources/Spool/Services/NotificationRepository.swift`; Test `ios/Spool/Tests/SpoolTests/NotificationTests.swift`.
**Interfaces — Produces:**
```swift
extension FeedRepository {
    public func mutes() async throws -> (users: Set<UUID>, media: Set<String>)
    public func muteUser(_ id: UUID) async throws; public func unmuteUser(_ id: UUID) async throws
    public func muteMedia(_ tmdbID: String) async throws; public func unmuteMedia(_ tmdbID: String) async throws
}
public enum NotificationKind: String, CaseIterable, Sendable { case newFollower = "new_follower", reviewLike = "review_like", listLike = "list_like", badgeUnlock = "badge_unlock", rankingComment = "ranking_comment", journalTag = "journal_tag"
    public static func orFallback(_ raw: String) -> NotificationKind } // unknown → .newFollower (contract fallback)
public actor NotificationRepository {
    public static let shared: NotificationRepository
    public func unreadCount() async throws -> Int                       // head count, is_read = false
    public func fetchLatest(limit: Int = 30) async throws -> [NotificationItem]  // newest first, actor profiles batch-joined (avatar_path only)
    public func markRead(ids: [UUID]) async throws                      // exactly the fetched unread ids
}
public struct NotificationItem: Sendable, Hashable { /* row fields + actorUsername?, actorAvatarPath? */ }
```
- Verify-before-code: `grep -n "new_follower" ios/Spool/Sources/Spool/Services/FollowRepository.swift` — the follow-notification write exists (C0 established this); do NOT add a second writer; cite the line in your report.
- Verify `feed_mutes` schema (column names for user-vs-media mutes) from the phase-5 migration before writing the CRUD.
- Pure tests (RED first): `NotificationKind.orFallback` for all 6 + unknown; mark-read id-set logic (only fetched AND unread); mute set-building from raw rows.
- Commit `feat(ios): feed mutes + notification repository`.

### Task 5: Docs + ledger

**Files:** `docs/plans/2026-07-07-ios-parity-ledger.md` (C1 row: iOS data layer built, PR held behind #32; note UI plan pending owner design input), plus a `## iOS implementations` pointer line in this plan's header area if drift found.
- Verify every DTO/field in Tasks 1-4 against the contract quotes in Global Constraints one final time; any mismatch found = fix the code, not the contract.
- Commit `docs: C1 ledger — iOS feed data layer`.

## Self-Review Notes

- UI intentionally out of scope (owner's visual questions pending) — FeedScreen/NotificationBell UI is Part B.
- Network paths cannot be integration-tested until #32's migrations exist; every algorithmic behavior is a pure helper with RED-first tests, matching the program's established pattern (C0/C1-web).
- Type consistency: `FeedCursor`/`FeedEventRow`/`FeedMode`/`EngagementCounts`/`FeedComment`/`NotificationKind`/`NotificationItem` names used consistently across Tasks 2-4; `PostgresErrors.isUniqueViolation` reused from C0.
- Task 1 is independently mergeable (metadata writes are contract-safe regardless of #32) but ships in this PR for one-cycle-one-PR discipline.
