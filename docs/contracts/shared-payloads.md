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
