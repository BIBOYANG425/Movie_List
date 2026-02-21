/**
 * Backend API service — wraps calls to the FastAPI /media endpoints.
 *
 * Requires environment variable: VITE_API_URL
 * Example: VITE_API_URL=https://your-api.example.com
 *
 * If VITE_API_URL is not set the helpers return [] and the app falls back
 * to calling TMDB directly.
 */

import type { TMDBMovie } from './tmdbService';

const API_BASE = import.meta.env.VITE_API_URL as string | undefined;

/** True when the backend URL is configured. */
export function hasBackendUrl(): boolean {
  return !!API_BASE;
}

/** Shape of one item returned by GET /media/search */
interface BackendMediaItem {
  id: string;
  title: string;
  release_year: number | null;
  media_type: string;
  tmdb_id: number | null;
  attributes: Record<string, any>;
  is_verified: boolean;
  is_user_generated: boolean;
}

/** Map a backend media item to the TMDBMovie shape the UI expects. */
function mapBackendItem(item: BackendMediaItem): TMDBMovie {
  const posterUrl: string | null = item.attributes?.poster_url ?? null;
  const genres: string[] = Array.isArray(item.attributes?.genres)
    ? item.attributes.genres
    : [];

  return {
    // Prefer a stable tmdb_xxx id so the frontend dedup logic works correctly.
    id: item.tmdb_id ? `tmdb_${item.tmdb_id}` : item.id,
    tmdbId: item.tmdb_id ?? 0,
    title: item.title,
    year: item.release_year ? String(item.release_year) : '—',
    posterUrl,
    type: 'movie',
    genres,
    overview: item.attributes?.overview ?? '',
  };
}

/**
 * Search the backend's hybrid /media/search endpoint.
 * Falls back to [] if VITE_API_URL is not set or the request fails.
 */
export async function searchMediaFromBackend(query: string): Promise<TMDBMovie[]> {
  if (!API_BASE || !query.trim()) return [];

  try {
    const url = new URL(`${API_BASE}/media/search`);
    url.searchParams.set('q', query.trim());
    url.searchParams.set('limit', '12');

    const res = await fetch(url.toString());
    if (!res.ok) {
      console.error(`Backend search error: ${res.status} ${res.statusText}`);
      return [];
    }

    const data = await res.json();
    return (data.items as BackendMediaItem[])
      .filter((item) => item.attributes?.poster_url)
      .map(mapBackendItem);
  } catch (err) {
    console.error('Backend search failed:', err);
    return [];
  }
}
