# Shared Payload Contracts

Shapes BOTH clients write to shared tables. Any PR that changes a shape on
one platform updates this file and the other platform in the same cycle.
Program rule source: docs/plans/2026-07-07-ios-parity-program-design.md.

## movie_stubs (since PR #30 / C0)

One stub per `(user_id, media_type, tmdb_id)` — unique index; rewatches are
not representable. `media_type` ∈ {"movie", "tv_season"}; books never get
stubs (CHECK constraint). `poster_path` holds a FULL image URL (w500), not
a bare TMDB path.

**INSERT** (first rank of an item) — exactly these columns:
`user_id, media_type, tmdb_id, title, poster_path, tier, template_id,
watched_date, updated_at`.
- `watched_date`: the user's LOCAL calendar day, `yyyy-MM-dd`. Never UTC.
- `template_id`: `"s_tier_gold"` when tier = S, else `"default"`.
- `palette`, `mood_tags`, `stub_line`: NEVER sent — DB defaults own them
  (`palette text[] NOT NULL DEFAULT '{}'`). Reserved until C2 decides
  whether moods/one-liner move onto stubs.

**On unique violation (SQLSTATE 23505)** — UPDATE exactly
`title, poster_path, tier, template_id, updated_at`, keyed on
`(user_id, media_type, tmdb_id)`. `watched_date`, `palette`, `mood_tags`,
`stub_line` are preserved: a re-rank must not rewrite stub history.

**Palette refresh** (async, after either path): fetch poster, extract up to
3 lowercase `#rrggbb` colors, UPDATE `palette` only. Extraction failure
leaves the existing value. Renderers require length ≥ 2 and fall back to
tier colors otherwise. Cross-platform color equality is NOT required.

`poster_path` is encoded as an EXPLICIT JSON null when absent on both
platforms (web `?? null`, iOS custom `encode(to:)`) — PostgREST treats a
missing key as "don't touch", so omission would silently preserve a stale
poster on conflict-update.

**Failure semantics:** stub writes are fire-and-forget on both platforms —
a stub failure never fails or delays a rank save.

Implementations: web `services/stubService.ts`
(`buildStubInsertPayload` / `buildStubConflictUpdatePayload` /
`insertStubOrUpdateOnConflict`); iOS
`ios/Spool/Sources/Spool/Services/StubWriteContract.swift` + `StubWriter.swift`.
Tests: `services/__tests__/stubService.test.ts`,
`ios/Spool/Tests/SpoolTests/StubWriteContractTests.swift`.

## activity_events (since C1)

Append-only social-feed event log. Table:
`supabase/migrations/supabase_phase2_activity_patch.sql:4-16`; `event_type`
CHECK expanded by `supabase_phase5_social_feed.sql:8-10` to exactly
`('ranking_add','ranking_move','ranking_remove','review','list_create',
'milestone')`. No UPDATE/DELETE policies exist — events are never edited
or removed. Every field below was verified against the writing call sites
at branch `fix/c1-feed-web-blocking` (f52d90b) on 2026-07-07.

**Top-level columns both clients must set on INSERT:**
`actor_id` (= auth user), `event_type`, `media_tmdb_id`, `media_title`,
`media_tier`, `media_poster_url`, `metadata`. Media columns are NULL for
`list_create`/`milestone` (the writers omit them). `metadata` is
`jsonb NOT NULL DEFAULT '{}'` with a jsonb-object CHECK — send `{}` rather
than omitting only if your client can't rely on the default. Never set:
`id`, `created_at` (DB defaults), `target_user_id` (written by nobody on
either platform; iOS sends explicit nil). `media_tmdb_id` is the RAW media
id (numeric string / `tv_{id}_s{n}` / `ol_*`); despite the column name it
carries all three media kinds.

**Per-type `metadata` shape as written today** (keys omitted when
falsy/empty unless noted):

| event_type | Writer (verified file:line) | metadata |
|---|---|---|
| `ranking_add` | `services/activityService.ts:20-45` (`logRankingActivityEvent`), called from `pages/RankingAppPage.tsx:523` (movies), `:806` (TV), `:1041` (books), `pages/MovieOnboardingPage.tsx:389`, `services/activityService.ts:324` | `{ notes?: string, year?: string, watched_with_user_ids?: string[] (uuid) }` — only the three RankingAppPage sites pass `watched_with_user_ids`; onboarding passes no `notes` |
| `ranking_move` | same writer; `pages/RankingAppPage.tsx:396` (movies), `:933` (TV), `:1154` (books) | `{ notes?: string, year?: string }` (move sites never pass watched-with) |
| `ranking_remove` | same writer; `pages/RankingAppPage.tsx:605`, `:866`, `:1085` | `{ notes?: string, year?: string }` |
| `review` | `services/feedService.ts:664-693` (`logReviewActivityEvent`), called from `services/journalService.ts:143` (only when the journal entry has review text and visibility ≠ private) | `{ reviewBody: string, containsSpoilers: boolean }` — both ALWAYS present. `media_tier` is nullable here (`tier ?? null`) |
| `list_create` | `services/feedService.ts:695-720` (`logListCreatedEvent`), called from `services/socialService.ts:287` | `{ listId: string(uuid), listTitle: string, listPosterUrls: string[] (writer slices to ≤4), listItemCount: number }` — all ALWAYS present. Media columns NULL. The sole call site fires at list creation, so today's rows always carry `[]` / `0` |
| `milestone` | `services/feedService.ts:722-745` (`logMilestoneEvent`), called from `services/achievementService.ts:113` on badge grant | `{ badgeKey: string, badgeIcon: string(emoji), milestoneDescription: string }` — all ALWAYS present. Media columns NULL |

**iOS gap (closes in the C1 iOS PR):** iOS today writes only `ranking_add`,
with the four media columns and NO `metadata` key — the payload struct has
none (`ios/Spool/Sources/Spool/Services/RankingRepository.swift:125-141`,
struct at `:234-242`), so rows land with the DB-default `{}`. Web renders
them fine but loses `notes`/`year` (profile activity,
`services/activityService.ts:103-104`) and "watched with". The C1 iOS PR
adopts the shapes above.

**Dead path:** `metadata.bracket` is read (`services/feedService.ts:316`,
`:391`; rendered by `FeedRankingCard.tsx`) but NO writer ever sets it —
adjudicated D1: stays unwritten; delete-or-write is a W0.3 candidate. Do
not start writing it without updating this contract.

**Rendering note:** `ranking_remove` never appears in the social feed
(`getEventTypesForFilter`, `services/feedService.ts:424-433`, excludes it);
it is rendered only by the FriendsView mini-feed
(`services/activityService.ts:56`).

**Feed ordering contract (since the C1 web PR):** the feed is ordered by

    boosted_ts = created_at + interval '2 hours' * (event_type = 'review')::int

i.e. the review boost is WINDOWLESS — every review row sorts as
`created_at + 2h` permanently, matching the legacy client's
`applyReviewBoost`. `boosted_ts` is computed SERVER-side
(`feed_boosted_ts` / `get_feed_page`,
`supabase/migrations/20260707_feed_page_rpc.sql`) and returned as a column
alongside each row. Clients echo the returned value VERBATIM into the
keyset cursor `(boosted_ts, id)` and never recompute it (web:
`cursorFromFeedRow`, `services/feedService.ts:153-155`; pinned by
`services/__tests__/feedPagination.test.ts`). Deterministic per row — no
`now()`, no session anchor, cursors never expire.

## notifications (since C1)

Row shape (`supabase/migrations/supabase_phase4_engagement.sql:8-23`):
`id` uuid PK default, `user_id` uuid NOT NULL (recipient, CASCADE),
`type` text CHECK (below), `title` text NOT NULL, `body` text NULL,
`actor_id` uuid NULL (SET NULL), `reference_id` text NULL (generic id),
`is_read` bool NOT NULL default false, `created_at` timestamptz default
now(). Titles are baked English strings at write time (zh renders them
untranslated — audit D12); iOS writes the identical English strings.

**Type CHECK today** (after
`20260325_drop_parties_polls_groups.sql:17-25`): exactly
`('new_follower','review_like','list_like','badge_unlock',
'ranking_comment','journal_tag')` — matching the `NotificationType` union
(`types.ts:306-312`). The party/poll/group types of dropped features were
PRUNED from the CHECK and their rows deleted by that migration; the C1
audit §1.7's "CHECK never pruned" note was stale and is corrected here.

**Types actually written today** (all writes are CLIENT-side inserts;
there are NO DB triggers for notifications):

| type | Writer (verified file:line) | title | body | actor_id | reference_id |
|---|---|---|---|---|---|
| `new_follower` | `services/followService.ts:14-22` on follow | literal `'started following you'` | unset | follower | follower's user id |
| `journal_tag` | `services/journalService.ts:157-171`, one row per tagged friend | `` `watched ${title} with you` `` | first 100 chars of review text; omitted when none | journal author | journal entry id |

**Rendered-only types (no writer exists):** `review_like`, `list_like`,
`badge_unlock`, `ranking_comment` — they have bell icons
(`components/social/NotificationBell.tsx:7-14`) and live in the type
union, but nothing inserts them; feed reactions and comments generate no
notifications (adjudicated Q5: out of scope for C1).
`notificationService.createNotification`
(`services/notificationService.ts:5-23`) is a dead export with zero
callers.

**RLS:** SELECT/UPDATE/DELETE own rows only; INSERT allowed for ANY
authenticated user targeting any existing profile
(`supabase/migrations/supabase_fix_critical_rls.sql:38-43`) — forgeable by
design for now (audit D6; long-term fix is trigger/RPC writes).

**Read model / mark-read semantics (both clients):**
- Badge = head count of `is_read = false`, POLLED every 15 s
  (`components/social/NotificationBell.tsx:42-61`); no realtime
  subscription.
- Opening the bell fetches the newest 30 (`getNotifications`,
  `services/notificationService.ts:25-58`; actor profiles batch-joined;
  `actorAvatar` built from `avatar_path` ONLY — not the feed's
  `avatar_url` fallback chain), then bulk-updates `is_read = true` on
  exactly the fetched unread ids (`NotificationBell.tsx:82-88`,
  `markNotificationsRead`, `services/notificationService.ts:60-66`).
- The badge is zeroed locally; with >30 unread, the residual count
  resurrects on the next poll (known quirk, audit D5).
- Unknown/unwritten types render with the `new_follower` icon
  (`NotificationBell.tsx:127`).

## journal_entries (since C2 web fixes, branch `fix/c2-journal-web-blocking`)

One entry per `(user_id, tmdb_id)` — `UNIQUE(user_id, tmdb_id)`; the journal
is per-movie, not per-watch (rewatch = `is_rewatch` + `rewatch_note` on the
same row). Reference implementation: `services/journalService.ts`; SQL:
`supabase/migrations/20260708_journal_visibility_model.sql`,
`20260708_journal_search_likes_hardening.sql`,
`20260708_journal_photos_private.sql` (owner-applied per the C2 runbook in
`docs/plans/2026-07-07-ios-parity-ledger.md`). Enforcement labels used below:
**[server]** = RLS/trigger/RPC enforces it, clients cannot break it;
**[client]** = each client MUST implement it — the DB will not stop a wrong
write/read.

### Write shape — full replace [client]

`upsertJournalEntry(userId, tmdbId, data)` writes EVERY column below with
`?? null` / `?? []` / `?? false` defaults, `onConflict: 'user_id,tmdb_id'`.
**There is no partial-update path: any caller that omits a field wipes it.**
Before editing an existing entry a client must load the owner's FULL row
(web: `getJournalEntry`, the only `select('*')` path) and round-trip every
field. Web funnels this through the pure seam `pickEntryForEdit(probed,
passed)` — the freshly probed owner row always wins over a row passed in from
a cross-user list/search read (those omit `personal_takeaway`; populating a
form from one and saving would silently null the takeaway). iOS must mirror
this probe-before-edit rule.

Client-written columns (exactly these, always all of them):
`user_id, tmdb_id, title, poster_url, rating_tier, review_text,
contains_spoilers, mood_tags, vibe_tags, favorite_moments,
standout_performances, watched_date, watched_location,
watched_with_user_ids, watched_platform, is_rewatch, rewatch_note,
personal_takeaway, photo_paths, visibility_override`.

Server-owned, never client-written: `id`, `created_at`, `updated_at`
(trigger), `like_count` (trigger, see Likes), `search_vector` (generated
column: title=A, review_text=B, favorite_moments=C — `personal_takeaway` is
NOT indexed since C2).

Column semantics (beyond the obvious):
- `rating_tier` [client]: NEVER taken from the form — looked up from
  `user_rankings.tier` for `(user_id, tmdb_id)` at every upsert; null if the
  item isn't ranked. Stale if the ranking later moves (no sync-back).
- `review_text` / other optional texts [client]: empty string coerced to null.
- `mood_tags`: ids from `MOOD_TAGS` (23 ids, constants.ts) — not
  DB-validated. `vibe_tags`: ids from `VIBE_TAGS` (11 ids).
  `watched_platform`: id from `PLATFORM_OPTIONS` (14 ids).
  `favorite_moments`: free text, max `JOURNAL_MAX_MOMENTS` = 5.
- `standout_performances`: jsonb array of
  `{personId: number, name: string, character?: string}`.
- `watched_date` [client]: the user's LOCAL calendar day `yyyy-MM-dd` — see
  Local dates below.
- `photo_paths`: storage object PATHS, never URLs — see Photos below.
- `visibility_override`: `'public' | 'friends' | 'private' | NULL` (CHECK).
  NULL = "Default" in the UI = inherit the author's
  `profiles.profile_visibility` — see Visibility below.

Upsert side effects, in order (both platforms must match):
1. [client] `review` activity event — ONLY when `review_text` is non-empty
   AND resolved visibility = `'public'` (`shouldEmitReviewEvent`). The
   author's `profile_visibility` is fetched at emission time only when the
   override is NULL; a failed fetch resolves to `'friends'` → gate closed
   (fail-closed). The old `!== 'private'` gate leaked friends-only review
   bodies into explore — do not regress.
2. [client] one `journal_tag` notification per tagged friend (body = first
   100 chars of review). Known deferred flaw: fires regardless of visibility
   and re-fires on every save (audit D2) — mirror as-is until D2 is fixed.

### Visibility — resolved model [server]

RLS on `journal_entries` (20260708_journal_visibility_model.sql), mirrored
1:1 by the pure `resolveVisibility(override, profileVisibility)`:
`RESOLVED = COALESCE(visibility_override, profiles.profile_visibility)`.

| override | profile_visibility | resolved | readable by |
|---|---|---|---|
| 'public' | any | public | owner + all authenticated |
| 'friends' | any | friends | owner + followers of the author |
| 'private' | any | private | owner only |
| NULL | 'public' | public | owner + all authenticated |
| NULL | 'friends' | friends | owner + followers of the author |
| NULL | 'private' | private | owner only |

"Friends" = viewer FOLLOWS author (one-way `friend_follows`, same relation
as the C1 feed). Anon reads nothing. Fail-closed edges: invalid override →
'private' (TS) / matches-no-branch (SQL); unknown profile visibility →
'friends' in TS, never 'public'. INSERT/UPDATE/DELETE stay owner-only.
Row filtering is server-enforced; clients never re-implement it for reads —
they simply see the rows RLS admits.

### personal_takeaway — owner-only (split enforcement)

- [server] excluded from the `search_vector` weights and from the search
  RPC's return table — no search can match or return it.
- [client] every cross-user read selects
  `JOURNAL_ENTRY_SHARED_COLUMN_LIST` (23 columns — exactly the search RPC's
  return set; asserted equal by test) instead of `*`. Owner-scoped reads
  (`getJournalEntry`) keep `select('*')`.
- **Residual (ledger open item):** RLS is row-level, so a hand-rolled API
  select can still read `personal_takeaway` on rows already visible to the
  caller. The real fix is a split-table redesign; until then the UI's
  "(private)" label is an unmet promise. iOS MUST NOT select or render
  another user's `personal_takeaway` regardless.

### Search RPC [server]

`search_journal_entries(search_query text, target_user_id uuid)` —
`SECURITY INVOKER`, `LANGUAGE sql STABLE`, `search_path` pinned. Returns a
23-column TABLE (all contract columns EXCEPT `personal_takeaway` and
`search_vector`). `target_user_id` is a narrowing FILTER, never a trust
boundary: the caller's RLS decides which rows come back (by construction —
the body is a plain select under invoker rights). `plainto_tsquery('english')`,
`ts_rank` desc, LIMIT 50. Wire shape helper: `buildSearchRpcArgs`.

### Likes — `journal_entry_likes` + trigger-maintained count

- Table: `journal_entry_likes(entry_id, user_id, created_at)`,
  PK `(entry_id, user_id)`. [server] RLS: INSERT own row AND the entry is
  visible to the liker; DELETE own row unconditional (a like can always be
  withdrawn); SELECT gated on entry visibility (no liker enumeration on
  invisible entries).
- [server] `journal_entries.like_count` is maintained ONLY by the
  lock-then-recount trigger on likes INSERT/DELETE (`SECURITY DEFINER`,
  EXECUTE revoked; manipulation- and race-proof). The old
  `increment_journal_likes` / `decrement_journal_likes` RPCs are DROPPED —
  never call them, never write `like_count` from a client.
- [client] toggle = INSERT `{entry_id, user_id}` with
  `ON CONFLICT DO NOTHING` (idempotent) / DELETE own row
  (`buildLikeInsertPayload`, `toggleJournalLike`). Read `like_count` from the
  entry row; optimistic UI via the pure `applyLikeToggle` (clamps at 0).
- [client] initial liked-state must be loaded (`getLikedEntryIds(viewerId,
  entryIds)` batch read) — cards defaulting to "not liked" caused the
  historical double-increment drift. Web currently calls it per-card
  (known N+1, ledger open item); iOS should batch at list level from day one.
- Side effect: any like/unlike bumps the entry's `updated_at` via the
  pre-existing BEFORE UPDATE trigger — do NOT treat `updated_at` as
  "content edited" (web renders `created_at` only).

### Photos — private bucket + signed URLs

- [client] `photo_paths` stores storage object PATHS
  (`{userId}/{entryId}/{index}.{ext}`, bucket `journal-photos`,
  max `JOURNAL_MAX_PHOTOS` = 6) — never URLs, public or signed.
- [server] the bucket is PRIVATE (20260708_journal_photos_private.sql);
  storage policies are owner-only on the `{userId}/` prefix for
  SELECT/INSERT/UPDATE/DELETE.
- [client] rendering mints signed URLs fresh on every render/mount —
  `createSignedUrl(s)` with `JOURNAL_PHOTO_SIGNED_URL_TTL_SECONDS` =
  2,592,000 (30 days) — and NEVER persists them, so expiry cannot strand a
  stored link. Legacy defense: `extractJournalPhotoPath` converts any
  full-URL value found in `photo_paths` back to a path before signing
  (unsignable input → placeholder, never a broken public link).
- **Cross-user photo rendering does not exist on web** (cards show a camera
  indicator only; the composer grid is owner-only), so owner-only SELECT
  fails closed. If iOS ships cross-user photo rendering, the storage SELECT
  policy MUST first be extended with the resolved-visibility EXISTS
  documented in `20260708_journal_photos_private.sql` §4 — without it,
  viewers cannot mint signed URLs for other users' photos. Do not ship the
  iOS surface before that policy extension is applied.

### Local dates + streaks [client]

- Any written calendar day (`watched_date` default, composer date pre-fill)
  uses `localDateString(new Date())` from `services/stubService.ts` — local
  date components, no UTC methods, `yyyy-MM-dd`. An explicitly provided
  `watchedDate` passes through verbatim.
- Streaks: pure `computeStreaks(watchedDates, todayLocal)` — deliberately
  Swift-transliterable; port the helper, not the old inline block. Semantics:
  dedupe + drop nulls + sort (ISO strings sort chronologically); day ordinal
  = `Date.UTC(y, m-1, d) / 86_400_000` (pure integer calendar arithmetic —
  no wall-clock instant is converted, so this does not violate the no-UTC
  rule); consecutive = ordinal difference exactly 1 (month/year/leap safe);
  `longestStreak` = longest consecutive run; the trailing run is
  `currentStreak` iff `ordinal(todayLocal) − ordinal(lastDate) ≤ 1` —
  negative differences included, so legacy future-dated rows (old UTC
  "tomorrow" stamps) never zero an active streak. `todayLocal` must come
  from `localDateString(new Date())`.

Tests: `services/__tests__/journalService.test.ts` (visibility truth table,
event gate, column lists, edit seam), `journalLikes.test.ts` (toggle/payload),
`journalPhotos.test.ts` (path extraction/signing), `journalDates.test.ts`
(streak truth table + named-timezone fixtures).
