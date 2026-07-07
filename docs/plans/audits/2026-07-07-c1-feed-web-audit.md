# C1 Web Audit — social feed + notifications (reference semantics for iOS `FeedRepository`)

**Cycle:** C1 (social feed + notifications)
**Audited at commit:** `c2338dd` on `feat/ios-parity-c0-stub-write` (all web files audited here match main)
**Scope:** `services/feedService.ts`, `services/notificationService.ts`, `services/activityService.ts`, `services/followService.ts`, `services/journalService.ts` (notification writes), `services/achievementService.ts` + `services/socialService.ts` (event writes), `components/feed/*`, `components/social/NotificationBell.tsx`, `supabase/migrations/supabase_phase2_activity_patch.sql`, `supabase_phase5_social_feed.sql`, `supabase_phase4_engagement.sql`, `supabase_fix_critical_rls.sql`, `20260406_public_profiles.sql`, iOS `RankingRepository.swift`. Audit only — no code changed.

---

## 1. Reference semantics

### 1.1 Feed assembly contract (`feedService.getFeedCards`, `feedService.ts:168-329`)

Pipeline, in order:

1. **Actor scope** (`feedService.ts:174-181`). `filters.tab === 'friends'` → actor set = `friend_follows.following_id` where `follower_id = viewer` (`getFollowingIds`, `:38-49`). **The viewer's own events are NOT in the friends tab** (you don't follow yourself). Empty follow list → return `[]` without querying. `tab === 'explore'` → no actor filter; visibility is delegated entirely to RLS (see §1.6).
2. **Mutes** (`:184-192`). Load all viewer rows from `feed_mutes` (`getMutes`, `:546-562`). `user` mutes are removed from the friends actor list pre-query (`:190`); in explore mode they are filtered client-side post-query (`:231`). `movie` mutes filter rows by `media_tmdb_id` post-query (`:230`) — the `target_id` is the raw media id, so despite the name `'movie'` it applies equally to `tv_*`/`ol_*` ids.
3. **Event-type filter** (`getEventTypesForFilter`, `:331-340`). `all` → `['ranking_add','ranking_move','review','list_create','milestone']`. Note `ranking_remove` is **never rendered in the feed** (it exists only for the FriendsView mini-feed, `activityService.ts:56`).
4. **Server query** (`:198-219`). `activity_events` select of the 8 card columns, `.in('event_type', …)`, `.order('created_at', desc)`, optional `.eq('media_tier', filters.tier)` (`:209-211`), optional `created_at >= now - {24h|7d|30d}` (`applyTimeFilter`, `:153-164`, cutoff computed from client clock). Fetch window: `fetchLimit = limit + offset + 20` (`:216`) — **offset pagination re-downloads the entire feed prefix each page** (see finding B4).
5. **Client-side post-filters** (`:229-247`): mutes (above); bracket filter on `metadata.bracket` (`:236-241`, dead — see D1); `throttleMilestones` (`:342-352`) caps milestone cards at 3 per **UTC** calendar day (`created_at.slice(0,10)`) across all actors within the fetched window; `applyReviewBoost` (`:354-366`) re-sorts by `created_at + 2h` for `review` events (reviews float above up-to-2h-newer cards).
6. **Paginate** (`:250`): `rows.slice(offset, offset + limit)`.
7. **Hydration** (`:255-276`), 3 parallel batches: profiles for actors + `metadata.watched_with_user_ids` (`getProfilesByIds`, `:51-78`; avatar fallback chain `avatar_url` → storage public URL from `avatar_path` → dicebear seeded by username); engagement (`getReactionsForEvents`, §1.4); live scores (`getRankingScores`, §2 — the N+1).
8. **Card mapping** (`:279-328`). `event_type → cardType`: `ranking_add|ranking_move → 'ranking'`, `review → 'review'`, `milestone → 'milestone'`, `list_create → 'list'` (`toFeedCardType`, `:140-146`); unknown types coerce to `'ranking'` (`:282`). `media_tier` outside S–D → undefined (`toTier`, `:148-151`). `mediaScore` only set when the score map has `${actor_id}:${media_tmdb_id}`.

Consumer (`SocialFeedView.tsx:29-72`): `PAGE_SIZE = 20`, `offset = cards.length`, infinite scroll via IntersectionObserver; `hasMore = newCards.length >= PAGE_SIZE` (`:64`) — any page shortened by client-side filtering prematurely ends the feed. Reaction toggles are optimistic with revert-on-failure (`:101-133`).

**Events are append-only.** No UPDATE/DELETE policy exists on `activity_events` (phase 2 migration defines only SELECT + INSERT), so re-ranking produces a new `ranking_move` card per move with no dedupe, and deleting a ranking leaves the old `ranking_add` cards in the feed forever (a `ranking_remove` row is written but never rendered).

### 1.2 `activity_events` row + complete metadata shapes (the contract)

Table (`supabase_phase2_activity_patch.sql:4-16`): `id` uuid PK, `actor_id` uuid NOT NULL → profiles, `event_type` text CHECK, `target_user_id` uuid (written by nobody), `media_tmdb_id/media_title/media_poster_url` text NULL, `media_tier` CHECK S–D, `metadata` jsonb NOT NULL DEFAULT `{}` (CHECK object), `created_at` timestamptz default now(). CHECK after phase 5 (`supabase_phase5_social_feed.sql:8-10`): `('ranking_add','ranking_move','ranking_remove','review','list_create','milestone')`.

| event_type | Writer | Columns set | `metadata` shape (keys omitted when falsy) |
|---|---|---|---|
| `ranking_add` | `activityService.logRankingActivityEvent` (`activityService.ts:20-45`), called from `RankingAppPage.tsx` (movie `:523`, TV `:806`, book `:1041`), `MovieOnboardingPage.tsx:389`, `activityService.rankActivityMovie:324` | `media_tmdb_id` (raw id: numeric string / `tv_{id}_s{n}` / `ol_*`), `media_title`, `media_tier`, `media_poster_url` | `{ notes?: string, year?: string, watched_with_user_ids?: string[] (uuid) }` |
| `ranking_move` | same writer; `RankingAppPage.tsx:396,933,1154` | same | `{ notes?: string, year?: string }` (the move call sites don't pass `watchedWithUserIds`) |
| `ranking_remove` | same writer; `RankingAppPage.tsx:605,866,1085` | same | `{ notes?: string, year?: string }` |
| `review` | `feedService.logReviewActivityEvent` (`feedService.ts:597-626`), called from `journalService.ts:143` when a journal entry has `reviewText` and visibility ≠ private | media columns; `media_tier` nullable | `{ reviewBody: string, containsSpoilers: boolean }` (both always present) |
| `list_create` | `feedService.logListCreatedEvent` (`feedService.ts:628-653`), called from `socialService.ts:287` | media columns all NULL | `{ listId: string(uuid), listTitle: string, listPosterUrls: string[] (≤4), listItemCount: number }` |
| `milestone` | `feedService.logMilestoneEvent` (`feedService.ts:655-678`), called from `achievementService.ts:113` on badge grant | media columns all NULL | `{ badgeKey: string, badgeIcon: string(emoji), milestoneDescription: string }` |

Never written despite being read: `metadata.bracket` (`feedService.ts:238,298`) — see D1. Never written at all: `target_user_id`. Legacy phase-2 types `follow|comment|reaction` were removed from the CHECK by phase 5.

**Load-bearing fields per card component** (what iOS-written rows must carry to render fully on web):
- `FeedRankingCard.tsx`: `media_title`, `media_tier` (tier chip + left border + score-badge background), `media_poster_url`, `mediaScore` (computed, needs the actor's ranking row visible to the viewer), `metadata.watched_with_user_ids` → "watched with @…" line (`:132-138`). `card.bracket` renders if present (`:125-127`) but never is. `metadata.notes` is NOT rendered in the feed.
- `FeedReviewCard.tsx`: `metadata.reviewBody` (falls back to `''`), `metadata.containsSpoilers` gates a tap-to-reveal blur (`:124-153`), plus the ranking-card media fields.
- `FeedMilestoneCard.tsx`: `metadata.badgeIcon` (fallback Award icon), `metadata.milestoneDescription`. `badgeKey` is stored but unused by renderers.
- `FeedListCard.tsx`: `listPosterUrls`, `listTitle`, `listItemCount`; `listId` is stored but there is no navigation to the list from the card.

### 1.3 What iOS writes today vs. required

iOS `RankingRepository.insertRanking` (`ios/Spool/Sources/Spool/Services/RankingRepository.swift:125-141`) writes `ranking_add` with the four media columns and **no `metadata` key** (payload struct has none → DB default `{}`), fire-and-forget. It never writes `ranking_move`/`ranking_remove` (repo is insert-only), nor review/list/milestone events. Consequences on web today: iOS cards render title/tier/poster/score fine, but lose `notes`/`year` (profile-activity consumers, `activityService.ts:103-104`) and can never show "watched with". iOS additions required for full parity: metadata `{notes?, year?, watched_with_user_ids?}` on ranking events; `ranking_move`/`ranking_remove` when C4 adds management; review/milestone events when C2/C7 land those features.

### 1.4 Reactions + comments contract

- `activity_reactions` (`supabase_phase2_activity_patch.sql:25-31` + phase5 `:13-17`): PK `(event_id, user_id, reaction)`, `reaction` CHECK `('fire','agree','disagree','want_to_watch','love')` (phase 5 migrated legacy `'like'` → `'love'`). Multiple different reactions per user per event are allowed; duplicates of the same reaction are impossible (PK).
- Toggle (`feedService.toggleReaction`, `feedService.ts:370-400`): add = plain INSERT (duplicate → PK violation → `false` → UI reverts); remove = DELETE on the triple. No upsert, no read-back.
- Counts (`getReactionsForEvents`, `feedService.ts:402-449`): one batched select of all reaction rows for the page's event ids + one batched select of all comment rows (id only), tallied client-side; `myReactions` = rows where `user_id === viewer`. Unknown reaction strings are dropped (`:434`). **No LIMIT on either select** — unbounded per-event row counts by design.
- `activity_comments` (`supabase_phase2_activity_patch.sql:38-46` + phase5 `:20-22`): `body` CHECK `length(btrim(body)) BETWEEN 1 AND 500`, `parent_comment_id` self-FK for 1-level threading (CASCADE delete of replies).
- List (`listFeedComments`, `feedService.ts:453-505`): ascending `created_at`, LIMIT 100, replies nested one level under parents client-side. Add (`addFeedComment`, `:507-528`): `body.slice(0,500)`, no trim (see D10). Delete (`deleteFeedComment`, `:530-542`): scoped `user_id = viewer` (matches RLS).
- RLS (phase 2, never updated for explore — finding B3): SELECT and INSERT on both tables require the parent event's actor to be the viewer **or someone the viewer follows**. DELETE = own rows only.
- `@username` tokens in comment bodies are bolded client-side (`FeedCommentThread.tsx:8-13`); plain text, no entity linking.
- Legacy dead path: `activityService.toggleActivityLike/getActivityEngagement/listActivityComments/addActivityComment` (`activityService.ts:119-259`) have zero UI consumers, and `toggleActivityLike` inserts `reaction:'like'`, which the phase-5 CHECK now rejects — it can only fail (D11).

### 1.5 Mutes contract (`feed_mutes`, `supabase_phase5_social_feed.sql:25-46`)

Row: `(user_id, mute_type 'user'|'movie', target_id text)`, UNIQUE triple, RLS = owner-only for SELECT/INSERT/DELETE. Semantics: strictly **viewer-side read filtering** — anyone can mute anyone (no relationship check, self-mute possible), muting never notifies or affects the muted party, and does not stop the muted user from seeing/reacting to the viewer's content. Mute filtering applies **only** in `getFeedCards`; a muted user's **reactions still count and their comments still appear** in threads (`getReactionsForEvents`/`listFeedComments` never consult mutes — D3). `addMute` on duplicate → unique violation → `false` (silent in UI). There is **no unmute UI** — `removeMute` (`feedService.ts:581-593`) has no consumer, so mutes are permanent from the user's perspective (D3).

### 1.6 Explore feed + RLS visibility model

`activity_events` SELECT policies (both are permissive, OR'd):
1. Phase 2 (`supabase_phase2_activity_patch.sql:57-69`): own events + events of actors the viewer follows (all event types, incl. `ranking_move`/`ranking_remove`).
2. Phase 5 explore policy (`supabase_phase5_social_feed.sql:49-55`): **any authenticated user** can read anyone's `ranking_add`, `review`, `list_create`, `milestone` events.

So explore = global newest-first stream of those 4 types from every user (plus the viewer's own and followed users' `ranking_move` rows, which sneak in because `getEventTypesForFilter('all')` includes `ranking_move` and policy 1 admits them — explore is therefore not purely global-types). Selection is purely recency + the client-side throttles; there is no ranking/recommendation logic. **The policy predates `profile_visibility` (`20260406_public_profiles.sql`) and ignores it** — see finding B2. Score badges on explore cards usually stay hidden for strangers because the ranking-table RLS (own/followed/public-profile) blocks `getRankingScores`, which is also why B3's reaction gap is user-visible: the card renders but every interaction fails.

### 1.7 Notifications contract

Table (`supabase_phase4_engagement.sql:8-35` + `supabase_fix_critical_rls.sql:8-14`): `id` uuid PK, `user_id` (recipient, CASCADE), `type` text CHECK in `('new_follower','review_like','party_invite','party_rsvp','poll_vote','poll_closed','list_like','badge_unlock','group_invite','ranking_comment','journal_tag')`, `title` text NOT NULL, `body` text, `actor_id` uuid SET NULL, `reference_id` text (generic), `is_read` bool default false, `created_at`. Indexes: `(user_id, created_at DESC)` + partial unread. RLS: SELECT/UPDATE/DELETE own; INSERT allowed for **any authenticated user targeting any existing profile** (`supabase_fix_critical_rls.sql:39-43`) — all notification writes are client-side inserts, there are **no DB triggers** for notifications.

Actually written today (the live contract):
| type | Writer | title | body | reference_id |
|---|---|---|---|---|
| `new_follower` | `followService.followUser` (`followService.ts:14-22`) | `'started following you'` (literal English) | — | follower's user id |
| `journal_tag` | `journalService.upsertJournalEntry` (`journalService.ts:156-170`), one row per tagged friend | `` `watched ${title} with you` `` | first 100 chars of review text | journal entry id |

`review_like`, `list_like`, `badge_unlock`, `ranking_comment` have icons in the bell (`NotificationBell.tsx:7-14`) and live in the `NotificationType` union (`types.ts:306-312`) but **no writer exists**; `party_*`/`poll_*`/`group_invite` are orphans of dropped features (tables deleted by `20260325_drop_parties_polls_groups.sql`, CHECK never pruned). Feed reactions and comments generate **no notifications at all**. `notificationService.createNotification` (`notificationService.ts:5-23`) is a dead export with zero callers.

Read model (`notificationService.ts:25-75` + `NotificationBell.tsx`):
- List: newest-first, LIMIT 30, actor profiles batch-joined client-side; `actorAvatar` built from `avatar_path` only (not `avatar_url` — subtle divergence from the feed's avatar fallback chain).
- Badge: `getUnreadCount` = head count of `is_read = false`, polled every **15 s** (`NotificationBell.tsx:42-61`), no realtime subscription.
- Mark-read: opening the dropdown fetches the list, then bulk `update is_read = true` on all fetched unread ids (`NotificationBell.tsx:82-88`, `markNotificationsRead` filters only `.in('id', ids)` — RLS confines it to own rows). Badge is zeroed locally; if unread > 30 exist, the next poll resurrects the residual count (D5).
- Unknown types render with the `new_follower` icon (`NotificationBell.tsx:127`). Titles are baked English strings at write time; the zh locale renders them untranslated (D12).

---

## 2. The N+1 (blocking B1): `getRankingScores` (`feedService.ts:84-138`)

For a 20-card page, `rankingPairs` holds up to 20 `(actor, media_id)` pairs (`:264-270`). The function then:
1. Groups pairs by user (`:91-96`), and iterates users **sequentially** (`for…of` with `await`, `:98`).
2. Per user: 3 parallel selects (`user_rankings`, `tv_rankings`, `book_rankings`) filtered to that user's media ids (`:100-104`).
3. Per table with hits: for **each distinct tier** among the matched rows, one **sequential** `count: exact, head: true` query for the user's total rows in that tier (`:117-124`) — the count is over the whole table for that user+tier (needed because score depends on tier population), so it cannot be derived from the already-fetched rows.
4. Score = `computeTierScore(rank_position, tierTotal, range.min, range.max)` (`rankingAlgorithm.ts:153-172`) with `TIER_SCORE_RANGES` (`constants.ts:65-71`), rounded to 1 decimal.

**Query count:** `3·U + Σ(distinct tiers per user per table)` where U = distinct actors on the page. Typical page (20 distinct actors, movies only, 1–2 tiers each): ~60 selects + ~30 counts ≈ **90–100 queries**; worst case (5 tiers × 3 tables) is 360. Latency compounds because users are serialized and tier counts are serialized within each table: ~3–5 round-trips per actor ≈ 60–100 serialized RTTs per feed page. This runs on every page load and every pagination step. Matches the parity study's "~100-query N+1" and roadmap item W0.4 (`docs/plans/2026-07-06-refactor-roadmap.md:14`).

**Recommended fix (design, for the C1 web PR — both clients adopt):** one SQL RPC.

```sql
-- migration: get_feed_ranking_scores.sql
create or replace function public.get_feed_ranking_scores(pairs jsonb)
-- pairs: [{"user_id":"<uuid>","tmdb_id":"<text>"}, ...]  (≤ ~40 per call)
returns table (user_id uuid, tmdb_id text, score numeric)
language sql stable security invoker set search_path = public as $$
  with req as (
    select distinct (e->>'user_id')::uuid as user_id, e->>'tmdb_id' as tmdb_id
    from jsonb_array_elements(pairs) e
  ),
  users as (select distinct user_id from req),
  all_rows as (
    select 'm' as src, r.user_id, r.tmdb_id, r.tier, r.rank_position
      from user_rankings r join users u using (user_id)
    union all
    select 'tv', r.user_id, r.tmdb_id, r.tier, r.rank_position
      from tv_rankings r join users u using (user_id)
    union all
    select 'bk', r.user_id, r.tmdb_id, r.tier, r.rank_position
      from book_rankings r join users u using (user_id)
  ),
  counted as (
    select src, user_id, tmdb_id, tier, rank_position,
           count(*) over (partition by src, user_id, tier) as tier_total
    from all_rows
  )
  select c.user_id, c.tmdb_id,
    round(case when c.tier_total <= 1 then (t.lo + t.hi) / 2
          else t.lo + (t.hi - t.lo) * (c.tier_total - 1 - c.rank_position) / (c.tier_total - 1)
          end, 1)
  from counted c
  join req using (user_id, tmdb_id)
  join (values ('S',9.0,10.0),('A',7.0,8.9),('B',5.0,6.9),('C',3.0,4.9),('D',0.1,2.9))
       as t(tier, lo, hi) on t.tier = c.tier;
$$;
grant execute on function public.get_feed_ranking_scores(jsonb) to authenticated;
```

Parity notes: `security invoker` keeps ranking-table RLS in force, so tier totals are computed over exactly the rows the viewer can already see — identical to today's client-side counts (own/followed/public-profile actors return scores; strangers return no rows and the badge stays hidden). Per-table window partition (`src`) preserves the per-table tier-count semantics of `feedService.ts:107-124`. Rounding: JS `Math.round(x*10)/10` and PG `round(numeric, 1)` agree for all positive scores in these ranges (verified for the half-way midpoint cases, e.g. A-tier single item → 8.0 both sides). Web swaps `getRankingScores`'s body for one `supabase.rpc('get_feed_ranking_scores', { pairs })`; iOS `FeedRepository` calls the same RPC. Fallback if the RPC is missing (older DB): keep the current path behind a feature check, or ship the migration in the same PR (preferred; per the standing DB rule, verify the migration is applied and E2E-smoke before relying on it). A grouped-query alternative (3 row-selects + 3 tier-count aggregates) is not expressible in PostgREST without a view per table; the RPC is strictly simpler.

---

## 3. Findings

### Blocking

- **B1 — ~100-query N+1 on every feed page.** `feedService.ts:84-138` (detail + fix design in §2). Ported as-is it would make the iOS feed unusably slow and double the duplicated logic. Fix: `get_feed_ranking_scores` RPC; both clients adopt.
- **B2 — Explore RLS ignores `profile_visibility` (privacy leak).** `supabase_phase5_social_feed.sql:49-55` lets any authenticated user read anyone's `ranking_add`/`review`/`list_create`/`milestone` events, while `20260406_public_profiles.sql` deliberately restricts the underlying `user_rankings`/`tv_rankings`/`book_rankings` rows to public profiles. Default visibility is `'friends'`, so today every non-public user's titles/tiers/posters/review bodies leak globally through `activity_events` even though their rankings tables are protected. Fix: recreate the explore policy with `AND EXISTS (select 1 from profiles p where p.id = actor_id and p.profile_visibility = 'public')` — or drop the event-type list and gate purely on visibility; needs owner call on whether explore should default-include `'friends'`-visibility users (see Q2).
- **B3 — Reactions/comments RLS was never extended for explore.** `supabase_phase2_activity_patch.sql:78-171` gates SELECT and INSERT on both tables to events whose actor is the viewer or followed. Explore (phase 5) shows strangers' cards, so: reaction/comment **counts read as 0** on any explore card from a non-followed actor, and every reaction toggle / comment insert on such cards **fails RLS** — the optimistic UI bumps then silently reverts (`SocialFeedView.tsx:108-132`), comments just don't post. Fix: same migration as B2 — extend both SELECT/INSERT policies with an `OR` clause matching the (fixed) explore-visible predicate, so engagement rights track card visibility exactly.
- **B4 — Offset pagination with client-side re-sorting: duplicates, skips, premature end, O(n²) refetch.** `feedService.ts:216,250` + `SocialFeedView.tsx:55,64`. (a) New events between page loads shift offsets → repeated cards (duplicate React keys) or skipped cards. (b) `applyReviewBoost` re-sorts a window that grows with offset, so an old review can jump into an already-consumed slice and never be shown. (c) `hasMore = newCards.length >= PAGE_SIZE` ends the feed early whenever mutes/throttle shorten a page even though older rows exist beyond `fetchLimit`. (d) `fetchLimit = limit + offset + 20` re-downloads the whole prefix every page. Ported to Swift this all ships to iOS. Fix design: keyset cursor on the **boosted** sort key — `sort_ts = created_at + interval '2 hours' * (event_type = 'review')::int`, order `(sort_ts desc, id desc)`, cursor = last row's `(sort_ts, id)`. PostgREST can't order by an expression, so either (i) fold page selection into a small `get_feed_page` RPC (natural companion to B1's RPC; milestone throttle and mute filtering can stay client-side), or (ii) drop the 2h review boost and keyset on plain `(created_at, id)` — a visible behavior change needing owner ack (Q3).

### Deferred

- **D1 — `bracket` is a dead contract path.** Read at `feedService.ts:236-241,298` and rendered at `FeedRankingCard.tsx:125-127`, typed in `FeedFilters` (`types.ts:585`), but no writer ever puts `bracket` in `activity_events.metadata` and `FeedFilterBar` exposes no bracket control. Decide: write `bracket` at ranking-event time (contract addition) or delete the filter/field.
- **D2 — Dead event types in tasteService.** `tasteService.ts:558-560` maps `'review_add'`/`'watchlist_add'`, which violate the CHECK and are never written; dead branches.
- **D3 — Mute leaks + no unmute.** Muted users' reactions/comments remain visible (`feedService.ts:402-449,453-505` never consult mutes); `removeMute` (`feedService.ts:581-593`) has no UI consumer so mutes are irreversible in-product; `SocialFeedView.tsx:9,11` imports `getMutes`/`removeMute` unused.
- **D4 — Milestone throttle quirks.** UTC day bucketing (`feedService.ts:346`) and per-request window mean the 3/day cap resets across pagination requests; cap is global across friends (comment says intended) but not stable across pages.
- **D5 — Bell mark-read races/limits.** Only the 30 fetched notifications get marked; with >30 unread the badge zeroes then resurrects on the next 15 s poll (`NotificationBell.tsx:82-88,42-61`). Consider `update … eq(user_id, is_read=false)` server-side mark-all.
- **D6 — Notification INSERT policy allows forgery/spam.** Any authenticated user may insert any type for any user (`supabase_fix_critical_rls.sql:39-43`); all writes are client-side. Long-term fix is trigger- or RPC-based notification writes; also prune the 7 orphaned CHECK types (`party_*`, `poll_*`, `group_invite`) or the CHECK drifts further from reality.
- **D7 — Reaction double-toggle noise.** Concurrent add from two devices → PK violation → second client's UI reverts a reaction that actually exists. Harmless to data (PK dedupes); fix is `upsert(…, ignoreDuplicates: true)` treating duplicate as success.
- **D8 — Unbounded `.in('actor_id', …)`.** Friends feed passes the entire following list into one `IN` (`feedService.ts:204-206`); hundreds of follows → very large query URLs. Fine at current scale; the B4 RPC can take `uuid[]` instead.
- **D9 — Silent score corruption on count failure.** `count ?? 1` (`feedService.ts:123`) turns a failed tier-count query into "tier of 1" → wildly wrong midpoint score rendered with confidence. Superseded by B1's RPC.
- **D10 — Comment validation mismatch.** `addFeedComment` sends `body.slice(0,500)` without trim (`feedService.ts:516`); whitespace-only bodies violate the `btrim` CHECK and fail silently (UI ignores the `false`). `FeedCommentThread` trims its own drafts, so only programmatic callers hit it; iOS must trim + enforce 1–500 to match the DB.
- **D11 — Dead legacy engagement layer.** `activityService.ts:119-259` (`toggleActivityLike` inserts CHECK-violating `'like'`, `getActivityEngagement` filters on `'like'` so always counts 0) has no consumers — delete in W0.3/W1.x rather than port.
- **D12 — Notification titles are baked English.** Written as literal strings at insert (`followService.ts:17`, `journalService.ts:162`); zh clients render them untranslated. Parity contract for now: iOS writes the identical English strings; i18n-by-type is a later web fix (C6 adjacent).

---

## 4. iOS gap list (what `FeedRepository` must implement)

Today iOS has only `RankingRepository.getRecentActivity` (own `ranking_add` rows, `RankingRepository.swift:79-93`) and a metadata-less `ranking_add` insert (`:125-141`). For C1 parity:

1. **Feed read:** the §1.1 pipeline — friends/explore tabs, event-type/tier/time filters, mute filtering, milestone throttle, review boost, pagination (per B4's fixed cursor contract, not the current offset model), profile hydration with the 3-step avatar fallback, card mapping incl. `toFeedCardType` coercion and S–D tier guard.
2. **Scores:** call `get_feed_ranking_scores` RPC (B1); hide score badge when no row returns.
3. **Engagement:** batched reactions/comments counts + `myReactions` per page; reaction toggle (insert/delete triple, treat duplicate-key as success per D7); comment list (asc, limit 100, 1-level reply nesting), add (trimmed, ≤500), delete (own).
4. **Mutes:** CRUD on `feed_mutes` (add user/movie mute, list, remove — iOS can ship the unmute UI web lacks), apply at read time exactly as §1.1 step 2.
5. **Event writes:** extend the activity insert with `metadata` (`notes`, `year`, `watched_with_user_ids`) so iOS ranking cards render "watched with" and profile notes on web; keep event write fire-and-forget after the ranking row lands (web awaits but ignores failure — same net contract).
6. **Notifications:** unread-count badge (15 s poll or better), list (limit 30, actor join), open-marks-fetched-unread-read semantics; **write** `new_follower` on follow (exact row shape §1.7) — `journal_tag` arrives with C2. Render the 6 `NotificationType` cases with unknown-type fallback.
7. **Contract doc:** add the §1.2 metadata table and §1.7 notification rows to `docs/contracts/shared-payloads.md` in the C1 PR.

## 5. Open questions for the plan

- **Q1:** Friends tab excludes the viewer's own events (web semantics). Keep for iOS, or include self (would also need a web change to stay identical)?
- **Q2 (gates B2 fix):** Should explore include events from `'friends'`-visibility profiles (today's de-facto behavior, but it contradicts the rankings RLS) or only `'public'` profiles? Default-visibility is `'friends'`, so public-only could empty the explore tab until users opt in.
- **Q3 (gates B4 fix):** Keep the 2h review boost (requires expression-keyset via a `get_feed_page` RPC) or drop it (plain keyset, visible ordering change)?
- **Q4:** `ranking_move` events appear for followed users but re-ranks spam one card per move with no dedupe/collapse. Acceptable to port as-is, or collapse consecutive moves per (actor, media) in C1?
- **Q5:** Reactions/comments currently generate no notifications (`ranking_comment`/`review_like` types exist unread-side only). In-scope for C1 notifications parity, or explicitly out (recommend out; ledger a follow-up)?
- **D1 decision:** write `bracket` into ranking-event metadata (and add the missing filter UI) or delete the dead path — affects the contract doc either way.
