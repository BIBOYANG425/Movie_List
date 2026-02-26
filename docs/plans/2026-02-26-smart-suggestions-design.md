# Smart Suggestion Engine — Design Document

## Problem

The current suggestion algorithm is shallow:
- Genre personalization uses raw frequency counts (top 3), ignoring tier weight
- No director/actor/theme awareness
- Documentary fallback is arbitrary
- No decade/era awareness
- No variety injection to break genre bubbles
- No friend-influenced suggestions in the add flow
- Session fatigue is a binary switch at 5 clicks

## Approach: DB-Backed Taste Engine (Approach B)

Persist a computed taste profile in Supabase, recomputed on ranking changes via trigger. Serves as a reusable primitive for suggestions, friend compatibility, year-in-review, group recommendations, and more.

---

## Database Schema

### Table: `movie_credits_cache`

Caches TMDB credits for movies anyone has ranked. Fetched lazily on first rank, reused across all users.

| Column | Type | Notes |
|--------|------|-------|
| tmdb_id | integer PK | |
| directors | jsonb | `[{id, name}]` |
| top_cast | jsonb | `[{id, name, character}]` — top 5 billed |
| genres | text[] | from TMDB |
| runtime | integer | minutes |
| release_year | integer | |
| fetched_at | timestamptz | for staleness checks |

### Table: `user_taste_profiles`

One row per user. Recomputed on ranking changes.

| Column | Type | Notes |
|--------|------|-------|
| user_id | uuid PK FK profiles | |
| weighted_genres | jsonb | `{"Action": 14.5, "Drama": 12.0}` — S=5,A=4,B=3,C=2,D=1 |
| top_directors | jsonb | `[{id, name, score}]` — top 10, tier-weighted |
| top_actors | jsonb | `[{id, name, score}]` — top 10, tier-weighted |
| decade_distribution | jsonb | `{"1970s": 8.5, "2010s": 14.0}` |
| avg_runtime | integer | weighted average runtime in minutes |
| underexposed_genres | text[] | genres with <2 rankings |
| top_movie_ids | integer[] | S/A tier tmdb IDs for /similar queries |
| total_ranked | integer | total number of ranked movies |
| updated_at | timestamptz | |

### RPC: `recompute_taste_profile(target_user_id uuid)`

Called by trigger on `user_rankings` INSERT/UPDATE/DELETE.

1. Query all user's rankings joined with `movie_credits_cache`
2. Compute tier-weighted genre scores
3. Compute tier-weighted director/actor scores from credits cache
4. Compute decade distribution from release years
5. Compute average runtime
6. Identify underexposed genres (all TMDB genres minus genres with >=2 rankings)
7. Collect S/A tier tmdb_ids
8. Upsert into `user_taste_profiles`

### Trigger: `on_ranking_change`

```sql
CREATE TRIGGER on_ranking_change
AFTER INSERT OR UPDATE OR DELETE ON user_rankings
FOR EACH ROW EXECUTE FUNCTION trigger_recompute_taste();
```

The trigger function calls `recompute_taste_profile()` for the affected user_id.

---

## Credits Cache Population

When a user ranks a movie, before the taste profile recompute:

1. Check `movie_credits_cache` for the movie's tmdb_id
2. If missing (or `fetched_at` > 30 days ago), fetch from TMDB `/movie/{id}?append_to_response=credits`
3. Extract directors (crew where job=Director), top 5 cast, genres, runtime, release year
4. Insert/update `movie_credits_cache`

This happens client-side in the service layer before the ranking insert. The cache grows organically — popular movies get cached by the first user who ranks them.

---

## Suggestion Algorithm: 5-Pool System

### `getSmartSuggestions(profile: TasteProfile, ...)`

| Pool | Slots | Source | Logic |
|------|-------|--------|-------|
| **Similar** | 3 | TMDB `/movie/{id}/similar` | Pick random movie from `top_movie_ids`, fetch similar. Captures director/actor/theme taste without explicit signals. |
| **Taste** | 4 | TMDB Discover | Top 3 weighted genres, biased toward preferred decades via `primary_release_date` ranges. Runtime filter if strong preference (e.g., user averages >130min). |
| **Trending** | 2 | TMDB `/trending/movie/week` | Current cultural relevance. |
| **Variety** | 2 | TMDB Discover | Pick from `underexposed_genres`. Deliberate bubble-breaking. |
| **Friend picks** | 1 | Supabase query | Random S/A tier movie from followed users' rankings that the current user hasn't ranked. |

Total: 12 suggestions. ~6 parallel API calls (current does 3-4).

### `getSmartBackfill(profile: TasteProfile, ...)`

Replaces `getEditorsChoiceFills`. Used to replenish suggestion slots as user consumes them.

1. Pick random movie from user's rankings (any tier)
2. Fetch TMDB `/movie/{id}/recommendations`
3. Filter out already-ranked movies
4. If insufficient results, fall back to variety discover (underexposed genres)

No more arbitrary documentary fallback.

### Cold Start (0 rankings)

Keep `getGenericSuggestions()` as-is for users with no rankings. Switch to smart suggestions once `user_taste_profiles` row exists with `total_ranked >= 3`.

---

## Session Fatigue: Adaptive Rebalancing

Replace the binary 5-click cutoff with gradual pool rebalancing based on engagement.

Track per-pool engagement in session state (not DB):

```typescript
poolEngagement: { similar: 0, taste: 0, trending: 0, variety: 0, friend: 0 }
```

When user selects a movie from a pool, increment that pool's count. On next suggestion load:
- Pools with high engagement get +1 slot (capped at 6)
- Pools with zero engagement lose 1 slot (minimum 1)
- Total always sums to 12

This means if a user keeps picking "variety" movies, the system gives them more variety. If they ignore trending, trending shrinks. Organic adaptation.

---

## Type Definitions

```typescript
interface TasteProfile {
  weightedGenres: Record<string, number>;
  topDirectors: { id: number; name: string; score: number }[];
  topActors: { id: number; name: string; score: number }[];
  decadeDistribution: Record<string, number>;
  avgRuntime: number;
  underexposedGenres: string[];
  topMovieIds: number[];
  totalRanked: number;
}

interface SuggestionPool {
  type: 'similar' | 'taste' | 'trending' | 'variety' | 'friend';
  movies: TMDBMovie[];
  sourceLabel?: string; // e.g. "Because you loved Inception"
}
```

---

## Files Changed

| File | Change |
|------|--------|
| `supabase_smart_suggestions.sql` | **new** — migration (tables, trigger, RPC) |
| `types.ts` | Add TasteProfile, SuggestionPool types |
| `services/tasteProfileService.ts` | **new** — CRUD for taste profile, credits cache population |
| `services/tmdbService.ts` | Add `getSmartSuggestions()`, `getSmartBackfill()`, `fetchAndCacheCredits()` |
| `components/AddMediaModal.tsx` | Use new suggestion functions, pass taste profile, track pool engagement |
| `pages/MovieOnboardingPage.tsx` | Same updates as AddMediaModal |
| `constants.ts` | Add `TIER_WEIGHTS`, `ALL_TMDB_GENRES`, pool slot defaults |

---

## Future Uses of Taste Profile

- Friend compatibility scores (cosine similarity of weighted genre vectors)
- Group movie recommendations (blend profiles)
- Year-in-review / taste evolution tracking
- Journal insights (correlate mood tags with taste signals)
- Onboarding: seed from followed friend's profile
- Discovery feed: "users with similar profiles loved X"
