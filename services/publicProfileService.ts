import { supabase } from '../lib/supabase';
import { RankedItem, Tier, Bracket, MediaType } from '../types';
import { classifyBracket } from './rankingAlgorithm';

function rowToRankedItem(row: Record<string, unknown>, type: MediaType): RankedItem {
  return {
    id: row.tmdb_id as string,
    title: row.title as string,
    year: (row.year as string) ?? '',
    posterUrl: (row.poster_url as string) ?? '',
    type,
    genres: (row.genres as string[]) ?? [],
    director: row.director as string | undefined,
    tier: row.tier as Tier,
    rank: row.rank_position as number,
    bracket: (row.bracket as Bracket) ?? classifyBracket((row.genres as string[]) ?? []),
    notes: row.notes as string | undefined,
  };
}

const RANKING_COLUMNS = 'tmdb_id, title, year, poster_url, tier, rank_position, genres, bracket, director, notes';
const BOOK_RANKING_COLUMNS = 'tmdb_id, title, year, poster_url, tier, rank_position, genres, bracket, notes';

function extractItems(
  result: PromiseSettledResult<{ data: Record<string, unknown>[] | null; error: unknown }>,
  type: MediaType,
  label: string,
): RankedItem[] {
  if (result.status !== 'fulfilled') {
    console.error(`${label} rankings query rejected:`, result.reason);
    return [];
  }
  if (result.value.error) {
    console.error(`Failed to fetch ${label} rankings:`, result.value.error);
    return [];
  }
  return (result.value.data ?? []).map((r) => rowToRankedItem(r, type));
}

export async function getPublicRankings(userId: string): Promise<{
  movies: RankedItem[];
  tv: RankedItem[];
  books: RankedItem[];
}> {
  const [movieResult, tvResult, bookResult] = await Promise.allSettled([
    supabase
      .from('user_rankings')
      .select(RANKING_COLUMNS)
      .eq('user_id', userId)
      .order('tier')
      .order('rank_position'),
    supabase
      .from('tv_rankings')
      .select(RANKING_COLUMNS)
      .eq('user_id', userId)
      .order('tier')
      .order('rank_position'),
    supabase
      .from('book_rankings')
      .select(BOOK_RANKING_COLUMNS)
      .eq('user_id', userId)
      .order('tier')
      .order('rank_position'),
  ]);

  return {
    movies: extractItems(movieResult, 'movie', 'movie'),
    tv: extractItems(tvResult, 'tv_season', 'TV'),
    books: extractItems(bookResult, 'book', 'book'),
  };
}
