# C1 iOS Feed UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The owner-approved ticket-wall feed UI: FeedScreen rebuilt as a wall of admit-one stubs with a friends/explore switcher, flip-the-ticket reactions/comments, a header notification bell, and the Settings visibility row — wired to the PR #34 data layer per the ledger's Part-B caller contract.

**Architecture:** A pure `FeedCards` layer (card model, mapping/coercion, avatar chain, score-pair rule) and a pure-orchestrated `FeedPageAssembler` (the refill loop with injected fetch closures — unit-testable without network) sit between the repositories and SwiftUI. Views split by responsibility: `FeedTicket` (front), `FeedTicketBack` (reactions/comments), `FeedTicketFlip` (container + animation), rebuilt `FeedScreen`, `NotificationBellView` + sheet, and a Settings visibility row. Spec (binding for all visual/copy decisions): `docs/plans/2026-07-08-c1-ios-feed-ui-design.md`.

**Tech Stack:** Swift 5.9 / SwiftUI (SwiftPM `ios/Spool`), existing `SpoolTokens`/`AdmitStub` component family, XCTest for all pure logic.

## Global Constraints

- Branch `feat/ios-parity-c1-feed-ui` (spec committed at a4429ed). Suite baseline 142 tests — stays green; every pure helper ships RED-first tests. `swift test --package-path ios/Spool`.
- **The ledger's Part-B caller contract is binding** (docs/plans/2026-07-07-ios-parity-ledger.md, C1-iOS notes): pipeline order = type filter → mutes → throttle (throttle LAST); throttle counts dict lives for ONE page-assembly call; `hasMore` = raw page count == page_size; max 10 RPC pages per assembly call; stop early once `boosted_ts` sinks below any active time cutoff; cursor advances over every consumed row (kept or dropped); repository reads throw — the UI layer catches to empty states; `rankingScores` caller catches to empty map.
- Reaction types fixed: `love, fire, laugh, sad, mind_blown` (stamp icons per spec §2). Comment composer ≤500 chars, `CommentError.empty/.tooLong` surfaced inline (not toasts).
- Copy voice: lowercase mono, existing app conventions (`find your people`, `public profiles appear here — make yours public in settings`).
- Unknown event types coerce to the ranking presentation; tier strings outside S–D render no stamp (guard, don't crash).
- Avatar chain: `avatar_url` (non-empty) → else storage public URL from `avatar_path` (mirror the app's existing avatar URL builder — find it in `Avatar.swift`/ProfileScreen and REUSE, don't invent) → else dicebear URL `https://api.dicebear.com/7.x/initials/png?seed=<username>` (verify the exact web format in `services/feedService.ts` and mirror).
- No UIKit. Preview/fixture mode must keep working (screens render `SpoolData` fixtures when no session — follow FeedScreen's existing `hasSession` pattern).
- Conventional commits ending `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Pure card layer — `FeedCards.swift`

**Files:** Create `ios/Spool/Sources/Spool/Services/FeedCards.swift`; Test `ios/Spool/Tests/SpoolTests/FeedCardsTests.swift`.
**Interfaces — Produces (Tasks 2–5 depend on these exact names):**
```swift
public enum FeedCardKind: String { case ranking, review, list, milestone }
public struct FeedCard: Identifiable, Hashable, Sendable {
    public let id: UUID                    // event id
    public let kind: FeedCardKind
    public let actorID: UUID
    public let eventType: String           // raw, for context menus/analytics
    public let mediaTmdbID: String?
    public let title: String?              // media_title
    public let tier: Tier?                 // nil when outside S–D (guard)
    public let posterURL: String?
    public let metadata: JSONObject?
    public let createdAt: String           // raw timestamptz
    public let boostedTs: String
    // hydration (filled by assembler):
    public var actorUsername: String?
    public var actorAvatarURL: String?     // post-fallback-chain, ready to load
    public var score: Double?              // ranking/review only, when RPC returned a row
}
public enum FeedCards {
    static func card(from row: FeedEventRow) -> FeedCard          // kind coercion + tier guard
    static func avatarURL(avatarUrl: String?, avatarPath: String?, username: String?) -> String
    static func scorePairs(for cards: [FeedCard]) -> [(userID: UUID, tmdbID: String)]  // ranking/review + mediaTmdbID only
    static func relativeTime(from createdAt: String, now: Date) -> String  // "2h", "3d" — mirror web's formatter buckets (verify in SocialFeedView/FeedCard components and cite)
}
```
- TDD: coercion table (all 6 types + unknown → .ranking), tier guard (S–D map, "X"/nil/empty → nil), avatar chain truth table (all 3 fallbacks + whitespace url), score-pair rule (kind × mediaTmdbID presence), relativeTime buckets incl. the exact unit boundaries web uses (read web first; cite lines in the test comments).
- Verify-before-code: the existing avatar URL builder for `avatar_path` (grep `avatar_path` in Sources — reuse); web's dicebear format + time buckets.
- Commit `feat(ios): FeedCard pure layer — mapping, coercion, avatar chain, score pairs`.

### Task 2: `FeedPageAssembler` — the refill loop, pure-orchestrated

**Files:** Create `ios/Spool/Sources/Spool/Services/FeedPageAssembler.swift`; Test `ios/Spool/Tests/SpoolTests/FeedPageAssemblerTests.swift`.
**Interfaces — Produces:**
```swift
public struct FeedAssemblyResult: Sendable { public let cards: [FeedCard]; public let cursor: FeedCursor?; public let hasMore: Bool }
public struct FeedAssemblerConfig { public var pageSize = 20; public var maxRPCPages = 10 }
public actor FeedPageAssembler {
    public init(fetchPage: @escaping (FeedMode, FeedCursor?, Int) async throws -> [FeedEventRow],
                fetchMutes: @escaping () async throws -> (users: Set<UUID>, media: Set<String>),
                fetchProfiles: @escaping ([UUID]) async throws -> [UUID: ProfileRow],
                fetchScores: @escaping ([(userID: UUID, tmdbID: String)]) async throws -> [String: Double],
                config: FeedAssemblerConfig = .init())
    public func assemblePage(mode: FeedMode, after cursor: FeedCursor?, allowedTypes: Set<String>) async -> FeedAssemblyResult
}
```
- Behavior (binding, from the caller contract in Global Constraints): loop ≤ maxRPCPages raw fetches; per-call throttle dict; stage order type-filter → mutes → throttle; cursor advances over every raw row; stop when enough kept cards (pageSize), raw page short (hasMore false), or page cap; reads fail soft — a thrown fetchPage on the FIRST page yields empty/hasMore-false, on later refills returns what's kept so far; scores/profiles failures degrade (cards without score/username) — matching web's in-service soft-fails.
- TDD with injected closures (no network): refill-until-full across 3 raw pages; hasMore truth table; 10-page cap with narrow filter; mute-drop still advances cursor; throttle cap 3 shared across refills within ONE call but reset across calls; first-page throw → empty; scores-throw → cards retain nil score; profile hydration fills username/avatar via `FeedCards.avatarURL`.
- Commit `feat(ios): FeedPageAssembler — contract refill loop with injected IO`.

### Task 3: Ticket front + flip container

**Files:** Create `ios/Spool/Sources/Spool/Components/FeedTicket.swift`, `ios/Spool/Sources/Spool/Components/FeedTicketFlip.swift`; Test `ios/Spool/Tests/SpoolTests/FeedTicketLogicTests.swift` (pure presentation helpers only).
**Interfaces — Produces:** `FeedTicket(card: FeedCard, onFlip: () -> Void, onMuteUser:, onMuteMedia:, onOpenActor:)` (front face; variants per spec §FeedTicket: ranking/review/list/milestone; perforated header `ADMIT ONE · @HANDLE · <relativeTime>`; rotated tier stamp with score when present; review chip + spoiler shield honoring `metadata["containsSpoilers"]`; long-press context menu). `FeedTicketFlip(card:, isFlipped:, front:, back:)` — 3D Y-rotation spring flip per spec §2.
- Presentation-pure helpers extracted + tested: variant selection from `FeedCardKind`, spoiler flag extraction from `JSONObject`, notes-line extraction (`metadata["notes"]`), stamp text (`"S · 9.4"` composition, score-less fallback `"S"`).
- Visual details: follow the spec + existing `AdmitStub.swift`/`TierStamp`/`SpoolTokens` idioms (read them first). SwiftUI previews for all four variants + flipped state.
- Build gate: `swift build --package-path ios/Spool` + full test suite.
- Commit `feat(ios): FeedTicket front variants + flip container`.

### Task 4: Ticket back — reactions + comments

**Files:** Create `ios/Spool/Sources/Spool/Components/FeedTicketBack.swift`; Create `ios/Spool/Sources/Spool/Services/TicketEngagementModel.swift` (@MainActor observable holding per-ticket engagement state); Test `ios/Spool/Tests/SpoolTests/TicketEngagementModelTests.swift`.
**Interfaces — Produces:** `TicketEngagementModel(eventID: UUID, repo: <injected closures like Task 2>)` with `load()`, `toggle(reaction: String)` (optimistic + revert-on-throw, 23505-success passthrough already handled by the repository), `addComment(body:)` (validation errors → published `inlineError`), `deleteComment(id:)`, published `counts: EngagementCounts`, `thread: [(FeedComment, [FeedComment])]`, `sending: Bool`. `FeedTicketBack(card:, model:, onFlipBack:)` — five stamp buttons (mine = darker stamp per spec), scrolling thread, composer, `TAP TO FLIP BACK`.
- TDD on the model with injected closures: optimistic toggle + revert; counts update on toggle; addComment trims/propagates `CommentError` to `inlineError` without clearing the draft; delete-own removes from thread; load failure → empty state flag (not crash).
- Commit `feat(ios): flip-side engagement — reaction stamps, thread, composer`.

### Task 5: FeedScreen rebuild + bell + Settings row + wiring

**Files:** Rewrite `ios/Spool/Sources/Spool/Screens/FeedScreen.swift`; Create `ios/Spool/Sources/Spool/Components/NotificationBellView.swift`; Modify `ios/Spool/Sources/Spool/Screens/SettingsScreen.swift` (visibility row) + `ios/Spool/Sources/Spool/Services/ProfileRepository.swift` ONLY IF it lacks a visibility update method (check; add `updateVisibility(_ value: String)` mirroring its update idioms if missing); Test: extend `FeedCardsTests` only if new pure helpers emerge.
- FeedScreen: segmented friends/explore in header (follow `SpoolHeader` idiom), `FeedPageAssembler` wired to the real repositories, ticket wall LazyVStack with `FeedTicketFlip` rows, pull-to-refresh (new assembler call), infinite scroll (onAppear of last card + hasMore), empty states per spec (friends → `find your people` CTA → existing FriendsScreen route; explore → opt-in prompt + button to Settings), context-menu mute actions calling the repository then locally dropping the actor/media's tickets, fixture/preview mode preserved (no session → `SpoolData` demo rows through the same card mapping).
- Bell: badge polls `unreadCount()` every 15s while feed visible (`.task` + `Task.sleep` loop, cancelled on disappear); sheet lists `fetchLatest()`, marks fetched-unread read via `unreadIDs(from:)`, rows render `NotificationKind` icons with fallback; follower rows navigate to the actor profile.
- Settings: `profile visibility` row (public/friends/private picker, lowercase copy per spec) reading current value from the profile row and writing via ProfileRepository; a one-line footnote `public shows your activity in explore`.
- Full suite + build + previews compile. Commit `feat(ios): ticket-wall feed, flip engagement wiring, bell, visibility setting`.

### Task 6: Ledger + gates

**Files:** `docs/plans/2026-07-07-ios-parity-ledger.md` — C1 row → UI built (PR pending); non-goals ledgered (filter UI fast-follow with the pipeline pieces named; journal_tag deep-link → C2-iOS); device-smoke checklist for the owner (feed both modes, flip+react+comment round-trip, bell read-marking, visibility row drives explore).
- Final contract re-check: every closure signature the views inject matches the PR #34 repository signatures (compile is the proof); grep gates: no `ISODate`, no UIKit imports in new files.
- Commit `docs: C1 ledger — feed UI built`.

## Self-Review Notes

- Spec coverage: ticket wall (T3/T5), flip + stamps + thread (T3/T4), switcher + empty states (T5), bell (T5), Settings row (T5), deferred pure helpers (T1), refill contract (T2), mutes in context menu (T3/T5), fixtures preserved (T5), filters deferred (T6 ledger). 
- The two view-heavy tasks (3, 5) carry read-first gates on the existing component idioms instead of embedded 300-line SwiftUI listings; all logic that can diverge from web is in pure tested layers (T1/T2/T4 models).
- Type consistency: `FeedCard`/`FeedCards`/`FeedPageAssembler`/`FeedAssemblyResult`/`TicketEngagementModel` names consistent across tasks; repository types (`FeedEventRow`, `FeedCursor`, `FeedMode`, `EngagementCounts`, `FeedComment`, `ProfileRow`) are PR #34/main exports.
