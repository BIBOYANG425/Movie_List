# Spool Refactor & Parity Roadmap (Master Task List)

> **This is an index, not an implementation plan.** Each unchecked workstream below needs its own detailed plan (via superpowers:writing-plans) before execution. Items are sequenced by dependency and value-per-effort. Source: the 2026-07-06 complexity audit (web + iOS) and web↔iOS parity study.

**Legend:** effort is one-developer, focused. "Client-only" = the Supabase schema/RLS/RPCs already support it; no backend work needed.

---

## Wave 0 — Correctness & cheap wins (do first)

- [ ] **W0.1 Engine unification** — plan exists: `docs/plans/2026-07-06-engine-unification.md`. Fix Swift scars, backport `advanceSmallTier` to web, `RankingSession`/`PlacementSession` facades, golden-fixture parity corpus + CI gate. Ends the twice-already-happened engine drift. *~3–5 days.*
- [ ] **W0.2 iOS stub write fix (data loss)** — `RankPersistence.save` has a TODO where `insertStub` should be chained; iOS users generate zero `movie_stubs`, so their Stubs tab and the share loop start empty. Chain the stub insert + palette extraction (CIAreaAverage). Highest value-per-effort item in the repo. *Client-only, ~2–3 days.*
- [ ] **W0.3 Web dead-code deletion** — delete the orphaned shared-watchlist/taste-comparison cluster (`SharedWatchlistView`, `RankingComparisonView`, `TasteCompatibilityBadge`, half of `socialService`, chunks of `tasteService`/`types.ts`), the 5 `@deprecated` tmdbService exports, and the `friendsService.ts` `export *` barrel (codemod 14 importers to direct imports). ~1,400 lines gone. Verify with `tsc --noEmit` + build. *~1 day, near-zero risk.*
- [ ] **W0.4 Feed N+1 fix** — `feedService.getRankingScores` issues up to 100+ serialized round-trips per feed load (per-user, per-tier COUNT queries). Replace with one grouped query per table (3 total) or a Postgres RPC computing tier-position scores in SQL. Biggest perceived-speed win on the hottest read path. *~2 days.*

## Wave 1 — Web complexity paydown

- [ ] **W1.1 `useRankedCollection` hook** — de-triplicate RankingAppPage's per-media-type CRUD (movies/TV/books): one parameterized hook (`{table, watchlistTable, toRow, fromRow}`), page drops 1,695 → ~500 lines, 23 useState hooks collapse, accidental divergences (movie-only rollback, movie-only migration flow) become explicit decisions. *~1 week including drag-drop regression testing.*
- [ ] **W1.2 tmdbService MediaAdapter** — genericize the movie/TV parallel functions (`getSmartSuggestions`/`getSmartTVSuggestions` etc.) over a `MediaAdapter` object; extract `tmdbFetch` URL helper. 1,905 → ~900 lines. Consider deferring if W3.2 (discover as edge function) lands first — the code may move server-side anyway. *~3 days.*
- [ ] **W1.3 Add-modal unification** — extract `useSuggestionPool` + `useDebouncedMediaSearch` hooks; fold AddTVSeasonModal into "AddMediaModal + season-picker step". Depends on W0.1's `RankingSession` (already removes the biggest duplicated block). *~3–4 days.*
- [ ] **W1.4 profileService legacy-fallback removal** — verify prod schema has the phase-1 profile columns (one `select` against prod), then delete the 5× `usingLegacySchema` retry paths; fold feedService's private `getProfilesByIds` copy into profileService. *~1 day.*
- [ ] **W1.5 JournalConversation split** — split chat phase vs 15-field draft form into separate components; collapse form fields into one `useReducer` draft object; move `buildContext` queries into `agentService`. 818 lines / 28 hooks → 3 files / ~8 hooks. *~2 days.*

## Wave 2 — iOS structural paydown

- [ ] **W2.1 ScreenLoader + `.task(id:)`** — extract the generic loading/session/race-guard state machine used by 7 screens; the PR-#28 race-guard fix currently protects only 2 of them. Fixes the latent stale-response bug class everywhere at once. *~3–4 days, screen-by-screen.*
- [ ] **W2.2 Delete Service/Repository twins** — remove `FollowService`/`ProfileService`, point onboarding at the repositories (gains duplicate-follow idempotency + follow notifications during onboarding, currently silently missing). *~half a day.*
- [ ] **W2.3 SpoolAppRoot cleanup** — collapse the 7 parallel rank-flow optionals into one enum with associated values; replace UserDefaults-string-key signaling (`"spool.show_signin_sheet"`) with an injected `AppSignals` observable; model the 4 modal optionals as one `Overlay?` enum. *~2–3 days.*
- [ ] **W2.4 Shared helpers + profile components** — `String.firstWord` (currently defined in 7 files), `stableSeed` (4 files), `Tier.numericWeight` (3 diverging tables); extract `ProfileHeader`/`TopFourRow`/`RecentStubsRow` so FriendProfileScreen stops being a 90% copy of ProfileScreen. Split OnboardingScreens.swift into one file per step. *~2 days.*
- [ ] **W2.5 Fixture gating at the data layer** — read-path protocols + a `FixtureRepository` selected once at the root, deleting per-view `hasSession`/April-guard/opacity branches (the source of the fixture-leak bugs). *~1 week.*

## Wave 3 — iOS feature parity (order = product priority)

- [ ] **W3.1 Social feed + notifications UI** — port `feedService.getFeedCards` + reactions + comments + mutes into a Swift `FeedRepository`; align iOS `activity_events.metadata` payload with web's shape (iOS currently writes none, so its events render degraded on web); add bell + list + mark-read against the existing `notifications` table. Without this iOS is single-player. *Client-only, ~2–3 weeks.*
- [ ] **W3.2 Discover as an edge function** — do NOT port the 1.9k-line 5-pool suggestion engine to Swift; move it into a Supabase edge function both clients call. Also removes the TMDB key from the app binary (flagged in `docs/iOS_PORT_REVIEW.md` §6.2). *~1 week backend + thin clients.*
- [ ] **W3.3 Journal on iOS** — stage (a): ceremony-level quick entry (moods + one-liner → `journal_entries` instead of `user_rankings.notes`), ~3 days; stage (b): full journal tab + AI agent chat against the deployed `journal-agent` edge function, ~2–3 weeks. *Client-only.*
- [ ] **W3.4 Watchlist UI + rank-from-watchlist** — table + RLS exist. *Client-only, ~3–4 days.*
- [ ] **W3.5 Ranking management on iOS** — edit/reorder/delete (RankingRepository is currently insert-only; users cannot fix mistakes — a trust issue for a ranking app). *Client-only, ~1 week.*
- [ ] **W3.6 TV seasons + books verticals** — `tv_rankings`/`book_rankings` tables exist; needs Open Library client + `tv_{id}_s{n}`/`ol_` id handling. *Client-only, ~1–1.5 weeks.*
- [ ] **W3.7 zh localization on iOS** — `.xcstrings` catalog (web ships 376 keys × en/zh) + TMDB `language` param from locale. *~3–4 days.*
- [ ] **W3.8 Smaller parity items** — achievements (~3 days), Letterboxd import (~1 week), curated lists (~4 days), universal links for `/u/username` (~2–3 days), `movie_recommendations` migration + wire the dead "send 3 recs" button (~2–3 days).

## Wave 4 — Web backports from iOS (small, cheap)

- [ ] **W4.1 Re-wire orphaned web features** — FriendsView search and the taste-twin/compatibility UI exist as dead code on web while iOS ships them live; re-wire or delete deliberately. *~2–3 days.*
- [ ] **W4.2 Preview mode on web** — iOS's rank-before-signup queue (`OnboardingQueue`) is an acquisition win web lacks. *~1 week.*
- [ ] **W4.3 Backport batch taste-compat + recs-for-friend** — currently Swift-only business logic in `TasteRepository`; move to a SQL RPC both clients call rather than duplicating into `tasteService.ts`. *~2–3 days.*

## Standing rules (apply to every wave)

1. New shared business logic goes into the backend (RPC/edge function/trigger), never into a second client-side copy. The interactive H2H engine is the sole sanctioned duplicate, guarded by the W0.1 fixture corpus.
2. Any change to ranking semantics regenerates `fixtures/engine-parity.json` in the same PR, and both platforms' replay tests must be green before merge.
3. When a feature ships on one platform, file the parity gap for the other platform in this document immediately — the April docs went stale because parity was tracked by memory.
