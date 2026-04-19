<!-- /autoplan restore point: /Users/mac/.gstack/projects/BIBOYANG425-Movie_List/feature-acquisition-retention-features-autoplan-restore-20260418-180312.md -->
---
title: iOS Services Gap — Fill Missing & Partial
status: DRAFT
branch: feature/acquisition-retention-features
owner: yangb7777
created: 2026-04-18
---

# iOS Services Gap — Fill Missing & Partial

## Problem

The SwiftUI port at `ios/Spool/` is UI-complete with fixtures. Before we wire real data, seven service gaps surfaced in `docs/iOS_SERVICES_AUDIT.md`. Five are backend, two are iOS-only rendering work. The UI screens that need these services exist and are ready to consume them.

## Scope — what we're adding

### Backend (TypeScript, shared with web)

1. **`tasteService.getFriendsWhoRanked(viewerId, tmdbId)`**
   Returns the viewer's followed users who ranked a given movie, with their tier. Powers the "friends who also watched" strip on the stub detail screen and an equivalent row in future movie-detail views.
   - **Signature:** `(viewerId: string, tmdbId: string) => Promise<{ handle: string; tier: Tier }[]>`
   - **Query:** join `user_rankings` / `tv_rankings` / `book_rankings` with `profiles` where `user_id IN (SELECT following_id FROM friend_follows WHERE follower_id = viewerId)` AND `tmdb_id = ?`. Handle all three media tables via one helper that picks the right table by tmdb_id prefix (`tmdb_`, `tv_`, `ol_`).
   - **RLS:** already permissive for followed users' rankings; no new policy.

2. **`tasteService.getRecommendationsForFriend(viewerId, targetId, limit = 4)`**
   Viewer's S/A-tier rankings that the target hasn't ranked OR added to their watchlist. Powers the twin screen's "recommend to @friend" row.
   - **Signature:** `(viewerId: string, targetId: string, limit?: number) => Promise<{ tmdbId: string; title: string; posterUrl?: string; tier: Tier }[]>`
   - **Query:** `user_rankings WHERE user_id = viewerId AND tier IN ('S','A') AND tmdb_id NOT IN (target's rankings ∪ target's watchlist) ORDER BY tier, rank_position LIMIT ?`. Use `EXCEPT` / `NOT IN` subquery.

3. **`notifications.type = 'movie_rec'` + `notificationService.sendMovieRecs(fromUserId, toUserId, recs)`**
   Enables "send 3 recs →" on the twin screen.
   - **Migration:** extend the existing `notifications.type` CHECK constraint to include `'movie_rec'`. Already has `metadata` column (jsonb) — no new column.
   - **Sender:** `sendMovieRecs(fromUserId: string, toUserId: string, recs: { tmdbId: string; title: string; posterUrl?: string }[])` inserts one notification with `type = 'movie_rec'`, `actor_id = fromUserId`, `metadata = { recs: [...] }`.
   - **RLS:** already enforces `target user must exist in profiles`; `auth.uid() = actor_id` for INSERT. No new policy.

4. **`tasteService.getTasteCompatibilityBatch(viewerId, targetIds)`**
   Replaces N single calls on the friends list with one grouped call. Same math as the single version, aggregated per target.
   - **Signature:** `(viewerId: string, targetIds: string[]) => Promise<Map<string, number>>`
   - **Query:** one SELECT over `user_rankings` for viewer ∪ targets, group in JS. Preserves RLS (viewer can only see followed users' rankings).

5. **`services/profileAggregatesService.ts` (new file)**
   Thin service for profile screen aggregations that are ad-hoc queries in the web UI today. Gives iOS a clean seam.
   - `getTopTier(userId, tier, limit = 4)` — `user_rankings WHERE user_id = ? AND tier = ? ORDER BY rank_position LIMIT ?`
   - `getCurrentlyObsessed(userId, withinDays = 30)` — `journal_entries WHERE user_id = ? AND is_rewatch = true AND created_at > now() - interval '30 days'` grouped by tmdb_id, pick the one with most entries. Returns `{ tmdbId, title, rewatchCount } | null`.
   - `getRecentStubs(userId, limit = 5)` — delegates to `stubService.getAllStubs` with a slice (sorted by watched_date DESC server-side).

### iOS (SwiftUI, no backend)

6. **Feed Realtime subscriptions**
   Replace the web app's 15s polling with `supabase-swift` Realtime on `activity_events`, `activity_reactions`, `activity_comments`, `notifications`. No service changes; purely a repository layer choice when we wire the iOS feed.
   - **Scope here:** document the channel shapes and filter clauses so the iOS repository knows what to subscribe to. Actual subscription code lands with the feed repository in a later PR.

7. **Stub → PNG share**
   `ImageRenderer` (iOS 16+) on the `AdmitStub` SwiftUI view → `UIActivityViewController`. Pure iOS.
   - **Scope here:** add a helper in `ios/Spool/Sources/Spool/Components/` that takes an `AdmitStub` view + metadata and returns a `UIImage`; wire the share sheet hook in `StubShareScreen`. Still stub-only UI today; actual share action is stubbed behind a `ShareService` protocol so unit tests don't need UIKit.

## NOT in scope

- Rewriting the existing `tasteService.getTasteCompatibility` signature — `Batch` is additive.
- A new `recommendations` table. Reusing `notifications.metadata` is smaller, simpler, reuses the bell.
- Push notifications (APNs). `movie_rec` shows in the in-app bell only for now.
- Migrating web to use the new services. They can, but it's not required.
- Caching. First pass hits Postgres on every call. Add `NSCache` on iOS later if a specific screen shows lag.

## What already exists

- `tasteService.getTasteCompatibility(viewerId, targetId)` — gives `topShared`, `biggestDivergences`, agreement %. The batch version is a grouped variant.
- `tasteService.getFriendRecommendations(userId, limit)` — "for me based on friends," NOT "for friend from me." The new function is the mirror.
- `followService.followUser`, `profileService.getFollowingIdSet` — follow graph queries.
- `notificationService.createNotification` — generic notification insert. `sendMovieRecs` wraps it with the right type + metadata shape.
- `stubService.getAllStubs`, `journalService.getJournalEntry` — building blocks for `profileAggregates`.

## Migrations

One migration:

```sql
-- 20260418_notifications_movie_rec.sql
ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_type_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_type_check CHECK (
    type IN (
      'new_follower','review_like','list_like','badge_unlock',
      'ranking_comment','journal_tag','movie_rec'
    )
  );
```

Re-run safety: drop-if-exists then re-add. Idempotent on repeated apply.

## Tests

- `services/__tests__/tasteService.test.ts` — add cases for `getFriendsWhoRanked`, `getRecommendationsForFriend`, `getTasteCompatibilityBatch`. Use seeded in-memory fixtures matching existing tests.
- `services/__tests__/profileAggregatesService.test.ts` — new file.
- `services/__tests__/notificationService.test.ts` — add `sendMovieRecs` insert + RLS reject case for mismatched actor.
- Migration: smoke test locally (`supabase db reset && supabase db push`) and assert the type accepts `'movie_rec'`.

## Risk

- RLS interactions on `getFriendsWhoRanked`: if viewer isn't following a user, that user's ranking is invisible — expected, matches web behavior. Document with a test.
- `getRecommendationsForFriend` `NOT IN` can be slow on large ranked libraries. Mitigate with `LIMIT` pushdown in the target's filter subquery.
- Notification spam: a single "send 3 recs" creates one notification (not 3). Verified by sender writing one row with all recs in `metadata.recs`.

## Done when

- All 5 backend service functions land with tests passing.
- Migration applies cleanly against the dev DB.
- iOS `ShareService` protocol + `ImageRenderer` helper compile under `swift build`.
- `docs/iOS_SERVICES_AUDIT.md` updated to reflect closed gaps.
---

## CEO Phase — Dual Voices (autoplan)

### CODEX SAYS (CEO — strategy challenge)

- TS service functions are not a backend contract for iOS. The Swift package has no Supabase dependency today. Adding TS helpers helps web, but iOS needs ports to Swift OR RPCs/views/Edge Functions. Shared-service premise is unstated.
- Plan confuses "screen data gaps" with "launch blockers." The 10x problem is one complete authenticated iOS loop (sign in → rank → journal → feed event → notification → reopen → offline), not friends-who-ranked wrappers.
- **Schema fact errors (critical):** `notifications` table has NO `metadata` column (see `supabase_phase4_engagement.sql`). `AppNotification` TS model does not expose metadata. RLS INSERT is "target profile exists" (see `supabase_fix_critical_rls.sql:35-43`), NOT `auth.uid() = actor_id` as the plan claims. This invalidates the §3 security and data-shape premise.
- Reusing notifications for recs was dismissed too quickly. A real `movie_recommendations` table buys lifecycle, dedupe, accept/dismiss, conversion tracking, abuse controls.
- Media abstraction brittle: prefix dispatch assumes consistent prefixing (movies use `tmdb_`, TV uses `tv_`, books use `ol_`) — true in fixtures but coupling ID parsing to storage. Existing `feedService` queries all three tables in parallel with the same ID set — cleaner pattern.
- Batch compatibility as additive TS function duplicates single-call math → drift. If product-critical, make it a canonical SQL function.
- Realtime treated as "upgrade" when it's operational burden (backfill, reconnect, ordering, dedup). Polling may be strategically fine.

### CLAUDE SUBAGENT (CEO — strategic independence)

- **Wrong problem?** TestFlight reframing: ship iOS demo with fixtures for write paths this week, gather 20 user reactions, build only validated gap features. §2 and §3 are speculative, not demand-validated.
- **Unstated premises (critical):** "iOS uses supabase-swift anon-key direct" is nowhere stated. Mobile apps with anon keys + permissive RLS is a known footgun — RLS usually written for web auth flow.
- **6-month regret:** `notifications.metadata` for recs will hurt when product wants "mark rec as watched," "decline rec," rec→watch conversion analytics. Extra hour now on a real table gets 6 months of clean queries.
- **Dismissed alternative:** `recommendations` table rejected with one sentence — no read-pattern or analytics analysis.
- **Priority inversion:** Stub PNG share (item 7) is the viral loop — `ImageRenderer` → IG/TikTok — buried at bottom. Deserves top billing.
- **Competitive:** Letterboxd has activity + lists + shared watchlists. Spool differentiators (stubs, ceremony, taste twin %, books) should drive the roadmap; "send 3 recs" is a feature Letterboxd users have asked for and not gotten — possibly signal that it doesn't work socially.

### CEO CONSENSUS TABLE

```
═══════════════════════════════════════════════════════════════
  Dimension                            Claude   Codex   Consensus
  ──────────────────────────────────── ──────── ──────── ─────────
  1. Premises valid & stated?          no       no       CONFIRMED no (iOS auth/RLS; shared TS contract)
  2. Right problem to solve now?       no       no       CONFIRMED no (TestFlight-first; complete loop not gap-filling)
  3. Scope calibration correct?        no       no       CONFIRMED no (stub share underpriced; items 2/3 speculative)
  4. Alternatives sufficiently explored? no     no       CONFIRMED no (real recs table; SQL RPC for batch)
  5. Competitive/market risks covered? partial  partial  DISAGREE (Claude: Letterboxd+differentiators; Codex: no explicit risk analysis)
  6. 6-month trajectory sound?         no       no       CONFIRMED no (metadata shortcut; no caching/offline/push plan)
═══════════════════════════════════════════════════════════════
```

Plus: **3 factual schema errors** that must be corrected regardless of premise decisions (notifications has no metadata; RLS INSERT policy; type CHECK constraint current state per `supabase_fix_critical_rls.sql`).

### Premises (need your confirmation before proceeding)

| # | Premise in plan | Status |
|---|---|---|
| A | iOS will use `supabase-swift` direct with the anon key, sharing RLS with web | NOT STATED. Confirm or document alternative (proxy via Edge Functions? Custom backend?) |
| B | Closing these service gaps is the right iOS launch blocker (vs. TestFlight-first with fixtures) | NOT STATED. Both models recommend reframing. |
| C | `notifications` can host recs via a `metadata` column | FALSE (no such column). Must choose: (i) add `metadata jsonb` to notifications, or (ii) build `movie_recommendations` table. |
| D | "Send 3 recs" is product-valuable enough to design schema around | NOT STATED. Both models flag as unvalidated. |
| E | Shared TS services give iOS a stable API | PARTIAL. iOS needs either Swift ports or SQL RPCs for a real contract. |


---

## REVISED SCOPE (premises accepted)

User chose: real `movie_recommendations` table, loop-first strategy, stub share promoted to #1.

### Phase A — iOS full loop (blocking; do first)

**A.0 — Document iOS auth + RLS model.** Short doc at `docs/iOS_AUTH_MODEL.md`:
- Uses `supabase-swift` Auth with anon key (same as web). Session stored in Keychain by SDK.
- All existing RLS policies apply to iOS unchanged.
- OAuth: `ASWebAuthenticationSession` + Supabase Auth redirect (callback URL scheme: `com.spool.app://auth/callback`).
- Email signup: client polls `getProfile` up to 10× 250ms after signup (mirror web).
- No additional policies needed; iOS is a third client, not privileged.

**A.1 — Stub PNG share (promoted from #7).**
- `Sources/Spool/Components/StubImageRenderer.swift` — `@MainActor` helper that wraps `ImageRenderer(content: AdmitStub(...))` and returns `UIImage` at 3x scale.
- `Sources/Spool/Services/ShareService.swift` — protocol `ShareService` with default `UIActivityViewControllerShareService`. Protocol exists so tests don't need UIKit.
- Wire into `StubShareScreen` IG / TikTok / save buttons.
- No backend. No migration.

**A.2 — One end-to-end flow wired to real Supabase.**
- Pick: Ranking flow. Entry → Tier → H2H → Ceremony → Printed, but writing to `user_rankings` + `activity_events` + `movie_stubs` for real.
- Add thin Swift repository: `RankingRepository` actor wrapping `supabase-swift`. Methods: `searchMovies(query)`, `getTierItems(tier)`, `insertRanking(...)`, `insertStub(...)`.
- Fixtures remain as fallback when no session.

### Phase B — Gap-fill services (after Phase A ships)

**B.1 — `tasteService.getFriendsWhoRanked(viewerId, tmdbId)`** — unchanged from original plan. Queries all three ranking tables in parallel following `feedService` pattern (cleaner than prefix dispatch).

**B.2 — `profileAggregatesService.ts`** — unchanged. New file with `getTopTier`, `getCurrentlyObsessed`, `getRecentStubs`.

**B.3 — `tasteService.getTasteCompatibilityBatch(viewerId, targetIds)`** — implemented as Postgres RPC, NOT client-side grouping. New migration adds `calc_taste_compatibility_batch(viewer_id uuid, target_ids uuid[])` function; service is a thin RPC caller.

**B.4 — `movie_recommendations` table + `recommendationsService.ts`.**
- Migration `20260418_movie_recommendations.sql`:
  ```sql
  CREATE TABLE public.movie_recommendations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    from_user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    to_user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    tmdb_id text NOT NULL,
    title text NOT NULL,
    poster_url text,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','dismissed','watched')),
    note text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (from_user_id, to_user_id, tmdb_id)
  );
  CREATE INDEX idx_movie_recs_to_user ON movie_recommendations(to_user_id, status, created_at DESC);
  CREATE INDEX idx_movie_recs_from_user ON movie_recommendations(from_user_id, created_at DESC);
  ALTER TABLE movie_recommendations ENABLE ROW LEVEL SECURITY;
  CREATE POLICY "sender_insert" ON movie_recommendations FOR INSERT TO authenticated
    WITH CHECK (from_user_id = auth.uid()
      AND EXISTS (SELECT 1 FROM profiles WHERE id = to_user_id));
  CREATE POLICY "both_read" ON movie_recommendations FOR SELECT TO authenticated
    USING (from_user_id = auth.uid() OR to_user_id = auth.uid());
  CREATE POLICY "recipient_update_status" ON movie_recommendations FOR UPDATE TO authenticated
    USING (to_user_id = auth.uid())
    WITH CHECK (to_user_id = auth.uid());
  ```
- Migration `20260418_notifications_movie_rec.sql`: extend `notifications.type` CHECK to include `movie_rec`. (FROM earlier plan; keep as the bell-display mechanism.)
- Trigger: `AFTER INSERT ON movie_recommendations` → create one notification per recommendation for the recipient with `type='movie_rec'`, `reference_id = recommendation_id`.
- Service: `recommendationsService.sendMovieRecs(fromUserId, toUserId, recs[])` inserts N rows; trigger does the notification. `updateStatus(recId, newStatus)` handles accept/dismiss/watched.

**B.5 — `tasteService.getRecommendationsForFriend(viewerId, targetId, limit)`** — unchanged. Feeds the twin screen's "recommend to @friend" row.

### Not in scope (deferred)

- Feed Realtime subscriptions. Polling is fine until engagement justifies Realtime (per Codex).
- Push notifications (APNs). Bell only for now.
- Caching / offline mode. Measure first.
- Web adoption of new services. They can migrate when convenient.

### Migration list (revised)

1. `20260418_notifications_movie_rec.sql` — extend type CHECK.
2. `20260418_movie_recommendations.sql` — new table + RLS + indexes + trigger.
3. `20260418_calc_taste_compatibility_batch.sql` — RPC function.

### Correction: RLS on notifications INSERT

Original plan was wrong. Current policy (per `supabase_fix_critical_rls.sql`): `auth role = authenticated AND target profile exists`. `movie_rec` notifications land fine under this since the trigger runs as the inserting user and the recipient profile exists (FK guarantee).

---

## Eng Phase — condensed (autoplan)

Given the CEO phase already surfaced schema-level engineering issues, the Eng phase findings are mostly affirmations + 4 new items:

**Architecture** — `RankingRepository` as an `actor` isolates Supabase calls. Services stay pure TS. Three ranking tables stay queried in parallel via `Promise.all` matching `feedService` pattern. Trigger-based notification on rec insert keeps business logic in DB (preferred over app-layer join).

**Tests** — 
- New: `services/__tests__/recommendationsService.test.ts` (sender + RLS reject on impersonation)
- New: migration smoke test in CI (`supabase db reset && supabase db push`)
- Existing: `tasteService.test.ts` extended for the three new functions + RPC

**Performance** — `NOT IN (SELECT ... UNION SELECT ...)` for `getRecommendationsForFriend` measured on 500-row test; if > 50ms we switch to `EXCEPT` or denormalize. `calc_taste_compatibility_batch` RPC avoids N client round trips.

**Security / RLS** —
- `movie_recommendations.sender_insert` requires `from_user_id = auth.uid()` — no impersonation possible.
- `recipient_update_status` allows recipient to mark as watched/dismissed but not re-assign recipient.
- Trigger runs as SECURITY DEFINER to insert notification; caller doesn't need notifications INSERT permission.

**Failure modes** —
| Mode | Severity | Mitigation |
|---|---|---|
| Trigger fails on notification insert → rec insert rolls back | Medium | Wrap trigger in EXCEPTION handler that warns but does not fail the rec. |
| Stub `ImageRenderer` on very slow device blocks main thread | Low | Render on a background task; @MainActor only the presentation. |
| iOS auth session expires during rec send | Low | Supabase SDK auto-refreshes; surface "please sign in again" if refresh fails. |
| Duplicate rec (same from/to/tmdb) | Low | UNIQUE constraint returns error; service swallows and returns the existing row. |

**Skipped sections for autoplan context:** explicit ASCII dependency graph (small diff; mostly additive), design review (no UI changes — only wiring to existing iOS screens), DX review (not a developer-facing product).


---

## Algorithm Parity — iOS vs Web (added per user request)

**Gap found.** iOS `RankH2HScreen.swift` simulates comparisons with a trivial win-counter. Web has 888 lines of pure ranking logic across four files that iOS is missing entirely.

### Files to port (web → Swift)

| Web file | Lines | What it does | Port to |
|---|---:|---|---|
| `services/rankingAlgorithm.ts` | 206 | `classifyBracket`, `computeSeedIndex`, `adaptiveNarrow`, `computeTierScore`, `computeAllScores`, `getNaturalTier` | `ios/Spool/Sources/Spool/Algorithm/RankingAlgorithm.swift` |
| `services/spoolRankingEngine.ts` | 552 | 5-phase H2H state machine (Prediction → Probe → Escalation → Cross-Genre → Settlement) | `ios/Spool/Sources/Spool/Algorithm/SpoolRankingEngine.swift` |
| `services/spoolPrediction.ts` | 96 | Signal-based score prediction (genre/bracket/global affinities) | `ios/Spool/Sources/Spool/Algorithm/SpoolPrediction.swift` |
| `services/spoolPrompts.ts` | 34 | Tier/genre emotional comparison prompts | `ios/Spool/Sources/Spool/Algorithm/SpoolPrompts.swift` |

### Why this matters

- Without parity, a user's tier placement on iOS will differ from web for the same H2H choices. Scores diverge. Recommendations diverge downstream.
- These are **pure functions with no IO** — port is mechanical, no async, no URLSession. ~1 day CC.
- Tests: port the existing `services/__tests__/rankingAlgorithm.test.ts` cases to `ios/Spool/Tests/SpoolTests/RankingAlgorithmTests.swift` using the same inputs → same outputs as acceptance criteria.

### Added to Phase A

**A.3 — Port ranking algorithm to Swift.**
- Four Swift files under `ios/Spool/Sources/Spool/Algorithm/` (new directory).
- Test suite under `ios/Spool/Tests/SpoolTests/` with snapshot inputs from existing TS tests.
- `RankH2HScreen.swift` replaces its fake counter with a `SpoolRankingEngine` instance.
- Effort: 1 day CC.

### Validation

After porting, for each test case in `services/__tests__/rankingAlgorithm.test.ts`, run the same inputs through the Swift version and assert identical outputs. Any divergence is a port bug.

### Other logic to audit for parity

- `services/letterboxdImportService.ts` (`mapRatingToTier`) — simple; port if Letterboxd import lands on iOS.
- `services/fuzzySearch.ts` — Levenshtein distance; port when iOS needs fuzzy match on TMDB results.
- `services/correctionService.ts` — only relevant if iOS builds the AI agent flow; defer.

