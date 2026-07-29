import { Tier, RankedItem } from '../../../types';

/**
 * Shared RankedItem fixture for the gallery layout/turn tests. A fully-typed
 * object (no `as unknown as RankedItem` cast) so the tests exercise the same
 * shape the engine sees.
 */
export function makeItem(id: string, tier: Tier, rank: number): RankedItem {
  return {
    id,
    title: `Movie ${id}`,
    year: '2024',
    posterUrl: `https://image.tmdb.org/t/p/w500/${id}.jpg`,
    type: 'movie',
    genres: [],
    tier,
    rank,
  };
}
