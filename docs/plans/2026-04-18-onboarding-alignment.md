# Onboarding Alignment with Webapp + Stubs Screen Rework

**Date:** 2026-04-18
**Branch:** `feature/onboarding-alignment` off `feature/ios-functional-pass`
**Worktree:** `/Users/mac/Documents/Movie_List_MVP-rebrand-onboarding-alignment/`

## Problem

After the functional pass landed, the iOS onboarding still diverges from the web app in three ways, and the Stubs tab doesn't lean into the ticket-card visual language that Profile already uses:

1. Sign-in/sign-up sits at step 1 of onboarding (right after Cold Open). Web's model lets users sign in first too, but the iOS preview-mode infrastructure we just shipped makes it strictly better to move commitment to the END — users experience the product, then sign in to save.
2. iOS auth is email/password only. Web app's primary auth CTA is Google OAuth (`supabase.auth.signInWithOAuth({ provider: 'google' })`, see `contexts/AuthContext.tsx:94-104`). iOS has no OAuth.
3. iOS `OnbTwins` shows fixture "taste twins" — not real friends. Web has no in-onboarding friend discovery either, but its post-onboarding `FriendsView` does real username search. iOS has neither yet.

Separately: `StubsScreen` is a calendar heatmap + tier-stamp-grid (stats view). `ProfileScreen` has the "MY TOP 4" + "RECENT STUBS" card grid (pattern view). The Stubs tab should be card-forward.

## Scope

Four tasks. Round 1 parallelizes A + B (no file overlap). Round 2 parallelizes C + D (both touch the new end-of-flow sign-in that A introduces).

---

## Task A — Move sign-in to end of onboarding

**Files:**
- `ios/Spool/Sources/Spool/Screens/Onboarding/OnboardingFlow.swift`
- `ios/Spool/Sources/Spool/Screens/Onboarding/OnboardingScreens.swift` (no functional changes to OnbSignInScreen body; just removed from early-flow slot)
- `ios/Spool/Sources/Spool/App/SpoolAppRoot.swift` (OnboardingOutcome consumption — previewMode already handled)

**Behavior:**
1. New flow order:
   ```
   0 Cold Open
   1 Manifesto          (was 2)
   2 Grid               (was 3)
   3 H2H                (was 4)
   4 Print              (was 5)
   5 Identity           (was 6)
   6 Twins              (was 7) — will be replaced by Task D
   7 Season             (was 8)
   8 Sign In / Sign Up  (NEW — moved from old step 1)
   ```
2. The sign-in step at the end (reuse `OnbSignInScreen` or a tweaked copy):
   - Same skip semantics: "continue without account — preview only" fires `onDone(.skipped)` → OnboardingOutcome(signedIn: false) → previewMode = true
   - Signed-in path: `onDone(.signedIn)` → previewMode = false → AuthService.flushOnboardingQueue already drains the queue
   - Header/copy should reflect the position: "one last thing — save your picks?" or similar. User can refine later.
3. Progress dots at top stay 9 pips; the sign-in dot is now the last one instead of the second.

**Testing:**
- Unit: snapshot/flow test that confirms step indices map correctly (low priority — covered by compile)
- Manual: run onboarding with skip at end → main app shows preview banner. Run with sign-in at end → banner absent on first feed render (queue flushes).

**Acceptance:**
- No user-visible changes to steps 0 and 1-7 except progress dot offsets
- Skip at end keeps preview mode exactly like before
- Sign-in at end still triggers flushOnboardingQueue through AuthService (no new wiring needed)

---

## Task B — StubsScreen rework: card-forward layout

**Files:**
- `ios/Spool/Sources/Spool/Screens/StubsScreen.swift` (major rewrite)

**Behavior:**
1. Lead with MY TOP-RANKED posters (top 4 items across all tiers, rank-badge 1..4) — same PosterBlock pattern as `ProfileScreen.swift:128`
2. Below that: RECENT STUBS horizontal-scroll or 2-col grid of recent rankings with tier stamps (S/A/B/C/D big letter at bottom) — same pattern as `ProfileScreen.swift:152`
3. Keep the existing AdmitStub hero card at the very top if it reads as a "featured stub" or the most-recent rank; otherwise drop it
4. Move the calendar heatmap + tier tally grid to a compact secondary section below the card content, OR remove them (calendar feels more like a "stats" surface that could live on Profile). Implementer decides based on visual weight.
5. Data source: existing `RankingRepository.shared.getAllRankedItems()` or similar. If the screen currently uses fixture data, port to the real repo call on `.task`, fall back to fixtures when `hasSession == false`.

**Testing:**
- Manual: signed-in user with rankings sees their top 4 and recent stubs. Preview-mode user sees fixture top-4/recent or an empty state.
- Compile check: no regressions in other screens that use ProfileScreen/StubsScreen-shared components.

**Acceptance:**
- StubsScreen body is card-dominated (posters + tier stamps), not calendar-dominated
- Top 4 section reuses the rank-badge pattern from ProfileScreen
- Recent stubs section reuses the tier-stamp-on-card pattern
- No new component duplication — reuse PosterBlock + TierStamp

---

## Task C — Google OAuth (Round 2, after A)

**Prereqs (user-confirmed):**
- Supabase Google provider enabled ✓
- iOS URL scheme TBD — will use `com.spool.app://auth/callback`

**Files:**
- `ios/Spool/Sources/Spool/Services/AuthService.swift` (add `signInWithGoogle()`)
- `ios/Spool/Sources/Spool/Screens/SignInSheet.swift` (SignInFormBody — add "Continue with Google" button)
- `ios/SpoolApp/SpoolApp/Info.plist` (add `CFBundleURLTypes` for OAuth callback)
- `ios/SpoolApp/SpoolApp/SpoolAppEntry.swift` (handle `onOpenURL` to route OAuth callback back into supabase-swift)

**Behavior:**
1. `AuthService.signInWithGoogle() async -> AuthResult` — calls `client.auth.signInWithOAuth(provider: .google, redirectTo: URL(string: "com.spool.app://auth/callback"))`. supabase-swift handles the SFSafariViewController presentation.
2. SignInFormBody: "Continue with Google" button ABOVE the email/password form. Button triggers signInWithGoogle, on success → onSuccess closure (same as email).
3. Info.plist:
   ```xml
   <key>CFBundleURLTypes</key>
   <array>
       <dict>
           <key>CFBundleURLSchemes</key>
           <array><string>com.spool.app</string></array>
       </dict>
   </array>
   ```
4. SpoolAppEntry: `.onOpenURL { url in Task { await SpoolClient.shared?.auth.session(from: url) } }` — lets supabase-swift pick up the auth callback.
5. On OAuth success, the existing `flushOnboardingQueue` in AuthService hooks also apply — extend signInWithGoogle to call it.

**Testing:**
- Manual: tap Continue with Google → Safari sheet → Google consent → deep-link back to app → session established → queue flushes
- Log: confirm supabase-swift receives the redirect URL and establishes a session

**Acceptance:**
- Google OAuth present on both the end-of-onboarding sign-in (Task A) AND the recovery SignInSheet (existing)
- Email/password still works as fallback
- Queue flushes on OAuth sign-in just like email sign-in

---

## Task D — Real friend-search onboarding step (Round 2, after A)

**Files:**
- `ios/Spool/Sources/Spool/Services/ProfileService.swift` (NEW — port `profileService.searchUsers`)
- `ios/Spool/Sources/Spool/Services/FollowService.swift` (NEW or extend — `followUser(_ userID: UUID)`)
- `ios/Spool/Sources/Spool/Screens/Onboarding/OnbFriendSearch.swift` (NEW — replaces OnbTwins)
- `ios/Spool/Sources/Spool/Screens/Onboarding/OnboardingScreens.swift` (remove OnbTwins, wire OnbFriendSearch)
- `ios/Spool/Sources/Spool/Screens/Onboarding/OnboardingFlow.swift` (swap step 6)

**Behavior:**
1. `ProfileService.searchUsers(query: String) async throws -> [ProfileRow]`:
   - `profiles.select("id, username, display_name, avatar_url, avatar_path").ilike("username", "%\(query)%").or(ilike on display_name).limit(12)`
   - Debounce at the call site (300ms), same pattern as TMDB search
2. `FollowService.followUser(_ userID: UUID)` inserts into `friend_follows` (follower_id = auth.uid, followee_id = userID). RLS already scopes.
3. `OnbFriendSearch`:
   - Header: "find your people" / subhead "search a handle to follow someone"
   - TextField for handle, debounced search
   - List of up to 12 results with avatar + @handle + display_name + Follow button
   - Follow toggles to "Following"
   - Skip link → advance without following anyone
   - Requires session (preview users can't follow) — if no session, short-circuit with "sign in to add friends" message + skip link. The end-of-onboarding sign-in (Task A) means most users will have a session by the time they reach this step... wait, this step is BEFORE the new end sign-in. Reconcile: either (a) move friend search to AFTER sign-in, making it step 9 (post-sign-in) OR (b) keep at step 6 but allow preview users to queue follows (adds complexity). **Recommendation: (a) — put friend search AFTER sign-in at new step 9, so it only fires for signed-in users. Update Task A's flow accordingly when D lands.**
4. OnboardingFlow update: insert friend search step after sign-in.

**Testing:**
- Unit: ProfileService.searchUsers returns rows with expected columns
- Manual: search "y" → see results, tap follow on one → verify row in friend_follows table

**Acceptance:**
- Searching a handle returns real profiles from Supabase
- Follow button creates friend_follows row
- Skippable — doesn't block completion
- Respects session — preview-mode users see sign-in CTA instead of search

---

## Out of scope

- Contact import via phone hash (bigger migration — adds `phone` column to profiles, RPC for hash matching, iOS Contacts permission)
- SMS OTP OAuth (Supabase Phone Auth config + Twilio)
- Apple Sign In (Supabase config + Apple Developer identifier)
- Stubs calendar redesign (if we move calendar to Profile)

## Review

Per subagent-driven-development: implementer → spec reviewer → code quality reviewer → mark complete, per task. Final whole-diff review before handing to `finishing-a-development-branch`.
