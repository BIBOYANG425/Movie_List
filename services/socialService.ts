import { supabase } from '../lib/supabase';
import {
  MovieList,
  MovieListItem,
  SharedWatchlist,
  SharedWatchlistItem,
  SharedWatchlistMember,
} from '../types';
import { getProfilesByIds } from './profileService';
import { logListCreatedEvent } from './feedService';

export interface SharedWatchlistRow {
  id: string;
  name: string;
  created_by: string;
  created_at: string;
}

export interface SharedWLMemberRow {
  watchlist_id: string;
  user_id: string;
  joined_at: string;
}

export interface SharedWLItemRow {
  id: string;
  watchlist_id: string;
  tmdb_id: string;
  title: string;
  poster_url: string | null;
  added_by: string;
  vote_count: number;
  added_at: string;
}

export interface SharedWLVoteRow {
  item_id: string;
  user_id: string;
}

export async function createSharedWatchlist(
  userId: string,
  name: string = 'Movie Night',
): Promise<SharedWatchlist | null> {
  const { data: wlData, error: wlError } = await supabase
    .from('shared_watchlists')
    .insert({ name, created_by: userId })
    .select()
    .single();

  if (wlError || !wlData) {
    console.error('Failed to create shared watchlist:', wlError);
    return null;
  }

  const wl = wlData as SharedWatchlistRow;

  // Add creator as member
  await supabase.from('shared_watchlist_members').insert({
    watchlist_id: wl.id,
    user_id: userId,
  });

  const profileMap = await getProfilesByIds([userId]);
  const profile = profileMap.get(userId);

  return {
    id: wl.id,
    name: wl.name,
    createdBy: wl.created_by,
    creatorUsername: profile?.username ?? 'unknown',
    memberCount: 1,
    itemCount: 0,
    createdAt: wl.created_at,
  };
}

export async function getMySharedWatchlists(
  userId: string,
): Promise<SharedWatchlist[]> {
  const { data: memberships, error: memErr } = await supabase
    .from('shared_watchlist_members')
    .select('watchlist_id')
    .eq('user_id', userId);

  if (memErr || !memberships || memberships.length === 0) return [];

  const wlIds = (memberships as SharedWLMemberRow[]).map(m => m.watchlist_id);

  const { data: wlData, error: wlErr } = await supabase
    .from('shared_watchlists')
    .select('*')
    .in('id', wlIds)
    .order('created_at', { ascending: false });

  if (wlErr) {
    console.error('Failed to load shared watchlists:', wlErr);
    return [];
  }

  const watchlists = (wlData ?? []) as SharedWatchlistRow[];
  const creatorIds = [...new Set(watchlists.map(w => w.created_by))];
  const profileMap = await getProfilesByIds(creatorIds);

  return watchlists.map(wl => ({
    id: wl.id,
    name: wl.name,
    createdBy: wl.created_by,
    creatorUsername: profileMap.get(wl.created_by)?.username ?? 'unknown',
    memberCount: 0,
    itemCount: 0,
    createdAt: wl.created_at,
  }));
}

export async function getSharedWatchlistDetail(
  watchlistId: string,
  viewerId: string,
): Promise<SharedWatchlist | null> {
  const [wlRes, membersRes, itemsRes] = await Promise.all([
    supabase.from('shared_watchlists').select('*').eq('id', watchlistId).single(),
    supabase.from('shared_watchlist_members').select('*').eq('watchlist_id', watchlistId),
    supabase.from('shared_watchlist_items').select('*').eq('watchlist_id', watchlistId).order('vote_count', { ascending: false }),
  ]);

  if (wlRes.error || !wlRes.data) return null;

  const wl = wlRes.data as SharedWatchlistRow;
  const memberRows = (membersRes.data ?? []) as SharedWLMemberRow[];
  const itemRows = (itemsRes.data ?? []) as SharedWLItemRow[];

  // Get profiles for members and item adders
  const allUserIds = [...new Set([
    wl.created_by,
    ...memberRows.map(m => m.user_id),
    ...itemRows.map(i => i.added_by),
  ])];
  const profileMap = await getProfilesByIds(allUserIds);

  // Get viewer votes
  const itemIds = itemRows.map(i => i.id);
  const viewerVotes = new Set<string>();
  if (itemIds.length > 0) {
    const { data: votes } = await supabase
      .from('shared_watchlist_votes')
      .select('item_id')
      .eq('user_id', viewerId)
      .in('item_id', itemIds);
    (votes ?? []).forEach((v: SharedWLVoteRow) => viewerVotes.add(v.item_id));
  }

  const members: SharedWatchlistMember[] = memberRows.map(m => {
    const profile = profileMap.get(m.user_id);
    return {
      userId: m.user_id,
      username: profile?.username ?? 'unknown',
      displayName: profile?.displayName,
      avatarUrl: profile?.avatarUrl,
      joinedAt: m.joined_at,
    };
  });

  const items: SharedWatchlistItem[] = itemRows.map(item => {
    const adder = profileMap.get(item.added_by);
    return {
      id: item.id,
      mediaItemId: item.tmdb_id,
      mediaTitle: item.title,
      posterUrl: item.poster_url ?? undefined,
      addedByUsername: adder?.username ?? 'unknown',
      voteCount: item.vote_count,
      viewerHasVoted: viewerVotes.has(item.id),
      addedAt: item.added_at,
    };
  });

  return {
    id: wl.id,
    name: wl.name,
    createdBy: wl.created_by,
    creatorUsername: profileMap.get(wl.created_by)?.username ?? 'unknown',
    memberCount: members.length,
    itemCount: items.length,
    createdAt: wl.created_at,
    members,
    items,
  };
}

export async function addSharedWatchlistMember(
  watchlistId: string,
  userId: string,
): Promise<boolean> {
  const { error } = await supabase.from('shared_watchlist_members').insert({
    watchlist_id: watchlistId,
    user_id: userId,
  });
  if (error) {
    console.error('Failed to add member:', error);
    return false;
  }
  return true;
}

export async function addSharedWatchlistItem(
  watchlistId: string,
  userId: string,
  tmdbId: string,
  title: string,
  posterUrl?: string,
): Promise<boolean> {
  const { error } = await supabase.from('shared_watchlist_items').insert({
    watchlist_id: watchlistId,
    tmdb_id: tmdbId,
    title,
    poster_url: posterUrl ?? null,
    added_by: userId,
  });
  if (error) {
    console.error('Failed to add item to shared watchlist:', error);
    return false;
  }
  return true;
}

export async function toggleSharedWLVote(
  itemId: string,
  userId: string,
  shouldVote: boolean,
): Promise<boolean> {
  if (shouldVote) {
    const { error } = await supabase.from('shared_watchlist_votes').insert({
      item_id: itemId,
      user_id: userId,
    });
    if (error) {
      console.error('Failed to vote:', error);
      return false;
    }
  } else {
    const { error } = await supabase
      .from('shared_watchlist_votes')
      .delete()
      .eq('item_id', itemId)
      .eq('user_id', userId);
    if (error) {
      console.error('Failed to unvote:', error);
      return false;
    }
  }
  return true;
}

export async function deleteSharedWatchlist(
  watchlistId: string,
  userId: string,
): Promise<boolean> {
  const { error } = await supabase
    .from('shared_watchlists')
    .delete()
    .eq('id', watchlistId)
    .eq('created_by', userId);
  if (error) {
    console.error('Failed to delete shared watchlist:', error);
    return false;
  }
  return true;
}

// ── Movie Lists ────────────────────────────────────────────────────

export async function createMovieList(
  userId: string,
  title: string,
  description?: string,
  isPublic = true,
): Promise<MovieList | null> {
  const { data: row, error } = await supabase
    .from('movie_lists')
    .insert({ created_by: userId, title, description: description ?? null, is_public: isPublic })
    .select()
    .single();
  if (error || !row) { console.error('Create list failed:', error); return null; }

  // Log list creation activity event for the social feed
  try {
    await logListCreatedEvent(userId, {
      listId: row.id,
      title: row.title,
      posterUrls: [],
      itemCount: 0,
    });
  } catch (err) {
    console.error('Failed to log list created event:', err);
  }

  return {
    id: row.id,
    createdBy: row.created_by,
    title: row.title,
    description: row.description,
    isPublic: row.is_public,
    coverUrl: row.cover_url,
    likeCount: 0,
    itemCount: 0,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export async function getMyMovieLists(userId: string): Promise<MovieList[]> {
  const { data } = await supabase
    .from('movie_lists')
    .select('*')
    .or(`created_by.eq.${userId},is_public.eq.true`)
    .order('created_at', { ascending: false })
    .limit(50);
  if (!data) return [];

  // Check viewer likes
  const listIds = data.map((l: any) => l.id);
  const { data: likes } = await supabase
    .from('movie_list_likes')
    .select('list_id')
    .eq('user_id', userId)
    .in('list_id', listIds);
  const likedSet = new Set((likes ?? []).map((l: { list_id: string }) => l.list_id));

  return data.map((r: any) => ({
    id: r.id,
    createdBy: r.created_by,
    title: r.title,
    description: r.description,
    isPublic: r.is_public,
    coverUrl: r.cover_url,
    likeCount: r.like_count ?? 0,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
    isLikedByViewer: likedSet.has(r.id),
  }));
}

export async function getMovieListItems(listId: string): Promise<MovieListItem[]> {
  const { data } = await supabase
    .from('movie_list_items')
    .select('*')
    .eq('list_id', listId)
    .order('position');
  if (!data) return [];
  return data.map((i: any) => ({
    id: i.id,
    listId: i.list_id,
    tmdbId: i.tmdb_id,
    title: i.title,
    posterUrl: i.poster_url,
    year: i.year,
    position: i.position,
    note: i.note,
    addedAt: i.added_at,
  }));
}

export async function addMovieListItem(
  listId: string,
  movie: { tmdbId: string; title: string; posterUrl?: string; year?: string; note?: string },
  position: number,
): Promise<boolean> {
  const { error } = await supabase.from('movie_list_items').insert({
    list_id: listId,
    tmdb_id: movie.tmdbId,
    title: movie.title,
    poster_url: movie.posterUrl ?? null,
    year: movie.year ?? null,
    note: movie.note ?? null,
    position,
  });
  return !error;
}

export async function removeMovieListItem(itemId: string): Promise<boolean> {
  const { error } = await supabase.from('movie_list_items').delete().eq('id', itemId);
  return !error;
}

export async function toggleListLike(listId: string, userId: string): Promise<boolean> {
  // Check if already liked
  const { data: existing } = await supabase
    .from('movie_list_likes')
    .select('list_id')
    .eq('list_id', listId)
    .eq('user_id', userId)
    .maybeSingle();

  if (existing) {
    await supabase.from('movie_list_likes').delete().eq('list_id', listId).eq('user_id', userId);
    return false; // unliked
  } else {
    await supabase.from('movie_list_likes').insert({ list_id: listId, user_id: userId });
    return true; // liked
  }
}

export async function deleteMovieList(listId: string): Promise<boolean> {
  const { error } = await supabase.from('movie_lists').delete().eq('id', listId);
  return !error;
}
