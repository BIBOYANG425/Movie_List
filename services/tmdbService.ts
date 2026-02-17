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
      .filter((m) => m.poster_path) // skip movies without a poster
      .slice(0, 12)
      .map((m) => ({
        id: `tmdb_${m.id}`,
        tmdbId: m.id,
        title: m.title,
        year: m.release_date ? m.release_date.slice(0, 4) : '—',
        posterUrl: `${TMDB_IMAGE_BASE}${m.poster_path}`,
        type: 'movie' as const,
        genres: (m.genre_ids as number[])
          .map((id) => GENRE_MAP[id])
          .filter(Boolean)
          .slice(0, 3),
        overview: m.overview ?? '',
      }));
  } catch (err) {
    console.error('TMDB search failed:', err);
    return [];
  }
}
