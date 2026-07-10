/**
 * suggestions — 5-pool suggestion engine, server-side.
 *
 * Moves the client-side engine (services/tmdbService.ts, audit §1.3-§1.5) behind
 * an authenticated edge function so the TMDB key leaves both app bundles. Reads
 * the caller's rankings + watchlist under their FORWARDED JWT (RLS-scoped, no
 * service role), builds the taste profile + exclusions (B1-normalized), runs the
 * TMDB pools, and returns provenance-tagged items. Modes: suggestions | backfill
 * | new_releases. Pure engine logic lives in ./engine.ts (import-clean; the same
 * file is exercised by services/__tests__/suggestionsEngine.test.ts under vitest).
 *
 * ── Deployment (implementers NEVER deploy; the controller does) ──
 *   Redeploy:  `supabase functions deploy suggestions`
 *              (or MCP `deploy_edge_function` name="suggestions").
 *   Secret:    TMDB_API_KEY  (already set by the owner in the function store).
 *   Rollback:  delete the function (`supabase functions delete suggestions`
 *              or MCP delete_edge_function). Old clients don't call it, so
 *              deletion is safe pre-migration.
 *
 * Caching: none per §2 (randomness-on-refresh is the product). Per-user in-memory
 * token bucket (~30 req/min per isolate) guards TMDB quota.
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import {
  DEFAULT_POOL_SLOTS,
  TMDB_BASE,
  buildMovieProfile,
  buildTVProfile,
  buildMovieExclusions,
  buildTVExclusions,
  buildDiscoverUrl,
  genreNamesToIds,
  tvGenreNamesToIds,
  mapMovieResult,
  mapTVResult,
  dedupById,
  interleave,
  shuffle,
  assemble,
  isBelowThreshold,
  filterNewReleases,
  topWeightedGenres,
  TV_GENRE_NAME_TO_ID,
  type Exclusions,
  type Pools,
  type SuggestionItem,
  type TasteProfile,
} from './engine.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
}

const SESSION_EXCLUDE_CAP = 200
const NEW_RELEASES_DEFAULT_LIMIT = 10

// ── Request validation ───────────────────────────────────────────────────────

interface RequestBody {
  mediaType: 'movie' | 'tv'
  mode: 'suggestions' | 'backfill' | 'new_releases'
  page: number
  poolSlots?: Record<string, number>
  locale?: string
  sessionExcludeIds?: string[]
  limit?: number
}

function validateRequestBody(
  body: unknown,
): { valid: true; data: RequestBody } | { valid: false; error: string } {
  if (!body || typeof body !== 'object') {
    return { valid: false, error: 'Request body must be a JSON object' }
  }
  const b = body as Record<string, unknown>

  if (b.mediaType !== 'movie' && b.mediaType !== 'tv') {
    return { valid: false, error: 'mediaType must be "movie" or "tv"' }
  }
  if (
    b.mode !== 'suggestions' &&
    b.mode !== 'backfill' &&
    b.mode !== 'new_releases'
  ) {
    return {
      valid: false,
      error: 'mode must be "suggestions", "backfill", or "new_releases"',
    }
  }
  if (b.mode === 'new_releases' && b.mediaType !== 'movie') {
    return { valid: false, error: 'new_releases mode supports mediaType "movie" only' }
  }

  const page = b.page === undefined ? 1 : b.page
  if (typeof page !== 'number' || !Number.isFinite(page) || page < 1) {
    return { valid: false, error: 'page must be a positive number' }
  }

  if (b.poolSlots !== undefined) {
    if (typeof b.poolSlots !== 'object' || b.poolSlots === null) {
      return { valid: false, error: 'poolSlots must be an object' }
    }
    for (const [, v] of Object.entries(b.poolSlots as Record<string, unknown>)) {
      if (typeof v !== 'number' || !Number.isFinite(v) || v < 0) {
        return { valid: false, error: 'poolSlots values must be non-negative numbers' }
      }
    }
  }

  if (b.locale !== undefined && typeof b.locale !== 'string') {
    return { valid: false, error: 'locale must be a string' }
  }

  if (b.sessionExcludeIds !== undefined) {
    if (!Array.isArray(b.sessionExcludeIds)) {
      return { valid: false, error: 'sessionExcludeIds must be an array' }
    }
    if ((b.sessionExcludeIds as unknown[]).length > SESSION_EXCLUDE_CAP) {
      return {
        valid: false,
        error: `sessionExcludeIds exceeds cap of ${SESSION_EXCLUDE_CAP}`,
      }
    }
    for (const s of b.sessionExcludeIds as unknown[]) {
      if (typeof s !== 'string') {
        return { valid: false, error: 'sessionExcludeIds must be strings' }
      }
    }
  }

  if (b.limit !== undefined) {
    if (typeof b.limit !== 'number' || !Number.isFinite(b.limit) || b.limit < 1) {
      return { valid: false, error: 'limit must be a positive number' }
    }
  }

  return {
    valid: true,
    data: {
      mediaType: b.mediaType,
      mode: b.mode,
      page,
      poolSlots: b.poolSlots as Record<string, number> | undefined,
      locale: b.locale as string | undefined,
      sessionExcludeIds: (b.sessionExcludeIds as string[] | undefined) ?? [],
      limit: b.limit as number | undefined,
    },
  }
}

/** Normalize a caller locale to a TMDB language code (mirrors getTmdbLocale). */
function tmdbLanguage(locale?: string): string {
  return locale && locale.startsWith('zh') ? 'zh-CN' : 'en-US'
}

// ── Per-user in-memory token bucket (~30 req/min per isolate) ────────────────

const RATE_LIMIT = 30
const RATE_WINDOW_MS = 60_000
const buckets = new Map<string, { count: number; resetAt: number }>()

function rateLimited(userId: string): boolean {
  const now = Date.now()
  const b = buckets.get(userId)
  if (!b || now >= b.resetAt) {
    buckets.set(userId, { count: 1, resetAt: now + RATE_WINDOW_MS })
    return false
  }
  if (b.count >= RATE_LIMIT) return true
  b.count++
  return false
}

// ── TMDB fetch helper ────────────────────────────────────────────────────────

/** Fetch + parse JSON with a timeout. Returns null on any non-ok / error. */
async function fetchJson(url: string, timeoutMs = 6000): Promise<any | null> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), timeoutMs)
  try {
    const res = await fetch(url, { signal: controller.signal })
    if (!res.ok) return null
    return await res.json()
  } catch {
    return null
  } finally {
    clearTimeout(timeout)
  }
}

const rand = () => Math.random()
const randInt = (n: number) => Math.floor(Math.random() * n)

// ── Movie engine ─────────────────────────────────────────────────────────────

interface MovieCtx {
  apiKey: string
  language: string
  page: number
  slots: Record<string, number>
  profile: TasteProfile
  exclusions: Exclusions
  userClient: ReturnType<typeof createClient>
  userId: string
}

function excluded(m: SuggestionItem, ex: Exclusions): boolean {
  return (
    ex.ids.has(m.id) ||
    ex.ids.has(String(m.tmdbId)) ||
    ex.titles.has(m.title.toLowerCase())
  )
}

/** Generic movie suggestions (below-threshold fallback, §1.3). */
async function genericMovies(ctx: MovieCtx): Promise<SuggestionItem[]> {
  const { apiKey, language, page, exclusions } = ctx
  const currentYear = new Date().getFullYear()

  const recent = buildDiscoverUrl({
    base: `${TMDB_BASE}/discover/movie`,
    apiKey, language, sortBy: 'popularity.desc', voteCountGte: '50', page,
    dateWindow: { field: 'primary_release_date', gte: `${currentYear - 2}-01-01` },
  })
  const classic = buildDiscoverUrl({
    base: `${TMDB_BASE}/discover/movie`,
    apiKey, language, sortBy: 'vote_average.desc', voteCountGte: '1000', page,
    dateWindow: { field: 'primary_release_date', lte: `${currentYear - 5}-12-31` },
  })

  const [recentData, classicData] = await Promise.all([fetchJson(recent), fetchJson(classic)])
  if (!recentData || !classicData) return []

  const newFilms = (recentData.results as any[] ?? [])
    .map((m) => mapMovieResult(m, 'generic'))
    .filter((m): m is SuggestionItem => m !== null && !excluded(m, exclusions))
    .slice(0, 6)
  const classics = (classicData.results as any[] ?? [])
    .map((m) => mapMovieResult(m, 'generic'))
    .filter((m): m is SuggestionItem => m !== null && !excluded(m, exclusions))
    .slice(0, 6)

  return shuffle(dedupById(interleave(newFilms, classics)).slice(0, 12), rand)
}

/** Friend pool (movie): S/A rankings from follows, RLS-scoped. */
async function friendMovies(ctx: MovieCtx, limit: number): Promise<SuggestionItem[]> {
  const { userClient, userId, exclusions } = ctx
  try {
    const { data: follows } = await userClient
      .from('friend_follows')
      .select('following_id')
      .eq('follower_id', userId)
    const friendIds = (follows ?? []).map((f: any) => f.following_id)
    if (friendIds.length === 0) return []

    const { data: rankings } = await userClient
      .from('user_rankings')
      .select('tmdb_id, title, poster_url, year, genres')
      .in('user_id', friendIds)
      .in('tier', ['S', 'A'])
      .limit(100)
    if (!rankings || rankings.length === 0) return []

    const candidates = (rankings as any[])
      .filter((r) => !exclusions.ids.has(String(r.tmdb_id)) && r.poster_url)
      .reduce((acc: any[], r) => {
        if (!acc.some((a) => a.tmdb_id === r.tmdb_id)) acc.push(r)
        return acc
      }, [])

    return shuffle(candidates, rand)
      .slice(0, limit)
      .map((r: any): SuggestionItem => ({
        id: String(r.tmdb_id),
        tmdbId: parseInt(String(r.tmdb_id).replace('tmdb_', ''), 10) || 0,
        title: r.title,
        year: r.year ?? '—',
        posterUrl: r.poster_url,
        backdropUrl: null,
        mediaType: 'movie',
        genres: r.genres ?? [],
        overview: '',
        seasonCount: 0,
        pool: 'friend',
      }))
  } catch {
    return []
  }
}

/** 5-pool movie suggestions (§1.3, quirks preserved). */
async function smartMovies(ctx: MovieCtx): Promise<SuggestionItem[]> {
  const { apiKey, language, page, slots, profile, exclusions } = ctx

  if (isBelowThreshold(profile)) return genericMovies(ctx)

  const genreParam = genreNamesToIds(topWeightedGenres(profile, 3)).join(',')

  // Pool 1: Similar (ONE random S/A pick; overfetch +2)
  const similarP = (async (): Promise<SuggestionItem[]> => {
    if (profile.topMovieIds.length === 0) return []
    const pickId = profile.topMovieIds[randInt(profile.topMovieIds.length)]
    const data = await fetchJson(
      `${TMDB_BASE}/movie/${pickId}/similar?api_key=${apiKey}&language=${language}&page=${page}`,
    )
    if (!data) return []
    return (data.results as any[] ?? [])
      .map((m) => mapMovieResult(m, 'similar'))
      .filter((m): m is SuggestionItem => m !== null && !excluded(m, exclusions))
      .slice(0, slots.similar + 2)
  })()

  // Pool 2: Taste (top-3 genres, coin-flip decade, page + rand(0..2); overfetch +2)
  const tasteP = (async (): Promise<SuggestionItem[]> => {
    let dateWindow: { field: string; gte: string; lte: string } | undefined
    if (profile.preferredDecade) {
      const decadeStart = parseInt(profile.preferredDecade, 10)
      if (!isNaN(decadeStart) && rand() < 0.5) {
        dateWindow = {
          field: 'primary_release_date',
          gte: `${decadeStart}-01-01`,
          lte: `${decadeStart + 9}-12-31`,
        }
      }
    }
    const url = buildDiscoverUrl({
      base: `${TMDB_BASE}/discover/movie`,
      apiKey, language, sortBy: 'vote_average.desc', voteCountGte: '200',
      withGenres: genreParam || undefined,
      page: page + randInt(3),
      dateWindow,
    })
    const data = await fetchJson(url)
    if (!data) return []
    return (data.results as any[] ?? [])
      .map((m) => mapMovieResult(m, 'taste'))
      .filter((m): m is SuggestionItem => m !== null && !excluded(m, exclusions))
      .slice(0, slots.taste + 2)
  })()

  // Pool 3: Trending
  const trendingP = (async (): Promise<SuggestionItem[]> => {
    const data = await fetchJson(
      `${TMDB_BASE}/trending/movie/week?api_key=${apiKey}&language=${language}&page=${page}`,
    )
    if (!data) return []
    return (data.results as any[] ?? [])
      .map((m) => mapMovieResult(m, 'trending'))
      .filter((m): m is SuggestionItem => m !== null && !excluded(m, exclusions))
      .slice(0, slots.trending + 2)
  })()

  // Pool 4: Variety (2 random underexposed genres, page = 1 + rand(0..2) — ignores page param, D4)
  const varietyP = (async (): Promise<SuggestionItem[]> => {
    if (profile.underexposedGenres.length === 0) return []
    const pickGenres = shuffle(profile.underexposedGenres, rand).slice(0, 2)
    const varietyGenreParam = genreNamesToIds(pickGenres).join(',')
    if (!varietyGenreParam) return []
    const url = buildDiscoverUrl({
      base: `${TMDB_BASE}/discover/movie`,
      apiKey, language, sortBy: 'popularity.desc', voteCountGte: '100',
      withGenres: varietyGenreParam,
      page: 1 + randInt(3),
    })
    const data = await fetchJson(url)
    if (!data) return []
    return (data.results as any[] ?? [])
      .map((m) => mapMovieResult(m, 'variety'))
      .filter((m): m is SuggestionItem => m !== null && !excluded(m, exclusions))
      .slice(0, slots.variety + 2)
  })()

  // Pool 5: Friend (overfetch +1)
  const friendP = friendMovies(ctx, slots.friend + 1)

  const [similar, taste, trending, variety, friend] = await Promise.all([
    similarP, tasteP, trendingP, varietyP, friendP,
  ])

  const p: Pools = { similar, taste, trending, variety, friend }
  return assemble(p, slots, rand)
}

/** Movie backfill (§1.3: no threshold, recommendations of 2 random top ids, variety pad, cap 20). */
async function backfillMovies(ctx: MovieCtx): Promise<SuggestionItem[]> {
  const { apiKey, language, page, profile, exclusions } = ctx

  if (profile.topMovieIds.length === 0) return genericMovies(ctx)

  let movies: SuggestionItem[] = []
  const sampleIds = shuffle(profile.topMovieIds, rand).slice(0, 2)
  const results = await Promise.all(
    sampleIds.map((id) =>
      fetchJson(`${TMDB_BASE}/movie/${id}/recommendations?api_key=${apiKey}&language=${language}&page=${page}`),
    ),
  )
  for (const data of results) {
    if (!data) continue
    movies.push(
      ...(data.results as any[] ?? [])
        .map((m) => mapMovieResult(m, 'backfill'))
        .filter((m): m is SuggestionItem => m !== null && !excluded(m, exclusions)),
    )
  }
  movies = dedupById(movies)

  if (movies.length < 12 && profile.underexposedGenres.length > 0) {
    const pickGenres = shuffle(profile.underexposedGenres, rand).slice(0, 2)
    const varietyParam = genreNamesToIds(pickGenres).join(',')
    if (varietyParam) {
      const url = buildDiscoverUrl({
        base: `${TMDB_BASE}/discover/movie`,
        apiKey, language, sortBy: 'popularity.desc', voteCountGte: '100',
        withGenres: varietyParam, page,
      })
      const data = await fetchJson(url)
      if (data) {
        const varietyMovies = (data.results as any[] ?? [])
          .map((m) => mapMovieResult(m, 'backfill'))
          .filter((m): m is SuggestionItem => m !== null && !excluded(m, exclusions))
        movies = dedupById([...movies, ...varietyMovies])
      }
    }
  }

  return shuffle(movies, rand).slice(0, 20)
}

/** new_releases (movie-only): now_playing + upcoming, taste-filtered, date-asc. */
async function newReleaseMovies(ctx: MovieCtx, limit: number): Promise<SuggestionItem[]> {
  const { apiKey, language, profile, exclusions } = ctx
  const [nowPlaying, upcoming] = await Promise.all([
    fetchJson(`${TMDB_BASE}/movie/now_playing?api_key=${apiKey}&language=${language}&page=1`),
    fetchJson(`${TMDB_BASE}/movie/upcoming?api_key=${apiKey}&language=${language}&page=1`),
  ])
  const raw = [
    ...((nowPlaying?.results as any[]) ?? []),
    ...((upcoming?.results as any[]) ?? []),
  ]
  return filterNewReleases(raw, profile, exclusions, limit)
}

// ── TV engine ────────────────────────────────────────────────────────────────

interface TVCtx {
  apiKey: string
  language: string
  page: number
  slots: Record<string, number>
  profile: TasteProfile
  exclusions: Exclusions
  userClient: ReturnType<typeof createClient>
  userId: string
}

async function genericTV(ctx: TVCtx): Promise<SuggestionItem[]> {
  const { apiKey, language, page, exclusions } = ctx
  const currentYear = new Date().getFullYear()

  const recent = buildDiscoverUrl({
    base: `${TMDB_BASE}/discover/tv`,
    apiKey, language, sortBy: 'popularity.desc', voteCountGte: '30', page,
    dateWindow: { field: 'first_air_date', gte: `${currentYear - 2}-01-01` },
  })
  const classic = buildDiscoverUrl({
    base: `${TMDB_BASE}/discover/tv`,
    apiKey, language, sortBy: 'vote_average.desc', voteCountGte: '500', page,
    dateWindow: { field: 'first_air_date', lte: `${currentYear - 5}-12-31` },
  })

  const [recentData, classicData] = await Promise.all([fetchJson(recent), fetchJson(classic)])
  if (!recentData || !classicData) return []

  const newShows = (recentData.results as any[] ?? [])
    .map((s) => mapTVResult(s, 'generic'))
    .filter((s): s is SuggestionItem => s !== null && !excluded(s, exclusions))
    .slice(0, 6)
  const classics = (classicData.results as any[] ?? [])
    .map((s) => mapTVResult(s, 'generic'))
    .filter((s): s is SuggestionItem => s !== null && !excluded(s, exclusions))
    .slice(0, 6)

  return shuffle(dedupById(interleave(newShows, classics)).slice(0, 12), rand)
}

async function friendTV(ctx: TVCtx, limit: number): Promise<SuggestionItem[]> {
  const { userClient, userId, exclusions } = ctx
  try {
    const { data: follows } = await userClient
      .from('friend_follows')
      .select('following_id')
      .eq('follower_id', userId)
    const friendIds = (follows ?? []).map((f: any) => f.following_id)
    if (friendIds.length === 0) return []

    const { data: rankings } = await userClient
      .from('tv_rankings')
      .select('tmdb_id, show_tmdb_id, title, poster_url, year, genres')
      .in('user_id', friendIds)
      .in('tier', ['S', 'A'])
      .limit(100)
    if (!rankings || rankings.length === 0) return []

    const candidates = (rankings as any[])
      .filter((r) => !exclusions.ids.has(`tv_${r.show_tmdb_id}`) && r.poster_url)
      .reduce((acc: any[], r) => {
        if (!acc.some((a) => a.show_tmdb_id === r.show_tmdb_id)) acc.push(r)
        return acc
      }, [])

    return shuffle(candidates, rand)
      .slice(0, limit)
      .map((r: any): SuggestionItem => ({
        id: `tv_${r.show_tmdb_id}`,
        tmdbId: r.show_tmdb_id,
        title: r.title,
        year: r.year ?? '—',
        posterUrl: r.poster_url,
        backdropUrl: null,
        mediaType: 'tv',
        genres: r.genres ?? [],
        overview: '',
        seasonCount: 0,
        pool: 'friend',
      }))
  } catch {
    return []
  }
}

async function smartTV(ctx: TVCtx): Promise<SuggestionItem[]> {
  const { apiKey, language, page, slots, profile, exclusions } = ctx

  if (isBelowThreshold(profile)) return genericTV(ctx)

  const genreParam = tvGenreNamesToIds(topWeightedGenres(profile, 3)).join(',')

  const similarP = (async (): Promise<SuggestionItem[]> => {
    if (profile.topMovieIds.length === 0) return []
    const pickId = profile.topMovieIds[randInt(profile.topMovieIds.length)]
    const data = await fetchJson(
      `${TMDB_BASE}/tv/${pickId}/similar?api_key=${apiKey}&language=${language}&page=${page}`,
    )
    if (!data) return []
    return (data.results as any[] ?? [])
      .map((s) => mapTVResult(s, 'similar'))
      .filter((s): s is SuggestionItem => s !== null && !excluded(s, exclusions))
      .slice(0, slots.similar + 2)
  })()

  const tasteP = (async (): Promise<SuggestionItem[]> => {
    let dateWindow: { field: string; gte: string; lte: string } | undefined
    if (profile.preferredDecade) {
      const decadeStart = parseInt(profile.preferredDecade, 10)
      if (!isNaN(decadeStart) && rand() < 0.5) {
        dateWindow = {
          field: 'first_air_date',
          gte: `${decadeStart}-01-01`,
          lte: `${decadeStart + 9}-12-31`,
        }
      }
    }
    const url = buildDiscoverUrl({
      base: `${TMDB_BASE}/discover/tv`,
      apiKey, language, sortBy: 'vote_average.desc', voteCountGte: '100',
      withGenres: genreParam || undefined,
      page: page + randInt(3),
      dateWindow,
    })
    const data = await fetchJson(url)
    if (!data) return []
    return (data.results as any[] ?? [])
      .map((s) => mapTVResult(s, 'taste'))
      .filter((s): s is SuggestionItem => s !== null && !excluded(s, exclusions))
      .slice(0, slots.taste + 2)
  })()

  const trendingP = (async (): Promise<SuggestionItem[]> => {
    const data = await fetchJson(
      `${TMDB_BASE}/trending/tv/week?api_key=${apiKey}&language=${language}&page=${page}`,
    )
    if (!data) return []
    return (data.results as any[] ?? [])
      .map((s) => mapTVResult(s, 'trending'))
      .filter((s): s is SuggestionItem => s !== null && !excluded(s, exclusions))
      .slice(0, slots.trending + 2)
  })()

  const varietyP = (async (): Promise<SuggestionItem[]> => {
    if (profile.underexposedGenres.length === 0) return []
    const pickGenres = shuffle(profile.underexposedGenres, rand).slice(0, 2)
    // underexposedGenres are raw TV genre names → map directly
    const varietyIds = pickGenres
      .map((g) => TV_GENRE_NAME_TO_ID[g])
      .filter((id): id is number => id !== undefined)
    if (varietyIds.length === 0) return []
    const url = buildDiscoverUrl({
      base: `${TMDB_BASE}/discover/tv`,
      apiKey, language, sortBy: 'popularity.desc', voteCountGte: '50',
      withGenres: varietyIds.join(','),
      page: 1 + randInt(3),
    })
    const data = await fetchJson(url)
    if (!data) return []
    return (data.results as any[] ?? [])
      .map((s) => mapTVResult(s, 'variety'))
      .filter((s): s is SuggestionItem => s !== null && !excluded(s, exclusions))
      .slice(0, slots.variety + 2)
  })()

  const friendP = friendTV(ctx, slots.friend + 1)

  const [similar, taste, trending, variety, friend] = await Promise.all([
    similarP, tasteP, trendingP, varietyP, friendP,
  ])

  const p: Pools = { similar, taste, trending, variety, friend }
  return assemble(p, slots, rand)
}

async function backfillTV(ctx: TVCtx): Promise<SuggestionItem[]> {
  const { apiKey, language, page, profile, exclusions } = ctx

  if (profile.topMovieIds.length === 0) return genericTV(ctx)

  let shows: SuggestionItem[] = []
  const sampleIds = shuffle(profile.topMovieIds, rand).slice(0, 2)
  const results = await Promise.all(
    sampleIds.map((id) =>
      fetchJson(`${TMDB_BASE}/tv/${id}/recommendations?api_key=${apiKey}&language=${language}&page=${page}`),
    ),
  )
  for (const data of results) {
    if (!data) continue
    shows.push(
      ...(data.results as any[] ?? [])
        .map((s) => mapTVResult(s, 'backfill'))
        .filter((s): s is SuggestionItem => s !== null && !excluded(s, exclusions)),
    )
  }
  shows = dedupById(shows)

  if (shows.length < 12 && profile.underexposedGenres.length > 0) {
    const pickGenres = shuffle(profile.underexposedGenres, rand).slice(0, 2)
    const varietyIds = pickGenres
      .map((g) => TV_GENRE_NAME_TO_ID[g])
      .filter((id): id is number => id !== undefined)
    if (varietyIds.length > 0) {
      const url = buildDiscoverUrl({
        base: `${TMDB_BASE}/discover/tv`,
        apiKey, language, sortBy: 'popularity.desc', voteCountGte: '50',
        withGenres: varietyIds.join(','), page,
      })
      const data = await fetchJson(url)
      if (data) {
        const varietyShows = (data.results as any[] ?? [])
          .map((s) => mapTVResult(s, 'backfill'))
          .filter((s): s is SuggestionItem => s !== null && !excluded(s, exclusions))
        shows = dedupById([...shows, ...varietyShows])
      }
    }
  }

  return shuffle(shows, rand).slice(0, 20)
}

// ── Data reads (RLS-scoped under the caller's JWT) ───────────────────────────

async function loadMovieData(
  userClient: ReturnType<typeof createClient>,
  sessionExcludeIds: string[],
): Promise<{ profile: TasteProfile; exclusions: Exclusions }> {
  const [rankingsRes, watchlistRes] = await Promise.all([
    userClient.from('user_rankings').select('tmdb_id, title, year, genres, tier, director'),
    userClient.from('watchlist_items').select('tmdb_id, title'),
  ])
  const rankings = (rankingsRes.data ?? []) as any[]
  const watchlist = (watchlistRes.data ?? []) as any[]

  // The profile's item id must be the `tmdb_{n}` form the web client uses (its
  // in-memory items are always tmdb_-prefixed), NOT the row's UUID PK — the
  // topMovieIds regex `/tmdb_(\d+)/` runs against this id.
  const profileItems = rankings.map((r) => ({
    id: `tmdb_${String(r.tmdb_id).replace(/^tmdb_/, '')}`,
    genres: r.genres ?? [],
    year: r.year ?? '',
    tier: r.tier ?? 'B',
    director: r.director ?? undefined,
  }))
  const profile = buildMovieProfile(profileItems)
  const exclusions = buildMovieExclusions(
    rankings.map((r) => ({ tmdb_id: r.tmdb_id, title: r.title })),
    watchlist.map((w) => ({ tmdb_id: w.tmdb_id, title: w.title })),
    sessionExcludeIds,
  )
  return { profile, exclusions }
}

async function loadTVData(
  userClient: ReturnType<typeof createClient>,
  sessionExcludeIds: string[],
): Promise<{ profile: TasteProfile; exclusions: Exclusions }> {
  const [rankingsRes, watchlistRes] = await Promise.all([
    userClient
      .from('tv_rankings')
      .select('tmdb_id, show_tmdb_id, season_number, title, year, genres, tier, creator'),
    userClient.from('tv_watchlist_items').select('show_tmdb_id, title'),
  ])
  const rankings = (rankingsRes.data ?? []) as any[]
  const watchlist = (watchlistRes.data ?? []) as any[]

  // Profile item id must be the season-shaped `tv_{show}_s{n}` form the show-id
  // regex `/^tv_(\d+)_s\d+$/` expects. The tmdb_id text column already carries
  // it; fall back to reconstructing from show_tmdb_id + season_number.
  const profileItems = rankings.map((r) => ({
    id: /^tv_\d+_s\d+$/.test(String(r.tmdb_id))
      ? String(r.tmdb_id)
      : `tv_${r.show_tmdb_id}_s${r.season_number ?? 1}`,
    genres: r.genres ?? [],
    year: r.year ?? '',
    tier: r.tier ?? 'B',
    creator: r.creator ?? undefined,
  }))
  const profile = buildTVProfile(profileItems)
  const exclusions = buildTVExclusions(
    rankings.map((r) => ({ tmdb_id: r.tmdb_id, show_tmdb_id: r.show_tmdb_id, title: r.title })),
    watchlist.map((w) => ({ show_tmdb_id: w.show_tmdb_id, title: w.title })),
    sessionExcludeIds,
  )
  return { profile, exclusions }
}

// ── Response mapping (strip internal releaseDate) ────────────────────────────

function toResponseItem(m: SuggestionItem) {
  return {
    id: m.id,
    tmdbId: m.tmdbId,
    title: m.title,
    year: m.year,
    posterUrl: m.posterUrl,
    backdropUrl: m.backdropUrl ?? null,
    mediaType: m.mediaType,
    genres: m.genres,
    overview: m.overview,
    voteAverage: m.voteAverage,
    seasonCount: m.seasonCount,
    pool: m.pool,
  }
}

// ── HTTP shell ───────────────────────────────────────────────────────────────

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405)
  }

  try {
    // --- Auth: verify the forwarded Supabase JWT ---
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return json({ error: 'Missing Authorization header' }, 401)
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')
    if (!supabaseUrl || !supabaseAnonKey) {
      throw new Error('Supabase environment variables are not configured')
    }

    // User-scoped client: forwards the JWT so ALL reads run under caller RLS.
    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    })

    const {
      data: { user },
      error: authError,
    } = await userClient.auth.getUser()

    if (authError || !user) {
      return json({ error: 'Invalid or expired token' }, 401)
    }

    // --- Rate limit (per-user, in-memory) ---
    if (rateLimited(user.id)) {
      return json({ error: 'Rate limit exceeded' }, 429)
    }

    // --- Parse + validate body ---
    let rawBody: unknown
    try {
      rawBody = await req.json()
    } catch {
      return json({ error: 'Invalid JSON in request body' }, 400)
    }
    const validation = validateRequestBody(rawBody)
    if (!validation.valid) {
      return json({ error: validation.error }, 400)
    }
    const { mediaType, mode, page, poolSlots, locale, sessionExcludeIds, limit } =
      validation.data

    // --- TMDB secret ---
    const apiKey = Deno.env.get('TMDB_API_KEY')
    if (!apiKey) {
      throw new Error('TMDB_API_KEY is not configured')
    }

    const language = tmdbLanguage(locale)
    const slots = { ...DEFAULT_POOL_SLOTS, ...(poolSlots ?? {}) }
    const sessionIds = (sessionExcludeIds ?? []).slice(0, SESSION_EXCLUDE_CAP)

    let items: SuggestionItem[]
    let totalRanked: number

    try {
      if (mediaType === 'movie') {
        const { profile, exclusions } = await loadMovieData(userClient, sessionIds)
        totalRanked = profile.totalRanked
        const ctx: MovieCtx = { apiKey, language, page, slots, profile, exclusions, userClient, userId: user.id }
        if (mode === 'suggestions') items = await smartMovies(ctx)
        else if (mode === 'backfill') items = await backfillMovies(ctx)
        else items = await newReleaseMovies(ctx, Math.min(limit ?? NEW_RELEASES_DEFAULT_LIMIT, 10))
      } else {
        const { profile, exclusions } = await loadTVData(userClient, sessionIds)
        totalRanked = profile.totalRanked
        const ctx: TVCtx = { apiKey, language, page, slots, profile, exclusions, userClient, userId: user.id }
        if (mode === 'suggestions') items = await smartTV(ctx)
        else items = await backfillTV(ctx) // tv has no new_releases (validated above)
      }
    } catch (err) {
      console.error('suggestions upstream error:', err)
      return json({ error: 'TMDB upstream error' }, 502)
    }

    return json({ items: items.map(toResponseItem), totalRanked }, 200)
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Internal server error'
    console.error('suggestions error:', err)
    return json({ error: message }, 500)
  }
})
