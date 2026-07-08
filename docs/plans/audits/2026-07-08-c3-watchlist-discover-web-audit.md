# C3 Web Audit — watchlist + discover (reference semantics for iOS port + suggestions edge function)

**Cycle:** C3 (watchlist + discover)
**Audited at commit:** `af8ae3f` on `feat/ios-parity-c1-feed-data` (all web files audited here match main)
**Scope:** `services/tmdbService.ts` (1,905 ln, whole file), `services/tasteService.ts`, `services/letterboxdImportService.ts` (watchlist writes), `services/activityService.ts` (watchlist writes), `pages/RankingAppPage.tsx` (watchlist CRUD + rank-from-watchlist), `pages/MovieOnboardingPage.tsx` (engine consumer), `components/media/AddMediaModal.tsx`, `components/media/AddTVSeasonModal.tsx`, `components/media/Watchlist.tsx`, `components/shared/UniversalSearch.tsx`, `components/social/DiscoverView.tsx`, `hooks/useLocalizedItems.ts`, `supabase/migrations/supabase_schema.sql`, `supabase_tv_rankings.sql`, `supabase_book_rankings.sql`, `supabase_smart_suggestions.sql`, iOS `TasteRepository.swift` / `TMDBService.swift`. Audit only — no code changed.

**Premise corrections vs the program table (read first):**
1. **`user_taste_profiles` is written by nobody the client controls and read by nobody at all.** Zero references to `user_taste_profiles`, `movie_credits_cache`, or `recompute_taste_profile` exist anywhere in web, iOS, or `server.js`. The only writer is the DB trigger `trg_recompute_taste` (`supabase_smart_suggestions.sql:312-316`); the client engine uses an **ephemeral in-memory profile** built per call by `buildTasteProfile` (`tmdbService.ts:159-246`). There are no client taste-profile writes, hence no client-side race — but see finding B4 for what the trigger actually costs.
2. **The web "Discover" tab does not use the 5-pool engine.** `DiscoverView` (`components/social/DiscoverView.tsx:6-9,64-67`) renders `getFriendRecommendations` + `getTrendingAmongFriends` (`tasteService.ts:211,316`) — pure Supabase, zero TMDB. The 5-pool engine is consumed by **AddMediaModal** (`AddMediaModal.tsx:118,125`), **AddTVSeasonModal** (`AddTVSeasonModal.tsx:147,154`), and **MovieOnboardingPage** (`MovieOnboardingPage.tsx:157,166`) as the suggestion grid inside the ranking flow. The C3 "Discover surface calling the edge function" needs a product decision on which surface(s) that means (open question Q6).

---

## 1. Reference semantics

### 1.1 Watchlist contract (three parallel tables)

| | `watchlist_items` (`supabase_schema.sql:37-49`) | `tv_watchlist_items` (`supabase_tv_rankings.sql:65-80`) | `book_watchlist_items` (`supabase_book_rankings.sql:67-83`) |
|---|---|---|---|
| key | `UNIQUE(user_id, tmdb_id)` | same | same |
| `tmdb_id` format | `tmdb_{n}` from app paths (`mapTmdbResult`, `tmdbService.ts:99`); **bare `{n}` from Letterboxd import** (`letterboxdImportService.ts:461`); **`manual:{slug}[:year]` from dead `saveActivityMovieToWatchlist`** (`activityService.ts:267`) — see B1 | `tv_{showId}_s{n}` (season) or `tv_{showId}` (whole-show bookmark) | `ol_{workKey}` |
| media columns | title, year, poster_url (full URL), type='movie', genres text[], director | + show_tmdb_id int, season_number (whole-show rows get **0**, not the schema-intended NULL — `RankingAppPage.tsx:676` vs comment `supabase_tv_rankings.sql:70`), season_title, creator | + author, page_count, isbn, ol_work_key, ol_ratings_average |
| `added_at` | timestamptz default now(), never sent by client | same | same |
| RLS SELECT | **owner only** (`supabase_schema.sql:146`) | owner **+ followers** (`supabase_tv_rankings.sql:88-99`) | owner + followers (`supabase_book_rankings.sql:92-103`) |
| RLS UPDATE | **none** (only SELECT/INSERT/DELETE, `supabase_schema.sql:146-148`) | owner (`:105-108`) | owner (`:109-112`) |
| RLS INSERT/DELETE | owner | owner | owner |

The visibility + UPDATE asymmetries are finding B3.

**Write paths (complete inventory):**
- `addToWatchlist` (`RankingAppPage.tsx:620-652`): optimistic prepend, then **UPSERT** on `user_id,tmdb_id` (merge-duplicates); revert + toast on error. Guarded by a client-side pre-check `watchlist.some(w => w.id === item.id)` (`:622`) so the conflict/UPDATE path normally never fires — which is what masks the missing UPDATE policy (B3). Always writes `type:'movie'` (`:627`).
- `addToTVWatchlist` (`:666-694`): same shape; `show_tmdb_id: item.showTmdbId ?? 0`, `season_number: item.seasonNumber ?? 0` (`:675-676`).
- `addToBookWatchlist` (`:1092-1120`): same shape, book columns.
- Letterboxd import (`letterboxdImportService.ts:457-479`): batch upsert with `ignoreDuplicates: true` (DO NOTHING — never needs UPDATE), **bare-numeric tmdb_id**, pre-filtered against existing watchlist and the import's own ranked set (`:451-454`).
- Dead: `saveActivityMovieToWatchlist` (`activityService.ts:261-281`) — zero callers, writes `manual:` ids, empty genres.
- **Removes:** `removeFromWatchlist`/`removeTVFromWatchlist`/`removeBookFromWatchlist` (`RankingAppPage.tsx:654-664,696-706,1122-1126`): optimistic, DELETE by `(user_id, tmdb_id)`, errors ignored (no revert on TV/book/movie delete failure — item silently reappears on next load).

**Read paths:** one initial parallel load of all six tables scoped to the user, watchlists ordered `added_at desc` (`RankingAppPage.tsx:281-315`), mapped by `rowToWatchlistItem`/`rowToTVWatchlistItem`/`rowToBookWatchlistItem` (`:124-135,159-174,199-214`) into `WatchlistItem` (= `MediaItem` + `addedAt`, `types.ts:48-50`). No pagination, no refetch except full page reload. Cross-user watchlist reads: **none on web** (iOS already does one — B3). Also `letterboxdImportService.fetchExistingIds` (`:525-538`) and `tasteService.getFriendRecommendations` (`:224-231`) read the own-user watchlist for exclusion sets.

**Rank-from-watchlist flow:** `Watchlist` tab (`components/media/Watchlist.tsx`) is render-only (grid, Rank It / Remove hover actions). `rankFromWatchlist` (`RankingAppPage.tsx:708-752`) routes by type: movie → `preselectedForRank` + AddMediaModal (skips to tier step, `AddMediaModal.tsx:153-173`); TV → `preselectedTVItem` + AddTVSeasonModal (whole-show bookmark with truthy `showTmdbId` and falsy `seasonNumber` routes through season selection, `AddTVSeasonModal.tsx:206-216`; season bookmark goes straight to tier, `:217-231`); book → RankingFlowModal. On ceremony completion the handler **awaits the rank write then deletes the watchlist row** (`handleAddItem :1201-1217`, `handleAddTVItem :1192-1199`, `handleAddBookItem :1183-1190`) — but the rank write's failure is swallowed inside `addItem` (`:516-519`), so the watchlist row is deleted even when the ranking save failed (finding B5).

**Exclusion consumers:** `UniversalSearch` marks results owned via `rankedIds ∪ allWatchlistIds` (`UniversalSearch.tsx:174`, sets built at `RankingAppPage.tsx:1237-1241`); AddMediaModal excludes `currentItems ∪ watchlistIds` from suggestions and search (`AddMediaModal.tsx:67-70,286-301`); AddTVSeasonModal expands season-level ids to show-level (`AddTVSeasonModal.tsx:76-96`).

### 1.2 Discover tab (DiscoverView) — what it actually is

Friends-only, Supabase-only, TMDB-free:
- **For You** = `getFriendRecommendations(userId, 20)` (`tasteService.ts:211-311`): friends' S/A `user_rankings`, aggregated per movie, excluding the viewer's own ranked+watchlisted ids (raw string compare — B1 applies), sorted by friendCount then avg tier, top 20. 4 queries + profiles.
- **Trending** = `getTrendingAmongFriends(userId, 15, 30)` (`:316-398`): friends' `user_rankings` with `updated_at >= now-30d`, needs ≥2 distinct rankers, sorted by rankerCount. Note `updated_at` is bumped for a **whole tier** on any ceremony insert (`RankingAppPage.tsx:513`), so old rankings "trend" after unrelated re-sorts (D13).
- Save-to-watchlist normalizes ids to `tmdb_` prefix before writing (`DiscoverView.tsx:27-49,186`) — acknowledging the mixed id formats and able to mint a second row for the same movie a bare-id row already represents (B1).
- No pagination, no refresh control; loads once per mount (`:58-78`). Card needs: poster, title, year, top-2 genres, topTier badge, friendCount, ≤3 friend avatars + usernames (For You); rank #, rankerCount, avgTier, recentRankers (Trending).

### 1.3 The 5-pool suggestion engine (the edge-function payload)

Entry points and dispatch (movie copy; TV copy §1.4):
- `getSmartSuggestions(profile, excludeIds, page, excludeTitles, userId?, poolSlots)` (`tmdbService.ts:304-454`). If `profile.totalRanked < SMART_SUGGESTION_THRESHOLD` (**3**, `constants.ts:314`) → `getGenericSuggestions` (`:532-591`): 50% popular recent (≤2y, vote_count≥50, popularity desc) interleaved with 50% classics (≥5y old, vote_count≥1000, vote_average desc), 6+6, dedup, shuffle.
- Otherwise 5 pools fetched in parallel, each overfetching `slots+2` (friend: `slots+1`):
  1. **Similar** (`:331-345`): `/movie/{pick}/similar?page={page}` from ONE random member of `profile.topMovieIds` (S/A-tier ids parsed by regex `/tmdb_(\d+)/`, `:229-235` — bare-numeric ids never match, B1).
  2. **Taste** (`:348-376`): `/discover/movie` with top-3 weighted genres, vote_average desc, vote_count≥200, 50% coin-flip decade window from `preferredDecade`, `page = page + rand(0..2)`.
  3. **Trending** (`:379-391`): `/trending/movie/week?page={page}`.
  4. **Variety** (`:394-418`): `/discover/movie` with 2 random underexposed genres (<2 ranked occurrences), popularity desc, vote_count≥100, `page = 1 + rand(0..2)` — **ignores the page param** (D4).
  5. **Friend** (`:251-297`): viewer's follows → friends' S/A `user_rankings` (`.limit(100)`, no order — arbitrary sample, D1), exclude + poster-required, per-movie dedup, shuffle, take `slots+1`. Maps DB rows straight to `TMDBMovie` (id = friend's raw `tmdb_id` — format contagion, B1; `overview:''`).
- Assembly (`:430-453`): `take()` per pool in order similar(3)/taste(4)/trending(2)/variety(2)/friend(1) (`DEFAULT_POOL_SLOTS`, `constants.ts:305-312`, Σ=12), dedup by numeric `tmdbId`, hard cap 12; leftover slots refilled from `[taste, similar, trending, variety]` (**friend pool never refills**, D2); final Fisher-Yates shuffle. **Pool provenance is discarded** — the UI never knows which pool an item came from.
- Exclusion: `excludeIds.has(m.id)` (string `tmdb_{n}` vs caller's raw ranking/watchlist ids) OR `excludeTitles.has(title.toLowerCase())` (`:319-320`). Titles come from `currentItems` only; in zh locale TMDB returns zh titles (`getTmdbLocale`, `:17-21` reads `spool_locale` from localStorage) so the title net no-ops (part of B1).
- `getSmartBackfill` (`:460-526`): NO threshold check (asymmetric with suggestions); `topMovieIds` empty → generic. Else `/movie/{id}/recommendations?page={page}` for 2 random top ids, dedup, pad with one variety query if <12, shuffle, cap 20.
- **Consumer choreography** (identical in all 3 consumers, e.g. `AddMediaModal.tsx:76-133`): on open/refresh, fetch suggestions(12) AND prefetch backfill(≤20) with the same exclusions; ranking/bookmarking a card calls `consumeSuggestion` which splices in the next backfill candidate not already displayed and re-prefetches the next backfill page when the pool drops below 3 (`:83-107`); Refresh increments a page counter and refetches both (`:130-133`). Render-time safety net re-filters `isAlreadyOwned` every render (`:290-301`). Header copy is the only pool-ish UI: "Popular right now" until the first backfill mixes in, then "Based on your taste" (`:664`); no per-pool labels, no pagination UI beyond Refresh.
- No stale-request guard on any suggestion fetch (unlike search's `searchRequestIdRef`, `:209,229`) — rapid Refresh clicks can settle out of order (D3).
- API budget per modal open: 4 TMDB + 2 Supabase (suggestions) + 2-3 TMDB (backfill) ≈ 7 TMDB calls, all with `VITE_TMDB_API_KEY` in the query string of client-originated requests.

### 1.4 Movie/TV parallel-copy divergences (the W1.2 question: do they disagree where it matters?)

| Aspect | Movie (`tmdbService.ts`) | TV (same file) | Matters? |
|---|---|---|---|
| taste pool vote floor | 200 (`:354`) | 100 (`:1728`) | intentional tuning; edge fn keeps per-media config |
| variety vote floor | 100 (`:405`) | 50 (`:1782`) | same |
| generic floors recent/classic | 50 / 1000 (`:549,558`) | 30 / 500 (`:1633,1642`) | same |
| `topMovieIds` extraction | regex `/tmdb_(\d+)/`, keeps order + dupes impossible (`:229-235`) | anchored `/^tv_(\d+)_s\d+$/` → **show ids**, Set-dedup (`:1534-1542`) | yes — movie regex silently drops bare-numeric ids (B1); TV rankings are seasons but the engine recommends **shows** |
| friend pick id | friend's raw `tmdb_id` (`:284`) | `tv_{show_tmdb_id}` rebuilt from int column (`:1593`) — immune to format drift | yes — movie side propagates B1 |
| friend pick exclusion | `excludeIds.has(r.tmdb_id)` (`:275`) | `excludeIds.has('tv_'+show_tmdb_id)` (`:1584`) — works only because the CALLER pre-expands season ids to show ids (`AddTVSeasonModal.tsx:76-96`) | contract: TV excludeIds must contain show-level ids |
| genre id mapping | `genreNamesToIds` (`:117-121`) | `tvGenreNamesToIds` handles normalized→compound ("Action"→10759, `:1380-1404`); variety maps raw TV names via `TV_GENRE_NAME_TO_ID` (`:1772-1774`) | yes — server must keep both tables + `normalizeTVGenres` (`:1150-1171`) |
| underexposed universe | `ALL_TMDB_GENRES` (19) | `ALL_TV_GENRES` (13, News/Reality/Talk excluded; reverse-normalized counting, `:1506-1532`) | yes |
| profile "director" | `director` field | `creator` stored in `topDirectors` (`:1493-1504`) | naming only; neither is used by any pool today |
| threshold fallback | suggestions only; backfill keys off empty `topMovieIds` | identical asymmetry (`:1689,1849`) | replicate as-is |
| assembly/dedup/refill | identical logic (`:430-453` vs `:1807-1830`) | identical | no |

Verdict: the copies agree on structure; the divergences that matter are the id-format handling and the genre-mapping tables, both of which the edge function must own.

### 1.5 Taste profile — ephemeral client object vs dead DB infrastructure

- Live: `TasteProfile` (`types.ts:597-605`) built per call from the caller's in-memory ranked items; tier weights S..D = 5..1 (`constants.ts:275-281`); weighted genres, tier-weighted decade distribution + argmax `preferredDecade`, top-10 directors, `<2`-count underexposed genres, S/A `topMovieIds`, `totalRanked`.
- Dead-but-armed: `supabase_smart_suggestions.sql` ships `movie_credits_cache` (**no writer anywhere** — every join against it is empty), `user_taste_profiles` (no reader), SECURITY DEFINER `recompute_taste_profile` (`:100-287`), and trigger `trg_recompute_taste` **FOR EACH ROW on user_rankings INSERT/UPDATE/DELETE** (`:312-316`). Because every ceremony re-upserts the whole tier (`RankingAppPage.tsx:497-521`), one rank of a movie into a 30-item tier fires 30 full-profile recomputes, each scanning all of the user's rankings. A 500-film Letterboxd import fires up to 500 recomputes. All output is written to a table nothing reads (finding B4).
- RLS on `user_taste_profiles`: owner CRUD + **follower SELECT** (`supabase_smart_suggestions.sql:66-75`) — unused grant today (D8). `movie_credits_cache`: world-read, any-authenticated-user INSERT/UPDATE (`:22-37`) — poisoning surface if ever consumed (D9).

### 1.6 TMDB key exposure surfaces (inventory for the extraction)

Web bundle (`VITE_TMDB_API_KEY` via `import.meta.env`): `services/tmdbService.ts` (every function), `hooks/useLocalizedItems.ts:27` (zh title fetches, movie+TV), `components/journal/CastSelector.tsx`, `services/letterboxdImportService.ts` (import-time TMDB resolution). iOS bundle: `TMDB_API_KEY` in Info.plist (`ios/.../TMDBService.swift:21-22`, comment explicitly matches web's risk model). `server.js` and the `journal-agent` edge function never touch TMDB. Removing the key from bundles therefore requires proxying **search + person + details + season + zh-titles + import resolution**, not just suggestions — see spec §2.4 and open question Q4.

---

## 2. Edge-function spec — `suggestions`

**Endpoint.** `POST {SUPABASE_URL}/functions/v1/suggestions` (source `supabase/functions/suggestions/index.ts`). Auth identical to `journal-agent`: `Authorization: Bearer <user JWT>` + `apikey`; the function builds a Supabase client with the **forwarded user JWT** so every table read runs under the caller's own RLS (no service-role key needed for v1). 401 on missing/invalid auth; 405 non-POST; CORS restricted to the app origins + `OPTIONS` preflight.

**Request body** (validated like journal-agent's `:115-213` block):
```json
{
  "mediaType": "movie" | "tv",
  "mode": "suggestions" | "backfill",
  "page": 1,
  "poolSlots": { "similar": 3, "taste": 4, "trending": 2, "variety": 2, "friend": 1 },
  "locale": "en-US" | "zh-CN",
  "sessionExcludeIds": ["tmdb_603"]
}
```
`poolSlots` optional (server defaults = `DEFAULT_POOL_SLOTS`); `sessionExcludeIds` optional, capped (e.g. 200) — carries only the *session-local* consumed/bookmarked-this-minute ids; the durable exclusions are computed server-side.

**Server-side computation (all of §1.3 moves in):**
1. Read the caller's rankings + watchlist under their JWT: movie mode → `user_rankings` + `watchlist_items`; tv mode → `tv_rankings` + `tv_watchlist_items` (select `tmdb_id, show_tmdb_id, title, year, genres, tier, director/creator`). Build `excludeIds` (**normalizing both `tmdb_{n}` and bare `{n}` movie forms, and expanding TV season ids to show ids**, fixing B1's leak class at the server boundary), `excludeTitles`, and the ephemeral `TasteProfile` (§1.5 semantics verbatim, including the 3-ranking threshold and per-media genre tables of §1.4).
2. Run the pools against TMDB with `TMDB_API_KEY` from the function secret store (`Deno.env.get`), `language` from `locale`. Preserve behavior quirks: overfetch `+2`/`+1`, random similar-pick, taste-page jitter, variety page-1 jitter, coin-flip decade, take-order + numeric dedup + refill-without-friend + final shuffle, backfill cap 20.
3. Friend pool via the same user-scoped client (RLS enforces follow visibility exactly as today).

**Response** `200`:
```json
{
  "items": [{
    "id": "tmdb_603", "tmdbId": 603, "title": "The Matrix", "year": "1999",
    "posterUrl": "https://image.tmdb.org/t/p/w500/…", "backdropUrl": null,
    "mediaType": "movie", "genres": ["Action", "Sci-Fi"], "overview": "…",
    "voteAverage": 8.2, "seasonCount": 0,
    "pool": "similar" | "taste" | "trending" | "variety" | "friend" | "generic" | "backfill"
  }],
  "totalRanked": 42
}
```
`suggestions` mode ≤12, `backfill` ≤20. `pool` is new provenance metadata (free to emit now that assembly is server-side; web ignores it, iOS may use it — Q5). TV items reuse the same shape with `id: "tv_{showId}"`, `mediaType: "tv"`, `seasonCount`. Errors: 400 validation, 401 auth, 502 `{ "error": "TMDB upstream …" }` (do not echo upstream bodies), 500 catch-all.

**Caching.** Do **not** cache the composed response per user — randomness-on-refresh is the product behavior. v1: cache nothing, add a per-user token bucket (e.g. 30 req/min, in-memory per isolate) to protect TMDB quota. v2 option: URL-keyed upstream cache (`trending`/`discover` pages, 6-24h TTL) in a `tmdb_response_cache` table, since those endpoints dominate quota and are user-independent. `user_taste_profiles` is NOT used as a cache in v1 — the rankings read is already required for exclusions, and profile math over ≤a-few-hundred rows is microseconds; **recommend dropping the trigger/table cluster** (B4) rather than migrating to it.

**What stays client-side.** Rendering; the consume-one/refill-from-backfill choreography (client keeps the ≤20 backfill pool it got from `mode:"backfill"` and re-requests when <3 remain); the render-time `isAlreadyOwned` safety net for same-session bookmarks; Refresh = `page+1` re-request of both modes. Web migration: `AddMediaModal`/`AddTVSeasonModal`/`MovieOnboardingPage` swap `getSmartSuggestions/Backfill` + `buildTasteProfile` calls for two `functions.invoke('suggestions')` calls; `getGenericSuggestions` callers ride the same endpoint (server applies the threshold). iOS: one `SuggestionsClient` mirroring `JournalAgentClient`'s invoke pattern; delete `TMDBService.getGenericSuggestions` (keep fixtures fallback when signed out).

**2.4 Companion `tmdb-proxy` (required for the program DoD "key absent from both bundles").** The suggestions function alone leaves the key in search/details/localization paths (§1.6). Ship a thin authenticated GET passthrough `GET /functions/v1/tmdb-proxy?path=…` with an **allowlist**: `search/movie`, `search/tv`, `search/person`, `movie/{id}` (+`append_to_response=watch/providers,credits`), `movie/{id}/similar|recommendations` (used only by the suggestions fn — optional here), `tv/{id}`, `tv/{id}/season/{n}`, `person/{id}`, `person/{id}/movie_credits`, `trending/*`, `discover/*`; same JWT auth, same rate limit, 5s upstream timeout, path traversal rejected. Whether this lands in C3 or later is Q4 — until it does, `hasTmdbKey()` gating (`tmdbService.ts:80-82`) and both bundles keep the key.

---

## 3. Findings

### Blocking

**B1 — Split `tmdb_id` formats corrupt exclusions and can duplicate watchlist rows.**
The canonical movie id is `tmdb_{n}` (`tmdbService.ts:99`; confirmed by the 2026-04-08 tech spec §1), but Letterboxd import writes **bare** `String(entry.tmdbId)` into both `user_rankings` and `watchlist_items` (`letterboxdImportService.ts:424,461`), and the dead activity path writes a third `manual:{slug}` form (`activityService.ts:267`). Consequences, all live code: (a) engine exclusion `excludeIds.has(m.id)` (`tmdbService.ts:320`) misses bare-id rankings → **already-ranked/watchlisted movies come back as suggestions**, with only the English-title net as backstop — which itself no-ops in zh locale because pools return zh titles (`:17-21`); (b) `buildTasteProfile`'s `/tmdb_(\d+)/` (`:232`) drops bare ids → import-only users get an empty Similar pool and generic backfill forever; (c) `getFriendSuggestionPicks` returns the friend's raw id (`:284`) — clicking one propagates the bare format into the viewer's rankings; (d) `getFriendRecommendations`/`getTrendingAmongFriends` compare raw strings across users (`tasteService.ts:253`) → cross-format false negatives; (e) `DiscoverView.normalizeTmdbId` (`DiscoverView.tsx:27-29`) saves the `tmdb_` form even when the user's bare-form row exists → two `watchlist_items` rows for the same movie (UNIQUE key can't help across formats).
*Fix:* normalize at write time (import prefixes `tmdb_`), one-shot backfill `UPDATE … SET tmdb_id = 'tmdb_' || tmdb_id WHERE tmdb_id ~ '^\d+$'` on `user_rankings`/`watchlist_items` (+ dependents: journal_entries, movie_stubs written by import — verify before running), and the edge function normalizes both forms defensively (§2). Owner ack required for the data migration (Q3).

**B2 — UniversalSearch TV save mints corrupt rows; ranking them writes season-less `tv_rankings`.**
`handleSearchSaveTV` (`RankingAppPage.tsx:1341-1352`) builds the WatchlistItem **without `showTmdbId`** (and with un-normalized compound genres); `addToTVWatchlist` then stores `show_tmdb_id: 0` (`:675`). Ranking that row later: `rankFromWatchlist` (`:729-747`) passes `showTmdbId: 0`, which fails AddTVSeasonModal's show-level check `preselectedItem.showTmdbId && !seasonNumber` (`AddTVSeasonModal.tsx:206`) and falls into the direct-to-tier branch (`:217-222`) — the ceremony then persists a `tv_rankings` row with `tmdb_id = "tv_{showId}"` (no `_s{n}`), `show_tmdb_id = 0`, `season_number = 0` (`RankingAppPage.tsx:760-762`), violating the season id contract every downstream consumer assumes (taste profile `:1538`, stubs, C5 id handling). Contrast the in-modal bookmark path which sets `showTmdbId` correctly (`AddTVSeasonModal.tsx:169-183`).
*Fix:* set `showTmdbId: show.tmdbId` (+ `normalizeTVGenres`) in `handleSearchSaveTV`; defensively route any `show_tmdb_id=0`/`seasonNumber`-less item through season selection (match on the id pattern instead of the int column); audit prod for existing `tv_rankings.tmdb_id !~ '_s\d+$'` rows.

**B3 — Watchlist RLS gaps: missing UPDATE policy on the write path, and a 3-way visibility asymmetry that already breaks shipped iOS code.**
(a) `watchlist_items` has no UPDATE policy (`supabase_schema.sql:146-148`) while `addToWatchlist` writes with merge-duplicates upsert (`RankingAppPage.tsx:633-642`): whenever the client-side pre-check is stale (second device/tab, B1's dual-format rows), the upsert's ON CONFLICT DO UPDATE is RLS-denied → save fails with revert+toast for an item the user legitimately re-added. tv/book tables have the policy (`supabase_tv_rankings.sql:105-108`, `supabase_book_rankings.sql:109-112`); movie is the odd one out. (b) Movie watchlist SELECT is owner-only while tv/book are follower-visible — and iOS `TasteRepository.getRecommendationsForFriend` **already reads the target's `watchlist_items`** for its exclusion (`ios/.../TasteRepository.swift:123-127`): under owner-only RLS that read silently returns 0 rows, so TwinScreen recommends movies already on the friend's watchlist. One of the two sides must move (Q2).
*Fix:* add the owner UPDATE policy to `watchlist_items` (small migration); adjudicate visibility — either add the follower SELECT policy (matching tv/book, and making the iOS exclusion actually work) or declare movie watchlists private and change iOS to drop the target-watchlist exclusion.

**B4 — `trg_recompute_taste` burns O(tier-size) full recomputes per rank into tables nothing reads.**
FOR EACH ROW trigger on `user_rankings` (`supabase_smart_suggestions.sql:312-316`) calls a SECURITY DEFINER full-profile recompute (`:100-287`) per affected row; every ceremony upserts the entire tier (`RankingAppPage.tsx:497-521`) and Letterboxd imports batch 50-row upserts (`letterboxdImportService.ts:439-441`), so a single rank fires N recomputes and an import fires hundreds — each iterating all the user's rankings and joining `movie_credits_cache`, which has **no writer anywhere**, so the profiles being written are skeletons (genres/directors/actors empty; only `top_movie_ids`/`total_ranked` populated — and `replace(tmdb_id,'tmdb_','')::int` **throws on `manual:` ids**, `:142`, making any future manual-id ranking row abort its trigger). No client reads the result (§ premise 1).
*Fix (small migration):* drop `trg_recompute_taste`, `trigger_recompute_taste`, `recompute_taste_profile`; drop or park `user_taste_profiles`/`movie_credits_cache` per Q1. The edge function computes profiles per request (§2) and does not need them.

**B5 — Rank-from-watchlist deletes the watchlist row even when the ranking save failed.**
`addItem` swallows its upsert error (`RankingAppPage.tsx:516-519`, toast + `return` with a `void` signature), then `handleAddItem` unconditionally runs `removeFromWatchlist(preselectedForRank.id)` (`:1204-1206`). Net: a transient save failure destroys the user's bookmark — the item is in neither list (the optimistic tier-state insert also survives until reload, masking it). TV (`addTVItem`→`persistTVRankings` logs only, `:779-784`; `handleAddTVItem :1192-1197`) and book (`:1183-1190`) paths have the same shape. This exact flow is what iOS C3 will port.
*Fix:* return success from `addItem`/`addTVItem`/`addBookItem` and only delete the watchlist row on success (and only after `onAdd` resolves, which is already the ordering).

### Deferred

**D1 — Friend-pool sampling bias.** `.limit(100)` with no ORDER BY (`tmdbService.ts:270`, `:1578`) — Postgres returns an arbitrary 100 of friends' S/A rows; heavy-friend graphs never see the tail. Server-side fix in the edge function (order by random() or created_at desc).
**D2 — Friend picks never refill leftover slots.** `remaining` omits the friend pool (`:450`, `:1827`) — quirk to preserve or consciously change in the port.
**D3 — No stale-request guard on suggestion loads.** Rapid Refresh can settle out of order (`AddMediaModal.tsx:109-133`); search has the guard (`:229`), suggestions don't. Also `AddTVSeasonModal`'s suggestion promises lack `.catch` (`:147-156`) — harmless today because the service catches internally.
**D4 — Variety pool ignores `page`; taste-page jitter can exceed `total_pages`.** (`tmdbService.ts:407`, `:1784`; `:365`) Refresh re-randomizes rather than paginates variety; out-of-range pages return empty results (handled). Decide preserve-vs-fix in the edge function.
**D5 — `handleSearchSaveTV` stores raw compound TV genres** (`RankingAppPage.tsx:1347`) where every other TV write stores `normalizeTVGenres` output (`AddTVSeasonModal.tsx:178`, `:327`); `classifyBracket` at rank time won't recognize compound names. Sub-item of B2's fix.
**D6 — Whole-show bookmarks write `season_number: 0`, not the schema-documented NULL** (`RankingAppPage.tsx:676` vs `supabase_tv_rankings.sql:70`). All readers treat 0 as falsy so it works; iOS must replicate "0 or NULL = whole show" — document in the contract doc, or migrate to NULL.
**D7 — Dead code cluster (W0.3 overlap):** `SharedWatchlistView` + `shared_watchlists/*` tables (zero importers), `saveActivityMovieToWatchlist`/`rankActivityMovie` (`activityService.ts:261-330`, zero callers, `manual:` id minters), `getMediaSocialStats` reading never-written `watchlist_add`/`review_add` event types (`tasteService.ts:559-560` — the CHECK constraint doesn't even allow them), 5 `@deprecated` tmdbService exports (`:599,669,759,947,1040`). Do not port any of it.
**D8 — `user_taste_profiles` follower-SELECT grant is unused** (`supabase_smart_suggestions.sql:66-75`); if B4 keeps the table, tighten to owner-only until a feature needs it.
**D9 — `movie_credits_cache` is world-writable by any authenticated user** (`:27-37`) — cache-poisoning surface should it ever gain a consumer; moot if B4 drops it.
**D10 — Bookmarks are socially invisible.** No `watchlist_add` activity event exists (CHECK constraint excludes it, `supabase_phase5_social_feed.sql:8-10`), yet `MediaDetailModal` renders a "bookmarked" activity row that can never occur (`MediaDetailModal.tsx:523`). Product decision, not a bug.
**D11 — `useLocalizedWatchlist` fires doomed TMDB calls for book ids.** `fetchChineseTitles` treats `ol_*` ids as movies (`useLocalizedItems.ts:52-59`) → guaranteed 404 per book per cache miss; localStorage title cache is unbounded (`:22-24`). C6 territory.
**D12 — Watchlist date rendering hardcodes `en-US`** (`Watchlist.tsx:29`) — i18n miss; and the list has no pagination (fine at current scale, note for iOS).
**D13 — "Trending among friends" keys on whole-tier `updated_at` churn** (`tasteService.ts:334` vs `RankingAppPage.tsx:513`) — any ceremony bumps the entire tier, so stale rankings "trend". Fix candidate: key on `created_at` or on activity_events.
**D14 — Friend-pick fallback ids collide on 0.** `parseInt(...)||0` (`tmdbService.ts:285`) — two unparseable ids dedup to one; cosmetic today.

---

## 4. iOS gap list

iOS has **zero watchlist and zero discover/suggestions code** beyond: `TMDBService.getGenericSuggestions` (generic pool only, onboarding, bundled key — `ios/.../TMDBService.swift:29-49`) and `TasteRepository.getRecommendationsForFriend`'s broken watchlist read (B3). No repository, model, or screen exists for watchlists, the Discover tab, or the 5-pool engine.

Needed for C3:
1. **`WatchlistRepository`** — 3 tables, §1.1 contract: upsert-on-`(user_id,tmdb_id)` (after B3's UPDATE-policy fix), delete by pair, list ordered `added_at desc`; id formats `tmdb_{n}` / `tv_{showId}[_s{n}]` / `ol_{key}`; TV whole-show rows `season_number 0-or-NULL` (D6); never trust `show_tmdb_id=0` rows (B2).
2. **Watchlist tab UI** — poster grid, Rank It / Remove actions, per-vertical switch (movies live in C3; tv/book tabs can land with C5 but the repository should be media-complete now).
3. **Rank-from-watchlist** — chain into the existing `PlacementSession`/`RankPersistence` flow; delete the watchlist row **only on confirmed rank save** (B5's corrected semantics, not the shipped web behavior); whole-show TV bookmarks route through season selection.
4. **`SuggestionsClient`** — `functions.invoke('suggestions')` per §2 (both modes), client-side consume/refill choreography (§1.3), render-time owned-filter; fixtures fallback when signed out. Retire the Info.plist TMDB key when the proxy (Q4) lands.
5. **Discover screen** — decision-dependent (Q6): DiscoverView port is Supabase-only (friend recs + trending, §1.2 — thin repository work, no TMDB), the suggestion grid is edge-function work.
6. **Fix `TasteRepository.getRecommendationsForFriend`** per the B3 adjudication.
7. Contract-doc updates (`docs/contracts/shared-payloads.md`): watchlist row shapes (all 3 tables), the suggestions request/response JSON, id-format canon (`tmdb_` prefix) post-B1.

## 5. Open questions

1. **Is `trg_recompute_taste` applied in prod?** (Migration files here aren't timestamped/tracked.) If yes, B4's drop migration is a prerequisite for not doubling write cost under the C3 cycle; if no, the drop is just file cleanup. Verify with `select tgname from pg_trigger where tgrelid = 'user_rankings'::regclass` before the fix PR.
2. **Movie watchlist visibility (B3b):** follower-visible (align with tv/book, unblocks the iOS Twin exclusion) or owner-only (privacy-first; change iOS)? Owner adjudication needed — it changes what friends can see.
3. **B1 data migration:** ack the one-shot bare→`tmdb_` UPDATE across `user_rankings`/`watchlist_items` (+ verify `journal_entries`/`movie_stubs` rows written by import share the bare format and migrate them consistently), or accept dual-format-forever with normalization at every boundary.
4. **Does C3 ship the `tmdb-proxy` (§2.4)?** The program DoD ("TMDB key absent from both client bundles") is unreachable with the suggestions function alone — search/details/zh-titles/CastSelector/import still hold the key. Recommend: yes, same PR as the suggestions function; it's ~100 lines.
5. **Pool provenance in UI:** the response now carries `pool` per item — does iOS Discover/suggestions design want provenance chips ("Friends loved", "Because you ranked X"), or keep web's undifferentiated grid?
6. **What is "Discover" on iOS?** Web has two disjoint surfaces (§ premise 2): the social Discover tab (friend recs/trending, no engine) and the in-ceremony suggestion grid (the engine). Does C3 build both, merge them into one iOS Discover surface, or port the tab as-is and keep the engine inside the rank flow?
7. **Generic-vs-smart threshold ownership:** with the engine server-side, `SMART_SUGGESTION_THRESHOLD = 3` becomes server config. Fine to hard-code, or does the owner want it tunable per media type (TV currently shares the movie threshold)?
