/**
 * TMDB (The Movie Database) API service
 * Docs: https://developer.themoviedb.org/docs
 *
 * Requires environment variable: VITE_TMDB_API_KEY
 * Add to Vercel: Project Settings → Environment Variables → VITE_TMDB_API_KEY
 */

const TMDB_BASE = 'https://api.themoviedb.org/3';
const TMDB_IMAGE_BASE = 'https://image.tmdb.org/t/p/w500';

// Full genre map from TMDB (stable — rarely changes)
const GENRE_MAP: Record<number, string> = {
  28:    'Action',
  12:    'Adventure',
  16:    'Animation',
  35:    'Comedy',
  80:    'Crime',
  99:    'Documentary',
  18:    'Drama',
  10751: 'Family',
  14:    'Fantasy',
  36:    'History',
  27:    'Horror',
  10402: 'Music',
  9648:  'Mystery',
  10749: 'Romance',
  878:   'Sci-Fi',
  10770: 'TV Movie',
  53:    'Thriller',
  10752: 'War',
  37:    'Western',
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
  type: 'movie';
  genres: string[];
  overview: string;
}

/** Returns true if the TMDB API key is configured */
export function hasTmdbKey(): boolean {
  return !!import.meta.env.VITE_TMDB_API_KEY;
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
    type: 'movie' as const,
    genres: (m.genre_ids as number[])
      .map((gid: number) => GENRE_MAP[gid])
      .filter(Boolean)
      .slice(0, 3),
    overview: m.overview ?? '',
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
    recentUrl.searchParams.set('language', 'en-US');
    recentUrl.searchParams.set('sort_by', 'popularity.desc');
    recentUrl.searchParams.set('include_adult', 'false');
    recentUrl.searchParams.set('primary_release_date.gte', `${currentYear - 2}-01-01`);
    recentUrl.searchParams.set('vote_count.gte', '50');
    recentUrl.searchParams.set('page', String(page));

    const classicUrl = new URL(`${TMDB_BASE}/discover/movie`);
    classicUrl.searchParams.set('api_key', apiKey);
    classicUrl.searchParams.set('language', 'en-US');
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

    return dedup(interleave(newFilms, classics)).slice(0, 12);
  } catch (err) {
    console.error('TMDB generic suggestions failed:', err);
    return [];
  }
}

/**
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
    recentUrl.searchParams.set('language', 'en-US');
    recentUrl.searchParams.set('sort_by', 'popularity.desc');
    recentUrl.searchParams.set('include_adult', 'false');
    recentUrl.searchParams.set('primary_release_date.gte', `${currentYear - 2}-01-01`);
    recentUrl.searchParams.set('vote_count.gte', '50');
    recentUrl.searchParams.set('with_genres', genreParam);
    recentUrl.searchParams.set('page', String(page));

    const classicUrl = new URL(`${TMDB_BASE}/discover/movie`);
    classicUrl.searchParams.set('api_key', apiKey);
    classicUrl.searchParams.set('language', 'en-US');
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
 * Search TMDB for movies matching *query*.
 * Returns up to 10 results with real posters and metadata.
 */
export async function searchMovies(query: string): Promise<TMDBMovie[]> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;

  if (!apiKey || !query.trim()) return [];

  try {
    const url = new URL(`${TMDB_BASE}/search/movie`);
    url.searchParams.set('api_key', apiKey);
    url.searchParams.set('query', query);
    url.searchParams.set('language', 'en-US');
    url.searchParams.set('page', '1');
    url.searchParams.set('include_adult', 'false');

    const res = await fetch(url.toString());

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
    console.error('TMDB search failed:', err);
    return [];
  }
}
