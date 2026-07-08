import { describe, it, expect } from 'vitest';

import { shouldRemoveBookmarkAfterRank } from '../watchlistRankHelpers';

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
