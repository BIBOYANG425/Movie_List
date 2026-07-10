/**
 * TMDB (The Movie Database) API service — proxy-routed.
 * Docs: https://developer.themoviedb.org/docs
 *
 * The web bundle no longer holds a TMDB key. Every TMDB request goes through the
 * authenticated `tmdb-proxy` edge function (see services/tmdbProxy.ts): the proxy
 * injects `TMDB_API_KEY` server-side and enforces a path allowlist. Requests carry
 * the caller's Supabase session JWT (Bearer) + the anon `apikey` header, mirroring
 * how the app invokes other edge functions. Signed-out callers have no session, so
 * proxyFetch short-circuits to a synthetic 401 — every consumer already treats a
 * non-ok response as "no results", preserving the pre-migration signed-out behavior
 * (fixtures / generic / empty).
 *
 * The 5-pool suggestion engine (getSmartSuggestions/getSmartBackfill + generic +
 * friend picks + taste-profile builders, both media) moved server-side into the
 * `suggestions` edge function (Task 1). Only the seams that still have client
 * callers remain here: search, details, person, season, and zh-title fetches.
 */

import { supabase } from '../lib/supabase';
import { typoRetryVariants } from './searchVariants';
import { buildProxyUrl } from './tmdbProxy';

/** TMDB public image CDN (no key required) — used to build poster/backdrop URLs. */
export const TMDB_IMAGE_BASE = 'https://image.tmdb.org/t/p/w500';
const DEFAULT_TMDB_SEARCH_TIMEOUT_MS = 4500;

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL as string;
const SUPABASE_ANON_KEY = import.meta.env.VITE_SUPABASE_ANON_KEY as string;

/** Read the user's locale from localStorage and return the TMDB language code. */
function getTmdbLocale(): string {
  const saved = typeof localStorage !== 'undefined' ? localStorage.getItem('spool_locale') : null;
  return saved === 'zh' ? 'zh-CN' : 'en-US';
}

/**
 * Single fetch seam. Routes a bare TMDB path (with its own query string, minus
 * api_key) through the tmdb-proxy edge function using the caller's session JWT.
 *
 * A signed-out caller (no session) returns a synthetic 401 Response WITHOUT
 * hitting the network — callers already read non-ok as empty, so this is the
 * signed-out gate. Any proxy non-2xx (401/403/429/502) is surfaced verbatim to
 * the caller's ok-check, which keeps typo-retry's "non-2xx skips variants" rule
 * intact now that proxy statuses stand in for the old direct-TMDB statuses.
 */
async function proxyFetch(tmdbPath: string, timeoutMs: number): Promise<Response> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await proxyRequest(tmdbPath, controller.signal);
  } finally {
    clearTimeout(timeout);
  }
}

/**
 * Lower-level proxy request driven by an EXTERNAL AbortSignal instead of an
 * internal timeout. Used by callers that own their own cancellation/backoff
 * (letterboxdImportService). Same auth + signed-out semantics as proxyFetch: a
 * missing session yields a synthetic 401 Response without touching the network.
 */
export async function proxyRequest(
  tmdbPath: string,
  signal?: AbortSignal,
): Promise<Response> {
  const { data } = await supabase.auth.getSession();
  const token = data.session?.access_token;
  if (!token) {
    // Signed out — no session to authenticate the proxy. Synthetic 401 so every
    // caller's `!res.ok` branch yields the same empty/generic result as before.
    return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401 });
  }

  const url = buildProxyUrl(SUPABASE_URL, tmdbPath);
  return fetch(url, {
    signal,
    headers: {
      Authorization: `Bearer ${token}`,
      apikey: SUPABASE_ANON_KEY,
      accept: 'application/json',
    },
  });
}

// Full genre map from TMDB (stable — rarely changes)
export const GENRE_MAP: Record<number, string> = {
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

/**
 * Access gate that replaces the old `hasTmdbKey()`. TMDB access now depends on
 * the Supabase edge functions (proxy + suggestions), not a client-bundled key,
 * so the gate is "is Supabase configured" — true in every real deployment. The
 * per-request session check lives in proxyFetch / functions.invoke, which return
 * 401 when signed out, and every consumer reads that as an empty result. This
 * preserves the pre-migration signed-out → generic/empty behavior without a key.
 * Kept named `hasTmdbKey` for a drop-in swap at existing call sites.
 */
export function hasTmdbKey(): boolean {
  return !!SUPABASE_URL && !!SUPABASE_ANON_KEY;
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

/**
 * Search TMDB for movies matching *query*.
 * Returns up to 10 results with real posters and metadata.
 */
export async function searchMovies(
  query: string,
  timeoutMs: number = DEFAULT_TMDB_SEARCH_TIMEOUT_MS,
): Promise<TMDBMovie[]> {
  if (!query.trim()) return [];

  // One fetch+map for a single query term. Reused verbatim by the zero-result
  // typo-retry loop below so retries share the exact same request/mapping path.
  // Returns null on a non-ok HTTP response so the caller can distinguish a real
  // zero-result from an HTTP error (429/5xx/401, now incl. proxy 401/403/429/502)
  // and skip the variant loop.
  const fetchAndMap = async (term: string): Promise<TMDBMovie[] | null> => {
    const path = new URLSearchParams({
      query: term,
      language: getTmdbLocale(),
      page: '1',
      include_adult: 'false',
    });

    const res = await proxyFetch(`search/movie?${path.toString()}`, timeoutMs);

    if (!res.ok) {
      // A 401 here is the synthetic signed-out gate from proxyRequest (no session,
      // no network hit) — an expected "no results" for anonymous callers, not a
      // fault. Don't log it as an error; only surface genuine upstream failures
      // (403/429/5xx). Either way we return null so the caller reads empty.
      if (res.status !== 401) {
        console.error(`TMDB API error: ${res.status} ${res.statusText}`);
      }
      return null;
    }

    const data = await res.json();

    return (data.results as any[])
      .map(mapTmdbResult)
      .filter((m): m is TMDBMovie => m !== null)
      .slice(0, 12);
  };

  try {
    const primary = await fetchAndMap(query);
    // null means HTTP error — bail immediately, no variant loop.
    if (primary === null) return [];
    if (primary.length > 0) return primary;

    // Zero-result path only: retry with cheap typo variants, first non-empty wins.
    // A non-ok response during variants also stops the loop.
    for (const variant of typoRetryVariants(query)) {
      const retry = await fetchAndMap(variant);
      if (retry === null) break;
      if (retry.length > 0) return retry;
    }

    return primary;
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
  if (!query.trim()) return [];

  try {
    const path = new URLSearchParams({
      query,
      language: getTmdbLocale(),
      page: '1',
      include_adult: 'false',
    });

    const res = await proxyFetch(`search/person?${path.toString()}`, timeoutMs);
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
  try {
    const lang = getTmdbLocale();
    const [personRes, creditsRes] = await Promise.all([
      proxyFetch(`person/${personId}?language=${lang}`, 5000),
      proxyFetch(`person/${personId}/movie_credits?language=${lang}`, 5000),
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
  if (!tmdbNumericId) return undefined;

  try {
    const res = await proxyFetch(
      `movie/${tmdbNumericId}?language=${getTmdbLocale()}`,
      4000,
    );
    if (!res.ok) return undefined;
    const data = await res.json();
    return typeof data.vote_average === 'number' ? data.vote_average : undefined;
  } catch {
    return undefined;
  }
}

/** A single billed cast member as returned by TMDB credits. */
export interface TMDBCastMember {
  id: number;
  name: string;
  character: string;
  profile_path: string | null;
}

/**
 * Fetch the top-billed cast for a movie.
 *
 * The proxy allowlist rejects `movie/{id}/credits` (Task 2 review, binding item
 * 1), so we ask for credits via the append_to_response on the base movie detail
 * — which IS allowlisted — and read `data.credits.cast`. Returns [] on any
 * failure (incl. signed-out 401) so the caller shows an empty cast list.
 */
export async function getMovieCredits(tmdbNumericId: number): Promise<TMDBCastMember[]> {
  if (!tmdbNumericId) return [];

  try {
    const res = await proxyFetch(
      `movie/${tmdbNumericId}?language=${getTmdbLocale()}&append_to_response=credits`,
      5000,
    );
    if (!res.ok) return [];
    const data = await res.json();
    const cast = data?.credits?.cast;
    if (!Array.isArray(cast)) return [];
    return cast.map((c: any): TMDBCastMember => ({
      id: c.id,
      name: c.name,
      character: c.character ?? '',
      profile_path: c.profile_path ?? null,
    }));
  } catch (err) {
    console.error('TMDB movie credits fetch failed:', err);
    return [];
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
  if (!tmdbNumericId) return null;

  try {
    // append_to_response keeps its literal `watch/providers,credits` value; the
    // proxy safelist pins exactly this set. The embedded '/' rides inside the
    // packed `path` param and is preserved end-to-end.
    const res = await proxyFetch(
      `movie/${tmdbNumericId}?language=${getTmdbLocale()}&append_to_response=watch/providers,credits`,
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

// ── TV Show Types & Service Functions ───────────────────────────────────────

/** TMDB TV genre ID → name mapping */
export const TV_GENRE_MAP: Record<number, string> = {
  10759: 'Action & Adventure',
  16: 'Animation',
  35: 'Comedy',
  80: 'Crime',
  99: 'Documentary',
  18: 'Drama',
  10751: 'Family',
  10762: 'Kids',
  9648: 'Mystery',
  10763: 'News',
  10764: 'Reality',
  10765: 'Sci-Fi & Fantasy',
  10766: 'Soap',
  10767: 'Talk',
  10768: 'War & Politics',
  37: 'Western',
};

/**
 * Normalize compound TV genre names to movie-compatible genre names
 * for bracket classification. E.g. "Action & Adventure" → ["Action", "Adventure"]
 */
export function normalizeTVGenres(tvGenreNames: string[]): string[] {
  const COMPOUND_MAP: Record<string, string[]> = {
    'Action & Adventure': ['Action', 'Adventure'],
    'Sci-Fi & Fantasy': ['Sci-Fi', 'Fantasy'],
    'War & Politics': ['War'],
    'Kids': ['Family'],
    'News': [],
    'Reality': [],
    'Soap': ['Drama'],
    'Talk': [],
  };

  const result: string[] = [];
  for (const g of tvGenreNames) {
    if (COMPOUND_MAP[g]) {
      result.push(...COMPOUND_MAP[g]);
    } else {
      result.push(g);
    }
  }
  return [...new Set(result)].slice(0, 3);
}

export interface TMDBTVShow {
  id: string;
  tmdbId: number;
  name: string;
  year: string;
  posterUrl: string | null;
  backdropUrl?: string | null;
  genres: string[];
  overview: string;
  seasonCount: number;
  status: string;
  creators: string[];
  voteAverage?: number;
  seasons?: TMDBTVSeasonSummary[];
}

export interface TMDBTVSeasonSummary {
  seasonNumber: number;
  name: string;
  posterUrl: string | null;
  episodeCount: number;
  airDate: string | null;
}

export interface TMDBTVSeason {
  id: number;
  showTmdbId: number;
  seasonNumber: number;
  name: string;
  showName: string;
  posterUrl: string | null;
  episodeCount: number;
  airDate: string | null;
  overview: string;
}

function mapTVGenres(genreIds: number[]): string[] {
  return genreIds
    .map(id => TV_GENRE_MAP[id])
    .filter(Boolean)
    .slice(0, 3);
}

// ── Suggestions edge-function client ─────────────────────────────────────────
// The 5-pool engine lives in the `suggestions` edge function (Task 1). These
// thin wrappers invoke it (JWT + apikey auto-attached by supabase.functions),
// map the provenance-tagged items back to the client TMDBMovie / TMDBTVShow
// shapes the modals + onboarding already render, and swallow errors → [] so a
// 401 (signed out) / 429 / 502 degrades to "no suggestions" exactly like the
// old key-gated engine returned [] when the key was absent.

export type SuggestionMode = 'suggestions' | 'backfill';

interface SuggestionResponseItem {
  id: string;
  tmdbId: number;
  title: string;
  year: string;
  posterUrl: string | null;
  backdropUrl: string | null;
  mediaType: 'movie' | 'tv';
  genres: string[];
  overview: string;
  voteAverage?: number;
  seasonCount?: number;
}

async function invokeSuggestions(
  mediaType: 'movie' | 'tv',
  mode: SuggestionMode,
  page: number,
  sessionExcludeIds: string[],
): Promise<SuggestionResponseItem[]> {
  try {
    const { data, error } = await supabase.functions.invoke('suggestions', {
      body: {
        mediaType,
        mode,
        page,
        locale: getTmdbLocale(),
        // Session-local consumed ids only, capped at 200 to match the function's
        // server-side cap (server also slices, this keeps the payload small).
        sessionExcludeIds: sessionExcludeIds.slice(0, 200),
      },
    });
    if (error) return [];
    const items = (data as { items?: SuggestionResponseItem[] } | null)?.items;
    return Array.isArray(items) ? items : [];
  } catch {
    return [];
  }
}

/** Fetch movie suggestions/backfill via the edge function, mapped to TMDBMovie. */
export async function fetchMovieSuggestions(
  mode: SuggestionMode,
  page: number,
  sessionExcludeIds: string[],
): Promise<TMDBMovie[]> {
  const items = await invokeSuggestions('movie', mode, page, sessionExcludeIds);
  return items.map((m): TMDBMovie => ({
    id: m.id,
    tmdbId: m.tmdbId,
    title: m.title,
    year: m.year,
    posterUrl: m.posterUrl,
    backdropUrl: m.backdropUrl,
    type: 'movie',
    genres: m.genres ?? [],
    overview: m.overview ?? '',
    voteAverage: m.voteAverage,
  }));
}

/** Fetch TV suggestions/backfill via the edge function, mapped to TMDBTVShow. */
export async function fetchTVSuggestions(
  mode: SuggestionMode,
  page: number,
  sessionExcludeIds: string[],
): Promise<TMDBTVShow[]> {
  const items = await invokeSuggestions('tv', mode, page, sessionExcludeIds);
  return items.map((s): TMDBTVShow => ({
    id: s.id,
    tmdbId: s.tmdbId,
    name: s.title,
    year: s.year,
    posterUrl: s.posterUrl,
    backdropUrl: s.backdropUrl,
    genres: s.genres ?? [],
    overview: s.overview ?? '',
    seasonCount: s.seasonCount ?? 0,
    status: '',
    creators: [],
    voteAverage: s.voteAverage,
  }));
}

/**
 * Fetch a single item's localized (Chinese) title + overview by Spool id.
 *
 * Powers the useLocalizedItems hook. Accepts the Spool composite id form:
 *   - `tv_{showId}` or `tv_{showId}_s{n}` → GET tv/{showId}?language=zh-CN
 *   - `tmdb_{movieId}`                    → GET movie/{movieId}?language=zh-CN
 * Returns null on any failure (incl. signed-out 401), so the hook falls back to
 * the original title exactly as before.
 */
export async function fetchLocalizedTitle(
  id: string,
  language: string = 'zh-CN',
): Promise<{ title: string; overview?: string } | null> {
  try {
    const tvMatch = id.match(/^tv_(\d+)(?:_s\d+)?$/);
    if (tvMatch) {
      const res = await proxyFetch(`tv/${tvMatch[1]}?language=${language}`, 5000);
      if (!res.ok) return null;
      const data = await res.json();
      return { title: data.name as string, overview: data.overview as string | undefined };
    }

    const numericId = id.replace('tmdb_', '');
    const res = await proxyFetch(`movie/${numericId}?language=${language}`, 5000);
    if (!res.ok) return null;
    const data = await res.json();
    return { title: data.title as string, overview: data.overview as string | undefined };
  } catch {
    return null;
  }
}

/**
 * Search TMDB for TV shows matching *query*.
 */
export async function searchTVShows(
  query: string,
  timeoutMs: number = DEFAULT_TMDB_SEARCH_TIMEOUT_MS,
): Promise<TMDBTVShow[]> {
  if (!query.trim()) return [];

  // One fetch+map for a single query term. Reused verbatim by the zero-result
  // typo-retry loop below so retries share the exact same request/mapping path.
  // Returns null on a non-ok HTTP response so the caller can distinguish a real
  // zero-result from an HTTP error (429/5xx/401, now incl. proxy 401/403/429/502)
  // and skip the variant loop.
  const fetchAndMap = async (term: string): Promise<TMDBTVShow[] | null> => {
    const path = new URLSearchParams({
      query: term,
      language: getTmdbLocale(),
      page: '1',
      include_adult: 'false',
    });

    const res = await proxyFetch(`search/tv?${path.toString()}`, timeoutMs);
    if (!res.ok) return null;

    const data = await res.json();

    return (data.results as any[])
      .filter((s: any) => s.poster_path)
      .slice(0, 12)
      .map((s: any): TMDBTVShow => ({
        id: `tv_${s.id}`,
        tmdbId: s.id,
        name: s.name,
        year: s.first_air_date ? s.first_air_date.slice(0, 4) : '—',
        posterUrl: s.poster_path ? `${TMDB_IMAGE_BASE}${s.poster_path}` : null,
        backdropUrl: s.backdrop_path ? `${TMDB_IMAGE_BASE}${s.backdrop_path}` : null,
        genres: mapTVGenres(s.genre_ids ?? []),
        overview: s.overview ?? '',
        seasonCount: 0,  // not available in search results
        status: '',
        creators: [],
        voteAverage: typeof s.vote_average === 'number' ? s.vote_average : undefined,
      }));
  };

  try {
    const primary = await fetchAndMap(query);
    // null means HTTP error — bail immediately, no variant loop.
    if (primary === null) return [];
    if (primary.length > 0) return primary;

    // Zero-result path only: retry with cheap typo variants, first non-empty wins.
    // A non-ok response during variants also stops the loop.
    for (const variant of typoRetryVariants(query)) {
      const retry = await fetchAndMap(variant);
      if (retry === null) break;
      if (retry.length > 0) return retry;
    }

    return primary;
  } catch (err) {
    if (err instanceof DOMException && err.name === 'AbortError') return [];
    console.error('TMDB TV search failed:', err);
    return [];
  }
}

/**
 * Fetch full TV show details including seasons list.
 * Filters out season 0 (specials).
 */
export async function getTVShowDetails(showId: number): Promise<TMDBTVShow | null> {
  if (!showId) return null;

  try {
    const res = await proxyFetch(
      `tv/${showId}?language=${getTmdbLocale()}`,
      5000,
    );
    if (!res.ok) return null;
    const data = await res.json();

    const genres = (data.genres as any[] ?? []).map((g: any) => g.name as string);
    const seasons: TMDBTVSeasonSummary[] = (data.seasons as any[] ?? [])
      .filter((s: any) => s.season_number > 0)
      .map((s: any) => ({
        seasonNumber: s.season_number,
        name: s.name,
        posterUrl: s.poster_path ? `${TMDB_IMAGE_BASE}${s.poster_path}` : null,
        episodeCount: s.episode_count ?? 0,
        airDate: s.air_date ?? null,
      }));

    return {
      id: `tv_${data.id}`,
      tmdbId: data.id,
      name: data.name,
      year: data.first_air_date ? data.first_air_date.slice(0, 4) : '—',
      posterUrl: data.poster_path ? `${TMDB_IMAGE_BASE}${data.poster_path}` : null,
      backdropUrl: data.backdrop_path ? `${TMDB_IMAGE_BASE}${data.backdrop_path}` : null,
      genres,
      overview: data.overview ?? '',
      seasonCount: seasons.length,
      status: data.status ?? '',
      creators: (data.created_by as any[] ?? []).map((c: any) => c.name as string),
      voteAverage: typeof data.vote_average === 'number' ? data.vote_average : undefined,
      seasons,
    };
  } catch (err) {
    console.error('TMDB TV show details failed:', err);
    return null;
  }
}

/**
 * Fetch details for a specific TV season.
 */
export async function getTVSeasonDetails(
  showId: number,
  seasonNum: number,
  showName: string = '',
): Promise<TMDBTVSeason | null> {
  if (!showId) return null;

  try {
    const res = await proxyFetch(
      `tv/${showId}/season/${seasonNum}?language=${getTmdbLocale()}`,
      5000,
    );
    if (!res.ok) return null;
    const data = await res.json();

    return {
      id: data.id,
      showTmdbId: showId,
      seasonNumber: data.season_number,
      name: data.name ?? `Season ${seasonNum}`,
      showName,
      posterUrl: data.poster_path ? `${TMDB_IMAGE_BASE}${data.poster_path}` : null,
      episodeCount: (data.episodes as any[] ?? []).length,
      airDate: data.air_date ?? null,
      overview: data.overview ?? '',
    };
  } catch (err) {
    console.error('TMDB TV season details failed:', err);
    return null;
  }
}

/**
 * Fetch the global average score (vote_average) for a TV show.
 */
export async function getTVShowGlobalScore(showId: number): Promise<number | undefined> {
  if (!showId) return undefined;

  try {
    const res = await proxyFetch(
      `tv/${showId}?language=${getTmdbLocale()}`,
      4000,
    );
    if (!res.ok) return undefined;
    const data = await res.json();
    return typeof data.vote_average === 'number' ? data.vote_average : undefined;
  } catch {
    return undefined;
  }
}
