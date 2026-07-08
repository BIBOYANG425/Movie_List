import { describe, it, expect } from 'vitest';

import { shouldRemoveBookmarkAfterRank, tvWatchlistItemFromShow } from '../watchlistRankHelpers';
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
