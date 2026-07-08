import { describe, it, expect, beforeEach, vi } from 'vitest';

// Captures the exact rows persistImport upserts into each table so we can assert
// the tmdb_id written is canonical `tmdb_{n}`, never bare `{n}` (B1). This pins
// the write value itself, not just the canonicalMovieTmdbId helper. The journal
// path in particular has no id-based dedup, so a bare id here would silently
// mint a duplicate against a later canonical in-app journal (UNIQUE user_id,tmdb_id).

// vi.hoisted so the capture store exists before the hoisted vi.mock factory runs.
const upsertsByTable = vi.hoisted(() => ({
  user_rankings: [] as unknown[][],
  watchlist_items: [] as unknown[][],
  journal_entries: [] as unknown[][],
}));

// Mock the Supabase client seam (path relative to THIS test file). `.select().eq()`
// (tier-count read) resolves to empty data; `.upsert()` records its rows per table
// and resolves with no error.
vi.mock('../../lib/supabase', () => {
  const from = (table: keyof typeof upsertsByTable) => ({
    select: () => ({
      eq: () => Promise.resolve({ data: [] }),
    }),
    upsert: (rows: unknown[]) => {
      upsertsByTable[table].push(rows);
      return Promise.resolve({ error: null });
    },
  });
  return { supabase: { from } };
});

import { persistImport, type ResolvedEntry } from '../letterboxdImportService';
import { Tier, Bracket } from '../../types';

function resolved(overrides: Partial<ResolvedEntry> = {}): ResolvedEntry {
  return {
    name: 'Fight Club',
    year: 1999,
    letterboxdUri: null,
    rating: 5,
    watchedDate: '2024-01-02',
    reviewText: 'great',
    isRewatch: false,
    tmdbId: 550, // bare numeric TMDB id, as the resolver holds it
    title: 'Fight Club',
    posterUrl: null,
    genres: ['Drama'],
    yearStr: '1999',
    ...overrides,
  };
}

describe('persistImport writes canonical tmdb_ ids (B1)', () => {
  beforeEach(() => {
    upsertsByTable.user_rankings = [];
    upsertsByTable.watchlist_items = [];
    upsertsByTable.journal_entries = [];
  });

  it('writes journal_entries with a canonical tmdb_ id (not bare)', async () => {
    const ranked = [
      { ...resolved(), tier: Tier.S, rankPosition: 0, bracket: Bracket.Commercial },
    ];

    await persistImport('user-1', ranked, [], new Set(), new Set());

    const journalRows = upsertsByTable.journal_entries.flat() as { tmdb_id: string }[];
    expect(journalRows).toHaveLength(1);
    expect(journalRows[0].tmdb_id).toBe('tmdb_550');
  });

  it('writes user_rankings and watchlist_items with canonical tmdb_ ids too', async () => {
    const ranked = [
      { ...resolved(), tier: Tier.A, rankPosition: 0, bracket: Bracket.Commercial },
    ];
    const watchlist = [resolved({ tmdbId: 603, title: 'The Matrix', reviewText: null, watchedDate: null })];

    await persistImport('user-1', ranked, watchlist, new Set(), new Set());

    const rankingRows = upsertsByTable.user_rankings.flat() as { tmdb_id: string }[];
    const watchlistRows = upsertsByTable.watchlist_items.flat() as { tmdb_id: string }[];
    expect(rankingRows[0].tmdb_id).toBe('tmdb_550');
    expect(watchlistRows[0].tmdb_id).toBe('tmdb_603');
  });

  it('skips a watchlist entry already present as a canonical existing id', async () => {
    // The dedup skip-check must compare in canonical form: an existing `tmdb_603`
    // must match the bare 603 the resolver holds, or a duplicate row is minted.
    const watchlist = [resolved({ tmdbId: 603, reviewText: null, watchedDate: null })];

    const result = await persistImport('user-1', [], watchlist, new Set(), new Set(['tmdb_603']));

    expect(result.watchlistSkipped).toBe(1);
    expect(upsertsByTable.watchlist_items.flat()).toHaveLength(0);
  });
});
