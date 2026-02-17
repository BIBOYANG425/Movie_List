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

/**
 * Fetch personalized suggestions:
 *  - 50% popular new releases, 50% top-rated classics
 *  - Filtered to the user's favourite genres (via TMDB discover)
 *  - Movies already in the user's collection are excluded
 *
 * @param topGenreNames  The user's most-common genre names (e.g. ["Sci-Fi", "Drama"])
 * @param excludeIds     Set of movie IDs (e.g. "tmdb_123") already ranked or on the watchlist
 */
export async function getSuggestions(
  topGenreNames: string[] = [],
  excludeIds: Set<string> = new Set(),
): Promise<TMDBMovie[]> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;
  if (!apiKey) return [];

  const genreIds = genreNamesToIds(topGenreNames);
  const genreParam = genreIds.length > 0 ? genreIds.join(',') : '';

  const currentYear = new Date().getFullYear();

  try {
    // Build two discover URLs: recent popular + all-time top-rated
    const recentUrl = new URL(`${TMDB_BASE}/discover/movie`);
    recentUrl.searchParams.set('api_key', apiKey);
    recentUrl.searchParams.set('language', 'en-US');
    recentUrl.searchParams.set('sort_by', 'popularity.desc');
    recentUrl.searchParams.set('include_adult', 'false');
    recentUrl.searchParams.set('primary_release_date.gte', `${currentYear - 2}-01-01`);
    recentUrl.searchParams.set('vote_count.gte', '50');
    if (genreParam) recentUrl.searchParams.set('with_genres', genreParam);

    const classicUrl = new URL(`${TMDB_BASE}/discover/movie`);
    classicUrl.searchParams.set('api_key', apiKey);
    classicUrl.searchParams.set('language', 'en-US');
    classicUrl.searchParams.set('sort_by', 'vote_average.desc');
    classicUrl.searchParams.set('include_adult', 'false');
    classicUrl.searchParams.set('primary_release_date.lte', `${currentYear - 5}-12-31`);
    classicUrl.searchParams.set('vote_count.gte', '1000');
    if (genreParam) classicUrl.searchParams.set('with_genres', genreParam);

    const [recentRes, classicRes] = await Promise.all([
      fetch(recentUrl.toString()),
      fetch(classicUrl.toString()),
    ]);

    if (!recentRes.ok || !classicRes.ok) return [];

    const [recentData, classicData] = await Promise.all([
      recentRes.json(),
      classicRes.json(),
    ]);

    const isExcluded = (m: TMDBMovie) => excludeIds.has(m.id);

    const newFilms: TMDBMovie[] = (recentData.results as any[])
      .map(mapTmdbResult)
      .filter((m): m is TMDBMovie => m !== null && !isExcluded(m))
      .slice(0, 8);

    const classics: TMDBMovie[] = (classicData.results as any[])
      .map(mapTmdbResult)
      .filter((m): m is TMDBMovie => m !== null && !isExcluded(m))
      .slice(0, 8);

    // Interleave: new, classic, new, classic...
    const mixed: TMDBMovie[] = [];
    const maxLen = Math.max(newFilms.length, classics.length);
    for (let i = 0; i < maxLen; i++) {
      if (i < newFilms.length) mixed.push(newFilms[i]);
      if (i < classics.length) mixed.push(classics[i]);
    }

    // Deduplicate by tmdbId
    const seen = new Set<number>();
    return mixed.filter(m => {
      if (seen.has(m.tmdbId)) return false;
      seen.add(m.tmdbId);
      return true;
    }).slice(0, 12);
  } catch (err) {
    console.error('TMDB suggestions failed:', err);
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
