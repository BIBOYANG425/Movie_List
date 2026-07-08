# C2-iOS Journal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** The full manual journal on iOS (no AI agent) — contract-faithful `journal_entries` CRUD, likes, search, photos, a composer for all 15 editable fields, an entry list inside the Stubs tab, and ceremony "write more" seeding the composer.

**Architecture:** Pure/tested contract + models under thin SwiftUI, mirroring the feed cycle. `JournalEntryContract` owns marshalling + visibility resolution; `JournalRepository` (actor) owns I/O; `PhotoStore` owns photos; `JournalDraftModel`/`JournalListModel` are @MainActor ObservableObjects; views extend `StubsScreen` and add the composer/list/card. Backend is LIVE in prod (PR #33 migrations applied), so network paths work on device now.

**Tech Stack:** Swift 5.9 / SwiftUI (SwiftPM `ios/Spool`), supabase-swift, PhotosUI, XCTest.

## Global Constraints (the binding journal_entries contract — every task inherits this)

- Branch `feat/ios-parity-c2-journal` (spec at 5a89d4c). Suite baseline: run `swift test --package-path ios/Spool` to get the current count; it stays green; every pure helper ships RED-first tests.
- **Full-replace upsert:** `upsertJournalEntry` writes ALL 20 client columns (`user_id, tmdb_id, title, poster_url, rating_tier, review_text, contains_spoilers, mood_tags, vibe_tags, favorite_moments, standout_performances, watched_date, watched_location, watched_with_user_ids, watched_platform, is_rewatch, rewatch_note, personal_takeaway, photo_paths, visibility_override`) with `?? null / ?? [] / ?? false` defaults, `onConflict: 'user_id,tmdb_id'`. No partial path — any omitted field WIPES it. Empty text → null.
- **Probe-before-edit:** before editing an existing entry, load the owner's FULL row (`getOwnEntry`, `select('*')`) and round-trip every field. The freshly-probed owner row always wins over any row from a list/search (those omit `personal_takeaway`). Pure seam `pickEntryForEdit(probed, passed)` — probed wins, passed backstops a nil probe, both nil → new entry.
- **Server-owned, never client-written:** `id, created_at, updated_at, like_count, search_vector`.
- **rating_tier** is NEVER from the form — looked up from `user_rankings.tier` for `(user_id, tmdb_id)` at every upsert (null if unranked).
- **Visibility:** `resolveVisibility(override, profileVisibility) = COALESCE(override, profileVisibility)`; values `public|friends|private|nil`; nil override = inherit profile default; invalid override → `private` (fail-closed); unknown profile visibility → `friends` (never public). RLS is server-enforced for reads; clients never re-filter reads.
- **Upsert side effects (mirror web exactly):** (1) emit a `review` activity event ONLY when `review_text` non-empty AND resolved visibility = `public` (`shouldEmitReviewEvent`; fetch author profile_visibility only when override nil; failed fetch → 'friends' → gate closed). (2) one `journal_tag` notification per `watched_with_user_ids` friend (body = first 100 chars of review) — fires regardless of visibility, re-fires each save (audit D2 known flaw; mirror as-is).
- **Likes:** `journal_entry_likes(entry_id,user_id)` table; toggle = INSERT `ON CONFLICT DO NOTHING` / DELETE own; read `like_count` from the row; batch initial liked-state via `likedEntryIds`; NEVER call the dropped increment/decrement RPCs or write `like_count`. Any like bumps `updated_at` — render `created_at`, not `updated_at`.
- **Photos:** paths only (`{userId}/{entryId}/{index}.{ext}`, bucket `journal-photos`, max `JOURNAL_MAX_PHOTOS`=6); private bucket, owner-only storage RLS; render via fresh 30-day signed URLs (`JOURNAL_PHOTO_SIGNED_URL_TTL_SECONDS`=2592000), never persist a signed URL. **This cycle renders ONLY the owner's own journal (inside the owner's Stubs tab), so owner-only SELECT is sufficient — do NOT build any cross-user journal/photo surface (that needs the storage-policy extension first, out of scope).**
- **personal_takeaway** owner-only: iOS only ever reads its own entries here (owner path `select('*')`), so it's always safe to read/render in this cycle; never build a cross-user read.
- **Dates:** `watched_date` default = local `yyyy-MM-dd` (reuse the local-date helper from stubs — `StubWriteContract.localDateString` or the equivalent; do NOT use a GMT formatter). Tag constant ID sets (`MOOD_TAGS` 23 ids, `VIBE_TAGS` 11 ids, `PLATFORM_OPTIONS` 13 ids — the "14" miscounted a type-annotation line, `JOURNAL_MAX_MOMENTS`=5) are in web `constants.ts:192,222,236,271` — mirror the ID lists verbatim into a Swift constants file; iOS is the source of the labels for its own UI but the IDs must match web.
- No UIKit except `PhotosUI` (PHPicker is the sanctioned exception; no `import UIKit` for layout). Conventional commits + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. `JournalEntrySheet` (web dead code) is NOT ported. AI agent + cross-user journal viewing + journal_tag deep-linking are OUT of scope (ledgered).

---

### Task 1: Journal models + tag constants + `JournalEntryContract` (pure)

**Files:** Create `ios/Spool/Sources/Spool/Services/JournalModels.swift`, `ios/Spool/Sources/Spool/Services/JournalConstants.swift`, `ios/Spool/Sources/Spool/Services/JournalEntryContract.swift`; Test `ios/Spool/Tests/SpoolTests/JournalContractTests.swift`.

**Interfaces — Produces (Tasks 2-6 depend on these exact names):**
```swift
public enum JournalVisibility: String, Sendable { case pub = "public", friends, priv = "private" }
public struct StandoutPerformance: Codable, Equatable, Sendable { public let personId: Int; public let name: String; public let character: String? }
public struct JournalRow: Codable, Sendable, Hashable {   // full select('*') owner row DTO — decodes 23 fields (omits search_vector + updated_at, both intentional); server cols optional-decoded
    public let id: UUID; public let user_id: UUID; public let tmdb_id: String; public let title: String
    public let poster_url: String?; public let rating_tier: String?; public let review_text: String?
    public let contains_spoilers: Bool; public let mood_tags: [String]?; public let vibe_tags: [String]?
    public let favorite_moments: [String]?; public let standout_performances: [StandoutPerformance]?
    public let watched_date: String?; public let watched_location: String?; public let watched_with_user_ids: [UUID]?
    public let watched_platform: String?; public let is_rewatch: Bool; public let rewatch_note: String?
    public let personal_takeaway: String?; public let photo_paths: [String]?; public let visibility_override: String?
    public let like_count: Int; public let created_at: String
}
public struct JournalDraft: Equatable, Sendable {   // the editable model
    public var tmdbId: String; public var title: String; public var posterUrl: String?
    public var reviewText: String; public var oneLiner: String   // oneLiner maps into review_text per web? NO — see note
    public var containsSpoilers: Bool; public var moodTags: [String]; public var vibeTags: [String]
    public var favoriteMoments: [String]; public var standoutPerformances: [StandoutPerformance]
    public var watchedDate: String; public var watchedLocation: String; public var watchedWithUserIds: [UUID]
    public var watchedPlatform: String?; public var isRewatch: Bool; public var rewatchNote: String
    public var personalTakeaway: String; public var photoPaths: [String]; public var visibilityOverride: JournalVisibility?
}
public struct JournalUpsertPayload: Encodable, Equatable { /* the 20 client columns, snake_case, explicit-null encoding for optionals */ }
public enum JournalEntryContract {
    static func resolveVisibility(override: JournalVisibility?, profileVisibility: String?) -> JournalVisibility
    static func upsertPayload(userID: UUID, ratingTier: String?, from draft: JournalDraft) -> JournalUpsertPayload
    static func draft(from row: JournalRow) -> JournalDraft
    static func pickEntryForEdit(probed: JournalRow?, passed: JournalRow?) -> JournalRow?   // probed ?? passed
    static func shouldEmitReviewEvent(reviewText: String, resolved: JournalVisibility) -> Bool  // non-empty && resolved == .pub
}
```
Note on the one-liner: the ceremony one-liner maps to `review_text` (web has no separate one-liner column; the ceremony's `line` becomes the review text for a quick entry). `JournalDraft.oneLiner` is a CEREMONY-seed convenience — Task 6 folds it into `reviewText` when opening the composer; the contract's `upsertPayload` reads only `reviewText`. Drop `oneLiner` from JournalDraft if it complicates round-trip; simplest is: ceremony sets `reviewText = line` directly and there is NO separate oneLiner field. **Implementer: use the simplest form — `reviewText` only, no `oneLiner`.**

- Steps: mirror the tag ID lists from web `constants.ts` (read it) into `JournalConstants.swift` (`moodTagIDs`, `vibeTagIDs`, `platformIDs`, `journalMaxMoments=5`, `journalMaxPhotos=6`, `journalPhotoSignedURLTTL=2592000`). RED-first tests: `resolveVisibility` full truth table (6 rows + invalid→private + unknown-profile→friends + nil/nil); `upsertPayload` asserts the exact 20-key set via JSON encode (no field dropped, explicit null for nil optionals, empty text→null, `?? []`/`?? false` defaults); `draft(from:)` round-trips a full row (encode draft→payload, decode row→draft, assert equal fields); `pickEntryForEdit` (probed wins / passed backstop / both nil); `shouldEmitReviewEvent` (empty→false, non-empty+public→true, non-empty+friends→false).
- Commit `feat(ios): journal models, tag constants, pure entry contract`.

### Task 2: `JournalRepository` (actor) — CRUD, search, likes, rating-tier lookup

**Files:** Create `ios/Spool/Sources/Spool/Services/JournalRepository.swift`; Test `ios/Spool/Tests/SpoolTests/JournalRepositoryLogicTests.swift` (pure parts only — the RPC arg builder, like payload, liked-set reducer, search-row mapping).

**Interfaces — Produces:**
```swift
public actor JournalRepository {
    public static let shared: JournalRepository
    public func getOwnEntry(tmdbId: String) async throws -> JournalRow?        // owner select('*')
    public func listOwnEntries(limit: Int = 50) async throws -> [JournalRow]   // own, order created_at desc
    public func upsert(_ payload: JournalUpsertPayload) async throws -> JournalRow  // full replace; returns the row
    public func ratingTier(tmdbId: String) async throws -> String?             // user_rankings.tier lookup
    public func deleteEntry(tmdbId: String) async throws
    public func search(_ query: String, targetUserID: UUID) async throws -> [JournalSearchRow]  // invoker RPC, 23 cols
    public func toggleLike(entryID: UUID, currentlyLiked: Bool) async throws    // insert ON CONFLICT DO NOTHING / delete own
    public func likedEntryIDs(_ entryIDs: [UUID]) async throws -> Set<UUID>     // batch, viewer = current user
}
public struct JournalSearchRow: Codable, Sendable, Hashable { /* 23 cols — NO personal_takeaway, NO search_vector */ }
public enum JournalRepoLogic {  // pure, tested
    static func searchRpcArgs(query: String, targetUserID: UUID) -> [String: AnyJSON]
    static func likeInsertPayload(entryID: UUID, userID: UUID) -> ... ; static func likedSet(from rows: [LikeRow]) -> Set<UUID>
}
```
- The upsert path: caller passes a fully-built `JournalUpsertPayload` (rating_tier already resolved via `ratingTier(...)` — the model does the lookup then builds the payload, or the repo exposes a convenience that looks up tier then upserts; pick one and document). Repo actor + `SpoolClient.shared` guard + `[JournalRepository]` logging like FollowRepository/StubRepository. Reads fail soft where the UI needs empty (`listOwnEntries`, `search`, `likedEntryIDs` → throw and let the model catch to empty — match the feed convention).
- Pure tests RED-first: `searchRpcArgs` shape (`{search_query, target_user_id}`); like payload; `likedSet` reducer; search-row decode excludes takeaway (the DTO has no such field — a compile+decode test). The side-effect emission (review event, journal_tag) lives in the MODEL (Task 4), not here — repo stays pure CRUD.
- Commit `feat(ios): JournalRepository — entries, search, likes`.

### Task 3: `PhotoStore` — PHPicker upload + signed URLs

**Files:** Create `ios/Spool/Sources/Spool/Services/PhotoStore.swift`; Test `ios/Spool/Tests/SpoolTests/PhotoStoreLogicTests.swift`.

**Interfaces — Produces:**
```swift
public enum PhotoStoreLogic {   // pure, tested
    static func photoPath(userID: UUID, tmdbId: String, index: Int, ext: String) -> String   // "{uid}/{tmdb}/{i}.{ext}"
    static func extractPath(fromStored value: String) -> String?   // legacy full-URL → path; unsignable → nil
}
public actor PhotoStore {
    public static let shared: PhotoStore
    public func upload(data: Data, userID: UUID, tmdbId: String, index: Int, ext: String) async throws -> String  // returns path
    public func signedURL(forPath path: String) async throws -> URL     // 30-day TTL
    public func signedURLs(forPaths paths: [String]) async throws -> [String: URL]  // batch
}
```
- Path scheme: match web exactly (`{userId}/{tmdbId}/{index}.{ext}` — verify web's exact segments in `journalService`/the photos contract; the contract says `{userId}/{entryId}/{index}` but entries are keyed by tmdb_id per-movie, so confirm whether web uses entryId (uuid) or tmdbId in the path and mirror EXACTLY — cite in the report). PHPicker selection is a VIEW concern (Task 6 supplies `Data`); PhotoStore takes bytes. Signed URL via supabase storage `createSignedURL`.
- Pure tests RED-first: `photoPath` format; `extractPath` (already-a-path passthrough, full-public-URL→path, foreign/unsignable→nil).
- Commit `feat(ios): PhotoStore — journal photo upload + signed URLs`.

### Task 4: `JournalDraftModel` — composer state, probe-before-edit, save + side effects

**Files:** Create `ios/Spool/Sources/Spool/Services/JournalDraftModel.swift`; Test `ios/Spool/Tests/SpoolTests/JournalDraftModelTests.swift`.

**Interfaces — Produces:** `@MainActor final class JournalDraftModel: ObservableObject` with injected repo closures (testability like the feed models): `openForEntry(tmdbId:title:posterUrl:seed:)` (async: probe full owner row via `getOwnEntry`, `pickEntryForEdit(probed, seed)`, populate `@Published draft`; a nil probe with a `seed` starts from the ceremony seed; both nil = fresh draft), `save()` (resolve rating_tier, build payload, upsert, then side effects: emit review event when `shouldEmitReviewEvent`, journal_tag notification per tagged friend), field mutators, `@Published saving`, `@Published inlineError`, photo add/remove (calls PhotoStore, appends path). `guard !saving` re-entrancy on save.
- The probe-before-edit is the load-bearing correctness point: `openForEntry` MUST await the full owner-row fetch before the composer renders editable fields (mirror the feed's chat→draft phase gating: start in a `loading` state, populate, then `ready`). A save from a not-fully-loaded draft is impossible by construction.
- Tests RED-first (injected closures, no network): probe-wins on open (probed row's `personalTakeaway` survives even when a takeaway-less `seed`/passed row is provided — the exact web wipe-bug guard); save builds a full-20-field payload (never partial); review-event emitted only on non-empty review + public resolved; journal_tag fired per friend; re-entrancy guard; ceremony-seed path (nil probe + seed → draft seeded from moods+line).
- Commit `feat(ios): JournalDraftModel — probe-before-edit composer state + side effects`.

### Task 5: Stubs/journal segmented header + `JournalListModel` + list/card views

**Files:** Modify `ios/Spool/Sources/Spool/Screens/StubsScreen.swift` (add `stubs`/`journal` segmented header — reuse the feed's segmented control idiom; read FeedScreen's header); Create `ios/Spool/Sources/Spool/Screens/JournalListView.swift`, `ios/Spool/Sources/Spool/Components/JournalEntryCard.swift`, `ios/Spool/Sources/Spool/Services/JournalListModel.swift`; Test `ios/Spool/Tests/SpoolTests/JournalListModelTests.swift`.

**Interfaces — Produces:** `@MainActor final class JournalListModel: ObservableObject` (injected repo closures): `load()` (`listOwnEntries` + batch `likedEntryIDs` for the loaded ids), `search(query:)` (debounced-ish; empty query → list), `toggleLike(entryID:)` (optimistic via pure `applyLikeToggle` clamped at 0, revert on throw), `@Published entries`, `@Published likedIDs`, `@Published loadFailed`. `JournalEntryCard(row:liked:onTap:onToggleLike:)` — torn-page paper: title/year, mood-tag stamps (labels from JournalConstants), review excerpt, photo thumbnail strip (signed URLs via PhotoStore, owner's own photos — camera glyph if present-but-unloaded), visibility glyph, like count. `JournalListView` — reverse-chron list + search field + empty state (`no entries yet — rank something and write about it`). Tapping a card opens the composer (Task 6) via `getOwnEntry` probe.
- Pure tests RED-first: `applyLikeToggle` (like→+1/liked, unlike→-1 clamped≥0); liked-set batch mapping; search-vs-list mode switch. Views verified by build + previews.
- Commit `feat(ios): stubs/journal segmented header, journal list + entry card`.

### Task 6: `JournalComposer` view + ceremony "write more" wiring

**Files:** Create `ios/Spool/Sources/Spool/Screens/JournalComposer.swift`; Modify the ceremony finish path (`ios/Spool/Sources/Spool/App/SpoolAppRoot.swift` around the `RankPrintedScreen` onFinish / the moods+line handoff ~298-318, and/or `RankPrintedScreen.swift`) to offer "write more" → open `JournalComposer` seeded with moods + one-liner (as `reviewText`). Test: any new pure presentation helper only.

- `JournalComposer(model: JournalDraftModel, onClose:)` — single scrolling paper sheet (SpoolScreen idiom), collapsible sections: **the moment** (review text editor, spoiler toggle), **the feeling** (mood tags + vibe tags as selectable stamps from JournalConstants), **the details** (favorite moments up to 5, standout performances add/remove, watch context: location text / platform picker / with-whom friend picker writing `watchedWithUserIds`, rewatch toggle + note), **private** (personal takeaway — labeled owner-only), **photos** (PHPicker up to 6, thumbnails via PhotoStore, remove), **visibility** (public/friends/private/default picker — "default" = nil override, with a one-line note that default follows your profile). Save button (disabled while `saving`), the composer opens in `loading` until the probe resolves.
- Ceremony: after `RankPrintedScreen`'s existing moods+line, add a "write more" affordance; tapping constructs a `JournalDraftModel`, calls `openForEntry(tmdbId: movie.id, title:, posterUrl:, seed:)` with the moods+line folded into the draft (`reviewText = line`, `moodTags = moods`), presents `JournalComposer`. Not tapping still writes the minimal quick entry via the same payload path (stage a) — wire that minimal write into the ceremony finish (moods+line → upsert) so a plain rank produces a real journal_entry, matching the audit's stage-a recommendation. (Verify: today the ceremony writes moods/line only to `user_rankings.notes`; ADD the journal_entry write — do not remove the notes write unless the contract says to; check `RankPersistence`/the C0 stub path for where to hook.)
- Build + full suite green; previews for the composer (loading, fresh, pre-filled, each visibility). Commit `feat(ios): journal composer + ceremony write-more, quick-entry writes a journal row`.

### Task 7: Docs + ledger

**Files:** Modify `docs/contracts/shared-payloads.md` (add an `iOS implementations` line to the journal section: JournalEntryContract/JournalRepository/PhotoStore + the probe-before-edit + owner-only-this-cycle notes); `docs/plans/2026-07-07-ios-parity-ledger.md` (C2 row → iOS journal built; deferred: AI agent chat, cross-user journal viewing + its storage-policy prerequisite, journal_tag deep-link; device-smoke checklist).
- Final contract re-verify: the 20-column upsert key set matches the contract; grep no `import UIKit` outside PhotoStore's PhotosUI; no GMT date formatter in journal code. Commit `docs: C2 ledger — iOS journal built`.

## Self-Review Notes

- Spec coverage: contract/marshalling/visibility (T1), CRUD+search+likes (T2), photos (T3), probe-before-edit composer state + side effects (T4), stubs/journal header + list/card (T5), composer view + ceremony seed + stage-a quick write (T6), docs (T7). Every spec section maps to a task.
- The load-bearing correctness invariants (full-replace, probe-before-edit, rating_tier lookup, review-event gate, owner-only-this-cycle) are all in Global Constraints so every task inherits them, and each has a specific RED-first test in T1/T2/T4.
- Type consistency: `JournalRow`/`JournalDraft`/`JournalUpsertPayload`/`JournalVisibility`/`JournalEntryContract`/`JournalRepository`/`PhotoStore`/`JournalDraftModel`/`JournalListModel` names consistent across tasks. Reuse from main: `AnyJSON`/`JSONObject`, `SpoolClient`, `PostgresErrors`, the local-date helper, `SpoolTokens`/`SpoolFonts`/`SpoolScreen`.
- Scope guard: OWNER'S OWN journal only this cycle — no cross-user journal/photo surface (would need the storage-policy extension); AI agent deferred. Both ledgered.
