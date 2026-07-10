/**
 * suggestions/engine.ts — PURE 5-pool suggestion engine (server-side port).
 *
 * This module is import-clean: NO Deno globals, NO URL-scheme imports, plain TS.
 * It is imported by BOTH:
 *   - `supabase/functions/suggestions/index.ts` (the Deno HTTP shell), and
 *   - `services/__tests__/suggestionsEngine.test.ts` (the vitest web suite).
 *
 * All I/O (TMDB fetches, Supabase table reads) is injected by the caller, and
 * randomness is injected via an `Rng` seam so the assembly/take/refill/shuffle
 * logic is deterministic under test.
 *
 * Semantics ported VERBATIM from `services/tmdbService.ts`
 * (movie ~304-591, tv ~1500-1849) and the C3 audit §1.3-§1.5.
 * Every preserved quirk is annotated with `QUIRK:`.
 */

// ── Injected seams ───────────────────────────────────────────────────────────

/** Deterministic-in-test random source. Production passes `Math.random`. */
export type Rng = () => number;

/** Injected JSON fetcher. Resolves to a parsed body, or null on any failure. */
export type FetchJson = (url: string) => Promise<any | null>;

// ── Constants (inlined — SYNC with /constants.ts + /types.ts) ────────────────
// Kept local so the module stays import-clean across the supabase/ boundary.

/** SYNC: TIER_WEIGHTS in /constants.ts (S..D = 5..1). */
export const TIER_WEIGHTS: Record<string, number> = {
  S: 5,
  A: 4,
  B: 3,
  C: 2,
  D: 1,
};

/** SYNC: ALL_TMDB_GENRES in /constants.ts (19 movie genres). */
export const ALL_TMDB_GENRES = [
  'Action', 'Adventure', 'Animation', 'Comedy', 'Crime', 'Documentary',
  'Drama', 'Family', 'Fantasy', 'History', 'Horror', 'Music', 'Mystery',
  'Romance', 'Sci-Fi', 'TV Movie', 'Thriller', 'War', 'Western',
];

/** SYNC: ALL_TV_GENRES in /constants.ts (13; News/Reality/Talk excluded). */
export const ALL_TV_GENRES = [
  'Action & Adventure', 'Animation', 'Comedy', 'Crime', 'Documentary',
  'Drama', 'Family', 'Kids', 'Mystery',
  'Sci-Fi & Fantasy', 'Soap', 'War & Politics', 'Western',
];

/** SYNC: DEFAULT_POOL_SLOTS in /constants.ts (Σ = 12). */
export const DEFAULT_POOL_SLOTS: Record<string, number> = {
  similar: 3,
  taste: 4,
  trending: 2,
  variety: 2,
  friend: 1,
};

/** SYNC: SMART_SUGGESTION_THRESHOLD in /constants.ts. */
export const SMART_SUGGESTION_THRESHOLD = 3;

/** Assembly hard cap (identical for movie + tv). */
const RESULT_CAP = 12;
/** Backfill cap. */
const BACKFILL_CAP = 20;

export const TMDB_BASE = 'https://api.themoviedb.org/3';
export const TMDB_IMAGE_BASE = 'https://image.tmdb.org/t/p/w500';

// ── Genre tables ─────────────────────────────────────────────────────────────

/** SYNC: GENRE_MAP in tmdbService.ts (movie genre id → name). */
export const GENRE_MAP: Record<number, string> = {
  28: 'Action', 12: 'Adventure', 16: 'Animation', 35: 'Comedy', 80: 'Crime',
  99: 'Documentary', 18: 'Drama', 10751: 'Family', 14: 'Fantasy', 36: 'History',
  27: 'Horror', 10402: 'Music', 9648: 'Mystery', 10749: 'Romance', 878: 'Sci-Fi',
  10770: 'TV Movie', 53: 'Thriller', 10752: 'War', 37: 'Western',
};

const GENRE_NAME_TO_ID: Record<string, number> = Object.fromEntries(
  Object.entries(GENRE_MAP).map(([id, name]) => [name, Number(id)]),
);

/** Convert movie genre names → TMDB genre ids (tmdbService.ts genreNamesToIds). */
export function genreNamesToIds(names: string[]): number[] {
  return names
    .map((n) => GENRE_NAME_TO_ID[n])
    .filter((id): id is number => id !== undefined);
}

/** SYNC: TV_GENRE_MAP in tmdbService.ts (tv genre id → name). */
export const TV_GENRE_MAP: Record<number, string> = {
  10759: 'Action & Adventure', 16: 'Animation', 35: 'Comedy', 80: 'Crime',
  99: 'Documentary', 18: 'Drama', 10751: 'Family', 10762: 'Kids', 9648: 'Mystery',
  10763: 'News', 10764: 'Reality', 10765: 'Sci-Fi & Fantasy', 10766: 'Soap',
  10767: 'Talk', 10768: 'War & Politics', 37: 'Western',
};

/** Reverse: raw TV genre name → TMDB TV genre id. */
export const TV_GENRE_NAME_TO_ID: Record<string, number> = Object.fromEntries(
  Object.entries(TV_GENRE_MAP).map(([id, name]) => [name, Number(id)]),
);

/**
 * Normalize compound TV genre names to movie-compatible names
 * (tmdbService.ts normalizeTVGenres). Currently unused by the pools but
 * ported for parity/completeness (audit §1.4 requires it live server-side).
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
    if (COMPOUND_MAP[g]) result.push(...COMPOUND_MAP[g]);
    else result.push(g);
  }
  return [...new Set(result)].slice(0, 3);
}

/**
 * Map normalized genre names (from tv_rankings) → TMDB TV genre ids for
 * /discover/tv (tmdbService.ts tvGenreNamesToIds). Handles compound mappings.
 */
export function tvGenreNamesToIds(names: string[]): number[] {
  const NORMALIZED_TO_TV_ID: Record<string, number> = {
    'Action': 10759, 'Adventure': 10759,
    'Sci-Fi': 10765, 'Fantasy': 10765,
    'War': 10768,
    'Animation': 16, 'Comedy': 35, 'Crime': 80, 'Documentary': 99,
    'Drama': 18, 'Family': 10751, 'Mystery': 9648, 'Western': 37,
  };
  const ids = new Set<number>();
  for (const name of names) {
    const id = NORMALIZED_TO_TV_ID[name] ?? TV_GENRE_NAME_TO_ID[name];
    if (id !== undefined) ids.add(id);
  }
  return [...ids];
}

// ── Item shape (unified response item) ───────────────────────────────────────

export type PoolTag =
  | 'similar' | 'taste' | 'trending' | 'variety' | 'friend'
  | 'generic' | 'backfill' | 'new_release';

export interface SuggestionItem {
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
  seasonCount: number;
  /** ISO release date, only populated for new_releases sort; not in the response. */
  releaseDate?: string;
  pool: PoolTag;
}

// ── Ranking / watchlist row shapes (server reads) ────────────────────────────

export interface MovieRankingRow {
  id?: string;
  tmdb_id: string | number;
  title?: string | null;
  year?: string | null;
  genres?: string[] | null;
  tier?: string | null;
  director?: string | null;
}

export interface MovieWatchlistRow {
  tmdb_id: string | number;
  title?: string | null;
}

export interface TVRankingRow {
  id?: string;
  tmdb_id: string | number;
  show_tmdb_id: number;
  title?: string | null;
  year?: string | null;
  genres?: string[] | null;
  tier?: string | null;
  creator?: string | null;
}

export interface TVWatchlistRow {
  show_tmdb_id: number;
  title?: string | null;
}

// ── Taste profile ────────────────────────────────────────────────────────────

export interface TasteProfile {
  weightedGenres: Record<string, number>;
  topDirectors: { name: string; score: number }[];
  decadeDistribution: Record<string, number>;
  preferredDecade: string | null;
  underexposedGenres: string[];
  topMovieIds: number[];
  totalRanked: number;
}

/**
 * Build the ephemeral movie TasteProfile (tmdbService.ts buildTasteProfile).
 *
 * QUIRK: topMovieIds via regex `/tmdb_(\d+)/` — bare-numeric ids never match
 * (audit B1). We reproduce the exact regex against the ROW's id form. Rows carry
 * `tmdb_id` which may be `tmdb_603` (string) or `603` (bare); to match the web's
 * `.match(/tmdb_(\d+)/)` on the item id we reconstruct the `tmdb_{n}` string id
 * from the row and run the same regex — B1 is preserved because a row whose
 * `tmdb_id` is bare numeric still yields `tmdb_{n}` here, matching the web
 * behavior AFTER the client had already built `tmdb_`-prefixed item ids. See the
 * report for the fidelity note.
 */
export function buildMovieProfile(
  items: { id: string; genres: string[]; year: string; tier: string; director?: string }[],
): TasteProfile {
  if (items.length === 0) {
    return emptyProfile(ALL_TMDB_GENRES);
  }

  const genreScores = tierWeightedGenreScores(items);
  const { decadeScores, preferredDecade } = tierWeightedDecades(items);
  const topDirectors = tierWeightedNames(items.map((i) => ({ tier: i.tier, name: i.director })));

  const genreCounts = rawGenreCounts(items);
  const underexposedGenres = ALL_TMDB_GENRES.filter((g) => (genreCounts.get(g) ?? 0) < 2);

  // QUIRK: S/A tier ids via regex /tmdb_(\d+)/, order-preserving, NaN-filtered.
  const topMovieIds = items
    .filter((i) => i.tier === 'S' || i.tier === 'A')
    .map((i) => {
      const match = i.id.match(/tmdb_(\d+)/);
      return match ? parseInt(match[1], 10) : NaN;
    })
    .filter((id) => !isNaN(id));

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
 * Build the ephemeral TV TasteProfile (tmdbService.ts buildTVTasteProfile).
 * Uses `creator` in topDirectors, anchored `^tv_(\d+)_s\d+$` show-id extraction
 * with Set-dedup, and reverse-normalized underexposed detection over ALL_TV_GENRES.
 */
export function buildTVProfile(
  items: { id: string; genres: string[]; year: string; tier: string; creator?: string }[],
): TasteProfile {
  if (items.length === 0) {
    return emptyProfile(ALL_TV_GENRES);
  }

  const genreScores = tierWeightedGenreScores(items);
  const { decadeScores, preferredDecade } = tierWeightedDecades(items);
  const topDirectors = tierWeightedNames(items.map((i) => ({ tier: i.tier, name: i.creator })));

  const genreCounts = rawGenreCounts(items);
  const TV_GENRE_NORMALIZED_FORMS: Record<string, string[]> = {
    'Action & Adventure': ['Action', 'Adventure'],
    'Sci-Fi & Fantasy': ['Sci-Fi', 'Fantasy'],
    'War & Politics': ['War'],
    'Kids': ['Family'],
    'Soap': ['Drama'],
    'News': [], 'Reality': [], 'Talk': [],
  };
  const underexposedGenres = ALL_TV_GENRES.filter((rawGenre) => {
    const normalizedForms = TV_GENRE_NORMALIZED_FORMS[rawGenre] ?? [rawGenre];
    if (normalizedForms.length === 0) return false;
    return !normalizedForms.some((n) => (genreCounts.get(n) ?? 0) >= 2);
  });

  // QUIRK: show ids via anchored /^tv_(\d+)_s\d+$/, Set-deduped.
  const showIdSet = new Set<number>();
  for (const item of items) {
    if (item.tier === 'S' || item.tier === 'A') {
      const match = item.id.match(/^tv_(\d+)_s\d+$/);
      if (match) showIdSet.add(parseInt(match[1], 10));
    }
  }

  return {
    weightedGenres: Object.fromEntries(genreScores),
    topDirectors,
    decadeDistribution: Object.fromEntries(decadeScores),
    preferredDecade,
    underexposedGenres,
    topMovieIds: [...showIdSet],
    totalRanked: items.length,
  };
}

function emptyProfile(allGenres: string[]): TasteProfile {
  return {
    weightedGenres: {},
    topDirectors: [],
    decadeDistribution: {},
    preferredDecade: null,
    underexposedGenres: [...allGenres],
    topMovieIds: [],
    totalRanked: 0,
  };
}

function tierWeightedGenreScores(items: { genres: string[]; tier: string }[]): Map<string, number> {
  const scores = new Map<string, number>();
  for (const item of items) {
    const w = TIER_WEIGHTS[item.tier] ?? 3;
    for (const g of item.genres) scores.set(g, (scores.get(g) ?? 0) + w);
  }
  return scores;
}

function tierWeightedDecades(
  items: { year: string; tier: string }[],
): { decadeScores: Map<string, number>; preferredDecade: string | null } {
  const decadeScores = new Map<string, number>();
  for (const item of items) {
    if (item.year && item.year.length >= 4) {
      const yr = parseInt(item.year.slice(0, 4), 10);
      if (!isNaN(yr)) {
        const decade = `${Math.floor(yr / 10) * 10}s`;
        const w = TIER_WEIGHTS[item.tier] ?? 3;
        decadeScores.set(decade, (decadeScores.get(decade) ?? 0) + w);
      }
    }
  }
  let preferredDecade: string | null = null;
  let maxDecadeScore = 0;
  for (const [decade, score] of decadeScores) {
    if (score > maxDecadeScore) {
      maxDecadeScore = score;
      preferredDecade = decade;
    }
  }
  return { decadeScores, preferredDecade };
}

function tierWeightedNames(
  items: { tier: string; name?: string | null }[],
): { name: string; score: number }[] {
  const scores = new Map<string, number>();
  for (const item of items) {
    if (item.name) {
      const w = TIER_WEIGHTS[item.tier] ?? 3;
      scores.set(item.name, (scores.get(item.name) ?? 0) + w);
    }
  }
  return [...scores.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10)
    .map(([name, score]) => ({ name, score }));
}

function rawGenreCounts(items: { genres: string[] }[]): Map<string, number> {
  const counts = new Map<string, number>();
  for (const item of items) {
    for (const g of item.genres) counts.set(g, (counts.get(g) ?? 0) + 1);
  }
  return counts;
}

// ── Exclusion normalization (B1 fix at the boundary) ─────────────────────────

export interface Exclusions {
  ids: Set<string>;
  titles: Set<string>;
}

/**
 * Build the movie exclusion set from rankings + watchlist + session ids.
 *
 * B1 FIX: every id is normalized to BOTH `tmdb_{n}` and bare `{n}` so the
 * exclusion net catches format drift (the web leaked because it only compared
 * one form). Titles are lowercased. sessionExcludeIds (already `tmdb_{n}`) are
 * normalized the same way.
 */
export function buildMovieExclusions(
  rankings: MovieRankingRow[],
  watchlist: MovieWatchlistRow[],
  sessionExcludeIds: string[] = [],
): Exclusions {
  const ids = new Set<string>();
  const titles = new Set<string>();
  const addId = (raw: string | number) => {
    for (const form of movieIdForms(raw)) ids.add(form);
  };
  for (const r of rankings) {
    addId(r.tmdb_id);
    if (r.title) titles.add(r.title.toLowerCase());
  }
  for (const w of watchlist) {
    addId(w.tmdb_id);
    if (w.title) titles.add(w.title.toLowerCase());
  }
  for (const s of sessionExcludeIds) addId(s);
  return { ids, titles };
}

/**
 * Build the TV exclusion set. TV season ids (`tv_{show}_s{n}`) expand to
 * show-level ids (`tv_{show}`) — the audit §1.4 contract that lets the friend
 * pool's `excludeIds.has('tv_'+show)` check work. Bare show ids and
 * `tv_{show}` forms are also normalized.
 */
export function buildTVExclusions(
  rankings: TVRankingRow[],
  watchlist: TVWatchlistRow[],
  sessionExcludeIds: string[] = [],
): Exclusions {
  const ids = new Set<string>();
  const titles = new Set<string>();
  const addShow = (showId: number) => {
    ids.add(`tv_${showId}`);
    ids.add(String(showId));
  };
  for (const r of rankings) {
    addShow(r.show_tmdb_id);
    for (const form of tvIdForms(r.tmdb_id)) ids.add(form);
    if (r.title) titles.add(r.title.toLowerCase());
  }
  for (const w of watchlist) {
    addShow(w.show_tmdb_id);
    if (w.title) titles.add(w.title.toLowerCase());
  }
  for (const s of sessionExcludeIds) {
    for (const form of tvIdForms(s)) ids.add(form);
  }
  return { ids, titles };
}

/** All exclusion forms for a movie id (both `tmdb_{n}` and bare `{n}`). */
function movieIdForms(raw: string | number): string[] {
  const s = String(raw);
  const forms = new Set<string>([s]);
  const m = s.match(/tmdb_(\d+)/);
  if (m) {
    forms.add(m[1]); // bare
  } else if (/^\d+$/.test(s)) {
    forms.add(`tmdb_${s}`); // prefixed
  }
  return [...forms];
}

/** Exclusion forms for a TV id: season → show expansion + bare + prefixed. */
function tvIdForms(raw: string | number): string[] {
  const s = String(raw);
  const forms = new Set<string>([s]);
  const season = s.match(/^tv_(\d+)_s\d+$/);
  if (season) {
    forms.add(`tv_${season[1]}`);
    forms.add(season[1]);
    return [...forms];
  }
  const show = s.match(/^tv_(\d+)$/);
  if (show) {
    forms.add(show[1]);
  } else if (/^\d+$/.test(s)) {
    forms.add(`tv_${s}`);
  }
  return [...forms];
}

// ── Result mappers ───────────────────────────────────────────────────────────

/** Map a raw TMDB movie result → SuggestionItem, or null (poster-required). */
export function mapMovieResult(m: any, pool: PoolTag): SuggestionItem | null {
  if (!m || !m.poster_path) return null;
  return {
    id: `tmdb_${m.id}`,
    tmdbId: m.id,
    title: m.title,
    year: m.release_date ? m.release_date.slice(0, 4) : '—',
    posterUrl: `${TMDB_IMAGE_BASE}${m.poster_path}`,
    backdropUrl: m.backdrop_path ? `${TMDB_IMAGE_BASE}${m.backdrop_path}` : null,
    mediaType: 'movie',
    genres: (m.genre_ids as number[] | undefined)
      ?.map((gid: number) => GENRE_MAP[gid])
      .filter(Boolean)
      .slice(0, 3) ?? [],
    overview: m.overview ?? '',
    voteAverage: typeof m.vote_average === 'number' ? m.vote_average : undefined,
    seasonCount: 0,
    releaseDate: m.release_date ?? undefined,
    pool,
  };
}

/** Map a raw TMDB TV result → SuggestionItem, or null (poster-required). */
export function mapTVResult(s: any, pool: PoolTag): SuggestionItem | null {
  if (!s || !s.poster_path) return null;
  return {
    id: `tv_${s.id}`,
    tmdbId: s.id,
    title: s.name ?? s.original_name ?? '',
    year: s.first_air_date ? s.first_air_date.slice(0, 4) : '—',
    posterUrl: `${TMDB_IMAGE_BASE}${s.poster_path}`,
    backdropUrl: s.backdrop_path ? `${TMDB_IMAGE_BASE}${s.backdrop_path}` : null,
    mediaType: 'tv',
    genres: (s.genre_ids as number[] | undefined)
      ?.map((gid: number) => TV_GENRE_MAP[gid])
      .filter(Boolean)
      .slice(0, 3) ?? [],
    overview: s.overview ?? '',
    seasonCount: s.number_of_seasons ?? 0,
    releaseDate: s.first_air_date ?? undefined,
    pool,
  };
}

// ── Pure helpers ─────────────────────────────────────────────────────────────

/** Fisher-Yates shuffle with injected RNG (tmdbService.ts shuffle). */
export function shuffle<T>(arr: T[], rng: Rng): T[] {
  const copy = [...arr];
  for (let i = copy.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [copy[i], copy[j]] = [copy[j], copy[i]];
  }
  return copy;
}

/** Dedup by numeric tmdbId, first-wins (tmdbService.ts dedup/dedupTV). */
export function dedupById(items: SuggestionItem[]): SuggestionItem[] {
  const seen = new Set<number>();
  return items.filter((m) => {
    if (seen.has(m.tmdbId)) return false;
    seen.add(m.tmdbId);
    return true;
  });
}

/** Interleave two arrays (tmdbService.ts interleave/interleaveTV). */
export function interleave(a: SuggestionItem[], b: SuggestionItem[]): SuggestionItem[] {
  const mixed: SuggestionItem[] = [];
  const maxLen = Math.max(a.length, b.length);
  for (let i = 0; i < maxLen; i++) {
    if (i < a.length) mixed.push(a[i]);
    if (i < b.length) mixed.push(b[i]);
  }
  return mixed;
}

// ── Assembly (take-order / dedup / refill-without-friend / shuffle) ──────────

export interface Pools {
  similar: SuggestionItem[];
  taste: SuggestionItem[];
  trending: SuggestionItem[];
  variety: SuggestionItem[];
  friend: SuggestionItem[];
}

/**
 * Assemble the final ≤12 result from the five pools (tmdbService.ts :430-454 /
 * :1850-1873, identical movie/tv).
 *
 * QUIRK: take-order similar(slots)/taste/trending/variety/friend; hard cap 12;
 * dedup by numeric tmdbId; leftover slots refilled ONLY from
 * [taste, similar, trending, variety] (friend never refills, D2); final shuffle.
 */
export function assemble(pools: Pools, slots: Record<string, number>, rng: Rng): SuggestionItem[] {
  const result: SuggestionItem[] = [];
  const used = new Set<number>();

  const take = (pool: SuggestionItem[], count: number) => {
    for (const m of pool) {
      if (result.length >= RESULT_CAP) break;
      if (count <= 0) break;
      if (used.has(m.tmdbId)) continue;
      used.add(m.tmdbId);
      result.push(m);
      count--;
    }
  };

  take(pools.similar, slots.similar);
  take(pools.taste, slots.taste);
  take(pools.trending, slots.trending);
  take(pools.variety, slots.variety);
  take(pools.friend, slots.friend);

  // QUIRK: refill order [taste, similar, trending, variety]; friend excluded.
  const remaining = [...pools.taste, ...pools.similar, ...pools.trending, ...pools.variety];
  take(remaining, RESULT_CAP - result.length);

  return shuffle(result, rng);
}

/** Below-threshold guard (audit §1.3): generic when totalRanked < 3. */
export function isBelowThreshold(profile: TasteProfile): boolean {
  return profile.totalRanked < SMART_SUGGESTION_THRESHOLD;
}

// ── new_releases filter (movie-only, NEW mode) ───────────────────────────────

/**
 * Filter + rank raw new-release results.
 *
 * - When `totalRanked >= 3`, keep only items whose genres intersect the caller's
 *   top-3 weighted taste genres; else pass through unfiltered (popular).
 * - Exclude ranked ∪ watchlisted (by id) and lowercased titles.
 * - Poster-required (mapper enforces).
 * - Sort by release date ASCENDING (soonest first); undated sort last.
 * - Cap at `limit` (default 10, ≤10).
 */
export function filterNewReleases(
  raw: any[],
  profile: TasteProfile,
  exclusions: Exclusions,
  limit: number,
): SuggestionItem[] {
  const topGenres = topWeightedGenres(profile, 3);
  const genreFilterActive = profile.totalRanked >= SMART_SUGGESTION_THRESHOLD && topGenres.length > 0;
  const topGenreSet = new Set(topGenres);

  const mapped = raw
    .map((m) => mapMovieResult(m, 'new_release'))
    .filter((m): m is SuggestionItem => m !== null)
    // dedup by id first (now_playing + upcoming may overlap)
    ;

  const deduped = dedupById(mapped);

  const filtered = deduped.filter((m) => {
    if (exclusions.ids.has(m.id) || exclusions.ids.has(String(m.tmdbId))) return false;
    if (exclusions.titles.has(m.title.toLowerCase())) return false;
    if (genreFilterActive) {
      return m.genres.some((g) => topGenreSet.has(g));
    }
    return true;
  });

  filtered.sort((a, b) => {
    const da = a.releaseDate ?? '9999-12-31';
    const db = b.releaseDate ?? '9999-12-31';
    return da < db ? -1 : da > db ? 1 : 0;
  });

  return filtered.slice(0, Math.min(limit, 10));
}

/** Top-N weighted genre names (descending) for taste/new_releases filtering. */
export function topWeightedGenres(profile: TasteProfile, n: number): string[] {
  return Object.entries(profile.weightedGenres)
    .sort((a, b) => b[1] - a[1])
    .slice(0, n)
    .map(([name]) => name);
}

// ── URL builders (pure — keep the page/vote/decade quirks) ───────────────────

export interface DiscoverParams {
  base: string;      // `${TMDB_BASE}/discover/movie` or `/discover/tv`
  apiKey: string;
  language: string;
  sortBy: string;
  voteCountGte: string;
  withGenres?: string;
  page: number;
  /**
   * Optional date bound(s). `field` is `primary_release_date` (movie) or
   * `first_air_date` (tv). `gte`/`lte` are set independently — the generic
   * pools use ONLY one bound each (recent = gte, classic = lte), matching the
   * web verbatim, while the taste-decade window sets both.
   */
  dateWindow?: { field: string; gte?: string; lte?: string };
}

/** Build a /discover URL string (params in stable order). */
export function buildDiscoverUrl(p: DiscoverParams): string {
  const url = new URL(p.base);
  url.searchParams.set('api_key', p.apiKey);
  url.searchParams.set('language', p.language);
  url.searchParams.set('sort_by', p.sortBy);
  url.searchParams.set('include_adult', 'false');
  url.searchParams.set('vote_count.gte', p.voteCountGte);
  if (p.withGenres) url.searchParams.set('with_genres', p.withGenres);
  if (p.dateWindow) {
    if (p.dateWindow.gte) url.searchParams.set(`${p.dateWindow.field}.gte`, p.dateWindow.gte);
    if (p.dateWindow.lte) url.searchParams.set(`${p.dateWindow.field}.lte`, p.dateWindow.lte);
  }
  url.searchParams.set('page', String(p.page));
  return url.toString();
}
