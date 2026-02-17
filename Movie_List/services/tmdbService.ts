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

/**
 * Fetch suggested movies: 50% new releases (trending this week),
 * 50% classics (top-rated of all time).
 * Returns up to 12 mixed results, alternating new/classic.
 */
export async function getSuggestions(): Promise<TMDBMovie[]> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;
  if (!apiKey) return [];

  try {
    // Fetch both in parallel
    const [trendingRes, classicsRes] = await Promise.all([
      fetch(`${TMDB_BASE}/trending/movie/week?api_key=${apiKey}&language=en-US`),
      fetch(`${TMDB_BASE}/movie/top_rated?api_key=${apiKey}&language=en-US&page=1`),
    ]);

    if (!trendingRes.ok || !classicsRes.ok) return [];

    const [trendingData, classicsData] = await Promise.all([
      trendingRes.json(),
      classicsRes.json(),
    ]);

    const newFilms: TMDBMovie[] = (trendingData.results as any[])
      .map(mapTmdbResult)
      .filter((m): m is TMDBMovie => m !== null)
      .slice(0, 6);

    const classics: TMDBMovie[] = (classicsData.results as any[])
      .map(mapTmdbResult)
      .filter((m): m is TMDBMovie => m !== null)
      .slice(0, 6);

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
