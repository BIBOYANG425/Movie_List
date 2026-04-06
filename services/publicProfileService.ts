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
  const [movieResult, tvResult, bookResult] = await Promise.allSettled([
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

  let movies: RankedItem[] = [];
  let tv: RankedItem[] = [];
  let books: RankedItem[] = [];

  if (movieResult.status === 'fulfilled') {
    if (movieResult.value.error) {
      console.error('Failed to fetch movie rankings:', movieResult.value.error);
    } else {
      movies = (movieResult.value.data ?? []).map((r) => rowToRankedItem(r, 'movie'));
    }
  } else {
    console.error('Movie rankings query rejected:', movieResult.reason);
  }

  if (tvResult.status === 'fulfilled') {
    if (tvResult.value.error) {
      console.error('Failed to fetch TV rankings:', tvResult.value.error);
    } else {
      tv = (tvResult.value.data ?? []).map((r) => rowToRankedItem(r, 'tv_season'));
    }
  } else {
    console.error('TV rankings query rejected:', tvResult.reason);
  }

  if (bookResult.status === 'fulfilled') {
    if (bookResult.value.error) {
      console.error('Failed to fetch book rankings:', bookResult.value.error);
    } else {
      books = (bookResult.value.data ?? []).map((r) => rowToRankedItem(r, 'book'));
    }
  } else {
    console.error('Book rankings query rejected:', bookResult.reason);
  }

  return { movies, tv, books };
}
