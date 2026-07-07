# C2 Web Audit — journal + AI agent (reference semantics for iOS journal port)

**Cycle:** C2 (journal + AI agent)
**Audited at commit:** `e57850c` on `fix/c1-feed-web-blocking` (journal files match main)
**Scope:** `services/journalService.ts`, `services/agentService.ts`, `services/correctionService.ts`, `services/consentService.ts`, `services/reviewService.ts` (journal reads), `services/letterboxdImportService.ts` (journal batch write), `supabase/functions/journal-agent/index.ts`, `components/journal/*`, `components/shared/NotesStep.tsx`, `components/media/RankingFlowModal.tsx`, `pages/RankingAppPage.tsx`, `pages/ProfilePage.tsx`, `supabase/migrations/supabase_journal_entries.sql`, `supabase_emotional_data.sql`, `supabase_fix_critical_rls.sql`, `supabase_watched_with.sql`. Audit only — no code changed.

---

## 1. Reference semantics

### 1.1 `journal_entries` row contract (the shape both clients must write)

Table (`supabase_journal_entries.sql:13-45`). One entry per `(user_id, tmdb_id)` — `UNIQUE(user_id, tmdb_id)` (`:44`), so journal is **per-movie, not per-watch**; rewatches are a boolean + note on the same row, not new rows.

| column | type / default | write semantics (web) |
|---|---|---|
| `id` | uuid PK gen_random_uuid() | server-generated |
| `user_id` | uuid NOT NULL → profiles | owner |
| `tmdb_id` | text NOT NULL | raw ranked-item id (numeric string for movies; the same id space as `user_rankings.tmdb_id`) |
| `title` | text NOT NULL | denormalized from the ranked item at save time |
| `poster_url` | text NULL | denormalized full URL |
| `rating_tier` | text CHECK S/A/B/C/D | **never taken from the form** — looked up from `user_rankings.tier` for `(user_id, tmdb_id)` at every upsert (`journalService.ts:96-104`); null if the movie isn't ranked. Stale if the ranking moves later (no sync-back) |
| `review_text` | text NULL | empty string coerced to null (`:114`, form sends `reviewText \|\| undefined`) |
| `contains_spoilers` | boolean NOT NULL default false | checkbox |
| `mood_tags` | text[] default `{}` | ids from `constants.ts:192` `MOOD_TAGS` (23 ids, 4 categories). Not DB-validated; edge function filters generated tags to this list (`journal-agent/index.ts:463-468`) |
| `vibe_tags` | text[] default `{}` | ids from `constants.ts:222` `VIBE_TAGS` (11 ids). Never AI-generated |
| `favorite_moments` | text[] default `{}` | free text, max 5 (`JOURNAL_MAX_MOMENTS`, `constants.ts:271`); blanks filtered client-side before save |
| `standout_performances` | jsonb default `[]` | array of `{personId: number, name: string, character?: string}` (`types.ts:388-392`), picked from TMDB credits via `CastSelector` |
| `watched_date` | date default CURRENT_DATE | **UTC-derived client default** `new Date().toISOString().split('T')[0]` (`journalService.ts:120`, `JournalConversation.tsx:49`) — see finding B7 |
| `watched_location` | text NULL | free text |
| `watched_with_user_ids` | uuid[] default `{}` | friend profile ids from `FriendTagInput` (friendsOnly in JournalConversation, `:718`); triggers `journal_tag` notifications on save |
| `watched_platform` | text NULL | id from `PLATFORM_OPTIONS` (`constants.ts:236`) |
| `is_rewatch` | boolean NOT NULL default false | checkbox |
| `rewatch_note` | text NULL | saved even when `is_rewatch` is false if text remains in state |
| `personal_takeaway` | text NULL | UI labels it "(private)" (`JournalConversation.tsx:761`) but it is **not** column-protected — see finding B5 |
| `photo_paths` | text[] default `{}` | storage object paths `{userId}/{entryId}/{index}.{ext}` in bucket `journal-photos` (`JOURNAL_PHOTO_BUCKET`, `constants.ts:268`) |
| `visibility_override` | text CHECK public/friends/private, NULL allowed | NULL = "Default" in UI; NULL semantics are broken — see finding B2 |
| `like_count` | int NOT NULL default 0 | denormalized counter mutated only via RPCs — see finding B3 |
| `search_vector` | tsvector GENERATED (`:36-41`) | weights: title=A, review_text=B, favorite_moments=C, **personal_takeaway=D** |
| `created_at` / `updated_at` | timestamptz now() | `updated_at` bumped by trigger (`:157-168`) |

**Upsert = full replace.** `upsertJournalEntry` (`journalService.ts:91-174`) writes **every** column with `?? null`/`?? []` defaults, `onConflict: 'user_id,tmdb_id'`. There is no partial-update path: any caller that omits a field wipes it. Side effects on every successful upsert, in order: (1) `logReviewActivityEvent` when `reviewText && visibilityOverride !== 'private'` (`:141-154`) — appends a new `activity_events` `review` row each save (append-only, so each edit re-emits a feed card); (2) `journal_tag` notification insert per tagged friend, body = first 100 chars of review (`:157-171`), fired regardless of visibility.

**Delete** (`deleteJournalEntry`, `:204-231`): client-side best-effort — reads `photo_paths`, removes storage objects, then deletes the row scoped to `user_id`. No server-side storage cascade exists; if row delete fails after storage remove, or the client dies between steps, state diverges.

**Photos**: `uploadJournalPhoto` (`:378-399`) path `{userId}/{entryId}/{index}.{ext}`, `upsert: true`, cacheControl 3600, index = current `photoPaths.length` (collision-prone after removals — D6). Bucket is **public**, 5 MB limit, jpeg/png/webp (`supabase_journal_entries.sql:171-173`). `deleteJournalPhoto` (`:401-415`) checks `path.startsWith(userId/)` client-side; storage RLS insert/delete checks folder[1] = auth.uid() (`:179-183`); there is no storage UPDATE policy. Max 6 photos (`JOURNAL_MAX_PHOTOS`).

**Other writers**: Letterboxd import batch-upserts journal rows with `ignoreDuplicates: true` (`letterboxdImportService.ts:510-511`) — insert-only, never clobbers, all optional fields empty, `visibility_override: null`.

### 1.2 Visibility model + RLS (current effective policies)

The original `USING (true)` SELECT policy (`supabase_journal_entries.sql:85-86`) was replaced by `supabase_fix_critical_rls.sql:20-33`:

```
auth.uid() = user_id
OR visibility_override = 'public'
OR visibility_override IS NULL            -- ⚠ Default = world-readable (B2)
OR (visibility_override = 'friends' AND EXISTS (
     SELECT 1 FROM friend_follows
     WHERE follower_id = auth.uid() AND following_id = journal_entries.user_id))
```

- "friends" = **viewer follows author** (one-way follow, not mutual) — same relation as C1 feed.
- `profiles.profile_visibility` (default `'friends'`, per C1 B2 adjudication) is **never consulted** for journal entries. NULL override does not mean "inherit profile default"; it means public. That contradicts the C1-adjudicated model and the "Default" label.
- INSERT/UPDATE/DELETE: owner-only (`supabase_journal_entries.sql:88-95`).
- `journal_likes`: SELECT `USING (true)`, INSERT/DELETE own rows (`:98-105`). Anyone can enumerate who liked what, and can like entries they cannot read (id knowledge required).
- Row-level only: any row a viewer can SELECT exposes **all** columns (`select('*')` everywhere) — personal_takeaway, watched_location, watched_with, photo paths.

**Reader queries that traverse other users' entries** (all rely on RLS): `getReviewsForMovie` (`reviewService.ts:74-135`, all reviews for a tmdb_id, friends-first sort), `getReviewsByUser` (`:141+`), `listJournalEntries` on another profile's journal tab (`journalService.ts:235-284`, joined with profiles via `journal_entries_user_id_fkey`), `getJournalStats(profileId)` on ProfilePage (`ProfilePage.tsx:135` — stats silently computed only over RLS-visible rows for other users), `StubDetailModal` (own entries only, `:41-44` guards `isOwnProfile`). The one reader that does **not** go through RLS is the search RPC — finding B1.

### 1.3 RPC signatures

| RPC | signature | semantics | issue |
|---|---|---|---|
| `search_journal_entries` | `(search_query text, target_user_id uuid) RETURNS SETOF journal_entries` (`supabase_journal_entries.sql:127-138`) | `plainto_tsquery('english')` against `search_vector`, `WHERE user_id = target_user_id`, ts_rank desc, LIMIT 50 | **SECURITY DEFINER, no auth check** — B1 |
| `increment_journal_likes` | `(entry_id_param uuid) RETURNS void` (`:108-115`) | `like_count = like_count + 1` | **SECURITY DEFINER, no caller/like-row check** — B3 |
| `decrement_journal_likes` | `(entry_id_param uuid) RETURNS void` (`:117-124`) | `GREATEST(like_count - 1, 0)` | same — B3 |

**Like toggle** (`journalService.ts:419-446`): like = upsert into `journal_likes` on `(entry_id, user_id)` then call increment RPC; unlike = delete then decrement RPC. Non-atomic and non-idempotent: an upsert that hits an existing row still increments; a delete of a non-existent row still decrements. `JournalEntryCard` never loads the viewer's existing like state (`isLiked` prop defaults false, `JournalEntryCard.tsx:31`), so re-liking across sessions double-increments in normal use.

**Stats** (`getJournalStats`, `journalService.ts:306-374`): client-side over ALL of the user's entries (no pagination): totalEntries, entriesWithReview, mostCommonMood (mode of mood_tags), mostTaggedFriendId, streaks over unique `watched_date`s — consecutive-day streak, "current" if last date within 1 day of local today (timezone-mixed math, B7).

**List** (`listJournalEntries`, `:235-284`): `order('created_at', desc)`, `range(offset, offset+limit-1)` (offset pagination), filters: mood/vibe via `contains`, tier/platform via `eq`, dateFrom/dateTo via gte/lte on `watched_date`. Note the sort key (created_at) differs from the date filters (watched_date).

### 1.4 Agent protocol (what an iOS chat client must speak)

Split-brain design: **the edge function is a stateless LLM proxy; all persistence is client-side** against `agent_sessions` / `agent_messages` / `agent_generations` / `user_corrections` (all RLS owner-scoped, `supabase_emotional_data.sql`).

**Edge function** `POST {SUPABASE_URL}/functions/v1/journal-agent` (`supabase/functions/journal-agent/index.ts`):
- Auth: `Authorization: Bearer <supabase user JWT>` + `apikey`; verified via `auth.getUser()` (`:308-343`). 401 without it. No consent check, no session check, no rate limit server-side.
- Request body (`:55-63`, strictly validated `:115-213`):
  ```json
  { "messages": [{"role": "user|assistant|system", "content": "..."}],   // non-empty
    "context": {
      "movie":       {"title": str, "year": str, "genres": [str], "director?": str},
      "ranking":     {"tier": str, "rankPosition": number, "primaryGenre?": str},
      "userProfile": {"moodHistory": [str], "topGenres": {genre: number}, "recentJournalCount": number} },
    "action": "chat" | "generate_review" }
  ```
- Model: **Kimi `kimi-k2-0905-preview` via `api.moonshot.ai/v1/chat/completions`**, key `MOONSHOT_API_KEY` from function env (`:219-241`), temperature 0.7, 25 s abort. Server builds the system prompt (`:74-113`); client history is sent as-is after it.
- `chat` → 200 `{"reply": str, "usage": {prompt_tokens, completion_tokens}}` (`:406-418`).
- `generate_review` → 200 `{"generation": {"review_text": str, "mood_tags": [str] (filtered to the 23 allowed ids), "favorite_moments": [str], "personal_takeaway": str, "standout_performances": [str]}, "raw_output": str, "usage": {...}}` (`:470-489`). JSON parsed from raw output with 3 fallbacks (direct / ```json fence / first `{...}`) (`:260-289`); parse failure → 502 with `raw_output` echoed.
- Errors: 400 validation, 401 auth, 405 method, 502 upstream (`AI service error: ...`), 500 catch-all. CORS `*`.

**Client-side session lifecycle** (reference implementation `agentService.ts` + `JournalConversation.tsx`):
1. **Consent gate**: `ensureConsentRecord(userId)` (`consentService.ts:120-126`) — creates `user_data_consent` row if absent with DB defaults (`consent_product_improvement` **defaults TRUE**, `supabase_emotional_data.sql:23`) and stamps `consented_at = now()`. If `consentProductImprovement` is false → skip agent, go straight to manual form (`JournalConversation.tsx:150-155`). `createSession` re-checks via `hasConsent(userId,'product_improvement')` (`agentService.ts:135-136`).
2. **Create session**: insert `agent_sessions` `{user_id, movie_tmdb_id, ranking_id?, context_snapshot, prompt_version:'v1'}` (`agentService.ts:127-161`); DB defaults `model_version:'kimi-2.5'`, `completion_status:'in_progress'`, `input_modality:'text'`. Context snapshot = the same AgentContext built from: last 10 entries' deduped mood_tags, tier-weighted (S=5..D=1) genre counts from `user_rankings`, totalEntries (`JournalConversation.tsx:71-119`).
3. **Seed message**: client sends the synthetic opener `"I just ranked {title} ({year}) as {tier} Tier."` through the normal send path (`:181`).
4. **Send turn** (`sendAgentMessage`, `agentService.ts:346-422`): read session (RLS-guarded ownership check) → insert user message into `agent_messages` with `sequence_number = max+1` (read-then-write, `:211-226`), `content_source:'typed'` → build full history (role `agent`→`assistant`) → invoke edge `action:'chat'` → insert agent reply with measured `latency_ms`, `content_source:'generated'`. `agent_messages` is append-only (no UPDATE/DELETE policies); `UNIQUE(session_id, sequence_number)`; AFTER INSERT trigger bumps `agent_sessions.turn_count` (`supabase_emotional_data.sql:125-139`).
5. **Generate** (enabled after ≥2 user turns, `JournalConversation.tsx:557`): `requestReviewGeneration` (`agentService.ts:424-494`) invokes edge `action:'generate_review'` (the generate request itself is NOT appended to `agent_messages`) → `recordGeneration` inserts `agent_generations` (**`UNIQUE(session_id)`** — one generation per session, `supabase_emotional_data.sql:173`). Fields populate the draft form; generated standout performance strings get fabricated `personId: i` (D9).
6. **Corrections** on Save (`JournalConversation.tsx:361-371` → `correctionService.recordAllCorrections`): for each of the 5 generated fields (`reviewText`, `moodTags`, `favoriteMoments`, `personalTakeaway`, `standoutPerformances`; arrays JSON-stringified), insert a `user_corrections` row with `correction_type` in accept/add/remove/rewrite/edit (Levenshtein for text, set-diff for arrays; rewrite = distance > 80% of original length or zero set overlap — `correctionService.ts:89-136`), `edit_distance`, optional `time_spent_editing_ms`. Immutable (no UPDATE/DELETE policies), **recorded even for accepts**, no uniqueness on `(generation_id, field_name)`.
7. **End session**: `endSession(sessionId, 'completed')` after successful save, `'abandoned'` on dismiss (`JournalConversation.tsx:264-273, 396-398`). Status enum: `in_progress|completed|abandoned|error`.

Fallbacks: consent-off, session-create failure, or edge errors all route to the manual draft form ("Skip to form" always available). Existing entry (prop or DB probe on open, `:213-229`) skips chat entirely and opens the draft pre-populated.

### 1.5 Ceremony quick-entry path (C2 stage a baseline)

- `RankingFlowModal` steps tier → notes → compare (`RankingFlowModal.tsx:22`). `NotesStep` collects a **free-text one-liner ≤280 chars** ("Your thoughts") + optional watched-with friends (`NotesStep.tsx:7,62-99`). Skippable.
- On finish, the one-liner lands in **`user_rankings.notes`** and the tags in `user_rankings.watched_with_user_ids` via the tier-wide upsert in `addItem` (`RankingAppPage.tsx:496-520`), plus `metadata.notes` / `metadata.watched_with_user_ids` on the `ranking_add` activity event (C1 §1.2).
- **No moods are collected at ceremony time on web.** `movie_stubs.mood_tags` / `stub_line` are never written by web (C0 audit confirmed, C0 §"never written by web"). Moods only enter via the journal composer.
- After ranking, `setJournalSheetItem(newItem)` (`RankingAppPage.tsx:1216`) auto-opens **`JournalConversation`** (AI chat) — the journal upsell is post-ceremony, optional, and disconnected: the ceremony one-liner is never copied into `journal_entries.review_text`, so a user who typed notes and then saves a journal draft gets two divergent texts in two tables.

### 1.6 Consumers / invariants an iOS renderer must uphold

- `JournalHomeView` (`components/journal/JournalHomeView.tsx`) is mounted per-profile (own AND other users', `ProfilePage.tsx:560`): stats bar (entries / most-felt emoji / streak), search box (routes to the RPC — B1), filter bar, 2-4 col poster grid, IntersectionObserver infinite scroll, PAGE_SIZE 20, `hasMore = page full`. Search results lose username enrichment (blanked, `:41-46`).
- `JournalEntryCard` (`JournalEntryCard.tsx`): poster-hero card; tier badge top-left; up to 2 mood emojis top-right; spoiler is a **badge only — review text is NOT blurred/hidden** (contrast: feed's `FeedReviewCard` blurs); like heart with optimistic count; camera/sparkles indicators; `timeAgo(createdAt)` (not watched_date); review text >200 chars truncates with expand; watched-with usernames resolved via `getProfilesByIds`. Edit button only when `isOwnProfile`.
- Edit flow from card → `JournalConversation` with a **partially reconstructed RankedItem** (`ProfilePage.tsx:564-573`: `year:''`, `genres:[]`, `rank:0`, `tier: entry.ratingTier!` — crashes if ratingTier is null) — the agent context built from this is degraded on edit.
- `JournalConversation` is the live composer (28 useState hooks, `:34-64`). `JournalEntrySheet` (`components/journal/JournalEntrySheet.tsx`) is **dead code — no importer anywhere**; do not port it (it also contains an auto-save-on-dismiss that creates empty entries, `:94-99`).
- Save-path completeness check: all 15 form-editable fields ARE present in the upsert payload (`JournalConversation.tsx:373-391`) — no silent field drops in the current live form. The historical data-loss risk lives in `upsertJournalEntry`'s full-replace semantics (any future partial caller clobbers).

---

## 2. Findings

### Blocking

**B1 — `search_journal_entries` leaks any user's private entries to any authenticated user.**
`supabase_journal_entries.sql:127-138`: SECURITY DEFINER, takes caller-supplied `target_user_id`, no `auth.uid()` predicate → bypasses RLS entirely and returns full rows (review, personal_takeaway, location, watched-with, photo paths) for private/friends entries. Actively exercised from the UI: typing in the search box on **another user's** journal tab calls it with their id (`JournalHomeView.tsx:39`, `journalService.ts:286-302`). Fix: either drop SECURITY DEFINER (invoker + RLS), or enforce inside the function `target_user_id = auth.uid() OR visibility check`; exclude `personal_takeaway` weight from cross-user results.

**B2 — `visibility_override IS NULL` ("Default") = world-readable; profile default visibility ignored.**
`supabase_fix_critical_rls.sql:20-33`. NULL is the untouched default for every entry (both forms initialize it undefined; Letterboxd import writes null), yet the policy treats NULL as public instead of inheriting `profiles.profile_visibility` (default `'friends'`, per C1 B2 adjudication). A friends-visibility profile's entire journal (minus explicit overrides) is readable by any authenticated user, and surfaces in `getReviewsForMovie` for strangers. Fix: NULL branch → resolve against `profiles.profile_visibility` (same EXISTS pattern as the C1 explore policy).

**B3 — like-count RPCs allow arbitrary manipulation, and the web toggle drifts counts in normal use.**
`increment_journal_likes`/`decrement_journal_likes` (`supabase_journal_entries.sql:108-124`) are SECURITY DEFINER, callable by any authenticated user with any entry id, unbounded, and not tied to a `journal_likes` row. Additionally `toggleJournalLike` (`journalService.ts:419-446`) is non-idempotent (upsert-hit still increments; delete-miss still decrements) and `JournalEntryCard.tsx:31` never loads initial liked state, so real users double-increment across sessions. Fix: replace both RPCs with triggers on `journal_likes` INSERT/DELETE (count derived from actual rows), and have the card fetch `isLiked` for the viewer.

**B4 — `journal-photos` bucket is public with unconditional read: photos of friends/private entries are exposed.**
`supabase_journal_entries.sql:171-177`: `public = true` + `journal_photos_select USING (bucket_id = 'journal-photos')`. Paths are structured and low-entropy apart from the entry uuid (`{userId}/{entryId}/{index}.{ext}`), and are disclosed in `photo_paths` on any row a viewer can read (including via B1/B2). Entry visibility never gates photo access. Fix: private bucket + signed URLs, or SELECT policy joining `journal_entries.photo_paths`/visibility. (Cleanup gap is D5.)

**B5 — `personal_takeaway` is promised "(private)" but shipped to every viewer of the row and full-text indexed.**
UI label (`JournalConversation.tsx:761`, dead sheet `:384`) vs reality: column rides along in every `select('*')` cross-user read (`journalService.ts:243`, `reviewService.ts:76,143`), is weight-D in the public `search_vector` (`supabase_journal_entries.sql:40`), and is returned by the B1 RPC. Fix (pick one, decide before iOS port): honor the promise — exclude it from cross-user selects/search and treat as owner-only; or relabel the UI. iOS must not render other users' `personal_takeaway` regardless.

**B6 — `visibility_override = 'friends'` review text leaks to explore via the activity event.**
`journalService.ts:141` gates the `review` activity event only on `!== 'private'`. A 'friends'-only entry by a public-visibility profile emits `metadata.reviewBody` into `activity_events`, which the C1 explore policy (`20260707_explore_visibility_rls.sql:47-68`) exposes to **all** authenticated users. Entry-level intent is stricter than event-level enforcement. Fix: only log the event for `'public'` or (NULL + profile-public after B2); or carry visibility into the event and filter.

**B7 — UTC-derived `watched_date` and mixed-timezone streak math.**
Default date is `new Date().toISOString().split('T')[0]` (`journalService.ts:120`, `JournalConversation.tsx:49,130`) — for any user west of UTC, evening entries are stamped tomorrow (permanent wrong data, shared table). `getJournalStats` then compares UTC-parsed date-only strings against **local** midnight (`journalService.ts:357-363`), so `daysSinceLast` for a yesterday-entry evaluates to ~1.3 in UTC-7 → `currentStreak = 0`; streaks are systematically broken outside UTC. This exact code would be transliterated into Swift. Fix: local-date formatting (`en-CA` locale trick or manual y-m-d from local components) on write; do streak math in whole local days.

### Deferred

**D1 — Every save of an entry with review text re-emits a feed `review` card.** `journalService.ts:141-154` + append-only `activity_events` (C1 §1.1) → editing an entry duplicates feed cards. Dedupe by (actor, tmdb_id) upsert or emit only on first save.
**D2 — `journal_tag` notifications ignore visibility and leak review text.** `journalService.ts:157-171` notifies tagged friends with a 100-char review snippet even for `private` entries; also re-sends on every save (no dedupe). Combined with the weak notifications INSERT policy (`supabase_fix_critical_rls.sql:38-43`, only checks target exists) the type is spoofable by any user.
**D3 — Second generation in a session always fails.** `agent_generations UNIQUE(session_id)` (`supabase_emotional_data.sql:173`) vs `recordGeneration` plain insert (`agentService.ts:312-321`): back-to-chat → regenerate hits the unique violation, returns null, UI shows "Failed to generate review" despite a successful (and paid) LLM call. Upsert on session_id or allow multiple generations.
**D4 — Correction duplication on save retry.** `recordAllCorrections` runs before the entry upsert with no idempotency key (`JournalConversation.tsx:361-371`; no UNIQUE on `(generation_id, field_name)`) — a failed save + retry double-writes the immutable "gold" rows. Also `time_spent_editing_ms` is never passed (always null).
**D5 — Photo orphan/cleanup gaps.** Photos upload before save (`JournalConversation.tsx:414-426`: creates a **skeleton entry** `{title, posterUrl}` — full-replace clobber if a row already existed but hadn't loaded); abandoning after upload leaves storage objects unreferenced; `handlePhotoRemove` deletes the object but the DB row keeps the stale path until next save; `deleteJournalEntry` cleanup is client-side only (no cascade on account deletion). With B4's public bucket these orphans are permanently public.
**D6 — Photo path index collision + missing storage UPDATE policy.** Index = `photoPaths.length` (`journalService.ts:385`): remove photo 0 of 2 then add → path `…/1.ext` collides; `upsert: true` needs a storage UPDATE policy that doesn't exist (`supabase_journal_entries.sql:176-183`) → failure or stale-extension orphan.
**D7 — `appendMessage` sequence race.** Read-max-then-insert (`agentService.ts:211-226`) under `UNIQUE(session_id, sequence_number)` — concurrent sends (two tabs) violate and drop a message. Compute sequence server-side (trigger/RPC).
**D8 — Cross-user message injection into a known session id.** `agent_messages` INSERT policy checks only `auth.uid() = user_id`, never that the session belongs to the inserter (`supabase_emotional_data.sql:148-150`) — user A can append rows to B's session uuid (B never sees them due to SELECT policy; turn_count untouched since the invoker-rights trigger update is RLS-filtered to 0 rows). Pollutes analytics/training joins. Add a session-ownership EXISTS to the policy.
**D9 — Fabricated `personId` in AI-generated standout performances.** `JournalConversation.tsx:323-330` maps generated name strings to `{personId: i}` (0,1,2…) — fake TMDB person ids persisted into the shared jsonb shape; any client keying on personId misbehaves. Use a sentinel (-1/null) or resolve against credits.
**D10 — Provenance mislabels in `agent_generations`.** `recordGeneration` is called with `session.promptVersion` ("v1") as `prompt_template_hash` and `session.modelVersion` (DB default "kimi-2.5") as `model_id` (`agentService.ts:488-489`), while the edge function actually runs `kimi-k2-0905-preview` (`journal-agent/index.ts:235`). `token_count`/`confidence_scores` never written despite usage being returned. Training-data lineage is wrong.
**D11 — Consent is auto-granted.** `consent_product_improvement` defaults TRUE (`supabase_emotional_data.sql:23`) and `ensureConsentRecord` stamps `consented_at = now()` on a row the user never saw (`consentService.ts:120-126, 62-66`). No consent UI exists in the composer flow. Decide the real consent UX before iOS replicates opt-out-by-default.
**D12 — Edge function is an open LLM proxy for any authenticated user.** No consent/session/ownership validation, no rate limit, CORS `*`, upstream error text echoed to clients (`journal-agent/index.ts:387, 429-435`) — Moonshot spend is burnable by any account with a script.
**D13 — Spoiler flag not enforced by the journal renderer.** `JournalEntryCard.tsx:150-154` shows a badge but renders review text uncovered (feed blurs; journal doesn't). Align (iOS should blur/gate like `FeedReviewCard`).
**D14 — `rating_tier` staleness.** Captured at upsert from `user_rankings` (`journalService.ts:96-104`); tier moves never propagate. Card shows a stale tier badge. Also edit-from-card crashes on entries with null tier (`ProfilePage.tsx:571` non-null assertion).
**D15 — Dead `JournalEntrySheet`.** Zero importers; contains auto-save-on-dismiss that creates empty entries for every open/close (`JournalEntrySheet.tsx:94-99`). Delete on web; iOS ports `JournalConversation` semantics only.
**D16 — Perf notes.** `buildContext` re-runs 3 queries per chat turn (`JournalConversation.tsx:286-287`); `getJournalStats` loads all rows unpaginated; `listJournalEntries` offset pagination (same class as C1 B4).

---

## 3. iOS gap list

iOS has **zero journal code** — the only reference is a comment in `ios/Spool/Sources/Spool/Screens/StubsScreen.swift:156`. No repository, model, or screen exists for: journal entries, likes, consent, agent sessions/messages/generations, corrections.

Repositories needed:
1. `JournalRepository` — upsert (full-replace semantics, tier lookup from rankings, local-date default per B7 fix), getByUserAndTmdb, getById, delete (+photo cleanup), list (filters + pagination), search (post-B1 fix), stats (post-B7 fix), like toggle (post-B3 fix).
2. `JournalPhotoStore` — `journal-photos` bucket, path scheme `{userId}/{entryId}/{index}.{ext}` (post-B4/D6 decisions; prefer uuid filenames + signed URLs).
3. `ConsentRepository` — `user_data_consent` get/upsert/hasConsent, `CURRENT_CONSENT_VERSION = 1`, prompt logic (`needsConsentPrompt`), pending D11 UX decision.
4. `AgentRepository` — sessions (create/end/get), messages (append with server-side sequencing per D7, list), generations (record/get, one-per-session or post-D3 fix), corrections (detectCorrectionType port: Levenshtein + array set-diff + 80% rewrite threshold — pure logic, direct Swift transliteration, tests exist in `services/__tests__/correctionService.test.ts`).
5. `JournalAgentClient` — `functions.invoke('journal-agent')` with the §1.4 request/response contract; Supabase session JWT auth; 25 s+ timeout budget; 502-with-raw_output handling.

Screens: journal tab on profile (grid + stats + filters + search), entry composer (chat phase + draft phase, skip-to-form fallback, consent-off fallback), thin chat UI (typing indicator, retry, generate button gated at ≥2 user turns), photo grid (max 6), mood selector (23 ids/4 categories), vibe selector (11 ids), cast selector (TMDB credits), friend tag input (friends-only), visibility picker (Default/public/friends/private).

Constants to mirror: `MOOD_TAGS` (must stay in sync with the edge function's hardcoded `MOOD_TAG_IDS`, `journal-agent/index.ts:9-34`), `VIBE_TAGS`, `PLATFORM_OPTIONS`, `JOURNAL_MAX_PHOTOS = 6`, `JOURNAL_MAX_MOMENTS = 5`, tier prompts. Shared shapes (journal row incl. `standout_performances` jsonb, correction rows, agent tables) belong in `docs/contracts/shared-payloads.md` per program rule 2.

## 4. Ceremony quick-entry recommendation

Today the ceremony one-liner lives in `user_rankings.notes` (+ event metadata) and moods don't exist at ceremony time at all; the journal is a separate, optional post-rank flow, and stubs' `mood_tags`/`stub_line` are unwritten (C0). "Quick entry writes journal_entries instead of notes" should mean, on both platforms: at ceremony completion, when the user entered a one-liner and/or picks moods, upsert a `journal_entries` row (`review_text` = one-liner, `mood_tags`, `watched_with_user_ids`, `watched_date` = local today, `visibility_override` = null) via the same upsert used by the composer — making journal the single source of truth — while continuing to mirror the one-liner into `user_rankings.notes` for existing renderers (profile activity, event metadata) until a later cycle deprecates it. Guardrails learned from this audit: the quick path must reuse full-replace-safe logic (read-modify-write or a partial-update RPC) so it never clobbers an existing richer entry (D5's skeleton-clobber is the cautionary tale), must not fire the review activity event/journal_tag notification twice when the user continues into the full composer (D1/D2), and lands only after B2/B7 fix visibility-of-NULL and date semantics — otherwise every ceremony would mint world-readable, possibly wrong-dated entries at 10x today's volume.

## 5. Open questions

1. **NULL visibility semantics (B2):** inherit `profiles.profile_visibility` (recommended, matches C1 adjudication) or make "Default" mean public and say so in the UI? Needs owner adjudication before the RLS fix.
2. **`personal_takeaway` (B5):** enforce owner-only (column-level: view or separate table) or relabel? Affects search_vector definition (generated column rebuild).
3. **Consent UX (D11):** is opt-out-by-default product_improvement consent acceptable for the AI agent, and does iOS need an explicit consent sheet (App Store privacy implications)?
4. **Photo storage (B4):** signed-URL private bucket (breaks current `<img>` public-URL rendering, needs web change) vs policy-gated public bucket?
5. **Rewatch model:** one row per movie forces rewatches to overwrite the original entry's context (date/location/platform). Is per-watch journaling (schema change) in scope for any cycle, or documented as intended?
6. **Does iOS port the AI chat in C2 stage b, or CRUD-only first?** The edge function contract is stable, but D3/D7/D10 argue for fixing the persistence layer before a second client writes it.
7. **Should `search_journal_entries` support cross-user search at all post-B1?** Web UI exposes search on other profiles; if that's intended, the fixed RPC needs a visibility-aware variant rather than owner-only.
