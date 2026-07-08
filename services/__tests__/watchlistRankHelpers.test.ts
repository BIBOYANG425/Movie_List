import { describe, it, expect } from 'vitest';

import {
  shouldRemoveBookmarkAfterRank,
  tvWatchlistItemFromShow,
  canonicalMovieTmdbId,
} from '../watchlistRankHelpers';
import type { TMDBTVShow } from '../tmdbService';

// Pins the CORRECTED rank-from-watchlist contract (B5 data-loss fix): the
// bookmark is removed only when the ranking save succeeded. iOS C3 must copy
// these semantics, not the shipped web behavior that deleted unconditionally.
describe('shouldRemoveBookmarkAfterRank', () => {
  it('removes the bookmark when the save succeeded', () => {
    expect(shouldRemoveBookmarkAfterRank(true)).toBe(true);
  });

  it('keeps the bookmark when the save failed', () => {
    expect(shouldRemoveBookmarkAfterRank(false)).toBe(false);
  });
});

// Pins the CORRECTED TV-search-save shape (B2/D5): a whole-show bookmark carries
// the numeric showTmdbId (so ranking it later routes through season selection
// instead of minting a season-less tv_rankings row) and normalized, non-compound
// genres (so classifyBracket recognizes them at rank time).
describe('tvWatchlistItemFromShow', () => {
  const show: TMDBTVShow = {
    id: 'tv_1396',
    tmdbId: 1396,
    name: 'Breaking Bad',
    year: '2008',
    posterUrl: '/poster.jpg',
    genres: ['Action & Adventure', 'Sci-Fi & Fantasy', 'Drama'],
    overview: '',
    seasonCount: 5,
    status: 'Ended',
    creators: ['Vince Gilligan'],
  };

  it('carries the numeric showTmdbId', () => {
    expect(tvWatchlistItemFromShow(show, '2026-07-07T00:00:00.000Z').showTmdbId).toBe(1396);
  });

  it('normalizes compound TV genres', () => {
    expect(tvWatchlistItemFromShow(show, '2026-07-07T00:00:00.000Z').genres).toEqual([
      'Action',
      'Adventure',
      'Sci-Fi',
    ]);
  });

  it('does not set a seasonNumber (whole-show bookmark)', () => {
    expect(tvWatchlistItemFromShow(show, '2026-07-07T00:00:00.000Z').seasonNumber).toBeUndefined();
  });

  it('coalesces a null posterUrl to empty string', () => {
    const noPoster: TMDBTVShow = { ...show, posterUrl: null };
    expect(tvWatchlistItemFromShow(noPoster, '2026-07-07T00:00:00.000Z').posterUrl).toBe('');
  });

  it('carries the passed addedAt and tv_season type', () => {
    const item = tvWatchlistItemFromShow(show, '2026-07-07T00:00:00.000Z');
    expect(item.addedAt).toBe('2026-07-07T00:00:00.000Z');
    expect(item.type).toBe('tv_season');
  });
});

// Pins the canonical movie tmdb_id write-time contract (B1 preventive): Letterboxd
// import must write `tmdb_{n}`, never bare `{n}`, or engine exclusion, the
// taste-profile /tmdb_(\d+)/ regex, and cross-user comparison all break, and a
// second watchlist row can be minted for a movie a bare-id row already represents.
// Behavior matches DiscoverView.normalizeTmdbId (prefix iff not already prefixed;
// no numeric validation).
describe('canonicalMovieTmdbId', () => {
  it('leaves an already-prefixed id unchanged (idempotent)', () => {
    expect(canonicalMovieTmdbId('tmdb_603')).toBe('tmdb_603');
  });

  it('prefixes a bare numeric string', () => {
    expect(canonicalMovieTmdbId('603')).toBe('tmdb_603');
  });

  it('prefixes a numeric value', () => {
    expect(canonicalMovieTmdbId(603)).toBe('tmdb_603');
  });

  it('is idempotent when applied twice', () => {
    expect(canonicalMovieTmdbId(canonicalMovieTmdbId('603'))).toBe('tmdb_603');
    expect(canonicalMovieTmdbId(canonicalMovieTmdbId('tmdb_603'))).toBe('tmdb_603');
  });

  it('passes through non-numeric input by prefixing (matches DiscoverView.normalizeTmdbId, no validation)', () => {
    // DiscoverView.normalizeTmdbId only checks the `tmdb_` prefix; it never
    // validates the payload, so a non-numeric raw id is prefixed verbatim rather
    // than rejected. This helper reproduces that exact guard.
    expect(canonicalMovieTmdbId('abc')).toBe('tmdb_abc');
  });
});
