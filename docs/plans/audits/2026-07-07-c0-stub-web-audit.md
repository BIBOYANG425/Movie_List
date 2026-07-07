# C0 Web Audit — movie_stubs creation (reference semantics for the iOS stub write)

**Cycle:** C0 (iOS stub write fix, `RankPersistence.swift:70` TODO)
**Audited at commit:** `fb1e616` on `feat/ios-parity-c0-stub-write`
**Scope:** end-to-end web stub-creation logic (`services/stubService.ts`, `pages/RankingAppPage.tsx`, stub components, `supabase/migrations/20260325_movie_stubs.sql`, `20260408_scope_movie_stubs_rls.sql`). Audit only — no code changed.

---

## 1. Reference semantics (the contract an iOS writer must implement)

### 1.1 Table shape (`supabase/migrations/20260325_movie_stubs.sql:6-42`)

| Column | Type / constraint | Web write behavior |
|---|---|---|
| `id` | uuid PK, `gen_random_uuid()` | never sent by client |
| `user_id` | uuid NOT NULL → `profiles(id)` ON DELETE CASCADE | auth user's UUID; RLS INSERT `WITH CHECK (auth.uid() = user_id)` |
| `media_type` | text NOT NULL, CHECK IN `('movie','tv_season')` | `'movie'` or `'tv_season'`. **Books never get stubs** (CHECK would reject; web never tries) |
| `tmdb_id` | text NOT NULL | movie: numeric TMDB id as string (`RankedItem.id`); tv_season: composite `tv_{showTmdbId}_s{seasonNumber}` (same id format as `tv_rankings.tmdb_id`) |
| `title` | text NOT NULL | ranked item title verbatim |
| `poster_path` | text NULL | **despite the name, web writes a full URL** — `https://image.tmdb.org/t/p/w500{path}` (`tmdbService.ts:14,103` builds `posterUrl`; `RankingAppPage.tsx:542,825` passes it straight through). All consumers handle both bare paths and full URLs via `startsWith('http')` (`StubCard.tsx:29,127`, `CalendarView.tsx:188`). `null` when absent |
| `tier` | text NOT NULL, CHECK IN `('S','A','B','C','D')` | tier at rank time; refreshed on re-rank via upsert |
| `watched_date` | date NOT NULL DEFAULT `CURRENT_DATE` | **omitted on the live rank path** — `createStub` only sends it when explicitly provided (`stubService.ts:91-94`); new inserts rely on the DB default (see finding B2, timezone). Backfill sends the ranking's `created_at` UTC date (`stubService.ts:236,250`). User-editable later as `yyyy-MM-dd` (`updateStubWatchedDate`, `stubService.ts:161-176`) |
| `mood_tags` | text[] DEFAULT `'{}'` | **never written by web** (schema-reserved for AI enrichment; no writer exists anywhere) |
| `stub_line` | text NULL | **never written by web** |
| `is_ai_enriched` | boolean NOT NULL DEFAULT false | never written by web |
| `palette` | text[] NOT NULL DEFAULT `'{}'` | web sends `[]` in the insert payload, then a **background** `.update({palette})` with up to 3 lowercase `#rrggbb` hex colors (ColorThief on the poster). On any failure it stays `[]`. See §1.3 and finding B1 |
| `template_id` | text NOT NULL DEFAULT `'default'` | `'s_tier_gold'` when tier === 'S', else `'default'` (`stubService.ts:78`). Recomputed on every upsert. **Write-only** — no consumer reads it (`StubCard.tsx:18` derives S-tier styling from `tier`) |
| `shared_externally` | boolean NOT NULL DEFAULT false | never written by web |
| `journal_entry_id` | uuid NULL | never written by web (StubDetailModal joins journal by `(userId, tmdbId)` instead — `StubDetailModal.tsx:47`) |
| `created_at` | timestamptz DEFAULT now() | never sent |
| `updated_at` | timestamptz DEFAULT now() | client sends `new Date().toISOString()` on every upsert (`stubService.ts:89`) and date edit (`stubService.ts:167`) |

### 1.2 Idempotency / dedup contract

- Unique key: `UNIQUE(user_id, media_type, tmdb_id)` (`20260325_movie_stubs.sql:41`).
- Web writes via **UPSERT** on `user_id,media_type,tmdb_id` with `ignoreDuplicates: false` (`stubService.ts:96-100`). Re-ranking the same movie (including cross-tier migration) **updates** the existing stub: `tier`, `template_id`, `title`, `poster_path`, `updated_at` refresh; `watched_date`, `mood_tags`, `stub_line`, `is_ai_enriched`, `shared_externally`, `journal_entry_id`, `created_at` are preserved because they're absent from the payload. (`palette` is NOT preserved — that's finding B1.)
- Consequence the iOS side already documents: one stub per media item forever; rewatches are not representable (`ios/.../StubsScreen.swift:154`).
- **iOS gap:** `RankingRepository.insertStub` (`RankingRepository.swift:162-168`) is a plain `.insert` — a re-rank would throw a unique violation. The iOS writer must use upsert-on-`user_id,media_type,tmdb_id` to match web.

### 1.3 Palette contract (`stubService.ts:35-61,107-120`)

- Source image: whatever string is in `posterPath`. If it starts with `http` it's used as-is (in practice always the full **w500** URL); only bare paths get the `w185` shrink — a branch that never runs on live paths (finding D7).
- Extraction: `ColorThief.getPalette(img, 3)` with `crossOrigin='anonymous'`, mapped to lowercase `#rrggbb` hex.
- Failure behavior: image error, ColorThief throw, or 5-second timeout all resolve to `[]`; the background update is skipped when the palette is empty (`stubService.ts:110`), so the row keeps `[]`. No retry ever.
- Fire-and-forget: extraction runs after `createStub` returns; the caller never awaits it. A failed palette `.update` is only `console.error`'d (`stubService.ts:116`).
- Renderer expectations (`StubCard.tsx:15-17`): palette is used only when `length >= 2`; otherwise the card falls back to `[tierColor, '#1a1a2e', '#0f0f1a']`. Third color optional (`c3 ?? c2`, `StubCard.tsx:71`). So a valid stub may carry `[]` forever and still render.
- iOS parity note: exact color equality with ColorThief is not required by any consumer — colors are only fed to gradients/swatches. Deterministic cross-client palette parity is a non-goal unless the owner says otherwise (open question Q4).

### 1.4 Date semantics

- Live rank path sends **no** `watched_date`; the row gets Postgres `CURRENT_DATE`, which on Supabase is evaluated in the **UTC** session timezone — not the user's local date (finding B2).
- Backfill derives the date from the ranking row's `created_at` via `split('T')[0]` — also the UTC date (`stubService.ts:236,250`).
- Edits from `StubDetailModal` send the raw `<input type="date">` value (user-local `yyyy-MM-dd`) (`StubDetailModal.tsx:61-70`).
- All read paths treat `watched_date` as a plain calendar date and parse with `+ 'T00:00:00'` (local midnight) so no read-side shift occurs (`CalendarView.tsx:93`, `StubCollectionView.tsx:58`, `StubCard.tsx:159`).
- Historical note: iOS commit `4ab90ea` ("real stub date") was purely a **rendering** fix — `AdmitStub` had a hardcoded `"APR · 18 · 2026"` default. It did not touch write semantics; iOS has never written a stub. The existing iOS `ISODate` formatter for the future write is pinned to UTC (`RankingRepository.swift:315-323`) and would reproduce the web's UTC off-by-one (B2).

### 1.5 RLS (`20260325_movie_stubs.sql:49-61`, `20260408_scope_movie_stubs_rls.sql`)

- INSERT: `WITH CHECK (auth.uid() = user_id)` — client must send its own `user_id`.
- UPDATE / DELETE: `USING (auth.uid() = user_id)`.
- SELECT: owner OR any user whose `profiles.profile_visibility = 'public'` (the 20260408 migration replaced the original `USING (true)`).
- The upsert's `.select().single()` readback works because the owner always passes the SELECT policy. No client/policy mismatch found.

### 1.6 Error contract

- Stub creation is **non-fatal by design**: `createStub` returns `null` on error and only `console.error`s (`stubService.ts:102-105`); both call sites are fire-and-forget with `.catch(() => {})` (`RankingAppPage.tsx:538-544, 821-827`). A failed stub insert does not roll back the ranking (no transaction) and never surfaces to the user. Recovery is the manual "backfill" button (finding D3).
- The iOS writer should match: stub failure must not fail the rank save, but should at least NSLog (parity with web's console.error).

---

## 2. Creation flow trace

**Movie (the C0 reference path):**
1. User finishes the ranking ceremony in `AddMediaModal` (`components/media/AddMediaModal.tsx:187,348,375` call `onAdd`), which internally runs the `RankingFlowModal` H2H flow (`components/media/RankingFlowModal.tsx:59,83,101`).
2. `onAdd` = `handleAddItem` (`pages/RankingAppPage.tsx:1201-1217`) → `addItem` (`:479`).
3. `addItem` performs, sequentially:
   a. `user_rankings` tier-list upsert (`:515`, awaited, toast on failure),
   b. `logRankingActivityEvent(..., 'ranking_add')` (`:523`, awaited),
   c. `createStub(user.id, {mediaType:'movie', tmdbId, title, posterPath: posterUrl, tier})` — **fire-and-forget**, no `watchedDate` (`:538-544`).
4. `createStub` upserts the row, then kicks off background palette extraction + a second `.update({palette})` (`stubService.ts:96-120`).

**TV season:** `AddTVSeasonModal` → `handleAddTVItem` (`:1192`) → `addTVItem` (`:786`) → `persistTVRankings` + `createStub` with `mediaType:'tv_season'` (`:821-827`). Same shape; `tmdbId` is the composite `tv_{id}_s{n}` string.

**Books:** `addBookItem` (`:1024`) writes `book_rankings` only — no stub call, and the CHECK constraint excludes books anyway.

**Cross-tier move (movie):** drag to another tier sets `migrationState` and re-opens the ceremony (`handleDrop`, `:355-369`); completion funnels back through `addItem`, so the stub's `tier`/`template_id` refresh via upsert. Same-tier drags never touch stubs.

**Backfill:** `CalendarView.tsx:76` / `StubCollectionView.tsx:41` → `backfillStubs` (`stubService.ts:194-268`): reads `user_rankings` + `tv_rankings` + existing stubs, diffs on `media_type:tmdb_id`, then calls `createStub` for each missing ranking in chunks of 5 with `watchedDate = created_at.split('T')[0]`.

**Date edit:** `StubDetailModal.tsx:64` → `updateStubWatchedDate` (`stubService.ts:161`).

**Other writers — none.** `server.js` never touches stubs; the only edge function (`supabase/functions/journal-agent`) doesn't either; no migration backfills rows; nothing writes `mood_tags`/`stub_line`/`is_ai_enriched`/`shared_externally`/`journal_entry_id` anywhere in the codebase. On iOS, `RankingRepository.insertStub` exists but has **zero callers** (the C0 TODO), and `StubRepository` is read-only. The two `RankingAppPage` call sites + backfill are the complete write surface today.

---

## 3. Findings

### Blocking

**B1 — Re-rank wipes an existing palette (upsert clobber).**
`services/stubService.ts:87` puts `palette: []` in the upsert payload unconditionally, and `:98` upserts with `ignoreDuplicates: false`. On conflict (any re-rank, including every cross-tier migration), PostgREST's merge-duplicates updates **every column present in the payload**, so a previously extracted palette is overwritten with `[]`. It's only restored if the background re-extraction (`:107-120`) succeeds — which silently fails on the 5s timeout, image error, ColorThief throw, or the user navigating away before the promise runs. Net effect: re-ranking can permanently degrade a good stub to the tier-color fallback. Corrupts shared data and would be ported into Swift verbatim.
*Suggested fix:* drop `palette` from the upsert payload entirely (the column has `NOT NULL DEFAULT '{}'`, so fresh inserts are unaffected — same pattern the code already uses for `watched_date` at `:91-94`). Optionally skip re-extraction when the existing row already has a palette.

**B2 — Stub dates are the UTC date, not the user's local date (off-by-one after 5pm PT).**
The live rank path omits `watched_date` (`services/stubService.ts:91-94` — comment says "new inserts use DB DEFAULT CURRENT_DATE"). Supabase Postgres sessions run in UTC, so `CURRENT_DATE` is the UTC calendar date: a user who ranks a movie at 7pm PDT on July 6 gets `watched_date = 2026-07-07`, and `CalendarView` faithfully renders the stub on tomorrow's cell. `backfillStubs` has the same bug from the other direction — `created_at.split('T')[0]` (`:236,250`) is the UTC date of a timestamptz. The intent is clearly the user's local "watched on" date (the `StubDetailModal` date picker edits in local terms). This would be ported into Swift as-is: the prepared iOS formatter is already pinned to `TimeZone(secondsFromGMT: 0)` (`ios/.../RankingRepository.swift:315-323`).
*Suggested fix (web):* have `createStub` always send an explicit local calendar date (`new Date()` → local `yyyy-MM-dd`, e.g. via `toLocaleDateString('en-CA')` or manual component formatting), and make backfill convert `created_at` to a local date before splitting. iOS then mirrors with `Calendar.current`/`TimeZone.current` instead of GMT.

### Deferred (log only)

**D3 — Failed stub insert is silently lost.** `createStub` returns `null` and `console.error`s (`stubService.ts:102-105`); callers use `.catch(() => {})` (`RankingAppPage.tsx:538,821` — moot anyway since `createStub` never rejects). No retry, no toast; the only recovery is the manual backfill button, which disappears from the UI after one click per session (`CalendarView.tsx:133`, `StubCollectionView` same). Acceptable UX tradeoff, but worth a deliberate decision when iOS picks its error surface.

**D4 — Ranking deletion/reset orphans stubs; `deleteStubByRanking` is dead code.** `removeItem` (`RankingAppPage.tsx:573-577`), `removeTVItem` (`:855-859`) and `handleReset` (`:339-346`) delete ranking rows but never touch `movie_stubs`. `deleteStubByRanking` (`stubService.ts:178-190`) has had zero callers since it was introduced in `cd991ad`. Stubs therefore outlive their rankings (possibly intentional — "you still watched it" — but then the helper should be deleted; if unintentional, deletes should wire it in). Needs an owner decision before C4 (ranking management) ports delete flows.

**D5 — TV cross-tier drag leaves the stub's `tier`/`template_id` stale.** Movie cross-tier drags reroute through the migration ceremony and refresh the stub via upsert, but `handleTVDrop` (`RankingAppPage.tsx:881-947`) persists `tv_rankings` directly and never calls `createStub`. A TV stub keeps its original tier badge/gold styling forever after a drag move. Same class of divergence flagged for C5.

**D6 — Onboarding and Letterboxd import create rankings without stubs.** `MovieOnboardingPage.tsx:89,130,383` and `letterboxdImportService.ts:404,440` write `user_rankings` and never call `createStub`; those movies only get stubs if the user finds the backfill button. iOS onboarding-queue drain (`AuthService` flushing `OnboardingQueue`) will have the same hole — decide in the C0 plan whether the queue flush also writes stubs.

**D7 — `template_id` is write-only and the palette fetch always downloads w500.** No consumer reads `template_id` (S-tier styling is derived from `tier` at `StubCard.tsx:18`); keep writing it for compat but don't build iOS logic on it. Separately, because `posterPath` is always a full w500 URL, the `w185` fast-path in `extractPalette` (`stubService.ts:40-42`) never runs — extraction downloads the large poster. Perf-only.

**D8 — Backfill has a small watched_date race.** `backfillStubs` snapshots existing stubs, then upserts with an explicit `watchedDate` (`stubService.ts:221-264`). A stub created (or date-edited) between the snapshot and the chunked upsert gets its `watched_date` overwritten with the ranking's created-date. Window is seconds and the overwrite value is usually correct; log only.

---

## 4. Open questions for the C0 plan

1. **Orphan policy (D4):** should deleting a ranking delete its stub? Decides whether iOS C4 wires stub deletion and whether web's `deleteStubByRanking` gets wired or removed (W0.x cleanup).
2. **Local-date rollout (B2):** the fix changes what "today" means for both clients. Confirm the owner wants user-local dates, fix web first (per program bug policy), then have the iOS writer send `Calendar.current` dates — and note that historical rows keep their UTC dates (no backfix planned?).
3. **Should iOS write `mood_tags` / `stub_line` at ceremony time?** The iOS `StubInsert` DTO already carries them and the RankPersistence TODO says "moods + line → movie_stubs", but **web has never written these fields**. If iOS becomes the first writer, web's `StubCard` will render them (it already handles both) — fine, but it's a new shared-shape behavior that must land in `docs/contracts/shared-payloads.md` per the drift rules.
4. **Palette parity:** iOS will extract with native APIs (not ColorThief), producing different hex values for the same poster. Confirm "3 lowercase #rrggbb colors, [] on failure, only update when non-empty" is the whole contract and exact color parity is a non-goal.
5. **Upsert vs insert on iOS:** `RankingRepository.insertStub` must switch to upsert on `user_id,media_type,tmdb_id` (and omit `watched_date`-preserved fields from the update set) before it's chained into `RankPersistence.save` — otherwise the first re-rank crashes the stub write. Should the C0 build also fix B1 semantics on iOS from day one (never send `palette` in the conflict-update payload)?
