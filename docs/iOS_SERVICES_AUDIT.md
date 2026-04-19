# Spool iOS — Services Audit vs Hi-Fi Design

Cross-check between what the ported SwiftUI screens in `ios/Spool/` need from the backend, and what exists in `services/*.ts` today. Generated 2026-04-18 alongside the UI port.

| # | UI operation | Status | Where it lives (or doesn't) |
|---|---|---|---|
| 1 | Feed — paginated friend activity + reactions + comments | ⚠️ Partial | `feedService.getFeedCards`, `toggleReaction`, `addFeedComment` all exist. Real-time is not wired (web polls). iOS can subscribe via `supabase-swift` Realtime to `activity_events` and `notifications`. |
| 2 | Rank entry — search movies | ✅ Exists | `tmdbService.ts`. For "from your watchlist" prioritisation, filter results against `watchlist_items` locally. |
| 3 | Rank tier (S/A/B/C/D pick) | ✅ Exists | Insert to `user_rankings` with chosen tier; `activityService.logRankingActivityEvent` records the feed event. |
| 4 | Head-to-head comparisons | ✅ Exists | `spoolRankingEngine.ts` has the full state machine. Read opponents from `user_rankings WHERE tier = X`. |
| 5 | Ceremony (moods + one line) | ✅ Exists | `journalService.upsertJournalEntry` accepts `moodTags` and `reviewText`; `stubService.createStub` accepts `moodTags` + `stubLine`. |
| 6 | Printed stub artifact | ✅ Exists | `stubService.createStub` handles palette extraction, template, stub number, palette writeback. |
| 7 | Stubs calendar (month view) | ✅ Exists | `stubService.getStubsForMonth(userId, year, month)`. |
| 8 | Stub detail — friends who also watched | ❌ Missing | No dedicated function. Ad-hoc query: `SELECT user_id, tier FROM user_rankings WHERE tmdb_id = ? AND user_id IN (SELECT following_id FROM friend_follows WHERE follower_id = auth.uid())`. Wrap into `tasteService.getFriendsWhoRanked(tmdbId)`. |
| 9 | Stub PNG / share to IG-TikTok | ❌ Missing | Pure client-side rendering. On iOS: `ImageRenderer` (iOS 16+) on the SwiftUI stub view → `UIActivityViewController`. No backend work. |
| 10 | Friends list + twin % per friend | ⚠️ Partial | `profileService.getFollowingProfilesForUser` gives the list. `tasteService.getTasteCompatibility(viewerId, targetId)` gives the %. Calling it per friend is N queries; add `tasteService.getTasteCompatibilityBatch(viewerId, targetIds)` for the list view. |
| 11 | Taste twin detail (Venn + biggest fights + recs) | ⚠️ Partial | `tasteService.getTasteCompatibility` already returns `topShared` and `biggestDivergences` — those are your Venn intersections and "biggest fights." Venn-only counts (you-only, them-only) are not returned; extend the RPC or compute client-side with set difference. `getFriendRecommendations` exists but returns "movies for me based on friends," **not** "movies to send this specific friend." Add `tasteService.getRecommendationsForFriend(viewerId, targetId, limit)` — the viewer's S/A rankings that target hasn't ranked or added. |
| 11b | "Send 3 recs" action | ❌ Missing | No service pushes a recommendation into another user's inbox. Options: (a) add rows to a new `recommendations` table with RLS allowing target to read, (b) reuse `notifications` with a new type `recommendation`, reference_id = tmdb_id list. Recommendation: new `notifications.type = 'movie_rec'` plus `metadata jsonb` with the list — smallest migration, reuses existing bell. |
| 12 | Profile aggregations (top-4, obsessed, recent) | ⚠️ Partial | Top-4: query `user_rankings WHERE tier='S' ORDER BY rank_position LIMIT 4`. Currently-obsessed: count `journal_entries WHERE user_id=? AND is_rewatch=true AND created_at > now()-interval '30 days'` grouped by tmdb_id. Recent 5: `stubService.getAllStubs(userId).prefix(5)`. None of these exist as dedicated services; all are cheap ad-hoc queries. Add a `profileAggregates.ts` thin service so iOS has a clean seam. |

## Prioritized build list

1. **`tasteService.getFriendsWhoRanked(tmdbId, viewerId)`** — needed for stub detail screen. Small query, big UX payoff.
2. **`notifications.type = 'movie_rec'` + `movie_recs` sender** — needed for "send 3 recs" on twin screen. Migration + a helper in `notificationService`.
3. **`tasteService.getRecommendationsForFriend(viewerId, targetId)`** — feeds the twin-screen recs row. Query is "my S/A rankings where tmdb_id NOT IN target's user_rankings + watchlist_items."
4. **`tasteService.getTasteCompatibilityBatch(viewerId, targetIds[])`** — avoids N+1 on the friends list. Same logic as the single-target variant, grouped.
5. **`profileAggregates.ts`** — `getTopTier(userId, tier, limit)`, `getCurrentlyObsessed(userId, days)`, `getRecentStubs(userId, limit)`. Thin wrappers, not complex.
6. **Feed reaction/comment realtime** — not missing service-wise; just needs a Realtime channel on iOS instead of polling.
7. **Stub → PNG share** — pure iOS (SwiftUI `ImageRenderer` + `UIActivityViewController`). No backend.

Everything else in the design already has a home in the existing service layer.
