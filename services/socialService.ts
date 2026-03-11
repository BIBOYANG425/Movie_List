import { supabase } from '../lib/supabase';
import {
  GroupRanking,
  GroupRankingEntry,
  MovieList,
  MovieListItem,
  MoviePoll,
  MoviePollOption,
  RsvpStatus,
  SharedWatchlist,
  SharedWatchlistItem,
  SharedWatchlistMember,
  Tier,
  WatchParty,
  WatchPartyMember,
} from '../types';
import {
  getProfilesByIds,
  SUPABASE_URL,
  SUPABASE_ANON_KEY,
} from './profileService';
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

// ── Watch Parties ──────────────────────────────────────────────────

export async function createWatchParty(
  userId: string,
  data: { title: string; scheduledAt: string; movieTmdbId?: string; movieTitle?: string; moviePosterUrl?: string; location?: string; notes?: string },
): Promise<WatchParty | null> {
  const { data: row, error } = await supabase
    .from('watch_parties')
    .insert({
      host_id: userId,
      title: data.title,
      scheduled_at: data.scheduledAt,
      movie_tmdb_id: data.movieTmdbId ?? null,
      movie_title: data.movieTitle ?? null,
      movie_poster_url: data.moviePosterUrl ?? null,
      location: data.location ?? null,
      notes: data.notes ?? null,
    })
    .select()
    .single();
  if (error || !row) { console.error('Create party failed:', error); return null; }

  // Auto-add host as member
  await supabase.from('watch_party_members').insert({
    party_id: row.id,
    user_id: userId,
    rsvp: 'going',
    responded_at: new Date().toISOString(),
  });

  return {
    id: row.id,
    hostId: row.host_id,
    title: row.title,
    movieTmdbId: row.movie_tmdb_id,
    movieTitle: row.movie_title,
    moviePosterUrl: row.movie_poster_url,
    scheduledAt: row.scheduled_at,
    location: row.location,
    notes: row.notes,
    status: row.status,
    createdAt: row.created_at,
    memberCount: 1,
    goingCount: 1,
  };
}

export async function getMyWatchParties(userId: string): Promise<WatchParty[]> {
  // Parties I host + parties I'm invited to
  const { data: hosted } = await supabase
    .from('watch_parties')
    .select('*')
    .eq('host_id', userId)
    .order('scheduled_at', { ascending: true });

  const { data: invited } = await supabase
    .from('watch_party_members')
    .select('party_id')
    .eq('user_id', userId);
  const invitedIds = (invited ?? []).map((r: { party_id: string }) => r.party_id);

  let invitedParties: any[] = [];
  if (invitedIds.length > 0) {
    const { data } = await supabase
      .from('watch_parties')
      .select('*')
      .in('id', invitedIds)
      .neq('host_id', userId)
      .order('scheduled_at', { ascending: true });
    invitedParties = data ?? [];
  }

  const all = [...(hosted ?? []), ...invitedParties];
  return all.map((r: any) => ({
    id: r.id,
    hostId: r.host_id,
    title: r.title,
    movieTmdbId: r.movie_tmdb_id,
    movieTitle: r.movie_title,
    moviePosterUrl: r.movie_poster_url,
    scheduledAt: r.scheduled_at,
    location: r.location,
    notes: r.notes,
    status: r.status,
    createdAt: r.created_at,
  }));
}

export async function getPartyMembers(partyId: string): Promise<WatchPartyMember[]> {
  const { data } = await supabase
    .from('watch_party_members')
    .select('party_id, user_id, rsvp, responded_at')
    .eq('party_id', partyId);
  if (!data) return [];

  const userIds = data.map((m: { user_id: string }) => m.user_id);
  const { data: profiles } = await supabase.from('profiles').select('id, username, display_name, avatar_path').in('id', userIds);
  const profileMap = new Map((profiles ?? []).map((p: any) => [p.id, p]));

  return data.map((m: any) => {
    const p = profileMap.get(m.user_id);
    return {
      partyId: m.party_id,
      userId: m.user_id,
      username: p?.username ?? '',
      displayName: p?.display_name,
      avatarUrl: p?.avatar_path ? `${SUPABASE_URL}/storage/v1/object/public/avatars/${p.avatar_path}` : undefined,
      rsvp: m.rsvp,
      respondedAt: m.responded_at,
    };
  });
}

export async function inviteToParty(partyId: string, targetUserId: string): Promise<boolean> {
  const { error } = await supabase.from('watch_party_members').insert({
    party_id: partyId,
    user_id: targetUserId,
    rsvp: 'pending',
  });
  return !error;
}

export async function rsvpToParty(partyId: string, userId: string, rsvp: RsvpStatus): Promise<boolean> {
  const { error } = await supabase
    .from('watch_party_members')
    .upsert({ party_id: partyId, user_id: userId, rsvp, responded_at: new Date().toISOString() }, {
      onConflict: 'party_id,user_id',
    });
  return !error;
}

// ── Group Rankings ─────────────────────────────────────────────────

export async function createGroupRanking(
  userId: string,
  name: string,
  description?: string,
): Promise<GroupRanking | null> {
  const { data: row, error } = await supabase
    .from('group_rankings')
    .insert({ name, created_by: userId, description: description ?? null })
    .select()
    .single();
  if (error || !row) { console.error('Create group ranking failed:', error); return null; }

  // Auto-add creator as member
  await supabase.from('group_ranking_members').insert({ group_id: row.id, user_id: userId });

  return {
    id: row.id,
    name: row.name,
    createdBy: row.created_by,
    description: row.description,
    createdAt: row.created_at,
    memberCount: 1,
    entryCount: 0,
  };
}

export async function getMyGroupRankings(userId: string): Promise<GroupRanking[]> {
  // Groups created by user + groups where user is member
  const { data: created } = await supabase
    .from('group_rankings')
    .select('*')
    .eq('created_by', userId);

  const { data: memberships } = await supabase
    .from('group_ranking_members')
    .select('group_id')
    .eq('user_id', userId);
  const memberGroupIds = (memberships ?? []).map((m: { group_id: string }) => m.group_id);

  let memberGroups: any[] = [];
  if (memberGroupIds.length > 0) {
    const { data } = await supabase
      .from('group_rankings')
      .select('*')
      .in('id', memberGroupIds)
      .neq('created_by', userId);
    memberGroups = data ?? [];
  }

  const all = [...(created ?? []), ...memberGroups];
  return all.map((r: any) => ({
    id: r.id,
    name: r.name,
    createdBy: r.created_by,
    description: r.description,
    createdAt: r.created_at,
  }));
}

export async function getGroupRankingEntries(groupId: string): Promise<GroupRankingEntry[]> {
  const { data } = await supabase
    .from('group_ranking_entries')
    .select('*')
    .eq('group_id', groupId)
    .order('created_at');
  if (!data) return [];

  const userIds = [...new Set(data.map((e: { user_id: string }) => e.user_id))];
  const { data: profiles } = await supabase.from('profiles').select('id, username').in('id', userIds);
  const usernameMap = new Map((profiles ?? []).map((p: any) => [p.id, p.username]));

  return data.map((e: any) => ({
    id: e.id,
    groupId: e.group_id,
    userId: e.user_id,
    username: usernameMap.get(e.user_id) ?? '',
    tmdbId: e.tmdb_id,
    title: e.title,
    posterUrl: e.poster_url,
    year: e.year,
    genres: e.genres ?? [],
    tier: e.tier as Tier,
    createdAt: e.created_at,
  }));
}

export async function addGroupRankingEntry(
  groupId: string,
  userId: string,
  movie: { tmdbId: string; title: string; posterUrl?: string; year?: string; genres?: string[]; tier: Tier },
): Promise<boolean> {
  const { error } = await supabase.from('group_ranking_entries').upsert({
    group_id: groupId,
    user_id: userId,
    tmdb_id: movie.tmdbId,
    title: movie.title,
    poster_url: movie.posterUrl ?? null,
    year: movie.year ?? null,
    genres: movie.genres ?? [],
    tier: movie.tier,
  }, { onConflict: 'group_id,user_id,tmdb_id' });
  return !error;
}

export async function inviteToGroupRanking(groupId: string, targetUserId: string): Promise<boolean> {
  const { error } = await supabase.from('group_ranking_members').insert({
    group_id: groupId,
    user_id: targetUserId,
  });
  return !error;
}

// ── Movie Polls ────────────────────────────────────────────────────

export async function createMoviePoll(
  userId: string,
  question: string,
  options: { title: string; tmdbId: string; posterUrl?: string }[],
): Promise<MoviePoll | null> {
  const { data: poll, error } = await supabase
    .from('movie_polls')
    .insert({ created_by: userId, question })
    .select()
    .single();
  if (error || !poll) { console.error('Create poll failed:', error); return null; }

  const optionRows = options.map((o, i) => ({
    poll_id: poll.id,
    tmdb_id: o.tmdbId || `manual_${i}`,
    title: o.title,
    poster_url: o.posterUrl ?? null,
    position: i,
  }));

  const { data: insertedOpts } = await supabase.from('movie_poll_options').insert(optionRows).select();

  return {
    id: poll.id,
    createdBy: poll.created_by,
    question: poll.question,
    expiresAt: poll.expires_at,
    isClosed: poll.is_closed,
    createdAt: poll.created_at,
    options: (insertedOpts ?? []).map((o: any) => ({
      id: o.id,
      pollId: o.poll_id,
      tmdbId: o.tmdb_id,
      title: o.title,
      posterUrl: o.poster_url,
      position: o.position,
      voteCount: 0,
    })),
    totalVotes: 0,
  };
}

export async function getMyPolls(userId: string): Promise<MoviePoll[]> {
  // Polls from people I follow + my own
  const { data: follows } = await supabase
    .from('friend_follows')
    .select('following_id')
    .eq('follower_id', userId);
  const followingIds = [userId, ...(follows ?? []).map((f: { following_id: string }) => f.following_id)];

  const { data: polls } = await supabase
    .from('movie_polls')
    .select('*')
    .in('created_by', followingIds)
    .order('created_at', { ascending: false })
    .limit(20);
  if (!polls || polls.length === 0) return [];

  const pollIds = polls.map((p: any) => p.id);

  // Get options with vote counts
  const { data: options } = await supabase
    .from('movie_poll_options')
    .select('*')
    .in('poll_id', pollIds)
    .order('position');

  // Get vote counts per option
  const { data: votes } = await supabase
    .from('movie_poll_votes')
    .select('poll_id, option_id, user_id')
    .in('poll_id', pollIds);

  // Get creator usernames
  const creatorIds = [...new Set(polls.map((p: any) => p.created_by))];
  const { data: profiles } = await supabase.from('profiles').select('id, username').in('id', creatorIds);
  const usernameMap = new Map((profiles ?? []).map((p: any) => [p.id, p.username]));

  // Aggregate
  const votesByOption = new Map<string, number>();
  const myVotes = new Map<string, string>(); // pollId -> optionId
  for (const v of (votes ?? [])) {
    votesByOption.set(v.option_id, (votesByOption.get(v.option_id) ?? 0) + 1);
    if (v.user_id === userId) myVotes.set(v.poll_id, v.option_id);
  }

  return polls.map((p: any) => {
    const pollOptions = (options ?? [])
      .filter((o: any) => o.poll_id === p.id)
      .map((o: any) => ({
        id: o.id,
        pollId: o.poll_id,
        tmdbId: o.tmdb_id,
        title: o.title,
        posterUrl: o.poster_url,
        position: o.position,
        voteCount: votesByOption.get(o.id) ?? 0,
      }));

    // Determine winner
    const maxVotes = Math.max(...pollOptions.map((o: MoviePollOption) => o.voteCount ?? 0), 0);
    const totalVotes = pollOptions.reduce((sum: number, o: MoviePollOption) => sum + (o.voteCount ?? 0), 0);
    const closed = p.is_closed || (p.expires_at && new Date(p.expires_at) < new Date());

    return {
      id: p.id,
      createdBy: p.created_by,
      creatorUsername: usernameMap.get(p.created_by) ?? '',
      question: p.question,
      expiresAt: p.expires_at,
      isClosed: p.is_closed,
      createdAt: p.created_at,
      options: pollOptions.map((o: MoviePollOption) => ({
        ...o,
        isWinner: closed && maxVotes > 0 && (o.voteCount ?? 0) === maxVotes,
      })),
      totalVotes,
      viewerVoteOptionId: myVotes.get(p.id),
    };
  });
}

export async function votePoll(pollId: string, userId: string, optionId: string): Promise<boolean> {
  const { error } = await supabase
    .from('movie_poll_votes')
    .upsert({ poll_id: pollId, user_id: userId, option_id: optionId }, {
      onConflict: 'poll_id,user_id',
    });
  return !error;
}

export async function closePoll(pollId: string): Promise<boolean> {
  const { error } = await supabase
    .from('movie_polls')
    .update({ is_closed: true })
    .eq('id', pollId);
  return !error;
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
