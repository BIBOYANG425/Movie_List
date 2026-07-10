import { describe, it, expect } from 'vitest';
import {
  buildMovieProfile,
  buildTVProfile,
  buildMovieExclusions,
  buildTVExclusions,
  assemble,
  dedupById,
  shuffle,
  isBelowThreshold,
  filterNewReleases,
  topWeightedGenres,
  mapMovieResult,
  SMART_SUGGESTION_THRESHOLD,
  type SuggestionItem,
  type Pools,
  type Rng,
} from '../../supabase/functions/suggestions/engine';

// Imports the SAME engine.ts that supabase/functions/suggestions/index.ts uses.
// engine.ts is import-clean (no Deno globals) so vitest compiles it directly.

// ── helpers ──────────────────────────────────────────────────────────────────

/**
 * Deterministic RNG whose Fisher-Yates result is the identity permutation.
 * Fisher-Yates swaps element i with j = floor(rng()*(i+1)); returning ~1 makes
 * j === i at every step, so no element moves. (rng()=0 would rotate, not fix.)
 */
const rngIdentity: Rng = () => 0.999999999;

/** Sequenced RNG for reproducible shuffles. */
function seqRng(values: number[]): Rng {
  let i = 0;
  return () => values[i++ % values.length];
}

function item(tmdbId: number, pool: SuggestionItem['pool'], extra: Partial<SuggestionItem> = {}): SuggestionItem {
  return {
    id: `tmdb_${tmdbId}`,
    tmdbId,
    title: `Movie ${tmdbId}`,
    year: '2020',
    posterUrl: `/p${tmdbId}.jpg`,
    backdropUrl: null,
    mediaType: 'movie',
    genres: [],
    overview: '',
    seasonCount: 0,
    pool,
    ...extra,
  };
}

function pools(overrides: Partial<Pools> = {}): Pools {
  return {
    similar: [],
    taste: [],
    trending: [],
    variety: [],
    friend: [],
    ...overrides,
  };
}

const DEFAULT_SLOTS = { similar: 3, taste: 4, trending: 2, variety: 2, friend: 1 };

// ── exclusion normalization ──────────────────────────────────────────────────

describe('buildMovieExclusions — B1 both id forms', () => {
  it('normalizes a prefixed ranking id to both tmdb_{n} and bare {n}', () => {
    const ex = buildMovieExclusions([{ tmdb_id: 'tmdb_603', title: 'The Matrix' }], []);
    expect(ex.ids.has('tmdb_603')).toBe(true);
    expect(ex.ids.has('603')).toBe(true);
    expect(ex.titles.has('the matrix')).toBe(true);
  });

  it('normalizes a bare-numeric ranking id to both forms (fixes the leak)', () => {
    const ex = buildMovieExclusions([{ tmdb_id: 603 }], []);
    expect(ex.ids.has('603')).toBe(true);
    expect(ex.ids.has('tmdb_603')).toBe(true);
  });

  it('includes watchlist ids and session ids', () => {
    const ex = buildMovieExclusions(
      [{ tmdb_id: 'tmdb_1' }],
      [{ tmdb_id: 'tmdb_2', title: 'Two' }],
      ['tmdb_3'],
    );
    for (const n of [1, 2, 3]) {
      expect(ex.ids.has(`tmdb_${n}`)).toBe(true);
      expect(ex.ids.has(String(n))).toBe(true);
    }
    expect(ex.titles.has('two')).toBe(true);
  });
});

describe('buildTVExclusions — season → show expansion', () => {
  it('expands a season ranking id to show-level ids', () => {
    const ex = buildTVExclusions(
      [{ tmdb_id: 'tv_1399_s2', show_tmdb_id: 1399, title: 'Thrones' }],
      [],
    );
    expect(ex.ids.has('tv_1399')).toBe(true);
    expect(ex.ids.has('1399')).toBe(true);
    // the raw season id is also retained
    expect(ex.ids.has('tv_1399_s2')).toBe(true);
    expect(ex.titles.has('thrones')).toBe(true);
  });

  it('expands session season ids and watchlist show ids', () => {
    const ex = buildTVExclusions(
      [],
      [{ show_tmdb_id: 42, title: 'Answer' }],
      ['tv_1399_s1'],
    );
    expect(ex.ids.has('tv_42')).toBe(true);
    expect(ex.ids.has('42')).toBe(true);
    expect(ex.ids.has('tv_1399')).toBe(true);
  });
});

// ── dedup ────────────────────────────────────────────────────────────────────

describe('dedupById', () => {
  it('drops later duplicates by numeric tmdbId, first wins', () => {
    const out = dedupById([item(1, 'taste'), item(2, 'taste'), item(1, 'trending')]);
    expect(out.map((m) => m.tmdbId)).toEqual([1, 2]);
    expect(out[0].pool).toBe('taste');
  });
});

// ── assembly: take-order + refill-without-friend ─────────────────────────────

describe('assemble — take-order + cap + refill', () => {
  it('takes in order similar/taste/trending/variety/friend up to slots', () => {
    const p = pools({
      similar: [item(1, 'similar'), item(2, 'similar'), item(3, 'similar')],
      taste: [item(10, 'taste'), item(11, 'taste'), item(12, 'taste'), item(13, 'taste')],
      trending: [item(20, 'trending'), item(21, 'trending')],
      variety: [item(30, 'variety'), item(31, 'variety')],
      friend: [item(40, 'friend')],
    });
    const out = assemble(p, DEFAULT_SLOTS, rngIdentity);
    // rngIdentity → shuffle is identity; Σ slots = 12
    expect(out.map((m) => m.tmdbId)).toEqual([1, 2, 3, 10, 11, 12, 13, 20, 21, 30, 31, 40]);
  });

  it('dedups across pools by tmdbId during take', () => {
    const p = pools({
      similar: [item(1, 'similar')],
      taste: [item(1, 'taste'), item(2, 'taste')], // 1 already used
    });
    const out = assemble(p, DEFAULT_SLOTS, rngIdentity);
    expect(out.map((m) => m.tmdbId)).toEqual([1, 2]);
    expect(out[0].pool).toBe('similar');
  });

  it('refills leftover slots from [taste, similar, trending, variety] — NEVER friend', () => {
    // similar/taste/trending/variety underfilled; friend has extra candidates.
    const p = pools({
      similar: [item(1, 'similar')],
      taste: [item(10, 'taste'), item(11, 'taste')],
      trending: [item(20, 'trending')],
      variety: [item(30, 'variety')],
      friend: [item(40, 'friend'), item(41, 'friend'), item(42, 'friend')],
    });
    const out = assemble(p, DEFAULT_SLOTS, rngIdentity);
    const ids = out.map((m) => m.tmdbId);
    // friend contributes at most its 1 slot (40); 41/42 must NEVER refill.
    expect(ids).toContain(40);
    expect(ids).not.toContain(41);
    expect(ids).not.toContain(42);
  });

  it('caps at 12 even when pools overflow', () => {
    const big = Array.from({ length: 30 }, (_, i) => item(100 + i, 'taste'));
    const out = assemble(pools({ taste: big }), DEFAULT_SLOTS, rngIdentity);
    expect(out.length).toBe(12);
  });
});

// ── shuffle determinism ──────────────────────────────────────────────────────

describe('shuffle — injected RNG determinism', () => {
  it('rng()~1 is the identity permutation (no swaps)', () => {
    const arr = [1, 2, 3, 4, 5];
    expect(shuffle(arr, rngIdentity)).toEqual([1, 2, 3, 4, 5]);
  });

  it('same RNG sequence yields the same permutation', () => {
    const arr = [1, 2, 3, 4, 5];
    const a = shuffle(arr, seqRng([0.9, 0.1, 0.5, 0.3]));
    const b = shuffle(arr, seqRng([0.9, 0.1, 0.5, 0.3]));
    expect(a).toEqual(b);
    expect(a).not.toEqual(arr); // non-trivial permutation
  });

  it('does not mutate the input array', () => {
    const arr = [1, 2, 3];
    shuffle(arr, seqRng([0.9, 0.4]));
    expect(arr).toEqual([1, 2, 3]);
  });
});

// ── threshold fallback ───────────────────────────────────────────────────────

describe('threshold fallback — exactly 3 is the boundary', () => {
  it('totalRanked = 2 is below threshold (generic)', () => {
    expect(isBelowThreshold({ ...emptyProfile(), totalRanked: 2 })).toBe(true);
  });

  it('totalRanked = 3 is NOT below threshold (smart pools)', () => {
    expect(SMART_SUGGESTION_THRESHOLD).toBe(3);
    expect(isBelowThreshold({ ...emptyProfile(), totalRanked: 3 })).toBe(false);
  });

  it('a 2-ranking user builds a below-threshold profile', () => {
    const profile = buildMovieProfile([
      { id: 'tmdb_1', genres: ['Drama'], year: '2000', tier: 'S' },
      { id: 'tmdb_2', genres: ['Drama'], year: '2001', tier: 'A' },
    ]);
    expect(isBelowThreshold(profile)).toBe(true);
  });
});

function emptyProfile() {
  return {
    weightedGenres: {},
    topDirectors: [],
    decadeDistribution: {},
    preferredDecade: null,
    underexposedGenres: [],
    topMovieIds: [],
    totalRanked: 0,
  };
}

// ── profile id extraction quirks ─────────────────────────────────────────────

describe('buildMovieProfile — topMovieIds via /tmdb_(\\d+)/', () => {
  it('extracts S/A ids in order and skips lower tiers', () => {
    const p = buildMovieProfile([
      { id: 'tmdb_10', genres: ['Action'], year: '2020', tier: 'S' },
      { id: 'tmdb_20', genres: ['Action'], year: '2019', tier: 'B' },
      { id: 'tmdb_30', genres: ['Action'], year: '2018', tier: 'A' },
    ]);
    expect(p.topMovieIds).toEqual([10, 30]);
  });
});

describe('buildTVProfile — show ids via anchored /^tv_(\\d+)_s\\d+$/', () => {
  it('extracts deduped show ids for S/A seasons', () => {
    const p = buildTVProfile([
      { id: 'tv_1399_s1', genres: ['Drama'], year: '2011', tier: 'S' },
      { id: 'tv_1399_s2', genres: ['Drama'], year: '2012', tier: 'A' },
      { id: 'tv_82856_s1', genres: ['Sci-Fi & Fantasy'], year: '2019', tier: 'A' },
    ]);
    expect(p.topMovieIds.sort((a, b) => a - b)).toEqual([1399, 82856]);
  });
});

// ── new_releases ─────────────────────────────────────────────────────────────

describe('filterNewReleases — genre filter + ascending date sort', () => {
  const raw = [
    { id: 1, title: 'Action Soon', poster_path: '/a.jpg', genre_ids: [28], release_date: '2026-08-01' },
    { id: 2, title: 'Comedy Later', poster_path: '/c.jpg', genre_ids: [35], release_date: '2026-09-01' },
    { id: 3, title: 'Action Sooner', poster_path: '/s.jpg', genre_ids: [28], release_date: '2026-07-15' },
    { id: 4, title: 'No Poster', poster_path: null, genre_ids: [28], release_date: '2026-07-01' },
  ];

  it('filters to top taste genres when totalRanked >= 3 and sorts ascending', () => {
    const profile = { ...emptyProfile(), weightedGenres: { Action: 10, Drama: 5 }, totalRanked: 5 };
    const ex = { ids: new Set<string>(), titles: new Set<string>() };
    const out = filterNewReleases(raw, profile, ex, 10);
    // Comedy excluded (not in top taste); No Poster dropped; Action sorted ascending.
    expect(out.map((m) => m.tmdbId)).toEqual([3, 1]);
    expect(out.every((m) => m.pool === 'new_release')).toBe(true);
  });

  it('passes through unfiltered (popular) when totalRanked < 3', () => {
    const profile = { ...emptyProfile(), weightedGenres: { Action: 10 }, totalRanked: 2 };
    const ex = { ids: new Set<string>(), titles: new Set<string>() };
    const out = filterNewReleases(raw, profile, ex, 10);
    // All poster-bearing items pass, ascending by date: 3 (07-15), 1 (08-01), 2 (09-01)
    expect(out.map((m) => m.tmdbId)).toEqual([3, 1, 2]);
  });

  it('excludes ranked/watchlisted ids and respects the limit', () => {
    const profile = { ...emptyProfile(), weightedGenres: { Action: 10 }, totalRanked: 2 };
    const ex = { ids: new Set(['tmdb_1']), titles: new Set<string>() };
    const out = filterNewReleases(raw, profile, ex, 1);
    expect(out.map((m) => m.tmdbId)).toEqual([3]); // 1 excluded, limit 1
  });

  it('caps the limit at 10 even if a larger limit is requested', () => {
    const many = Array.from({ length: 15 }, (_, i) => ({
      id: i + 100,
      title: `Film ${i}`,
      poster_path: `/f${i}.jpg`,
      genre_ids: [28],
      release_date: `2026-08-${String((i % 28) + 1).padStart(2, '0')}`,
    }));
    const profile = { ...emptyProfile(), totalRanked: 1 };
    const ex = { ids: new Set<string>(), titles: new Set<string>() };
    const out = filterNewReleases(many, profile, ex, 99);
    expect(out.length).toBe(10);
  });
});

describe('topWeightedGenres', () => {
  it('returns the top-N genres by weight descending', () => {
    const profile = { ...emptyProfile(), weightedGenres: { Drama: 3, Action: 10, Comedy: 7 } };
    expect(topWeightedGenres(profile, 2)).toEqual(['Action', 'Comedy']);
  });
});

describe('mapMovieResult — poster required', () => {
  it('returns null without a poster', () => {
    expect(mapMovieResult({ id: 1, title: 'X', poster_path: null }, 'taste')).toBeNull();
  });
});
