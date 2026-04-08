# Discover Surface — Technical Spec

**Date:** 2026-04-08
**Branch (proposed):** `feature/discover-surface`
**Parent doc:** `~/.gstack/projects/BIBOYANG425-Movie_List/mac-feature-smart-suggestions-launch-design-20260408-005801.md`
**Siblings:** `2026-04-08-discover-ui-spec.md`, `2026-04-08-discover-copy-spec.md`, `2026-04-08-discover-rollout.md`

---

## 1. Existing state (what's already built)

### Code that exists and is correct
- `services/tmdbService.ts::buildTasteProfile()` — client-side taste profile from generic ranked items. Takes `{id, genres, year, tier, director?}[]`. Works for movies today, could work for anything with those fields. Watch out: it extracts `topMovieIds` with the regex `/tmdb_(\d+)/`, which is movie-specific.
- `services/tmdbService.ts::getSmartSuggestions()` — returns `TMDBMovie[]` from 5 pools in parallel (Similar, Taste, Trending, Variety, Friend). Hardcoded to movie TMDB endpoints.
- `services/tmdbService.ts::getSmartBackfill()` — replenishes exhausted suggestion slots. Movie-only.
- `services/tmdbService.ts::getFriendSuggestionPicks()` — queries `user_rankings` directly for S/A from followed users. Movie-only.
- `services/tmdbService.ts::getGenericSuggestions()` — cold-start fallback for `totalRanked < SMART_SUGGESTION_THRESHOLD` users. Movie-only.

### DB that exists
- `movie_credits_cache(tmdb_id, directors, top_cast, genres, runtime, release_year, fetched_at)`
- `user_taste_profiles(user_id, weighted_genres, top_directors, top_actors, decade_distribution, avg_runtime, underexposed_genres, top_movie_ids, total_ranked, updated_at)` — **movie-shaped. Columns like `top_movie_ids` and `avg_runtime` don't map to books at all.**
- RPC `recompute_taste_profile(target_user_id uuid)` — joins `user_rankings` to `movie_credits_cache`. Movie-only.
- Trigger `trg_recompute_taste` on `user_rankings` — fires on INSERT/UPDATE/DELETE.

### Schema facts that shape the design
- `user_rankings.tmdb_id` is `"tmdb_{movieId}"` (e.g. `tmdb_603`)
- `tv_rankings.tmdb_id` is `"tv_{showId}_s{seasonNum}"` (e.g. `tv_1396_s1`) — **compound. Rankings are per season, not per show.**
- `tv_rankings.show_tmdb_id` is the pure integer show ID
- `book_rankings.tmdb_id` is `"ol_{workKey}"` (e.g. `ol_OL27448W`) — **Open Library, not TMDB. No integer equivalent.**

## 2. Design principles for the technical changes

1. **Extend, don't replace.** The movie taste engine works. We add parallel structures for TV and books, not a polymorphic rewrite.
2. **Accept duplication for clarity.** Two parallel tables (`tv_credits_cache`, plus a books-specific shape) is easier to reason about than one polymorphic media cache.
3. **Books degrade gracefully.** Open Library has no credits equivalent. Book pools will be thinner than movie/TV pools. Accept this in the schema.
4. **The output of `getSmartSuggestions*` functions stays typed.** A unified `DiscoverItem` type covers all three media; the internals stay split by media.
5. **No new TMDB API calls.** We reuse the movie endpoints already wired (`/similar`, `/discover/movie`, `/trending/movie/week`) and their TV equivalents.
6. **No new book API calls beyond what Open Library already supports.** The existing `services/openLibraryService.ts` is the only book data source.

## 3. New unified types

Add to `types.ts`:

```typescript
// The user-facing item shown on Discover. Media-agnostic.
export interface DiscoverItem {
  id: string;                       // "tmdb_603", "tv_1396_s1", "ol_OL27448W"
  mediaType: 'movie' | 'tv' | 'book';
  title: string;
  year: string;
  posterUrl: string | null;
  genres: string[];
  overview: string;

  // Pool origin — drives the per-pool reasoning line
  poolType: 'similar' | 'taste' | 'trending' | 'variety' | 'friend';
  poolReason?: string;              // e.g. "Because you loved Past Lives"

  // Media-specific extras (optional, used by cards for extra info)
  director?: string;                // movies
  creator?: string;                 // tv
  seasonNumber?: number;            // tv
  author?: string;                  // books
  pageCount?: number;               // books
  runtime?: number;                 // movies
}

// A single pool's worth of results, pre-merge.
export interface PoolResult {
  type: 'similar' | 'taste' | 'trending' | 'variety' | 'friend';
  mediaType: 'movie' | 'tv' | 'book';
  items: DiscoverItem[];
  sourceLabel?: string;             // e.g. "Because you loved Past Lives"
}

// The unified taste profile. Extends the existing TasteProfile shape
// with TV and book signal, and adds per-media top item ID arrays.
export interface UnifiedTasteProfile {
  // Shared signal (union across media types)
  weightedGenres: Record<string, number>;
  decadeDistribution: Record<string, number>;
  preferredDecade: string | null;
  underexposedGenres: string[];

  // Per-media top picks (for /similar queries)
  topMovieIds: number[];            // pure TMDB IDs
  topTvShowIds: number[];           // pure TMDB show IDs (from show_tmdb_id)
  topBookWorkKeys: string[];        // Open Library work keys (without "ol_" prefix)

  // Per-media rank counts (for cold-start thresholding)
  totalMoviesRanked: number;
  totalTvRanked: number;
  totalBooksRanked: number;
  totalRanked: number;              // sum of the above

  // Director (movies) and creator (tv) signal
  topDirectors: { name: string; score: number }[];
  topCreators: { name: string; score: number }[];
  topAuthors: { name: string; score: number }[];
}
```

## 4. Database changes

### 4a. New table: `tv_credits_cache`

Mirror `movie_credits_cache` but keyed on show+season.

```sql
CREATE TABLE IF NOT EXISTS tv_credits_cache (
  tv_key          text PRIMARY KEY,           -- "tv_{showId}_s{seasonNum}"
  show_tmdb_id    integer NOT NULL,
  season_number   integer NOT NULL,
  creators        jsonb NOT NULL DEFAULT '[]',
  top_cast        jsonb NOT NULL DEFAULT '[]',
  genres          text[] NOT NULL DEFAULT '{}',
  episode_count   integer,
  first_air_year  integer,
  fetched_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tv_credits_cache_show ON tv_credits_cache(show_tmdb_id);
CREATE INDEX IF NOT EXISTS idx_tv_credits_cache_fetched_at ON tv_credits_cache(fetched_at);

ALTER TABLE tv_credits_cache ENABLE ROW LEVEL SECURITY;

CREATE POLICY "tv_credits_cache_select" ON tv_credits_cache FOR SELECT USING (true);
CREATE POLICY "tv_credits_cache_insert" ON tv_credits_cache FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "tv_credits_cache_update" ON tv_credits_cache FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
```

### 4b. No `book_credits_cache`

Books don't have a credits equivalent. Author is already on `book_rankings.author`. Subject tags are on `book_rankings.genres`. No cache needed.

### 4c. Extend `user_taste_profiles`

Add columns (nullable / defaulted) to carry TV and book signal without breaking the existing movie-only shape.

```sql
ALTER TABLE user_taste_profiles
  ADD COLUMN IF NOT EXISTS top_tv_show_ids integer[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS top_book_work_keys text[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS top_creators jsonb NOT NULL DEFAULT '[]',
  ADD COLUMN IF NOT EXISTS top_authors jsonb NOT NULL DEFAULT '[]',
  ADD COLUMN IF NOT EXISTS total_movies_ranked integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_tv_ranked integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_books_ranked integer NOT NULL DEFAULT 0;
```

**`total_ranked` is kept as a derived sum** (computed by the RPC on each recompute). Existing code reading it still works.

### 4d. Rewrite `recompute_taste_profile` RPC

The RPC expands to pull from all three ranking tables. Pseudocode:

```sql
CREATE OR REPLACE FUNCTION recompute_taste_profile(target_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_movies_count integer;
  v_tv_count integer;
  v_books_count integer;
BEGIN
  SELECT count(*) INTO v_movies_count FROM user_rankings WHERE user_id = target_user_id;
  SELECT count(*) INTO v_tv_count     FROM tv_rankings   WHERE user_id = target_user_id;
  SELECT count(*) INTO v_books_count  FROM book_rankings WHERE user_id = target_user_id;

  IF (v_movies_count + v_tv_count + v_books_count) = 0 THEN
    DELETE FROM user_taste_profiles WHERE user_id = target_user_id;
    RETURN;
  END IF;

  -- Weighted genres: union of movie + tv + book genres, tier-weighted
  --   (movies/tv/books all have a text[] genres column and a tier column)
  --
  -- Decade distribution: union of movie release_year + tv first_air_year + book year
  --
  -- Director/creator/author signals: from the three credits sources
  --   (movies via movie_credits_cache.directors,
  --    tv via tv_credits_cache.creators,
  --    books via book_rankings.author directly)
  --
  -- Underexposed genres: genres from a unified ALL_GENRES list not present
  --   with >=2 rankings across any media type
  --
  -- top_movie_ids: S/A from user_rankings
  -- top_tv_show_ids: S/A from tv_rankings (dedupe by show_tmdb_id)
  -- top_book_work_keys: S/A from book_rankings

  -- ...upsert into user_taste_profiles with all populated columns

  UPDATE user_taste_profiles
  SET total_movies_ranked = v_movies_count,
      total_tv_ranked     = v_tv_count,
      total_books_ranked  = v_books_count,
      total_ranked        = v_movies_count + v_tv_count + v_books_count,
      updated_at          = now()
  WHERE user_id = target_user_id;
END;
$$;
```

Full SQL is written during implementation, not in this spec. The shape and inputs are fixed here.

### 4e. Triggers on TV and book tables

Add parallel triggers:

```sql
CREATE TRIGGER trg_recompute_taste_tv
  AFTER INSERT OR UPDATE OR DELETE ON tv_rankings
  FOR EACH ROW EXECUTE FUNCTION trigger_recompute_taste();

CREATE TRIGGER trg_recompute_taste_books
  AFTER INSERT OR UPDATE OR DELETE ON book_rankings
  FOR EACH ROW EXECUTE FUNCTION trigger_recompute_taste();
```

The existing `trigger_recompute_taste()` already reads `user_id` from `OLD` or `NEW` — it works unchanged for TV and book tables because both have `user_id` columns.

### 4f. Backfill existing users

After migration runs, trigger a one-time recompute for all existing taste profiles:

```sql
-- One-shot backfill: recompute every existing user's profile so TV and book signal land.
DO $$
DECLARE
  u uuid;
BEGIN
  FOR u IN SELECT DISTINCT user_id FROM (
    SELECT user_id FROM user_rankings
    UNION SELECT user_id FROM tv_rankings
    UNION SELECT user_id FROM book_rankings
  ) src
  LOOP
    PERFORM recompute_taste_profile(u);
  END LOOP;
END $$;
```

## 5. New service module: `services/discoverService.ts`

A new file, not an extension of `tmdbService.ts`. Rationale: `tmdbService` is already 500+ lines. A dedicated module for Discover keeps the 5-pool orchestration code separate from raw TMDB wrappers.

### Public API

```typescript
// Core entry point the DiscoverView calls.
export async function getDiscoverFeed(
  userId: string,
  options?: {
    mediaFilter?: 'all' | 'movie' | 'tv' | 'book';
    seed?: string;                   // for deterministic shuffle per day
  }
): Promise<{
  pools: PoolResult[];
  profile: UnifiedTasteProfile;
}>;

// Load the unified taste profile (Supabase-backed).
export async function loadTasteProfile(userId: string): Promise<UnifiedTasteProfile>;

// Per-media pool builders (testable in isolation, used by getDiscoverFeed).
export async function buildMoviePools(profile: UnifiedTasteProfile, excludeIds: Set<string>): Promise<PoolResult[]>;
export async function buildTvPools(profile: UnifiedTasteProfile, excludeIds: Set<string>): Promise<PoolResult[]>;
export async function buildBookPools(profile: UnifiedTasteProfile, excludeIds: Set<string>): Promise<PoolResult[]>;
```

### Internal behavior of `getDiscoverFeed`

1. Load the user's `UnifiedTasteProfile` from `user_taste_profiles`.
2. Load `excludeIds` — the set of items the user has already ranked or added to a watchlist (query all three ranking tables + all three watchlist tables).
3. Decide which media pools to build based on `mediaFilter`.
4. Fire all pool builders in parallel via `Promise.allSettled`. One pool failing must not break the whole response.
5. Apply a seeded shuffle per pool using `seed || (userId + todayYYYYMMDD)`. Deterministic for the day.
6. Return pools in a fixed visual order: Friend → Similar → Taste → Trending → Variety. (Friend is the most emotionally resonant; Variety is the most "explore new things" and goes last.)

### Pool composition rules (per media type)

**Movies**
| Pool | Source | Slots |
|---|---|---|
| Similar | `/movie/{topMovieId}/similar` | 4 |
| Taste | `/discover/movie` with top 3 weighted genres + preferred decade bias | 6 |
| Trending | `/trending/movie/week` | 4 |
| Variety | `/discover/movie` with genre=underexposedGenres[0] | 4 |
| Friend | `user_rankings` S/A from followed users, not already ranked | 3 |

**TV**
| Pool | Source | Slots |
|---|---|---|
| Similar | `/tv/{topTvShowId}/similar` | 4 |
| Taste | `/discover/tv` with top genres + era | 6 |
| Trending | `/trending/tv/week` | 4 |
| Variety | `/discover/tv` with underexposed genre | 3 |
| Friend | `tv_rankings` S/A from followed users, deduped by show_tmdb_id | 3 |

**Books**
| Pool | Source | Slots |
|---|---|---|
| Similar | Open Library `subjects` from user's top author's other works (openLibraryService) | 3 |
| Taste | Open Library subject search using top weighted genres (mapped via `SUBJECT_TO_GENRE` reverse) | 5 |
| Trending | Open Library `/trending` if available; otherwise a hand-curated fallback list cached client-side | 2 |
| Variety | Open Library subject search using an underexposed genre | 2 |
| Friend | `book_rankings` S/A from followed users | 2 |

**Cold-start thresholds (per media)**
- If `total_movies_ranked < 5`: skip Similar + Taste pools for movies, promote Trending + Variety.
- Same rule for TV and books individually.
- If ALL three are <5 (new user), return pure Trending across all media types.

### `DiscoverItem` merge strategy

After all pool builders return, `getDiscoverFeed` does NOT interleave items across media types inside a single pool. Pools stay media-scoped. But the final ordering of pools in the response can mix media: e.g., the Friend pool can have a movie, a TV show, and a book in the same card row because they all originated from friend rankings.

This is intentional. A single "Friend" section showing "Alex S-tiered 3 things this month (1 movie, 1 TV show, 1 book)" is more emotionally resonant than three separate per-media Friend sections.

**The UI spec decides whether to render this as one blended section or three media-specific sections.** Both are possible from the data shape.

## 6. Exclude-set computation

The exclude set prevents Discover from recommending things the user has already interacted with. It must cover:

```typescript
const excludeIds = new Set<string>();

// Already ranked
(await supabase.from('user_rankings').select('tmdb_id').eq('user_id', userId))
  .data?.forEach(r => excludeIds.add(r.tmdb_id));
(await supabase.from('tv_rankings').select('tmdb_id').eq('user_id', userId))
  .data?.forEach(r => excludeIds.add(r.tmdb_id));
(await supabase.from('book_rankings').select('tmdb_id').eq('user_id', userId))
  .data?.forEach(r => excludeIds.add(r.tmdb_id));

// In watchlist
(await supabase.from('watchlist_items').select('tmdb_id').eq('user_id', userId))
  .data?.forEach(r => excludeIds.add(r.tmdb_id));
// (repeat for tv_watchlist_items, book_watchlist_items)
```

Optimization: fetch all 6 in parallel via `Promise.all`. Cache the exclude set in a React ref per session; re-fetch on ranking/watchlist changes (can hook into existing mutation points in `RankingAppPage`).

## 7. Daily refresh semantics

### The deterministic shuffle

```typescript
function dailySeed(userId: string): string {
  const today = new Date().toISOString().slice(0, 10);  // YYYY-MM-DD
  return `${userId}_${today}`;
}

function seededShuffle<T>(array: T[], seed: string): T[] {
  // Any stable seedable PRNG. Mulberry32 is fine, fits in ~10 lines.
  // Returns a new shuffled copy.
}
```

- Every call to `getDiscoverFeed` without an explicit `seed` computes `dailySeed(userId)`.
- Same user, same day = same feed. Refresh button (future) passes a custom seed to force a new shuffle.
- The seed affects ORDERING only, not which items are in the pool. Pool membership is determined by the recommendation algorithm; the seed just arranges them.

### Why this works for a side project

- No cron.
- No background workers.
- No new infra.
- Provides freshness without building a system.
- If the user looks at it 10 times the same day they see the same thing — that's fine, it means the feed is stable within a day.

## 8. Error handling and degradation

Every pool builder wraps its work in `try/catch`:

```typescript
async function buildMoviePools(profile, excludeIds): Promise<PoolResult[]> {
  const pools: PoolResult[] = [];

  // Each pool in its own try/catch
  try { pools.push(await buildMovieSimilarPool(profile, excludeIds)); } catch (e) { console.error('movie similar pool failed', e); }
  try { pools.push(await buildMovieTastePool(profile, excludeIds)); } catch (e) { console.error('movie taste pool failed', e); }
  // ... etc

  return pools.filter(p => p.items.length > 0);   // Hide empty pools
}
```

Empty pools are omitted from the response. The UI never shows a loading state for a pool that returned zero items — it just doesn't render that section.

An entirely empty `getDiscoverFeed` response (all pools failed, or the user has no signal + TMDB is down) triggers the DiscoverView empty state: "Rank a few things and come back — Discover needs a taste profile to work with."

## 9. Observability

- `console.error` on pool failures. Enough for a side project.
- A future improvement (not in scope): a `recs_events` table logging which pool an item came from when the user clicks → rank. This closes the feedback loop for tuning pool weights but is explicitly deferred.

## 10. Migration plan (SQL + code ordering)

1. **Migration 1:** `20260408_tv_credits_cache.sql` — new table, RLS.
2. **Migration 2:** `20260408_unified_taste_profile.sql` — ALTER `user_taste_profiles` to add TV/book columns.
3. **Migration 3:** `20260408_recompute_taste_profile_v2.sql` — CREATE OR REPLACE the RPC with multi-media logic.
4. **Migration 4:** `20260408_taste_triggers_tv_books.sql` — add triggers on `tv_rankings` and `book_rankings`.
5. **Migration 5:** `20260408_backfill_taste_profiles.sql` — one-shot DO block that recomputes every existing profile.

All five migrations should run atomically or at least in a single session during the rollout window, because the RPC change (#3) needs the new columns (#2) and the triggers (#4) need the updated RPC (#3).

Code changes land in this order, after migrations have been applied to staging:

1. Add `UnifiedTasteProfile`, `DiscoverItem`, `PoolResult` types to `types.ts`.
2. Create `services/discoverService.ts` with the public API but all pool builders returning `[]` stubs.
3. Implement movie pool builders. Test by calling `getDiscoverFeed` from a scratch file.
4. Rewrite `DiscoverView.tsx` to call `getDiscoverFeed` and render movie-only output. **Ship this as a standalone commit.** This is the smallest useful unit and closes Disconnect #1 from the master doc.
5. Implement TV pool builders. Update DiscoverView to render TV pools.
6. Implement book pool builders. Update DiscoverView to render book pools.
7. Add the per-media filter UI (handled in the UI spec).
8. Voice/copy pass (handled in the copy spec).
9. Delete unused legacy functions (`getFriendRecommendations`, `getTrendingAmongFriends`) only if no other caller remains. Otherwise leave them.

## 11. Things explicitly NOT in this spec

- Server-side rendering of Discover. Out.
- Redis or any caching layer beyond React state. Out.
- Background jobs for prefetching recommendations. Out.
- Push notifications for new Discover items. Out (it's a pull surface, not push).
- A/B testing different pool weights. Out.
- Per-user pool preferences (e.g., "hide the Trending pool"). Out. Defer until there's evidence anyone wants it.
- Logging recommendation → ranking conversion for training. Out. Listed as a future improvement in §9.

## 12. Open questions that need answers before implementation

1. **Should `tv_credits_cache` store per-show or per-season?** Current design is per-season (keyed on `tv_{showId}_s{seasonNum}`) to match `tv_rankings`. But the TMDB `/tv/{id}/credits` endpoint returns show-level data, not season-level. **Recommendation:** cache at show level, keyed on `show_tmdb_id`, and let the taste profile dedupe by show when computing signal. Rewrite this section during implementation if that turns out to be cleaner.

2. **Open Library's rate limits for book pools.** Open Library has no stated hard limit but is community-hosted. **Recommendation:** batch book pool requests sequentially, not in parallel, and cache results in a Supabase `book_recommendations_cache` table (scoped by subject) if the API feels fragile.

3. **Book Trending pool has no natural source.** Open Library doesn't have a `/trending` endpoint. **Recommendation:** ship the book Trending pool as an empty-until-data stub. Hide the row if empty. Revisit later with NYT Bestsellers API or curated client-side list.

4. **Dedup across media (same title in two media)?** If the user has ranked the Dune movie AND the Dune book, and the Friend pool recommends the Dune TV show, that's fine — different media types. No dedup by title.

5. **Taste profile staleness.** The trigger recomputes on every ranking change, which is fast for normal usage but could be slow during batch imports. **Recommendation:** accept for MVP. Add a `STATEMENT-level` trigger if batch imports become a real problem.

---

*End of technical spec. See sibling docs for UI, copy, and rollout.*
