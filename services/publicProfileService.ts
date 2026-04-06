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

export async function getPublicRankings(userId: string): Promise<{
  movies: RankedItem[];
  tv: RankedItem[];
  books: RankedItem[];
}> {
  const [movieRes, tvRes, bookRes] = await Promise.all([
    supabase
      .from('user_rankings')
      .select('*')
      .eq('user_id', userId)
      .order('tier')
      .order('rank_position'),
    supabase
      .from('tv_rankings')
      .select('*')
      .eq('user_id', userId)
      .order('tier')
      .order('rank_position'),
    supabase
      .from('book_rankings')
      .select('*')
      .eq('user_id', userId)
      .order('tier')
      .order('rank_position'),
  ]);

  return {
    movies: (movieRes.data ?? []).map((r) => rowToRankedItem(r, 'movie')),
    tv: (tvRes.data ?? []).map((r) => rowToRankedItem(r, 'tv_season')),
    books: (bookRes.data ?? []).map((r) => rowToRankedItem(r, 'book')),
  };
}
