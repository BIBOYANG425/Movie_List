# iOS Functional Pass — Make Onboarding + Rankings + Feed Actually Work

**Date:** 2026-04-18
**Branch:** `feature/ios-functional-pass` (new, off `feature/acquisition-retention-features`)
**Worktree:** `../Movie_List_MVP-rebrand-ios-functional-pass/`

## Problem

The iOS port at `ios/Spool/` has a polished UI but is functionally hollow:

1. **Onboarding writes nothing.** `OnboardingFlow.swift:55-57` returns only `handle + signedIn`. Tier picks from OnbGrid and the H2H winner are captured in `@State picks` and thrown away. A nine-step flow produces zero rows in `user_rankings`.
2. **Sign-in is skippable, so writes silently fail.** `OnboardingScreens.swift:183-184` offers "skip — rank first, sign in later". `RankingRepository.insertRanking` throws `.notAuthenticated` without a session. `RankH2HScreen.swift:305` wraps with `try?`. User sees confetti, database stays empty, no error.
3. **Feed falls back to fixtures.** `FeedScreen.swift:60-73` catches every error and shows `SpoolData.feed`. Fake "Mira" and "Dex" friends appear. No empty state, no "sign in to see real data" prompt.
4. **`try?` on persistence swallows failures.** Three live sites: `RankH2HScreen.swift:305` (insertRanking), `RankingRepository.swift:132` (activity_events), `AuthService.swift:73` (signOut). No user-visible error when the network drops or RLS rejects.

## Scope

Close all four gaps. Out of scope: auth UX polish beyond the banner, offline retry beyond the onboarding queue, backfilling fixtures data.

---

## Task 1 — Persist onboarding picks + H2H winner

**Files:**
- `ios/Spool/Sources/Spool/Screens/Onboarding/OnboardingFlow.swift`
- NEW: `ios/Spool/Sources/Spool/Services/OnboardingQueue.swift`

**Behavior:**
1. On `OnbSeason.onFinish`, build a list of `RankingInsert` payloads:
   - Each `OnbPick` → one insert at `pick.tier`
   - H2H winner → `rank_position = 1` in its contender tier
   - Other members of the contender tier → `rank_position = 2..N` in H2H outcome order (winners ahead of losers)
   - Picks outside the contender tier → `rank_position = 1..M` in grid order
2. If signed in AND `SpoolClient.shared != nil`: call `RankingRepository.insertRanking` sequentially. Show a small progress indicator. Toast on failure (deferred to Task 4).
3. If not signed in: serialize the payloads to UserDefaults key `spool.onboarding_queue` as JSON. Do not block the flow.
4. Add `OnboardingQueue.flush()` — called from `AuthService.signInOrSignUp` on success. Reads the queue, inserts each row, clears the key on success.

**Data model (new file `OnboardingQueue.swift`):**
```swift
public struct QueuedRanking: Codable, Sendable {
    public let tmdbId: String
    public let title: String
    public let year: String?
    public let posterURL: String?
    public let genres: [String]
    public let director: String?
    public let tier: String
    public let rankPosition: Int
}

public enum OnboardingQueue {
    public static func enqueue(_ rankings: [QueuedRanking])
    public static func flush() async throws
    public static var pending: [QueuedRanking]  // for tests
    public static func clear()
}
```

**Testing:**
- Unit: `QueuedRanking` Codable round-trip
- Unit: enqueue → pending reflects latest set; flush with no session throws `notAuthenticated`
- Manual: sign in + onboard → check `user_rankings` has N rows via Supabase dashboard

**Acceptance:**
- Signed-in onboard completion → N rows appear in `user_rankings` for this user
- Skipped-sign-in onboard completion → picks queued in UserDefaults
- Post-skip sign-in → queue flushes, rows appear, UserDefaults key cleared

---

## Task 2 — Preview mode for skippers + sign-in gate on rank persistence

**Files:**
- `ios/Spool/Sources/Spool/App/SpoolAppRoot.swift`
- `ios/Spool/Sources/Spool/Screens/Onboarding/OnboardingScreens.swift` (OnbSignInScreen skip label)
- `ios/Spool/Sources/Spool/Screens/RankH2HScreen.swift` (persist path)
- NEW: `ios/Spool/Sources/Spool/Screens/SignInSheet.swift` (lifted from OnbSignInScreen internals)

**Behavior:**
1. Keep the skip option but relabel: "continue without account — preview only".
2. `OnboardingOutcome` already carries `signedIn`. Add `@AppStorage("spool.preview_mode")` in `SpoolAppRoot`, set to `!signedIn` on completion.
3. In `AppLayout`, when `previewMode == true`, show a slim banner: "preview mode — sign in to save your rankings". Tap opens `SignInSheet`.
4. `RankH2HScreen.persistRanking`:
   - If a session exists: insert as today
   - If preview mode: enqueue via `OnboardingQueue.enqueue([single])` and present `SignInSheet`. On successful sign-in, flush runs and the row lands.
   - On sign-in dismiss without auth: keep the item in the queue, toast "saved locally — sign in to sync" (toast wiring in Task 4).

**Testing:**
- UI: banner appears only when preview_mode is true
- Flow: preview rank → sheet → skip sheet → toast appears → item remains queued
- Flow: preview rank → sheet → sign in → item persists + queue clears

**Acceptance:**
- No silent ranking loss for preview-mode users — every rank attempt either persists or is queued and the user knows
- Signed-in flow unchanged (no banner, no sheet)

---

## Task 3 — Real empty state, no fake friends

**Files:**
- `ios/Spool/Sources/Spool/Screens/FeedScreen.swift`

**Behavior:**
1. Three feed states:
   - **Preview mode (no session):** show fixtures, prefixed with a "DEMO — SIGN IN TO SEE REAL FRIENDS" card
   - **Signed in + zero live events:** show empty state — centered message "no rankings yet · rank something to start your feed" with a "rank something" CTA that navigates to the rank tab
   - **Signed in + live events:** show only live events (no fixture append)
2. Detect session via `SpoolClient.currentUserID()` once on `.task`, store in `@State hasSession: Bool`.
3. Remove the unconditional `SpoolData.feed` append after `liveFeedItems`.

**Testing:**
- Manual: sign out + fresh install → DEMO header + fake cards
- Manual: sign in + fresh account → empty state card
- Manual: sign in + rank something → single real card, no Mira/Dex

**Acceptance:**
- `grep -n "SpoolData.feed" FeedScreen.swift` returns only the preview-mode branch
- Signed-in users never see fixture data

---

## Task 4 — Error toast primitive + wire every persistence `try?`

**Files:**
- NEW: `ios/Spool/Sources/Spool/Components/Toast.swift`
- `ios/Spool/Sources/Spool/App/SpoolAppRoot.swift` (mount ToastHost)
- `ios/Spool/Sources/Spool/Screens/RankH2HScreen.swift:305`
- `ios/Spool/Sources/Spool/Services/RankingRepository.swift:132` (activity_events — fire-and-forget, but we still surface on failure)
- `ios/Spool/Sources/Spool/Services/OnboardingQueue.swift` (Task 1 site)

**Behavior:**
1. Build a simple `ToastCenter`:
   ```swift
   @MainActor public final class ToastCenter: ObservableObject {
       public static let shared = ToastCenter()
       @Published public var current: ToastMessage?
       public func show(_ text: String, level: ToastLevel = .info, duration: TimeInterval = 3)
   }
   public enum ToastLevel { case info, error, success }
   public struct ToastMessage: Identifiable { public let id: UUID; public let text: String; public let level: ToastLevel }
   ```
2. `ToastHost` is a SwiftUI view that watches `ToastCenter.shared` and renders a top-of-screen pill with palette-aware styling (gold for success, red for error, cream for info).
3. Mount `ToastHost` in `SpoolAppRoot` as a ZStack overlay (above AppLayout, below any modal sheet).
4. Replace `try?` on persistence sites with `do/catch`. On catch, call `ToastCenter.shared.show("couldn't save — tap to retry", level: .error)`. For activity_events failures, log only (no toast — it's fire-and-forget telemetry).

**Testing:**
- Unit: ToastCenter show → current non-nil; after duration → current nil
- Manual: airplane mode + rank → error toast appears within 3s
- Grep: `grep -rn "try?" ios/Spool/Sources/Spool/Screens ios/Spool/Sources/Spool/Services | grep -v Task.sleep` returns only `signOut` in AuthService (accepted)

**Acceptance:**
- No silent persistence failure on the main rank path
- Toast is visible over the bottom tab bar
- AuthService signOut `try?` is documented as intentional (sign-out is best-effort local clear)

---

## Final review

After all four tasks:
- Dispatch a whole-implementation code-reviewer subagent against the combined diff
- Grep audit: no new fixture appends in FeedScreen, no `try?` on DB inserts, `OnboardingQueue` referenced exactly at enqueue (onboarding + rank preview) and flush (auth success) sites
- Manual smoke test on iPhone 13 Pro sim: fresh install → skip sign-in → onboard → rank → see preview banner + empty feed → sign in → see toast, queue flushes, feed populates

Hand off to `superpowers:finishing-a-development-branch`.
