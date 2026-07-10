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
  `watched_platform`: id from `PLATFORM_OPTIONS` (13 ids — see the iOS-build
  correction below; the earlier "14" miscounted a type-annotation line).
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
the body is a plain select under invoker rights). Since 2026-07-09 the WHERE
is tsvector-match OR trigram-backed ILIKE substring over `title` and
`review_text` ONLY — CJK characters and partial-word queries now match;
`personal_takeaway` remains unmatchable and unreturned. Ranking = `ts_rank`
desc then trigram `similarity()` desc. Wire contract unchanged: same
signature, same 23 returned columns, same LIMIT 50. Note: user-supplied
`%` and `_` characters act as ILIKE wildcards and over-match, but results
remain bounded by user scoping, RLS, and LIMIT 50. Wire shape helper:
`buildSearchRpcArgs`.

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

### iOS implementations (since C2-iOS, branch `feat/ios-parity-c2-journal`)

The full MANUAL journal (no AI agent — deferred, see below). Pure/tested
contract + models under thin SwiftUI, mirroring the feed cycle:

- `JournalEntryContract` (`ios/Spool/Sources/Spool/Services/JournalEntryContract.swift`)
  — the pure marshalling/policy seam: `resolveVisibility` (COALESCE + fail-closed
  edges), `upsertPayload` (the full-replace 20-column build), `draft(from:)`,
  `pickEntryForEdit`, `shouldEmitReviewEvent`. Models + tag constants in
  `JournalModels.swift` / `JournalConstants.swift`.
- `JournalRepository` (actor, `JournalRepository.swift`) — CRUD, search RPC,
  likes, `user_rankings.tier` lookup; `PhotoStore` (actor, `PhotoStore.swift`)
  — PHPicker-byte upload + 30-day signed URLs; `JournalDraftModel` /
  `JournalListModel` (@MainActor ObservableObjects) drive the `JournalComposer`
  (15 editable fields), the journal tab in `StubsScreen`, and the entry card.
  Emitters (`JournalEmitters.swift`) bind the review activity event + the
  `journal_tag` notification to real inserts, gated by the model's fail-closed
  public-only review gate (mirrors the web B6 fix).
- **Probe-before-edit rule mirrored:** iOS mirrors `pickEntryForEdit(probed,
  passed)` — the freshly-probed owner row (`getOwnEntry`, `select('*')`) always
  wins over a takeaway-less list/search row, so a save can never null
  `personal_takeaway`.
- **Owner-only this cycle:** iOS renders ONLY the owner's own journal (inside the
  owner's Stubs tab). There is NO cross-user journal/photo surface — that would
  need the storage-policy extension (the `20260708_journal_photos_private.sql`
  §4 resolved-visibility EXISTS) applied FIRST. Not built; ledgered.
- **iOS resolves an invalid stored `visibility_override` to `private`** via the
  raw-string overload `resolveVisibility(rawOverride:profileVisibility:)` — a
  non-empty override matching no valid enum case fails closed to `.priv` (web
  parity; the SQL policy grants nothing for such a value). The typed
  composer-picker overload maps a garbage stored value to nil (Default) for the
  picker only — the two concerns are deliberately separate.

**Two contract-text corrections found during the iOS build (both applied here):**

- `PLATFORM_OPTIONS` is **13 ids, not 14.** The "14" miscounted the source
  array's `{ id: string; ... }` type-annotation line as an option. The 13 ids:
  `theater, netflix, apple_tv, max, hulu, prime, disney, peacock, paramount,
  mubi, criterion, physical, other`. (Corrected in the Column semantics list
  above.)
- The plan's "25-column `JournalRow`" note is wrong: the owner-row DTO decodes
  **23 fields** — it omits `search_vector` and `updated_at`, both intentional
  (a generated column and a trigger-owned column that no client renders; likes
  bump `updated_at` and cards render `created_at`).

Tests (iOS): `JournalContractTests`, `JournalRepositoryLogicTests`,
`PhotoStoreLogicTests`, `JournalDraftModelTests`, `JournalListModelTests`,
`JournalEmittersTests` under `ios/Spool/Tests/SpoolTests/`.

## user_rankings ordering (since C4 blocking fixes, branch `fix/c4-ranking-blocking`)

### Position-integrity invariant

Within each `(user_id, tier)` and per media table (`user_rankings` / `tv_rankings` / `book_rankings`), `rank_position` is contiguous `0..n-1` with no duplicates (0 = best). Nothing in the DB enforces this — the only constraint is `UNIQUE(user_id, tmdb_id)`. Every management write must preserve it. Consumers that break visibly when it is violated: `get_feed_ranking_scores` does arithmetic on the raw column (`score = lo + (hi-lo)·(tier_total-1-rank_position)/(tier_total-1)`) — a gap puts the max position above `tier_total-1`, producing a negative numerator and a score below the tier floor; a duplicate gives two items identical scores. iOS `getAllRankedItems`/`getTierItems` order by `rank_position` — duplicates make order nondeterministic in the H2H engine.

### `set_tier_order` RPC contract

`set_tier_order(p_media text, p_tier text, p_tmdb_ids text[]) returns integer`

Migration: `supabase/migrations/20260709_set_tier_order_rpc.sql`.

- **SECURITY INVOKER.** Runs as the caller; the own-rows UPDATE RLS policies on all three tables gate writes to `auth.uid()`'s rows. No elevated privilege.
- **`p_media`** ∈ `('movie', 'tv', 'book')` — routes to `user_rankings`, `tv_rankings`, `book_rankings` respectively via three static branches (no dynamic SQL). Any other value RAISEs with errcode 22023.
- **UPDATE-only — resurrect-proof.** The function performs a single UPDATE per branch and is structurally incapable of INSERT. It can only move rows that already exist. A row must therefore be upserted by the caller BEFORE calling this RPC — the upsert creates the row; the RPC compacts the tier. A deleted id matches nothing and is silently skipped. This fixes the B6 resurrection race: the old full-row upsert shape could re-INSERT a row another device had just deleted.
- **Delete-aware compaction.** Positions are assigned by `row_number() OVER (ORDER BY ordinality) - 1` over only the ids in the array that actually exist as the caller's rows. Ids in the array with no matching row (deleted or never-ranked) are silently skipped, so surviving rows compact to a contiguous `0..k-1`. A caller can pass a stale membership snapshot that names a since-deleted id and the result is still gap-free.
- **Dedup: first occurrence wins.** If `p_tmdb_ids` lists the same id more than once (e.g., an iOS re-rank splices an id into a membership array that already contains it), the id is ranked at its FIRST occurrence and later occurrences are ignored: `['a','a','b']` behaves as `['a','b']` (a → 0, b → 1, returns 2).
- **Returns** the number of rows actually updated (missing ids not counted). Empty or NULL array is a no-op returning 0.

**FULL-MEMBERSHIP CALLER RULE (CRITICAL — partial arrays corrupt):** `p_tmdb_ids` MUST be the tier's ENTIRE intended membership, in the desired order. Rows of the same `(user_id, tier)` that are NOT in the array are left UNTOUCHED at their old positions. So a partial array does NOT "update just a few" — it orphans the unlisted rows' positions, recreating the very gap/dup corruption this RPC exists to prevent. Callers moving an item between tiers must call TWICE: once for the source tier (its full membership minus the departed id) and once for the target tier (its full membership plus the arriving id). Callers removing an item must call once for the item's tier (its full membership minus the removed id).

### Title-locale pin

The persisted `title` in `user_rankings`, `activity_events.media_title`, and `movie_stubs.title` is the TMDB **default-locale** title — never a localized (e.g., zh-CN) one. Web's `useLocalizedItems` replaces `title` with zh-CN strings for display only; the management handlers that write to persistence must look up the raw item by id before persisting.

iOS follows device locale for TMDB fetches (`TMDBService.locale()` → zh-CN for Chinese devices, en-US otherwise), matching web's `getTmdbLocale` surfaces. However, when a user ranks an item via the ceremony (or from a Discover suggestion), `RankingRepository.insertRanking` uses the title that came back from the `suggestions` edge function. The `suggestions` function receives the caller's `locale` param and fetches from TMDB with the corresponding language. The locale-fetched title is persisted on BOTH platforms at that same seam — exact web parity (web's `onRerank` handler looks up the raw item from the unlocalized `items` array, so re-ranks are pinned; the Discover-rank path carries the suggestion's title directly). The strict default-locale pin applies to the re-rank/raw-item paths (where the unlocalized item is always available) and to the raw DB read paths. A zh-CN `suggestions` response for a fresh rank will persist a zh-CN title; this is the same behavior as web's Discover rank path and is accepted.

### Deliberate orphan semantics on delete

When a ranking row is deleted, ONLY the ranking row is removed plus tier compaction (via `set_tier_order`) plus a `ranking_remove` activity event (`{notes?, year?}` metadata). The following artifacts survive by design and are not touched:

| Artifact | Fate |
|---|---|
| `movie_stubs` row | kept; a later re-rank refreshes it via the 23505 update path |
| `journal_entries` row | kept; the journal is a diary, independent of the shelf |
| `activity_events` history | kept forever (append-only; no UPDATE/DELETE policy) |
| `comparison_logs` | kept |
| watchlist | NOT restored; delete ≠ un-rank back to bookmark |

These semantics are deliberate and documented — do not add cleanup without an explicit product decision.

### Re-rank emits `ranking_move`, never `ranking_remove` + `ranking_add`

A web re-rank through the ceremony flow on ANY of the three media verticals (movie, TV, book) MUST emit a single `ranking_move` event with metadata `{notes?, year?}` (never `watched_with_user_ids` — the move sites do not pass it; consistent with the existing `ranking_move` sites in the `activity_events` table above). It must never emit `ranking_remove` followed by `ranking_add` — that double-emission miscounts milestones, misrepresents the feed, and was the pre-C4/C5 bug (movie B3; TV/book B2).

A same-tier reorder with no actual position change must emit NO event (B1 no-op suppression).

The iOS MOVIE ceremony satisfies the MUST too (tv/book ceremonies do not exist on iOS yet — C5 iOS plan): `RankingRepository.insertRanking`
pre-reads the existing `(user_id, tmdb_id)` row; when one exists it emits a
single `ranking_move` (`{notes?, year?}`, watched-with stripped) and, on a
cross-tier re-rank, compacts the source tier (full membership minus the id) as
well as the target — no gap left. A genuine fresh insert still emits
`ranking_add`. The pure fresh-vs-re-rank decision is `CeremonyEmission.decide`
(pinned by `TierSpliceTests`).

**Event + stub gating (all three verticals):** ceremony completion MUST emit events and write stubs ONLY after a confirmed save success. A failed upsert returns false; the caller must early-return before `logRankingActivityEvent` and stub writes (movie parity landed in C4-B4; TV/book parity landed in C5-B4). iOS already enforces this via the `insertRanking` throw boundary (`RankPersistence.swift:97-110`).

**Known deviations (ledgered):** One live path does not yet satisfy the re-rank MUST above; it is deliberately deferred and tracked in
`docs/plans/2026-07-07-ios-parity-ledger.md`:

1. **Web movie drag-migration** still emits `ranking_add` (the drag path was not touched in C4-B3; Q2 standardization deferred).

~~**Web TV/book re-rank**~~ — FIXED in C5 (B2): TV/book re-rank is now non-destructive (rerankState marker, upsert-on-unique-key, `set_tier_order` both tiers, single `ranking_move`). Item 2 from the C4 known-deviations list is retired.

~~**iOS ceremony re-rank**~~ — FIXED (C4 iOS management-UI sub-plan, Task 2): `insertRanking` now compacts the source tier and emits `ranking_move`; see the paragraph above.

## watchlist_items (+ tv/book variants) (since C3 web fixes, branch `fix/c3-watchlist-discover-web-blocking`)

Three parallel bookmark tables — one per media vertical. Reference
implementation: `pages/RankingAppPage.tsx` (CRUD + rank-from-watchlist),
`services/watchlistRankHelpers.ts` (pure seams), `services/letterboxdImportService.ts`
(import write paths). SQL: `supabase/migrations/supabase_schema.sql:37-49,146-148`
(movie) + `20260708_c3_watchlist_update_policy.sql`; `supabase_tv_rankings.sql:65-112`
(tv); `supabase_book_rankings.sql:67-116` (book). Enforcement labels:
**[server]** = RLS enforces it, clients cannot break it; **[client]** = each
client MUST implement it — the DB will not stop a wrong write/read.

### Row shapes (verified against DDL)

All three key on `UNIQUE(user_id, tmdb_id)`. `added_at` is
`timestamptz NOT NULL DEFAULT now()` and is NEVER sent by the client (DB default
owns it). `genres` is `text[] NOT NULL DEFAULT '{}'`. `id` uuid PK is DB-default.

| | `watchlist_items` | `tv_watchlist_items` | `book_watchlist_items` |
|---|---|---|---|
| id-format of `tmdb_id` | `tmdb_{n}` (movies) | `tv_{showId}_s{n}` (season) or `tv_{showId}` (whole-show bookmark) | `ol_{workKey}` (e.g. `ol_OL27448W`) |
| `type` default | `'movie'` | `'tv_season'` | `'book'` |
| shared media cols | `title` (NOT NULL), `year`, `poster_url` (FULL URL, not a bare path), `genres` | same | same |
| vertical cols | `director` | `show_tmdb_id integer NOT NULL`, `season_number integer` (NULL-able), `season_title`, `creator` | `author`, `page_count`, `isbn`, `ol_work_key`, `ol_ratings_average real` |

`poster_url` carries the full `w500` image URL (same convention as
`movie_stubs.poster_path`), NOT a bare TMDB path.

### id-format canon [client] (post-B1)

The canonical movie id is `tmdb_{n}` everywhere (`tmdbService.mapTmdbResult`,
`DiscoverView.normalizeTmdbId`). B1's fix normalizes at WRITE TIME ONLY: the
Letterboxd import used to write bare `String(entry.tmdbId)` into `user_rankings`,
`watchlist_items`, and `journal_entries` — all four import write/exclusion sites
now route through the pure `canonicalMovieTmdbId(rawId)`
(`services/watchlistRankHelpers.ts`), idempotent (`tmdb_603`→`tmdb_603`,
`603`→`tmdb_603`, `"603"`→`tmdb_603`). iOS MUST apply the same normalizer at every
movie-id write site so a bare id can never land and corrupt engine exclusion, the
taste regex `/tmdb_(\d+)/`, or cross-user string comparison. **No backfill was
run — prod verified 0 bare-format rows** (B1 is purely preventive). Books are
`ol_{key}`; TV rankings are `tv_{showId}_s{n}` (seasons) but the engine
recommends whole SHOWS (`tv_{showId}`) — callers pre-expand season ids to show
ids for exclusion.

### TV whole-show bookmarks: `season_number` is 0-or-NULL [client] (D6)

The schema comments `season_number integer` as "NULL = whole show bookmark"
(`supabase_tv_rankings.sql:70`), but web actually WRITES `0`:
`addToTVWatchlist` stores `season_number: item.seasonNumber ?? 0`
(`RankingAppPage.tsx:679`; same `?? 0` for `show_tmdb_id`). All readers treat 0
as falsy, so 0 and NULL are interchangeable "whole show" markers. iOS must
replicate "**0 OR NULL = whole show**" on read and may write either (web writes 0;
NULL is equally valid). A whole-show bookmark carries a real `show_tmdb_id` and a
season-less `tmdb_id` (`tv_{showId}`).

### Never trust `show_tmdb_id = 0` rows [client] (B2)

Before B2's fix, `handleSearchSaveTV` minted TV bookmarks WITHOUT `showTmdbId`, so
`addToTVWatchlist`'s `?? 0` stored `show_tmdb_id = 0`; ranking that row later
mis-routed into the direct-to-tier branch and persisted a season-LESS
`tv_rankings` row (`tv_{showId}`, `show_tmdb_id = 0`, `season_number = 0`),
violating the season-id contract every downstream consumer assumes. B2 fixes the
write (`tvWatchlistItemFromShow` sets `showTmdbId: show.tmdbId` + normalized
genres) and the correct show-level routing keys on a truthy `showTmdbId`. **Prod
verified clean (0 season-less rows), so B2 is preventive — no backfill.** iOS MUST
treat any `show_tmdb_id = 0` TV row as corrupt: never rank it directly; route it
through season selection (or ignore it).

### Rank-from-watchlist: delete the bookmark ONLY on confirmed save [client] (B5, CORRECTED)

The shipped web behavior was a data-loss bug: the ranking-save error was
swallowed inside `addItem`/`addTVItem`/`addBookItem` (void return + toast), then
the handler UNCONDITIONALLY deleted the watchlist row — a transient save failure
destroyed the bookmark (item in neither list). The corrected contract, now the
canon:

1. `addItem`/`addTVItem`/`addBookItem` RETURN a success boolean (true on resolved
   upsert, false on the caught error — keep the toast).
2. The handler deletes the bookmark only when
   `shouldRemoveBookmarkAfterRank(saveSucceeded)` is true
   (`services/watchlistRankHelpers.ts` — returns the flag verbatim; pinned by a
   vitest), and only AFTER `onAdd` resolves (existing ordering).
3. **Stale-origin guard [client]:** the rank-from-watchlist entry point must
   capture the originating watchlist item's `tmdb_id` before the ceremony opens.
   If the ceremony completes with a different movie id (user changed the selection
   mid-ceremony), do NOT delete the watchlist bookmark — the completed save does
   not correspond to this watchlist item.
4. **Id-match guard [client]:** when the delete executes, compare the saved
   item's canonical id against the captured watchlist `tmdb_id`; if they do not
   match (stale origin slipped through), skip the delete and log loudly. A failed
   delete is fire-and-forget (the item reappears on next load — self-healing);
   never gate the rank-success UX on the bookmark delete.

**iOS C3 MUST copy this CORRECTED semantics, NOT the shipped web behavior** —
delete the watchlist row only on confirmed rank save with a matching id. Same rule
for all three verticals. Whole-show TV bookmarks route through season selection
before the tier step; season bookmarks go straight to tier.

### RLS (post-Q2 migration)

| | `watchlist_items` | `tv_watchlist_items` | `book_watchlist_items` |
|---|---|---|---|
| SELECT | owner **+ followers** [server] | owner **+ followers** | owner + followers |
| INSERT | owner | owner | owner |
| UPDATE | owner (**added by B3a**) | owner | owner |
| DELETE | owner | owner | owner |

- **[server] B3a — UPDATE policy added.** `watchlist_items` previously had only
  SELECT/INSERT/DELETE (`supabase_schema.sql:146-148`); `addToWatchlist` writes a
  merge-duplicates UPSERT on `(user_id, tmdb_id)`, so whenever the client-side
  pre-check is stale (second device/tab, or dual-format B1 rows) the
  `ON CONFLICT DO UPDATE` path was RLS-denied → save failed with revert+toast.
  `20260708_c3_watchlist_update_policy.sql` adds the owner policy
  `USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id)`, mirroring the
  tv/book tables. iOS upsert-on-conflict works once this migration is live.
- **[server] Q2 adjudication (owner, 2026-07-09) — movie watchlist is now
  FOLLOWER-VISIBLE.** `20260709_c3_movie_watchlist_follower_select.sql` drops the
  original owner-only combined SELECT and recreates the tv/book two-policy shape
  verbatim: an owner SELECT plus a follower SELECT keyed on `friend_follows`
  (`follower_id = auth.uid() AND following_id = watchlist_items.user_id`). Postgres
  OR-combines permissive SELECT policies, so owner rows AND followee rows are both
  visible — identical to `tv_watchlist_items` (`supabase_tv_rankings.sql:88-99`)
  and `book_watchlist_items` (`supabase_book_rankings.sql:92-103`). iOS
  `TasteRepository.getRecommendationsForFriend` can now read a friend's
  `watchlist_items` for Twin-exclusion (was silently returning 0 rows under the
  prior owner-only policy). Followers still cannot INSERT/UPDATE/DELETE another
  user's watchlist rows.

### Write / remove paths [client]

- **Add:** optimistic prepend, then UPSERT on `(user_id, tmdb_id)`
  (merge-duplicates); revert + toast on error. Guarded by a client-side
  `watchlist.some(w => w.id === item.id)` pre-check, so the conflict/UPDATE path
  normally never fires (which historically masked the missing B3a policy). Movie
  add always writes `type: 'movie'`; TV add writes
  `show_tmdb_id: item.showTmdbId ?? 0`, `season_number: item.seasonNumber ?? 0`.
- **Letterboxd import:** batch upsert with `ignoreDuplicates: true` (DO NOTHING —
  never needs the UPDATE policy), canonical `tmdb_` ids, pre-filtered against the
  existing watchlist and the import's own ranked set.
- **Remove:** optimistic DELETE by `(user_id, tmdb_id)`; errors are ignored (no
  revert on delete failure — the item silently reappears on the next full load).
- **Read:** one initial parallel load of all six tables scoped to the user,
  watchlists ordered `added_at desc`. No pagination, no refetch except a full page
  reload.

Tests: `services/__tests__/watchlistRankHelpers.test.ts`
(`shouldRemoveBookmarkAfterRank` truth, `canonicalMovieTmdbId` idempotency/prefix,
`tvWatchlistItemFromShow` shape); `services/__tests__/letterboxdImportIds.test.ts`
(import writes canonical ids at all sites).

## suggestions function (since C3 Part B, branch `feat/c3-part-b-suggestions`)

Server-side 5-pool suggestion engine (`supabase/functions/suggestions/index.ts`).
Reads the caller's rankings + watchlist under their forwarded JWT (RLS-scoped, no
service role), builds the taste profile + exclusions, runs the TMDB pools, and returns
provenance-tagged items. Pure engine logic lives in `supabase/functions/suggestions/engine.ts`
(import-clean; exercised by `services/__tests__/suggestionsEngine.test.ts`).

### Auth + method

Authenticated `POST` (`Authorization: Bearer <supabase-jwt>`). Missing/invalid token
→ 401. Per-user in-memory token bucket (~30 req/min per isolate) → 429 on excess.
Only `POST` accepted; other methods → 405.

### Request body (JSON)

```json
{
  "mediaType": "movie" | "tv",
  "mode": "suggestions" | "backfill" | "new_releases",
  "page": 1,
  "poolSlots": { "similar": 3, "taste": 4, "trending": 2, "variety": 2, "friend": 1 },
  "locale": "zh-CN",
  "sessionExcludeIds": ["tmdb_603", "tmdb_238"],
  "limit": 10
}
```

- `mediaType`: required. `new_releases` mode supports `"movie"` only (400 if `tv`).
- `mode`: required. `"suggestions"` = smart 5-pool (generic fallback when below threshold
  3); `"backfill"` = recommendations-of-top-ids, variety pad, cap 20; `"new_releases"` =
  now_playing + upcoming, taste-filtered, date-asc, movie only. `new_releases`
  exclusions are a SUPERSET of the old client behavior: server-side ranked +
  watchlisted + the caller's `sessionExcludeIds` all apply.
- `page`: positive integer, defaults to 1 if omitted.
- `poolSlots`: optional; any keys override `DEFAULT_POOL_SLOTS` (similar:3, taste:4,
  trending:2, variety:2, friend:1; Σ=12). Values must be non-negative numbers.
- `locale`: optional string; `zh*` prefix → TMDB language `zh-CN`, anything else →
  `en-US`. Mirrors `getTmdbLocale` / `TMDBService.locale()` on both clients.
- `sessionExcludeIds`: optional array of strings; items to suppress this session (already
  seen in the UI). **Cap: 200 ids. Sending more than 200 → 400.** Server slices to 200
  as a defense-in-depth measure; callers must not rely on that silent slice.
- `limit`: positive integer, optional; effective only for `new_releases` (capped at 10).

### Response — 200 OK

```json
{
  "items": [
    {
      "id": "tmdb_603",
      "tmdbId": 603,
      "title": "The Matrix",
      "year": "1999",
      "posterUrl": "https://image.tmdb.org/t/p/w500/...",
      "backdropUrl": null,
      "mediaType": "movie",
      "genres": ["Action", "Sci-Fi"],
      "overview": "...",
      "voteAverage": 8.2,
      "seasonCount": 0,
      "pool": "similar"
    }
  ],
  "totalRanked": 47
}
```

`pool` ∈ `"similar" | "taste" | "trending" | "variety" | "friend" | "generic" | "backfill" | "new_release"` —
provenance tag for the chip label on Discover cards. `totalRanked` is the caller's
ranked-item count (informs the below-threshold/generic fallback branch).

**`items` may be empty** (empty array, 200 status) when TMDB fetch calls inside the
engine all return null. The most common cause on a fresh deploy is a missing or invalid
`TMDB_API_KEY` secret — an empty 200 is the signal to check the secret, not a protocol
error. Clients show an empty state rather than an error.

**Deferred wire fields (not yet in the response):**
- `releaseDate` (ISO string) — present internally on `new_release` items for date-asc
  sort but stripped by `toResponseItem` before transmission. When this field is wired,
  web/iOS New Releases rows can show the actual release date rather than year-only.
- `seedTitle` (string) — optional; the title of the S/A-tier movie the `similar` pool
  used as its TMDB seed. Useful for the "Because you ranked X" provenance chip. Not yet
  populated by the engine.

### Error codes

| Status | Meaning |
|---|---|
| 400 | Validation failure — missing/wrong field, `sessionExcludeIds` > 200, `new_releases` with `tv` |
| 401 | Missing or invalid `Authorization` header / expired token |
| 405 | Method not `POST` |
| 429 | Per-user rate limit exceeded (~30 req/min per isolate) |
| 502 | DB read failure (`user_rankings` / `watchlist_items` query errored) or upstream TMDB network error |
| 500 | Unexpected server error (e.g. missing `SUPABASE_URL` env var) |

**DB read failure = 502:** if `loadMovieData` / `loadTVData` throws (Supabase query
returns `.error`), the function catches and returns `{ error: "upstream error" }` with
status 502. Clients treat 502 as a transient failure and show an empty/error state.

### Harmless engine divergence

`loadMovieData` coerces bare numeric `tmdb_id` values from the DB (e.g. `603`) into
`tmdb_603` form for the taste profile (`id: \`tmdb_${String(r.tmdb_id).replace(/^tmdb_/, '')}\``),
rather than dropping them. This differs from the client-side `buildTasteProfile` which
only sees items already normalized to `tmdb_` form. Effect: a bare-id row that would
have been silently excluded from `topMovieIds` on the client now correctly seeds the
similar/backfill pools server-side. Since prod has 0 bare-format rows (B1 preventive),
the divergence is harmless in practice.

### CORS

Both functions ship `Access-Control-Allow-Origin: *`. A future tightening to the
deployed Vercel origin is a security audit action item (audit §2.4 — deferred; CORS
origin-tightening tension noted in the parity ledger).

Implementations: `supabase/functions/suggestions/index.ts` (HTTP shell),
`supabase/functions/suggestions/engine.ts` (pure engine).
Tests: `services/__tests__/suggestionsEngine.test.ts`.
iOS client: `ios/Spool/Sources/Spool/Services/SuggestionsClient.swift`.
Web client: `invokeSuggestions` + wrappers in `services/tmdbService.ts`.

## tmdb-proxy (since C3 Part B, branch `feat/c3-part-b-suggestions`)

Authenticated, allowlisted TMDB passthrough (`supabase/functions/tmdb-proxy/index.ts`).
With the `suggestions` function this retires the TMDB key from BOTH app bundles — the
key lives only in the function's secret store as `TMDB_API_KEY` and is injected
server-side. **DoD met: `VITE_TMDB_API_KEY` removed from the web bundle; iOS
`Info.plist` `TMDB_API_KEY` entry retired.** Both clients' TMDB fetch layers route through
this proxy.

### Auth + method

Authenticated `GET` (`Authorization: Bearer <supabase-jwt>`). Missing/invalid token →
401. Same per-user in-memory token bucket as `suggestions` (~30 req/min per isolate) →
429. Only `GET` accepted; other methods → 405.

### Path allowlist

The `?path=<tmdb path>` parameter is validated against a HARD allowlist (deny-by-default,
fully anchored regex). Non-matching paths, traversal (`..`), encoded slashes/dots (`%`),
backslashes, absolute/protocol-relative URLs → 403 (generic message, attempted path never
echoed). The pure logic lives in `supabase/functions/tmdb-proxy/rules.ts` (exercised by
`services/__tests__/tmdbProxyRules.test.ts`).

**Allowed paths (exact allowlist — `\d+` = numeric id):**

```
search/movie
search/tv
search/person
movie/{id}
movie/{id}/similar
movie/{id}/recommendations
movie/now_playing
movie/upcoming
tv/{id}
tv/{id}/season/{id}
person/{id}
person/{id}/movie_credits
trending/(movie|tv)/(day|week)
discover/movie
discover/tv
```

A single leading `/` is stripped before matching; everything else — extra slashes,
encoded bytes, dots, query/fragment characters, whitespace — falls through to the deny
path.

### Query param safelist

All query params are stripped to an explicit allowlist before forwarding. `api_key` is
**always stripped from the client request** and injected by the function from the secret
store. Unknown keys are silently dropped.

**Forwarded params:**
`query`, `page`, `language`, `include_adult`, `year`, `primary_release_year`,
`with_genres`, `sort_by`, `vote_count.gte`, `vote_average.gte`,
`primary_release_date.gte`, `primary_release_date.lte`,
`first_air_date.gte`, `first_air_date.lte`, `region`, `append_to_response`.

`append_to_response` is further constrained: the comma-separated value is only forwarded
if every element is in `{ "watch/providers", "credits" }` — any other sub-response drops
the whole param.

### Upstream behavior

5 s timeout; upstream non-2xx → 502 generic (TMDB response body never echoed, prevents
key-path / account leakage); 2xx JSON passed through with the same status code. CORS
mirrors `suggestions` (`Access-Control-Allow-Origin: *`; same tightening caveat).

Implementations: `supabase/functions/tmdb-proxy/index.ts` (HTTP shell),
`supabase/functions/tmdb-proxy/rules.ts` (pure allowlist + sanitize).
Tests: `services/__tests__/tmdbProxyRules.test.ts`.
