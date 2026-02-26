# Smart Suggestion Engine — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the shallow 3-pool suggestion system with a smart 5-pool engine using tier-weighted taste profiling, and lay the DB foundation for a full taste engine (Approach B).

**Architecture:** Client-side taste profile computed from ranked items (genres, years, tiers, directors already in memory). Five suggestion pools (Similar, Taste, Trending, Variety, Friend picks) fetched in parallel from TMDB + Supabase. DB tables created now but not wired into the suggestion flow yet — future work connects the trigger-based profile to replace client-side computation.

**Tech Stack:** React, TypeScript, Supabase (PostgreSQL), TMDB API v3

---

### Task 1: Database Migration — Approach B Foundation

**Files:**
- Create: `supabase_smart_suggestions.sql`

Create the DB tables, trigger, and RPC for the taste engine. These are not wired into the suggestion flow yet — just the foundation.

**Step 1: Write the migration SQL**

Create `supabase_smart_suggestions.sql` with:

```sql
-- =============================================
-- Smart Suggestions: DB Foundation (Approach B)
-- =============================================

-- 1. Movie credits cache (shared across all users)
CREATE TABLE IF NOT EXISTS movie_credits_cache (
  tmdb_id integer PRIMARY KEY,
  directors jsonb NOT NULL DEFAULT '[]',
  top_cast jsonb NOT NULL DEFAULT '[]',
  genres text[] NOT NULL DEFAULT '{}',
  runtime integer,
  release_year integer,
  fetched_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE movie_credits_cache ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read credits cache"
  ON movie_credits_cache FOR SELECT USING (true);
CREATE POLICY "Authenticated users can insert credits cache"
  ON movie_credits_cache FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "Authenticated users can update credits cache"
  ON movie_credits_cache FOR UPDATE TO authenticated USING (true);

-- 2. User taste profiles (one per user)
CREATE TABLE IF NOT EXISTS user_taste_profiles (
  user_id uuid PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  weighted_genres jsonb NOT NULL DEFAULT '{}',
  top_directors jsonb NOT NULL DEFAULT '[]',
  top_actors jsonb NOT NULL DEFAULT '[]',
  decade_distribution jsonb NOT NULL DEFAULT '{}',
  avg_runtime integer,
  underexposed_genres text[] NOT NULL DEFAULT '{}',
  top_movie_ids integer[] NOT NULL DEFAULT '{}',
  total_ranked integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE user_taste_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read own taste profile"
  ON user_taste_profiles FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can read friends taste profiles"
  ON user_taste_profiles FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM friend_follows
      WHERE follower_id = auth.uid() AND following_id = user_taste_profiles.user_id
    )
  );
CREATE POLICY "System can upsert taste profiles"
  ON user_taste_profiles FOR ALL TO authenticated USING (auth.uid() = user_id);

-- 3. Indexes
CREATE INDEX IF NOT EXISTS idx_credits_cache_fetched ON movie_credits_cache(fetched_at);
CREATE INDEX IF NOT EXISTS idx_taste_profiles_updated ON user_taste_profiles(updated_at);

-- 4. RPC: Recompute taste profile from rankings + credits cache
CREATE OR REPLACE FUNCTION recompute_taste_profile(target_user_id uuid)
RETURNS void AS $$
DECLARE
  v_weighted_genres jsonb;
  v_top_directors jsonb;
  v_top_actors jsonb;
  v_decade_dist jsonb;
  v_avg_runtime integer;
  v_underexposed text[];
  v_top_ids integer[];
  v_total integer;
  tier_weight integer;
  all_genres text[] := ARRAY[
    'Action','Adventure','Animation','Comedy','Crime','Documentary',
    'Drama','Family','Fantasy','History','Horror','Music','Mystery',
    'Romance','Sci-Fi','TV Movie','Thriller','War','Western'
  ];
BEGIN
  -- Count total rankings
  SELECT count(*) INTO v_total
  FROM user_rankings WHERE user_id = target_user_id;

  IF v_total = 0 THEN
    DELETE FROM user_taste_profiles WHERE user_id = target_user_id;
    RETURN;
  END IF;

  -- Weighted genres: unnest genres array, weight by tier
  SELECT coalesce(jsonb_object_agg(genre, score), '{}') INTO v_weighted_genres
  FROM (
    SELECT g AS genre, sum(
      CASE ur.tier
        WHEN 'S' THEN 5 WHEN 'A' THEN 4 WHEN 'B' THEN 3
        WHEN 'C' THEN 2 WHEN 'D' THEN 1 ELSE 0
      END
    ) AS score
    FROM user_rankings ur, unnest(ur.genres) AS g
    WHERE ur.user_id = target_user_id
    GROUP BY g
  ) sub;

  -- Top directors from credits cache (tier-weighted)
  SELECT coalesce(jsonb_agg(row_to_json(sub) ORDER BY sub.score DESC), '[]') INTO v_top_directors
  FROM (
    SELECT d->>'name' AS name, (d->>'id')::int AS id,
      sum(CASE ur.tier
        WHEN 'S' THEN 5 WHEN 'A' THEN 4 WHEN 'B' THEN 3
        WHEN 'C' THEN 2 WHEN 'D' THEN 1 ELSE 0
      END) AS score
    FROM user_rankings ur
    JOIN movie_credits_cache mcc ON mcc.tmdb_id = replace(ur.tmdb_id, 'tmdb_', '')::int
    CROSS JOIN jsonb_array_elements(mcc.directors) AS d
    WHERE ur.user_id = target_user_id
    GROUP BY d->>'name', (d->>'id')::int
    ORDER BY score DESC
    LIMIT 10
  ) sub;

  -- Top actors from credits cache (tier-weighted)
  SELECT coalesce(jsonb_agg(row_to_json(sub) ORDER BY sub.score DESC), '[]') INTO v_top_actors
  FROM (
    SELECT c->>'name' AS name, (c->>'id')::int AS id,
      sum(CASE ur.tier
        WHEN 'S' THEN 5 WHEN 'A' THEN 4 WHEN 'B' THEN 3
        WHEN 'C' THEN 2 WHEN 'D' THEN 1 ELSE 0
      END) AS score
    FROM user_rankings ur
    JOIN movie_credits_cache mcc ON mcc.tmdb_id = replace(ur.tmdb_id, 'tmdb_', '')::int
    CROSS JOIN jsonb_array_elements(mcc.top_cast) AS c
    WHERE ur.user_id = target_user_id
    GROUP BY c->>'name', (c->>'id')::int
    ORDER BY score DESC
    LIMIT 10
  ) sub;

  -- Decade distribution (tier-weighted, from year column)
  SELECT coalesce(jsonb_object_agg(decade, score), '{}') INTO v_decade_dist
  FROM (
    SELECT (floor(left(ur.year, 4)::int / 10) * 10)::text || 's' AS decade,
      sum(CASE ur.tier
        WHEN 'S' THEN 5 WHEN 'A' THEN 4 WHEN 'B' THEN 3
        WHEN 'C' THEN 2 WHEN 'D' THEN 1 ELSE 0
      END) AS score
    FROM user_rankings ur
    WHERE ur.user_id = target_user_id
      AND ur.year IS NOT NULL AND length(ur.year) >= 4
    GROUP BY decade
  ) sub;

  -- Average runtime from credits cache
  SELECT round(avg(mcc.runtime))::int INTO v_avg_runtime
  FROM user_rankings ur
  JOIN movie_credits_cache mcc ON mcc.tmdb_id = replace(ur.tmdb_id, 'tmdb_', '')::int
  WHERE ur.user_id = target_user_id AND mcc.runtime IS NOT NULL;

  -- Underexposed genres (all TMDB genres minus those with >=2 rankings)
  SELECT array_agg(g) INTO v_underexposed
  FROM unnest(all_genres) AS g
  WHERE g NOT IN (
    SELECT ug FROM (
      SELECT unnest(ur.genres) AS ug, count(*) AS cnt
      FROM user_rankings ur WHERE ur.user_id = target_user_id
      GROUP BY ug HAVING count(*) >= 2
    ) exposed
  );

  -- Top movie IDs (S and A tier)
  SELECT array_agg(replace(ur.tmdb_id, 'tmdb_', '')::int) INTO v_top_ids
  FROM user_rankings ur
  WHERE ur.user_id = target_user_id AND ur.tier IN ('S', 'A');

  -- Upsert
  INSERT INTO user_taste_profiles (
    user_id, weighted_genres, top_directors, top_actors,
    decade_distribution, avg_runtime, underexposed_genres,
    top_movie_ids, total_ranked, updated_at
  ) VALUES (
    target_user_id, v_weighted_genres, v_top_directors, v_top_actors,
    v_decade_dist, v_avg_runtime, coalesce(v_underexposed, '{}'),
    coalesce(v_top_ids, '{}'), v_total, now()
  )
  ON CONFLICT (user_id) DO UPDATE SET
    weighted_genres = EXCLUDED.weighted_genres,
    top_directors = EXCLUDED.top_directors,
    top_actors = EXCLUDED.top_actors,
    decade_distribution = EXCLUDED.decade_distribution,
    avg_runtime = EXCLUDED.avg_runtime,
    underexposed_genres = EXCLUDED.underexposed_genres,
    top_movie_ids = EXCLUDED.top_movie_ids,
    total_ranked = EXCLUDED.total_ranked,
    updated_at = EXCLUDED.updated_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Trigger function (calls recompute on ranking changes)
CREATE OR REPLACE FUNCTION trigger_recompute_taste()
RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM recompute_taste_profile(OLD.user_id);
  ELSE
    PERFORM recompute_taste_profile(NEW.user_id);
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_ranking_change
AFTER INSERT OR UPDATE OR DELETE ON user_rankings
FOR EACH ROW EXECUTE FUNCTION trigger_recompute_taste();
```

**Step 2: Apply migration via Supabase MCP**

Run the SQL via `mcp__supabase__execute_sql` or `mcp__supabase__apply_migration`.

**Step 3: Verify tables exist**

Run `mcp__supabase__list_tables` and confirm `movie_credits_cache` and `user_taste_profiles` appear.

**Step 4: Commit**

```bash
git add supabase_smart_suggestions.sql
git commit -m "feat(suggestions): add DB foundation for taste engine (tables, trigger, RPC)"
```

---

### Task 2: Types and Constants

**Files:**
- Modify: `types.ts` (append after line 645)
- Modify: `constants.ts` (append after line 235)

**Step 1: Add types to `types.ts`**

Append after the last line:

```typescript
// ── Smart Suggestions ─────────────────────────────────────────────────────────

export interface TasteProfile {
  weightedGenres: Record<string, number>;
  topDirectors: { name: string; score: number }[];
  decadeDistribution: Record<string, number>;
  preferredDecade: string | null;
  underexposedGenres: string[];
  topMovieIds: number[];
  totalRanked: number;
}

export type SuggestionPoolType = 'similar' | 'taste' | 'trending' | 'variety' | 'friend';

export interface SuggestionPoolResult {
  type: SuggestionPoolType;
  movies: TMDBMovie[];
  sourceLabel?: string;
}
```

Note: `TMDBMovie` is defined in `tmdbService.ts`, not `types.ts`. The `SuggestionPoolResult` type is only used in service code that already imports `TMDBMovie`, so the import relationship is fine. Move the interface to `tmdbService.ts` instead if the TS compiler complains about the circular reference.

**Step 2: Add constants to `constants.ts`**

Append after last line:

```typescript
// ── Smart Suggestions ─────────────────────────────────────────────────────────

export const TIER_WEIGHTS: Record<Tier, number> = {
  [Tier.S]: 5,
  [Tier.A]: 4,
  [Tier.B]: 3,
  [Tier.C]: 2,
  [Tier.D]: 1,
};

export const ALL_TMDB_GENRES = [
  'Action', 'Adventure', 'Animation', 'Comedy', 'Crime', 'Documentary',
  'Drama', 'Family', 'Fantasy', 'History', 'Horror', 'Music', 'Mystery',
  'Romance', 'Sci-Fi', 'TV Movie', 'Thriller', 'War', 'Western',
];

/** Default slot distribution for the 5-pool suggestion system */
export const DEFAULT_POOL_SLOTS: Record<string, number> = {
  similar: 3,
  taste: 4,
  trending: 2,
  variety: 2,
  friend: 1,
};

/** Minimum rankings before switching from generic to smart suggestions */
export const SMART_SUGGESTION_THRESHOLD = 3;
```

**Step 3: Verify build**

Run: `npx tsc --noEmit`
Expected: No new errors.

**Step 4: Commit**

```bash
git add types.ts constants.ts
git commit -m "feat(suggestions): add TasteProfile types and suggestion constants"
```

---

### Task 3: Client-Side Taste Profile Builder

**Files:**
- Modify: `services/tmdbService.ts` (add `buildTasteProfile` function)

**Step 1: Add `buildTasteProfile` to `tmdbService.ts`**

Add after the `shuffle` helper function (after line 142), before `getGenericSuggestions`:

```typescript
import { TIER_WEIGHTS, ALL_TMDB_GENRES, DEFAULT_POOL_SLOTS, SMART_SUGGESTION_THRESHOLD } from '../constants';
import { TasteProfile } from '../types';
```

(Merge with existing imports at top of file.)

Then add the function:

```typescript
/**
 * Build a client-side taste profile from ranked items.
 * Uses tier-weighted genre scores, decade distribution, director frequency,
 * and identifies underexposed genres for variety injection.
 */
export function buildTasteProfile(items: { id: string; genres: string[]; year: string; tier: string; director?: string }[]): TasteProfile {
  if (items.length === 0) {
    return {
      weightedGenres: {},
      topDirectors: [],
      decadeDistribution: {},
      preferredDecade: null,
      underexposedGenres: [...ALL_TMDB_GENRES],
      topMovieIds: [],
      totalRanked: 0,
    };
  }

  const tierWeights: Record<string, number> = { S: 5, A: 4, B: 3, C: 2, D: 1 };

  // Tier-weighted genre scores
  const genreScores = new Map<string, number>();
  for (const item of items) {
    const w = tierWeights[item.tier] ?? 3;
    for (const g of item.genres) {
      genreScores.set(g, (genreScores.get(g) ?? 0) + w);
    }
  }

  // Decade distribution (tier-weighted)
  const decadeScores = new Map<string, number>();
  for (const item of items) {
    if (item.year && item.year.length >= 4) {
      const yr = parseInt(item.year.slice(0, 4), 10);
      if (!isNaN(yr)) {
        const decade = `${Math.floor(yr / 10) * 10}s`;
        const w = tierWeights[item.tier] ?? 3;
        decadeScores.set(decade, (decadeScores.get(decade) ?? 0) + w);
      }
    }
  }

  // Preferred decade (highest weighted score)
  let preferredDecade: string | null = null;
  let maxDecadeScore = 0;
  for (const [decade, score] of decadeScores) {
    if (score > maxDecadeScore) {
      maxDecadeScore = score;
      preferredDecade = decade;
    }
  }

  // Director frequency (tier-weighted, from director field on RankedItem)
  const directorScores = new Map<string, number>();
  for (const item of items) {
    if (item.director) {
      const w = tierWeights[item.tier] ?? 3;
      directorScores.set(item.director, (directorScores.get(item.director) ?? 0) + w);
    }
  }
  const topDirectors = [...directorScores.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10)
    .map(([name, score]) => ({ name, score }));

  // Underexposed genres (genres with < 2 rankings)
  const genreCounts = new Map<string, number>();
  for (const item of items) {
    for (const g of item.genres) {
      genreCounts.set(g, (genreCounts.get(g) ?? 0) + 1);
    }
  }
  const underexposedGenres = ALL_TMDB_GENRES.filter(g => (genreCounts.get(g) ?? 0) < 2);

  // S/A tier movie IDs for /similar queries
  const topMovieIds = items
    .filter(i => i.tier === 'S' || i.tier === 'A')
    .map(i => {
      const match = i.id.match(/tmdb_(\d+)/);
      return match ? parseInt(match[1], 10) : NaN;
    })
    .filter(id => !isNaN(id));

  return {
    weightedGenres: Object.fromEntries(genreScores),
    topDirectors,
    decadeDistribution: Object.fromEntries(decadeScores),
    preferredDecade,
    underexposedGenres,
    topMovieIds,
    totalRanked: items.length,
  };
}
```

**Step 2: Verify build**

Run: `npx tsc --noEmit`

**Step 3: Commit**

```bash
git add services/tmdbService.ts types.ts constants.ts
git commit -m "feat(suggestions): add client-side buildTasteProfile function"
```

---

### Task 4: Smart Suggestion Functions

**Files:**
- Modify: `services/tmdbService.ts` (add `getSmartSuggestions`, `getSmartBackfill`, `getFriendSuggestionPicks`)

**Step 1: Add `getFriendSuggestionPicks` to `tmdbService.ts`**

This needs Supabase access. Add after `buildTasteProfile`:

```typescript
import { supabase } from '../lib/supabase';
```

(Merge with existing imports.)

```typescript
/**
 * Fetch 1-3 random S/A-tier movies from friends that the user hasn't ranked.
 * Returns TMDBMovie-shaped objects built from user_rankings data.
 */
export async function getFriendSuggestionPicks(
  userId: string,
  excludeIds: Set<string>,
  limit: number = 2,
): Promise<TMDBMovie[]> {
  try {
    // Get friend IDs
    const { data: follows } = await supabase
      .from('friend_follows')
      .select('following_id')
      .eq('follower_id', userId);

    const friendIds = follows?.map((f: { following_id: string }) => f.following_id) ?? [];
    if (friendIds.length === 0) return [];

    // Get friends' S/A tier rankings
    const { data: friendRankings } = await supabase
      .from('user_rankings')
      .select('tmdb_id, title, poster_url, year, genres')
      .in('user_id', friendIds)
      .in('tier', ['S', 'A'])
      .limit(100);

    if (!friendRankings || friendRankings.length === 0) return [];

    // Filter out movies user already has, deduplicate, shuffle, take limit
    const candidates = friendRankings
      .filter((r: any) => !excludeIds.has(r.tmdb_id) && r.poster_url)
      .reduce((acc: any[], r: any) => {
        if (!acc.some(a => a.tmdb_id === r.tmdb_id)) acc.push(r);
        return acc;
      }, []);

    const picked = shuffle(candidates).slice(0, limit);

    return picked.map((r: any): TMDBMovie => ({
      id: r.tmdb_id,
      tmdbId: parseInt(r.tmdb_id.replace('tmdb_', ''), 10) || 0,
      title: r.title,
      year: r.year ?? '—',
      posterUrl: r.poster_url,
      type: 'movie',
      genres: r.genres ?? [],
      overview: '',
    }));
  } catch (err) {
    console.error('Friend suggestion picks failed:', err);
    return [];
  }
}
```

**Step 2: Add `getSmartSuggestions` to `tmdbService.ts`**

Add after `getFriendSuggestionPicks`:

```typescript
/**
 * Smart 5-pool suggestion system.
 * Pools: Similar (from S/A movies) | Taste (weighted genres + decade) |
 *        Trending | Variety (underexposed genres) | Friend picks
 *
 * Falls back to getDynamicSuggestions if profile has < SMART_SUGGESTION_THRESHOLD rankings.
 */
export async function getSmartSuggestions(
  profile: TasteProfile,
  excludeIds: Set<string> = new Set(),
  page: number = 1,
  excludeTitles: Set<string> = new Set(),
  userId?: string,
  poolSlots: Record<string, number> = DEFAULT_POOL_SLOTS,
): Promise<TMDBMovie[]> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;
  if (!apiKey) return [];

  // Cold start: fall back to generic
  if (profile.totalRanked < SMART_SUGGESTION_THRESHOLD) {
    return getGenericSuggestions(excludeIds, page, excludeTitles);
  }

  const isExcluded = (m: TMDBMovie) =>
    excludeIds.has(m.id) || excludeTitles.has(m.title.toLowerCase());
  const currentYear = new Date().getFullYear();

  // Top 3 weighted genres (sorted by score desc)
  const topGenres = Object.entries(profile.weightedGenres)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3)
    .map(([name]) => name);
  const genreParam = genreNamesToIds(topGenres).join(',');

  // Build all pool fetches in parallel
  const fetches: Promise<TMDBMovie[]>[] = [];

  // ─── Pool 1: Similar (from random S/A movie) ───
  const similarFetch = (async (): Promise<TMDBMovie[]> => {
    if (profile.topMovieIds.length === 0) return [];
    const pickId = profile.topMovieIds[Math.floor(Math.random() * profile.topMovieIds.length)];
    try {
      const res = await fetch(
        `${TMDB_BASE}/movie/${pickId}/similar?api_key=${apiKey}&language=en-US&page=${page}`
      );
      if (!res.ok) return [];
      const data = await res.json();
      return (data.results as any[])
        .map(mapTmdbResult)
        .filter((m): m is TMDBMovie => m !== null && !isExcluded(m))
        .slice(0, poolSlots.similar + 2); // fetch extra for dedup headroom
    } catch { return []; }
  })();
  fetches.push(similarFetch);

  // ─── Pool 2: Taste (weighted genres + decade bias) ───
  const tasteFetch = (async (): Promise<TMDBMovie[]> => {
    const url = new URL(`${TMDB_BASE}/discover/movie`);
    url.searchParams.set('api_key', apiKey);
    url.searchParams.set('language', 'en-US');
    url.searchParams.set('sort_by', 'vote_average.desc');
    url.searchParams.set('include_adult', 'false');
    url.searchParams.set('vote_count.gte', '200');
    if (genreParam) url.searchParams.set('with_genres', genreParam);

    // Decade bias: if user has a preferred decade, constrain date range
    if (profile.preferredDecade) {
      const decadeStart = parseInt(profile.preferredDecade, 10);
      if (!isNaN(decadeStart)) {
        // Mix: half the time use preferred decade, half the time use wide range
        if (Math.random() < 0.5) {
          url.searchParams.set('primary_release_date.gte', `${decadeStart}-01-01`);
          url.searchParams.set('primary_release_date.lte', `${decadeStart + 9}-12-31`);
        }
      }
    }

    url.searchParams.set('page', String(page + Math.floor(Math.random() * 3)));

    try {
      const res = await fetch(url.toString());
      if (!res.ok) return [];
      const data = await res.json();
      return (data.results as any[])
        .map(mapTmdbResult)
        .filter((m): m is TMDBMovie => m !== null && !isExcluded(m))
        .slice(0, poolSlots.taste + 2);
    } catch { return []; }
  })();
  fetches.push(tasteFetch);

  // ─── Pool 3: Trending ───
  const trendingFetch = (async (): Promise<TMDBMovie[]> => {
    try {
      const res = await fetch(
        `${TMDB_BASE}/trending/movie/week?api_key=${apiKey}&language=en-US&page=${page}`
      );
      if (!res.ok) return [];
      const data = await res.json();
      return (data.results as any[])
        .map(mapTmdbResult)
        .filter((m): m is TMDBMovie => m !== null && !isExcluded(m))
        .slice(0, poolSlots.trending + 2);
    } catch { return []; }
  })();
  fetches.push(trendingFetch);

  // ─── Pool 4: Variety (underexposed genres) ───
  const varietyFetch = (async (): Promise<TMDBMovie[]> => {
    if (profile.underexposedGenres.length === 0) return [];
    // Pick 1-2 random underexposed genres
    const pickGenres = shuffle(profile.underexposedGenres).slice(0, 2);
    const varietyGenreParam = genreNamesToIds(pickGenres).join(',');
    if (!varietyGenreParam) return [];

    const url = new URL(`${TMDB_BASE}/discover/movie`);
    url.searchParams.set('api_key', apiKey);
    url.searchParams.set('language', 'en-US');
    url.searchParams.set('sort_by', 'popularity.desc');
    url.searchParams.set('include_adult', 'false');
    url.searchParams.set('vote_count.gte', '100');
    url.searchParams.set('with_genres', varietyGenreParam);
    url.searchParams.set('page', String(1 + Math.floor(Math.random() * 3)));

    try {
      const res = await fetch(url.toString());
      if (!res.ok) return [];
      const data = await res.json();
      return (data.results as any[])
        .map(mapTmdbResult)
        .filter((m): m is TMDBMovie => m !== null && !isExcluded(m))
        .slice(0, poolSlots.variety + 2);
    } catch { return []; }
  })();
  fetches.push(varietyFetch);

  // ─── Pool 5: Friend picks ───
  const friendFetch = userId
    ? getFriendSuggestionPicks(userId, excludeIds, poolSlots.friend + 1)
    : Promise.resolve([]);
  fetches.push(friendFetch);

  // ─── Merge all pools ───
  const [similarMovies, tasteMovies, trendingMovies, varietyMovies, friendMovies] =
    await Promise.all(fetches);

  // Take exact slot counts from each pool, then fill remaining from taste
  const result: TMDBMovie[] = [];
  const used = new Set<number>();

  const take = (pool: TMDBMovie[], count: number) => {
    for (const m of pool) {
      if (result.length >= 12) break;
      if (count <= 0) break;
      if (used.has(m.tmdbId)) continue;
      used.add(m.tmdbId);
      result.push(m);
      count--;
    }
  };

  take(similarMovies, poolSlots.similar);
  take(tasteMovies, poolSlots.taste);
  take(trendingMovies, poolSlots.trending);
  take(varietyMovies, poolSlots.variety);
  take(friendMovies, poolSlots.friend);

  // If we're short of 12, backfill from any pool with remaining items
  const remaining = [
    ...tasteMovies, ...similarMovies, ...trendingMovies, ...varietyMovies,
  ];
  take(remaining, 12 - result.length);

  return shuffle(result);
}
```

**Step 3: Add `getSmartBackfill` to `tmdbService.ts`**

Add after `getSmartSuggestions`:

```typescript
/**
 * Smart backfill: TMDB recommendations for a random ranked movie.
 * Replaces getEditorsChoiceFills (no more documentary fallback).
 * Falls back to variety discover if recommendations are insufficient.
 */
export async function getSmartBackfill(
  profile: TasteProfile,
  excludeIds: Set<string> = new Set(),
  page: number = 1,
  excludeTitles: Set<string> = new Set(),
): Promise<TMDBMovie[]> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;
  if (!apiKey) return [];

  const isExcluded = (m: TMDBMovie) =>
    excludeIds.has(m.id) || excludeTitles.has(m.title.toLowerCase());

  // Cold start: fall back to old generic
  if (profile.topMovieIds.length === 0) {
    return getGenericSuggestions(excludeIds, page, excludeTitles);
  }

  let movies: TMDBMovie[] = [];

  // Try recommendations from 2 random ranked movies
  const sampleIds = shuffle(profile.topMovieIds).slice(0, 2);
  try {
    const reqs = sampleIds.map(id =>
      fetch(`${TMDB_BASE}/movie/${id}/recommendations?api_key=${apiKey}&language=en-US&page=${page}`)
        .then(r => r.ok ? r.json() : { results: [] })
    );
    const results = await Promise.all(reqs);
    for (const data of results) {
      const mapped = (data.results as any[])
        .map(mapTmdbResult)
        .filter((m): m is TMDBMovie => m !== null && !isExcluded(m));
      movies.push(...mapped);
    }
  } catch (err) {
    console.error('Smart backfill recommendations failed:', err);
  }

  movies = dedup(movies);

  // If insufficient, pad with variety discover (underexposed genres)
  if (movies.length < 12 && profile.underexposedGenres.length > 0) {
    try {
      const pickGenres = shuffle(profile.underexposedGenres).slice(0, 2);
      const varietyParam = genreNamesToIds(pickGenres).join(',');
      if (varietyParam) {
        const url = new URL(`${TMDB_BASE}/discover/movie`);
        url.searchParams.set('api_key', apiKey);
        url.searchParams.set('language', 'en-US');
        url.searchParams.set('sort_by', 'popularity.desc');
        url.searchParams.set('include_adult', 'false');
        url.searchParams.set('vote_count.gte', '100');
        url.searchParams.set('with_genres', varietyParam);
        url.searchParams.set('page', String(page));

        const res = await fetch(url.toString());
        if (res.ok) {
          const data = await res.json();
          const varietyMovies = (data.results as any[])
            .map(mapTmdbResult)
            .filter((m): m is TMDBMovie => m !== null && !isExcluded(m));
          movies = dedup([...movies, ...varietyMovies]);
        }
      }
    } catch (err) {
      console.error('Smart backfill variety fallback failed:', err);
    }
  }

  return shuffle(movies).slice(0, 20);
}
```

**Step 4: Verify build**

Run: `npx tsc --noEmit`

**Step 5: Commit**

```bash
git add services/tmdbService.ts
git commit -m "feat(suggestions): add getSmartSuggestions, getSmartBackfill, getFriendSuggestionPicks"
```

---

### Task 5: Wire AddMediaModal to Smart Suggestions

**Files:**
- Modify: `components/AddMediaModal.tsx`

**Step 1: Update imports (line 5)**

Change:
```typescript
import { searchMovies, searchPeople, getPersonFilmography, getDynamicSuggestions, getEditorsChoiceFills, hasTmdbKey, getMovieGlobalScore, TMDBMovie, PersonProfile, PersonDetail } from '../services/tmdbService';
```
To:
```typescript
import { searchMovies, searchPeople, getPersonFilmography, getSmartSuggestions, getSmartBackfill, buildTasteProfile, hasTmdbKey, getMovieGlobalScore, TMDBMovie, PersonProfile, PersonDetail } from '../services/tmdbService';
```

Also add:
```typescript
import { useAuth } from '../contexts/AuthContext';
import { DEFAULT_POOL_SLOTS, SMART_SUGGESTION_THRESHOLD } from '../constants';
```

**Step 2: Add auth + taste profile inside the component (after line 51)**

After the component function declaration, add:
```typescript
const { user } = useAuth();
```

**Step 3: Replace `getTopGenres` (lines 96-107) with `buildTasteProfile`**

Remove the `getTopGenres` function. Replace the `loadInitialSuggestions` function (lines 149-166) with:

```typescript
const loadInitialSuggestions = (page: number) => {
  if (!hasTmdbKey()) return;
  setSuggestionsLoading(true);
  setHasBackfillMixed(false);

  const excludeIds = getExcludeIds();
  const excludeTitles = getExcludeTitles();
  const profile = buildTasteProfile(currentItems);

  getSmartSuggestions(profile, excludeIds, page, excludeTitles, user?.id ?? undefined).then((results) => {
    setSuggestions(results);
    setSuggestionsLoading(false);
  });

  backfillPageRef.current = 1;
  backfillPoolRef.current = [];
  // Prefetch smart backfill
  getSmartBackfill(profile, excludeIds, 1, excludeTitles).then((results) => {
    backfillPoolRef.current = results;
  });
};
```

**Step 4: Update `prefetchBackfillPool` (lines 109-121)**

Replace with:
```typescript
const prefetchBackfillPool = (excludeIds: Set<string>, excludeTitles: Set<string>, page?: number) => {
  const profile = buildTasteProfile(currentItems);
  getSmartBackfill(profile, excludeIds, page ?? backfillPageRef.current, excludeTitles).then((results) => {
    backfillPoolRef.current = results;
  });
};
```

**Step 5: Update `handleRefreshSuggestions` (lines 168-171)**

Change to:
```typescript
const handleRefreshSuggestions = () => {
  suggestionPageRef.current += 1;
  loadInitialSuggestions(suggestionPageRef.current);
};
```

**Step 6: Remove `sessionClickCount` from suggestion calls**

The old `getDynamicSuggestions` used `sessionClickCount`. The new `getSmartSuggestions` doesn't need it (adaptive rebalancing is pool-based). Remove the `sessionClickCount` parameter from `loadInitialSuggestions` calls throughout the file.

In the `useEffect` that calls `loadInitialSuggestions` on open (around line 174+), update to just call `loadInitialSuggestions(1)` without the clicks parameter.

**Step 7: Verify build**

Run: `npx tsc --noEmit`

**Step 8: Commit**

```bash
git add components/AddMediaModal.tsx
git commit -m "feat(suggestions): wire AddMediaModal to smart 5-pool suggestion system"
```

---

### Task 6: Wire MovieOnboardingPage to Smart Suggestions

**Files:**
- Modify: `pages/MovieOnboardingPage.tsx`

**Step 1: Update imports (line 6)**

Change:
```typescript
import { getDynamicSuggestions, getEditorsChoiceFills, hasTmdbKey, searchMovies, searchPeople, getPersonFilmography, getMovieGlobalScore, TMDBMovie, PersonProfile, PersonDetail } from '../services/tmdbService';
```
To:
```typescript
import { getSmartSuggestions, getSmartBackfill, buildTasteProfile, hasTmdbKey, searchMovies, searchPeople, getPersonFilmography, getMovieGlobalScore, TMDBMovie, PersonProfile, PersonDetail } from '../services/tmdbService';
```

**Step 2: Replace `getTopGenres` (lines 126-137)**

Remove the `getTopGenres` function entirely.

**Step 3: Replace `prefetchBackfill` (lines 139-151)**

Replace with:
```typescript
const prefetchBackfill = useCallback((page?: number) => {
  const p = page ?? backfillPageRef.current;
  const profile = buildTasteProfile(rankedItems);
  getSmartBackfill(profile, getExcludeIds(), p, getExcludeTitles()).then(results => {
    backfillPoolRef.current = results;
  });
}, [getExcludeIds, getExcludeTitles, rankedItems]);
```

**Step 4: Replace `loadSuggestions` (lines 153-164)**

Replace with:
```typescript
const loadSuggestions = useCallback((page: number) => {
  if (!hasTmdbKey()) return;
  setSuggestionsLoading(true);
  const profile = buildTasteProfile(rankedItems);
  getSmartSuggestions(profile, getExcludeIds(), page, getExcludeTitles(), user?.id ?? undefined).then(results => {
    setSuggestions(results);
    setSuggestionsLoading(false);
  });
  backfillPageRef.current = 1;
  backfillPoolRef.current = [];
  prefetchBackfill(1);
}, [getExcludeIds, getExcludeTitles, prefetchBackfill, rankedItems, user?.id]);
```

**Step 5: Update the useEffect that calls `loadSuggestions` (lines 166-181)**

Change to remove `sessionClickCount` from the call:
```typescript
useEffect(() => {
  if (!loading) {
    suggestionPageRef.current = 1;
    loadSuggestions(1);
  }
}, [loading]); // eslint-disable-line react-hooks/exhaustive-deps
```

**Step 6: Update `handleRefresh` (lines 183-186)**

Change to:
```typescript
const handleRefresh = () => {
  suggestionPageRef.current += 1;
  loadSuggestions(suggestionPageRef.current);
};
```

**Step 7: Verify build**

Run: `npx tsc --noEmit`

**Step 8: Commit**

```bash
git add pages/MovieOnboardingPage.tsx
git commit -m "feat(suggestions): wire MovieOnboardingPage to smart 5-pool suggestion system"
```

---

### Task 7: Final Build Verification and Cleanup

**Files:**
- All modified files

**Step 1: Full build check**

Run: `npx vite build`
Expected: Build succeeds with no errors.

**Step 2: Check for unused imports**

Verify that `getDynamicSuggestions`, `getEditorsChoiceFills`, and `getPersonalizedFills` are no longer imported anywhere. If truly unused, add `@deprecated` JSDoc comments to those functions in `tmdbService.ts` (don't delete — they're still valid code and may be useful for reference).

**Step 3: Commit any cleanup**

```bash
git add -A
git commit -m "chore(suggestions): mark old suggestion functions as deprecated"
```

---

## Verification Checklist

1. **DB tables exist:** `movie_credits_cache` and `user_taste_profiles` via `mcp__supabase__list_tables`
2. **Build passes:** `npx vite build` succeeds
3. **TypeScript clean:** `npx tsc --noEmit` has no new errors
4. **Manual test — AddMediaModal:**
   - Open add modal with 3+ ranked movies → see diverse suggestions (not just popular movies)
   - Refresh → get different movies, not the same set
   - User with S-tier Sci-Fi movies should see sci-fi-adjacent suggestions
5. **Manual test — Onboarding:**
   - Start onboarding, rank 3+ movies → suggestions become personalized
   - Refresh works, no errors in console
6. **Manual test — Cold start:**
   - New user with 0 rankings → sees generic suggestions (popular + classics)
7. **Console:** No new errors or warnings related to TMDB calls
