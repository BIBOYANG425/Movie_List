/**
 * TMDB (The Movie Database) API service
 * Docs: https://developer.themoviedb.org/docs
 *
 * Requires environment variable: VITE_TMDB_API_KEY
 * Add to Vercel: Project Settings → Environment Variables → VITE_TMDB_API_KEY
 */

import { ALL_TMDB_GENRES, DEFAULT_POOL_SLOTS, SMART_SUGGESTION_THRESHOLD, TIER_WEIGHTS } from '../constants';
import { TasteProfile } from '../types';
import { supabase } from '../lib/supabase';

const TMDB_BASE = 'https://api.themoviedb.org/3';
const TMDB_IMAGE_BASE = 'https://image.tmdb.org/t/p/w500';
const DEFAULT_TMDB_SEARCH_TIMEOUT_MS = 4500;

/** Read the user's locale from localStorage and return the TMDB language code. */
function getTmdbLocale(): string {
  const saved = typeof localStorage !== 'undefined' ? localStorage.getItem('spool_locale') : null;
  return saved === 'zh' ? 'zh-CN' : 'en-US';
}

// Full genre map from TMDB (stable — rarely changes)
const GENRE_MAP: Record<number, string> = {
  28: 'Action',
  12: 'Adventure',
  16: 'Animation',
  35: 'Comedy',
  80: 'Crime',
  99: 'Documentary',
  18: 'Drama',
  10751: 'Family',
  14: 'Fantasy',
  36: 'History',
  27: 'Horror',
  10402: 'Music',
  9648: 'Mystery',
  10749: 'Romance',
  878: 'Sci-Fi',
  10770: 'TV Movie',
  53: 'Thriller',
  10752: 'War',
  37: 'Western',
};

// Reverse map: genre name → TMDB genre ID
const GENRE_NAME_TO_ID: Record<string, number> = Object.fromEntries(
  Object.entries(GENRE_MAP).map(([id, name]) => [name, Number(id)])
);

export interface TMDBMovie {
  id: string;
  tmdbId: number;
  title: string;
  year: string;
  posterUrl: string | null;
  backdropUrl?: string | null;
  type: 'movie';
  genres: string[];
  overview: string;
  voteAverage?: number; // TMDb vote_average 0–10, maps to Spool global score
  runtime?: number; // minutes
}

export interface StreamingProvider {
  providerId: number;
  providerName: string;
  logoUrl?: string; // Full URL to TMDB image
}

export interface StreamingAvailability {
  link?: string;
  flatrate?: StreamingProvider[];
  rent?: StreamingProvider[];
  buy?: StreamingProvider[];
  free?: StreamingProvider[];
}

/** Returns true if the TMDB API key is configured */
export function hasTmdbKey(): boolean {
  return !!import.meta.env.VITE_TMDB_API_KEY;
}

async function fetchWithTimeout(url: string, timeoutMs: number): Promise<Response> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);

  try {
    return await fetch(url, { signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

// ── Shared response mapper ──────────────────────────────────────────────────
function mapTmdbResult(m: any): TMDBMovie | null {
  if (!m.poster_path) return null;
  return {
    id: `tmdb_${m.id}`,
    tmdbId: m.id,
    title: m.title,
    year: m.release_date ? m.release_date.slice(0, 4) : '—',
    posterUrl: `${TMDB_IMAGE_BASE}${m.poster_path}`,
    backdropUrl: m.backdrop_path ? `${TMDB_IMAGE_BASE}${m.backdrop_path}` : null,
    type: 'movie' as const,
    genres: (m.genre_ids as number[] | undefined)
      ?.map((gid: number) => GENRE_MAP[gid])
      .filter(Boolean)
      .slice(0, 3) ?? [],
    overview: m.overview ?? '',
    voteAverage: typeof m.vote_average === 'number' ? m.vote_average : undefined,
    runtime: m.runtime,
  };
}

/** Convert genre names (e.g. "Action") to TMDB genre IDs */
export function genreNamesToIds(names: string[]): number[] {
  return names
    .map(n => GENRE_NAME_TO_ID[n])
    .filter((id): id is number => id !== undefined);
}

// ── Shared helpers for discover fetching ─────────────────────────────────────

function dedup(movies: TMDBMovie[]): TMDBMovie[] {
  const seen = new Set<number>();
  return movies.filter(m => {
    if (seen.has(m.tmdbId)) return false;
    seen.add(m.tmdbId);
    return true;
  });
}

function interleave(a: TMDBMovie[], b: TMDBMovie[]): TMDBMovie[] {
  const mixed: TMDBMovie[] = [];
  const maxLen = Math.max(a.length, b.length);
  for (let i = 0; i < maxLen; i++) {
    if (i < a.length) mixed.push(a[i]);
    if (i < b.length) mixed.push(b[i]);
  }
  return mixed;
}

/** Fisher-Yates shuffle (returns a new shuffled array). */
function shuffle<T>(arr: T[]): T[] {
  const copy = [...arr];
  for (let i = copy.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [copy[i], copy[j]] = [copy[j], copy[i]];
  }
  return copy;
}

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

  const tierWeights = TIER_WEIGHTS as Record<string, number>;

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

  // Director frequency (tier-weighted)
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

/**
 * Fetch random S/A-tier movies from friends that the user hasn't ranked.
 */
export async function getFriendSuggestionPicks(
  userId: string,
  excludeIds: Set<string>,
  limit: number = 2,
): Promise<TMDBMovie[]> {
  try {
    const { data: follows } = await supabase
      .from('friend_follows')
      .select('following_id')
      .eq('follower_id', userId);

    const friendIds = follows?.map((f: { following_id: string }) => f.following_id) ?? [];
    if (friendIds.length === 0) return [];

    const { data: friendRankings } = await supabase
      .from('user_rankings')
      .select('tmdb_id, title, poster_url, year, genres')
      .in('user_id', friendIds)
      .in('tier', ['S', 'A'])
      .limit(100);

    if (!friendRankings || friendRankings.length === 0) return [];

    const candidates = friendRankings
      .filter((r: any) => !excludeIds.has(r.tmdb_id) && r.poster_url)
      .reduce((acc: any[], r: any) => {
        if (!acc.some((a: any) => a.tmdb_id === r.tmdb_id)) acc.push(r);
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

/**
 * Smart 5-pool suggestion system.
 * Pools: Similar (from S/A movies) | Taste (weighted genres + decade) |
 *        Trending | Variety (underexposed genres) | Friend picks
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

  if (profile.totalRanked < SMART_SUGGESTION_THRESHOLD) {
    return getGenericSuggestions(excludeIds, page, excludeTitles);
  }

  const isExcluded = (m: TMDBMovie) =>
    excludeIds.has(m.id) || excludeTitles.has(m.title.toLowerCase());

  const topGenres = Object.entries(profile.weightedGenres)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3)
    .map(([name]) => name);
  const genreParam = genreNamesToIds(topGenres).join(',');

  const fetches: Promise<TMDBMovie[]>[] = [];

  // Pool 1: Similar (from random S/A movie)
  fetches.push((async (): Promise<TMDBMovie[]> => {
    if (profile.topMovieIds.length === 0) return [];
    const pickId = profile.topMovieIds[Math.floor(Math.random() * profile.topMovieIds.length)];
    try {
      const res = await fetch(
        `${TMDB_BASE}/movie/${pickId}/similar?api_key=${apiKey}&language=${getTmdbLocale()}&page=${page}`
      );
      if (!res.ok) return [];
      const data = await res.json();
      return (data.results as any[])
        .map(mapTmdbResult)
        .filter((m): m is TMDBMovie => m !== null && !isExcluded(m))
        .slice(0, poolSlots.similar + 2);
    } catch { return []; }
  })());

  // Pool 2: Taste (weighted genres + decade bias)
  fetches.push((async (): Promise<TMDBMovie[]> => {
    const url = new URL(`${TMDB_BASE}/discover/movie`);
    url.searchParams.set('api_key', apiKey);
    url.searchParams.set('language', getTmdbLocale());
    url.searchParams.set('sort_by', 'vote_average.desc');
    url.searchParams.set('include_adult', 'false');
    url.searchParams.set('vote_count.gte', '200');
    if (genreParam) url.searchParams.set('with_genres', genreParam);

    if (profile.preferredDecade) {
      const decadeStart = parseInt(profile.preferredDecade, 10);
      if (!isNaN(decadeStart) && Math.random() < 0.5) {
        url.searchParams.set('primary_release_date.gte', `${decadeStart}-01-01`);
        url.searchParams.set('primary_release_date.lte', `${decadeStart + 9}-12-31`);
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
  })());

  // Pool 3: Trending
  fetches.push((async (): Promise<TMDBMovie[]> => {
    try {
      const res = await fetch(
        `${TMDB_BASE}/trending/movie/week?api_key=${apiKey}&language=${getTmdbLocale()}&page=${page}`
      );
      if (!res.ok) return [];
      const data = await res.json();
      return (data.results as any[])
        .map(mapTmdbResult)
        .filter((m): m is TMDBMovie => m !== null && !isExcluded(m))
        .slice(0, poolSlots.trending + 2);
    } catch { return []; }
  })());

  // Pool 4: Variety (underexposed genres)
  fetches.push((async (): Promise<TMDBMovie[]> => {
    if (profile.underexposedGenres.length === 0) return [];
    const pickGenres = shuffle(profile.underexposedGenres).slice(0, 2);
    const varietyGenreParam = genreNamesToIds(pickGenres).join(',');
    if (!varietyGenreParam) return [];

    const url = new URL(`${TMDB_BASE}/discover/movie`);
    url.searchParams.set('api_key', apiKey);
    url.searchParams.set('language', getTmdbLocale());
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
  })());

  // Pool 5: Friend picks
  fetches.push(
    userId
      ? getFriendSuggestionPicks(userId, excludeIds, poolSlots.friend + 1)
      : Promise.resolve([])
  );

  const [similarMovies, tasteMovies, trendingMovies, varietyMovies, friendMovies] =
    await Promise.all(fetches);

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

  const remaining = [...tasteMovies, ...similarMovies, ...trendingMovies, ...varietyMovies];
  take(remaining, 12 - result.length);

  return shuffle(result);
}

/**
 * Smart backfill: TMDB recommendations for random ranked movies.
 * Falls back to variety discover if insufficient.
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

  if (profile.topMovieIds.length === 0) {
    return getGenericSuggestions(excludeIds, page, excludeTitles);
  }

  let movies: TMDBMovie[] = [];

  const sampleIds = shuffle(profile.topMovieIds).slice(0, 2);
  try {
    const reqs = sampleIds.map(id =>
      fetch(`${TMDB_BASE}/movie/${id}/recommendations?api_key=${apiKey}&language=${getTmdbLocale()}&page=${page}`)
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

  if (movies.length < 12 && profile.underexposedGenres.length > 0) {
    try {
      const pickGenres = shuffle(profile.underexposedGenres).slice(0, 2);
      const varietyParam = genreNamesToIds(pickGenres).join(',');
      if (varietyParam) {
        const url = new URL(`${TMDB_BASE}/discover/movie`);
        url.searchParams.set('api_key', apiKey);
        url.searchParams.set('language', getTmdbLocale());
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

/**
 * Fetch GENERIC suggestions: 50% popular new releases + 50% all-time classics.
 * No genre filter -- this is the initial batch shown when the modal opens.
 */
export async function getGenericSuggestions(
  excludeIds: Set<string> = new Set(),
  page: number = 1,
  excludeTitles: Set<string> = new Set(),
): Promise<TMDBMovie[]> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;
  if (!apiKey) return [];

  const currentYear = new Date().getFullYear();

  try {
    const recentUrl = new URL(`${TMDB_BASE}/discover/movie`);
    recentUrl.searchParams.set('api_key', apiKey);
    recentUrl.searchParams.set('language', getTmdbLocale());
    recentUrl.searchParams.set('sort_by', 'popularity.desc');
    recentUrl.searchParams.set('include_adult', 'false');
    recentUrl.searchParams.set('primary_release_date.gte', `${currentYear - 2}-01-01`);
    recentUrl.searchParams.set('vote_count.gte', '50');
    recentUrl.searchParams.set('page', String(page));

    const classicUrl = new URL(`${TMDB_BASE}/discover/movie`);
    classicUrl.searchParams.set('api_key', apiKey);
    classicUrl.searchParams.set('language', getTmdbLocale());
    classicUrl.searchParams.set('sort_by', 'vote_average.desc');
    classicUrl.searchParams.set('include_adult', 'false');
    classicUrl.searchParams.set('primary_release_date.lte', `${currentYear - 5}-12-31`);
    classicUrl.searchParams.set('vote_count.gte', '1000');
    classicUrl.searchParams.set('page', String(page));

    const [recentRes, classicRes] = await Promise.all([
      fetch(recentUrl.toString()),
      fetch(classicUrl.toString()),
    ]);

    if (!recentRes.ok || !classicRes.ok) return [];

    const [recentData, classicData] = await Promise.all([
      recentRes.json(),
      classicRes.json(),
    ]);

    const isExcluded = (m: TMDBMovie) =>
      excludeIds.has(m.id) || excludeTitles.has(m.title.toLowerCase());

    const newFilms = (recentData.results as any[])
      .map(mapTmdbResult)
      .filter((m): m is TMDBMovie => m !== null && !isExcluded(m))
      .slice(0, 6);

    const classics = (classicData.results as any[])
      .map(mapTmdbResult)
      .filter((m): m is TMDBMovie => m !== null && !isExcluded(m))
      .slice(0, 6);

    return shuffle(dedup(interleave(newFilms, classics)).slice(0, 12));
  } catch (err) {
    console.error('TMDB generic suggestions failed:', err);
    return [];
  }
}

/**
 * @deprecated Use getSmartBackfill instead.
 * Fetch PERSONALIZED fills: genre-filtered discover results used to
 * backfill slots when the user ranks or bookmarks a generic suggestion.
 * Returns a larger buffer (~20 movies) so we rarely need to re-fetch.
 */
export async function getPersonalizedFills(
  topGenreNames: string[],
  excludeIds: Set<string> = new Set(),
  page: number = 1,
  excludeTitles: Set<string> = new Set(),
): Promise<TMDBMovie[]> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;
  if (!apiKey || topGenreNames.length === 0) return [];

  const genreParam = genreNamesToIds(topGenreNames).join(',');
  if (!genreParam) return [];

  const currentYear = new Date().getFullYear();

  try {
    const recentUrl = new URL(`${TMDB_BASE}/discover/movie`);
    recentUrl.searchParams.set('api_key', apiKey);
    recentUrl.searchParams.set('language', getTmdbLocale());
    recentUrl.searchParams.set('sort_by', 'popularity.desc');
    recentUrl.searchParams.set('include_adult', 'false');
    recentUrl.searchParams.set('primary_release_date.gte', `${currentYear - 2}-01-01`);
    recentUrl.searchParams.set('vote_count.gte', '50');
    recentUrl.searchParams.set('with_genres', genreParam);
    recentUrl.searchParams.set('page', String(page));

    const classicUrl = new URL(`${TMDB_BASE}/discover/movie`);
    classicUrl.searchParams.set('api_key', apiKey);
    classicUrl.searchParams.set('language', getTmdbLocale());
    classicUrl.searchParams.set('sort_by', 'vote_average.desc');
    classicUrl.searchParams.set('include_adult', 'false');
    classicUrl.searchParams.set('primary_release_date.lte', `${currentYear - 5}-12-31`);
    classicUrl.searchParams.set('vote_count.gte', '1000');
    classicUrl.searchParams.set('with_genres', genreParam);
    classicUrl.searchParams.set('page', String(page));

    const [recentRes, classicRes] = await Promise.all([
      fetch(recentUrl.toString()),
      fetch(classicUrl.toString()),
    ]);

    if (!recentRes.ok || !classicRes.ok) return [];

    const [recentData, classicData] = await Promise.all([
      recentRes.json(),
      classicRes.json(),
    ]);

    const isExcluded = (m: TMDBMovie) =>
      excludeIds.has(m.id) || excludeTitles.has(m.title.toLowerCase());

    const newFilms = (recentData.results as any[])
      .map(mapTmdbResult)
      .filter((m): m is TMDBMovie => m !== null && !isExcluded(m));

    const classics = (classicData.results as any[])
      .map(mapTmdbResult)
      .filter((m): m is TMDBMovie => m !== null && !isExcluded(m));

    return dedup(interleave(newFilms, classics));
  } catch (err) {
    console.error('TMDB personalized fills failed:', err);
    return [];
  }
}

/**
 * @deprecated Use getSmartSuggestions instead.
 * Fetch DYNAMIC suggestions based on session fatigue (15% New / 30% Global / 55% Taste)
 * New falls off after 5 clicks in a session.
 */
export async function getDynamicSuggestions(
  topGenreNames: string[],
  excludeIds: Set<string> = new Set(),
  page: number = 1,
  excludeTitles: Set<string> = new Set(),
  sessionClickCount: number = 0,
): Promise<TMDBMovie[]> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;
  if (!apiKey) return [];

  const isFatigued = sessionClickCount >= 5;
  const targetNew = isFatigued ? 0 : 2;
  const targetGlobal = isFatigued ? 5 : 4;
  const currentYear = new Date().getFullYear();

  try {
    const urls = [];

    // 1. New Movies
    if (targetNew > 0) {
      const newUrl = new URL(`${TMDB_BASE}/discover/movie`);
      newUrl.searchParams.set('api_key', apiKey);
      newUrl.searchParams.set('language', getTmdbLocale());
      newUrl.searchParams.set('sort_by', 'popularity.desc');
      newUrl.searchParams.set('include_adult', 'false');
      newUrl.searchParams.set('primary_release_date.gte', `${currentYear - 2}-01-01`);
      newUrl.searchParams.set('vote_count.gte', '50');
      newUrl.searchParams.set('page', String(page));
      urls.push(fetch(newUrl.toString()));
    }

    // 2. Global Trending
    const globalUrl = new URL(`${TMDB_BASE}/trending/movie/week`);
    globalUrl.searchParams.set('api_key', apiKey);
    globalUrl.searchParams.set('language', getTmdbLocale());
    globalUrl.searchParams.set('page', String(page));
    urls.push(fetch(globalUrl.toString()));

    // 3. Taste / Random
    const tasteUrl = new URL(`${TMDB_BASE}/discover/movie`);
    tasteUrl.searchParams.set('api_key', apiKey);
    tasteUrl.searchParams.set('language', getTmdbLocale());
    tasteUrl.searchParams.set('sort_by', 'popularity.desc');
    tasteUrl.searchParams.set('include_adult', 'false');
    const genreParam = genreNamesToIds(topGenreNames).join(',');
    if (genreParam) tasteUrl.searchParams.set('with_genres', genreParam);
    // Add varying offsets to inject high randomness
    tasteUrl.searchParams.set('page', String(page + Math.floor(Math.random() * 5)));
    urls.push(fetch(tasteUrl.toString()));

    const responses = await Promise.all(urls);
    if (responses.some(r => !r.ok)) return [];

    const data = await Promise.all(responses.map(r => r.json()));

    let newIdx = 0;
    const isExcluded = (m: TMDBMovie) => excludeIds.has(m.id) || excludeTitles.has(m.title.toLowerCase());

    const extractAndFilter = (resData: any, count: number) => {
      return (resData.results as any[])
        .map(mapTmdbResult)
        .filter((m): m is TMDBMovie => m !== null && !isExcluded(m))
        .slice(0, count);
    };

    let newFilms: TMDBMovie[] = [];
    if (targetNew > 0) {
      newFilms = extractAndFilter(data[newIdx++], targetNew);
    }
    const globalFilms = extractAndFilter(data[newIdx++], targetGlobal);

    // Ensure total sum to 12. If new or global missed their targets, taste fills the rest
    const totalSoFar = newFilms.length + globalFilms.length;
    const adjustedTasteTarget = 12 - totalSoFar;

    const tasteFilms = extractAndFilter(data[newIdx++], adjustedTasteTarget);

    const pool = shuffle([...newFilms, ...globalFilms, ...tasteFilms]);
    return dedup(pool).slice(0, 12);
  } catch (err) {
    console.error('TMDB dynamic suggestions failed:', err);
    return [];
  }
}

/**
 * @deprecated Use getSmartBackfill instead.
 * Fetch EDITOR'S CHOICE fills: Sequels & Prequels of ranked movies
 * If no sequels/prequels are found, falls back to documentaries (genre 99)
 */
export async function getEditorsChoiceFills(
  rankedTmdbIds: number[],
  excludeIds: Set<string> = new Set(),
  page: number = 1,
  excludeTitles: Set<string> = new Set(),
): Promise<TMDBMovie[]> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;
  if (!apiKey) return [];

  const isExcluded = (m: TMDBMovie) => excludeIds.has(m.id) || excludeTitles.has(m.title.toLowerCase());
  let collectionFilms: TMDBMovie[] = [];

  try {
    if (rankedTmdbIds.length > 0) {
      // Pick up to 5 random ranked movies to check for collections
      const sampleIds = shuffle(rankedTmdbIds).slice(0, 5);

      const moviePromises = sampleIds.map(id =>
        fetch(`${TMDB_BASE}/movie/${id}?api_key=${apiKey}&language=${getTmdbLocale()}`).then(res => res.json())
      );

      const movies = await Promise.all(moviePromises);
      const collectionIds = new Set<number>();

      for (const m of movies) {
        if (m.belongs_to_collection && m.belongs_to_collection.id) {
          collectionIds.add(m.belongs_to_collection.id);
        }
      }

      if (collectionIds.size > 0) {
        const collectionPromises = Array.from(collectionIds).slice(0, 3).map(id =>
          fetch(`${TMDB_BASE}/collection/${id}?api_key=${apiKey}&language=${getTmdbLocale()}`).then(res => res.json())
        );

        const collections = await Promise.all(collectionPromises);

        for (const c of collections) {
          if (c.parts) {
            const parts = (c.parts as any[])
              .map(mapTmdbResult)
              .filter((m): m is TMDBMovie => m !== null && !isExcluded(m));
            collectionFilms.push(...parts);
          }
        }
      }
    }
  } catch (err) {
    console.error('TMDB collection fetch failed:', err);
  }

  // Deduplicate collection films
  collectionFilms = dedup(collectionFilms);

  // If we have enough from collections, return them
  if (collectionFilms.length >= 12) {
    return shuffle(collectionFilms).slice(0, 12);
  }

  // Otherwise, pad with the standard Documentary fallback
  try {
    const url = new URL(`${TMDB_BASE}/discover/movie`);
    url.searchParams.set('api_key', apiKey);
    url.searchParams.set('language', getTmdbLocale());
    url.searchParams.set('sort_by', 'popularity.desc');
    url.searchParams.set('include_adult', 'false');
    url.searchParams.set('with_genres', '99'); // Documentaries
    url.searchParams.set('page', String(page));

    const res = await fetch(url.toString());
    if (!res.ok) return collectionFilms;

    const data = await res.json();
    const docFilms = (data.results as any[])
      .map(mapTmdbResult)
      .filter((m): m is TMDBMovie => m !== null && !isExcluded(m));

    // Combine collections and docs, then deduplicate again in case of overlap
    const combined = dedup([...collectionFilms, ...docFilms]);
    return shuffle(combined).slice(0, 12);
  } catch (err) {
    console.error('TMDB editors choice fallback failed:', err);
    return collectionFilms;
  }
}

/**
 * Search TMDB for movies matching *query*.
 * Returns up to 10 results with real posters and metadata.
 */
export async function searchMovies(
  query: string,
  timeoutMs: number = DEFAULT_TMDB_SEARCH_TIMEOUT_MS,
): Promise<TMDBMovie[]> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;

  if (!apiKey || !query.trim()) return [];

  try {
    const url = new URL(`${TMDB_BASE}/search/movie`);
    url.searchParams.set('api_key', apiKey);
    url.searchParams.set('query', query);
    url.searchParams.set('language', getTmdbLocale());
    url.searchParams.set('page', '1');
    url.searchParams.set('include_adult', 'false');

    const res = await fetchWithTimeout(url.toString(), timeoutMs);

    if (!res.ok) {
      console.error(`TMDB API error: ${res.status} ${res.statusText}`);
      return [];
    }

    const data = await res.json();

    return (data.results as any[])
      .map(mapTmdbResult)
      .filter((m): m is TMDBMovie => m !== null)
      .slice(0, 12);
  } catch (err) {
    if (err instanceof DOMException && err.name === 'AbortError') {
      console.warn(`TMDB search timed out after ${timeoutMs}ms`);
      return [];
    }
    console.error('TMDB search failed:', err);
    return [];
  }
}

/**
 * Person profile returned by searchPeople.
 */
export interface PersonProfile {
  id: number;
  name: string;
  role: 'Director' | 'Actor';
  photoUrl: string | null;
  knownFor: string[]; // titles of known movies
}

// Backwards-compat aliases
export type DirectorProfile = PersonProfile;
export type { PersonProfile as ActorProfile };

/**
 * Search TMDB for directors AND actors matching `query`.
 * Returns compact profiles the UI can show as selectable results.
 */
export async function searchPeople(
  query: string,
  timeoutMs: number = DEFAULT_TMDB_SEARCH_TIMEOUT_MS,
): Promise<PersonProfile[]> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;
  if (!apiKey || !query.trim()) return [];

  try {
    const url = new URL(`${TMDB_BASE}/search/person`);
    url.searchParams.set('api_key', apiKey);
    url.searchParams.set('query', query);
    url.searchParams.set('language', getTmdbLocale());
    url.searchParams.set('page', '1');
    url.searchParams.set('include_adult', 'false');

    const res = await fetchWithTimeout(url.toString(), timeoutMs);
    if (!res.ok) return [];

    const data = await res.json();

    return (data.results as any[])
      .filter(p => p.known_for_department === 'Directing' || p.known_for_department === 'Acting')
      .slice(0, 6)
      .map((p: any): PersonProfile => ({
        id: p.id,
        name: p.name,
        role: p.known_for_department === 'Directing' ? 'Director' : 'Actor',
        photoUrl: p.profile_path ? `${TMDB_IMAGE_BASE}${p.profile_path}` : null,
        knownFor: (p.known_for as any[] ?? [])
          .filter((m: any) => m.media_type === 'movie')
          .map((m: any) => m.title)
          .slice(0, 3),
      }));
  } catch (err) {
    console.error('TMDB person search failed:', err);
    return [];
  }
}

/** @deprecated Use searchPeople instead */
export const searchDirectors = searchPeople;

/**
 * Full person detail: bio, photo, and filmography.
 */
export interface PersonDetail {
  id: number;
  name: string;
  role: 'Director' | 'Actor';
  photoUrl: string | null;
  biography: string;
  birthday: string | null;
  placeOfBirth: string | null;
  movies: TMDBMovie[];
}

// Backwards-compat alias
export type DirectorDetail = PersonDetail;

/**
 * Fetch full person profile + filmography by their TMDB person ID.
 * For directors: uses crew credits (job=Director).
 * For actors: uses cast credits.
 */
export async function getPersonFilmography(
  personId: number,
  role: 'Director' | 'Actor' = 'Director',
): Promise<PersonDetail | null> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;
  if (!apiKey) return null;

  try {
    const [personRes, creditsRes] = await Promise.all([
      fetch(`${TMDB_BASE}/person/${personId}?api_key=${apiKey}&language=${getTmdbLocale()}`),
      fetch(`${TMDB_BASE}/person/${personId}/movie_credits?api_key=${apiKey}&language=${getTmdbLocale()}`),
    ]);

    if (!personRes.ok || !creditsRes.ok) return null;

    const [person, credits] = await Promise.all([personRes.json(), creditsRes.json()]);

    const mapMovie = (m: any): TMDBMovie => ({
      id: `tmdb_${m.id}`,
      tmdbId: m.id,
      title: m.title,
      year: m.release_date ? m.release_date.slice(0, 4) : '—',
      posterUrl: `${TMDB_IMAGE_BASE}${m.poster_path}`,
      type: 'movie' as const,
      genres: (m.genre_ids as number[] ?? [])
        .map((gid: number) => GENRE_MAP[gid])
        .filter(Boolean)
        .slice(0, 3),
      overview: m.overview ?? '',
    });

    let movies: TMDBMovie[];
    if (role === 'Director') {
      movies = (credits.crew as any[])
        .filter((c: any) => c.job === 'Director' && c.poster_path)
        .sort((a: any, b: any) => (b.popularity ?? 0) - (a.popularity ?? 0))
        .map(mapMovie);
    } else {
      movies = (credits.cast as any[])
        .filter((c: any) => c.poster_path)
        .sort((a: any, b: any) => (b.popularity ?? 0) - (a.popularity ?? 0))
        .map(mapMovie);
    }

    // Deduplicate (actors can appear in same movie multiple times)
    const seen = new Set<number>();
    movies = movies.filter(m => {
      if (seen.has(m.tmdbId)) return false;
      seen.add(m.tmdbId);
      return true;
    });

    return {
      id: person.id,
      name: person.name,
      role,
      photoUrl: person.profile_path ? `${TMDB_IMAGE_BASE}${person.profile_path}` : null,
      biography: person.biography ?? '',
      birthday: person.birthday ?? null,
      placeOfBirth: person.place_of_birth ?? null,
      movies,
    };
  } catch (err) {
    console.error('TMDB person filmography failed:', err);
    return null;
  }
}

/** @deprecated Use getPersonFilmography instead */
export const getDirectorFilmography = (personId: number) => getPersonFilmography(personId, 'Director');

/**
 * Fetch the global average score (vote_average) for a single movie from TMDb.
 * Used to seed the adaptive comparison algorithm.
 * Returns a number 0.0–10.0, or undefined on failure.
 */
export async function getMovieGlobalScore(tmdbNumericId: number): Promise<number | undefined> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;
  if (!apiKey || !tmdbNumericId) return undefined;

  try {
    const res = await fetchWithTimeout(
      `${TMDB_BASE}/movie/${tmdbNumericId}?api_key=${apiKey}&language=${getTmdbLocale()}`,
      4000,
    );
    if (!res.ok) return undefined;
    const data = await res.json();
    return typeof data.vote_average === 'number' ? data.vote_average : undefined;
  } catch {
    return undefined;
  }
}

/**
 * Fetch extended details for the Movie Detail Modal.
 * Includes full genres, runtime, backdrop, and watch providers (streaming).
 */
export async function getExtendedMovieDetails(tmdbNumericId: number): Promise<{
  movie: TMDBMovie;
  streaming: StreamingAvailability;
  director?: string;
} | null> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;
  if (!apiKey || !tmdbNumericId) return null;

  try {
    const res = await fetchWithTimeout(
      `${TMDB_BASE}/movie/${tmdbNumericId}?api_key=${apiKey}&language=${getTmdbLocale()}&append_to_response=watch/providers,credits`,
      5000,
    );
    if (!res.ok) return null;
    const data = await res.json();

    // Map genres (extended has array of objects instead of genre_ids)
    if (data.genres && Array.isArray(data.genres)) {
      data.genre_ids = data.genres.map((g: any) => g.id);
    }

    const movie = mapTmdbResult(data);
    if (!movie) return null;

    let director: string | undefined;
    if (data.credits && data.credits.crew) {
      const dirObj = data.credits.crew.find((c: any) => c.job === 'Director');
      if (dirObj) director = dirObj.name;
    }

    const providersData = data['watch/providers']?.results?.US; // Assuming US region for now
    const streaming: StreamingAvailability = { link: providersData?.link };

    const mapProviders = (pz: any[] | undefined) => {
      if (!pz) return undefined;
      return pz.map(p => ({
        providerId: p.provider_id,
        providerName: p.provider_name,
        logoUrl: p.logo_path ? `${TMDB_IMAGE_BASE}${p.logo_path}` : undefined,
      }));
    };

    if (providersData) {
      streaming.flatrate = mapProviders(providersData.flatrate);
      streaming.rent = mapProviders(providersData.rent);
      streaming.buy = mapProviders(providersData.buy);
      streaming.free = mapProviders(providersData.free);
    }

    return { movie, streaming, director };
  } catch (err) {
    console.error('TMDB extended details fetch failed:', err);
    return null;
  }
}
