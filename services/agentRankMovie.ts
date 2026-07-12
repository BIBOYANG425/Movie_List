// services/agentRankMovie.ts
//
// Movie-detail fetch for the /agent-rank route (P3-B, task B1).
//
// The normal app fetches TMDB through tmdbService.proxyFetch, which reads the
// live app session (supabase.auth.getSession) to authenticate the tmdb-proxy
// edge function. The agent-rank route has NO app session — it holds a raw
// fragment JWT. So this module builds the same proxy URL (buildProxyUrl) and
// fetches it with that token as the Bearer, then maps the response into the
// RankedItem the ceremony (RankingFlowModal) pre-seeds.
//
// The DTO produced here matches rowToRankedItem's shape from RankingAppPage so
// the ceremony and the subsequent user_rankings upsert see identical fields:
// id (`tmdb_<n>`), title, year, posterUrl, type 'movie', genres[], director,
// bracket, globalScore. Pure mapping (mapMovieDetailToRankedItem) is split out
// for unit tests; the fetch wrapper is thin.
//
// Header last reviewed: 2026-07-12

import type { RankedItem } from '../types';
import { classifyBracket } from './rankingAlgorithm';
import { buildProxyUrl } from './tmdbProxy';

const TMDB_IMAGE_BASE = 'https://image.tmdb.org/t/p/w500';

/** TMDB movie genre id → Spool genre name (mirrors tmdbService.GENRE_MAP). */
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

/**
 * Map a raw TMDB `movie/{id}?append_to_response=credits` payload into the
 * RankedItem the ceremony seeds. Returns null when the poster is missing (the
 * app treats poster-less results as unrenderable, same as mapTmdbResult).
 *
 * `genres` on an extended detail response is an array of `{ id, name }`; we take
 * the ids and look them up so the bracket classifier and tier picker match the
 * normal in-app add flow exactly.
 */
export function mapMovieDetailToRankedItem(data: any): RankedItem | null {
  if (!data || !data.poster_path) return null;

  const genreIds: number[] = Array.isArray(data.genres)
    ? data.genres.map((g: any) => g.id)
    : Array.isArray(data.genre_ids)
      ? data.genre_ids
      : [];

  const genres = genreIds
    .map((gid) => GENRE_MAP[gid])
    .filter(Boolean)
    .slice(0, 3);

  let director: string | undefined;
  const crew = data.credits?.crew;
  if (Array.isArray(crew)) {
    const dir = crew.find((c: any) => c.job === 'Director');
    if (dir) director = dir.name;
  }

  return {
    id: `tmdb_${data.id}`,
    title: data.title,
    year: data.release_date ? String(data.release_date).slice(0, 4) : '',
    posterUrl: `${TMDB_IMAGE_BASE}${data.poster_path}`,
    type: 'movie',
    genres,
    director,
    bracket: classifyBracket(genres),
    globalScore: typeof data.vote_average === 'number' ? data.vote_average : undefined,
    // tier/rank are placeholders — the ceremony overwrites them on placement.
    tier: undefined as unknown as RankedItem['tier'],
    rank: 0,
  };
}

/**
 * Fetch a movie's details through the tmdb-proxy edge function using the raw
 * fragment JWT as the Bearer. Returns the seeded RankedItem or null on any
 * non-2xx / mapping failure.
 *
 * @param supabaseUrl  the project URL (for buildProxyUrl).
 * @param anonKey      the anon key (sent as `apikey`, mirrors proxyRequest).
 * @param accessToken  the fragment JWT.
 * @param tmdbNumericId the TMDB movie id.
 * @param language     TMDB language code ('en-US' | 'zh-CN').
 * @param fetchImpl    injectable fetch for tests.
 */
export async function fetchAgentRankMovie(
  supabaseUrl: string,
  anonKey: string,
  accessToken: string,
  tmdbNumericId: number,
  language: string,
  fetchImpl: typeof fetch = fetch,
): Promise<RankedItem | null> {
  const url = buildProxyUrl(
    supabaseUrl,
    `movie/${tmdbNumericId}?language=${language}&append_to_response=credits`,
  );

  try {
    const res = await fetchImpl(url, {
      headers: {
        Authorization: `Bearer ${accessToken}`,
        apikey: anonKey,
        accept: 'application/json',
      },
    });
    if (!res.ok) return null;
    const data = await res.json();
    return mapMovieDetailToRankedItem(data);
  } catch (err) {
    console.error('agent-rank movie fetch failed:', err);
    return null;
  }
}
