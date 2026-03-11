import { supabase } from '../lib/supabase';
import {
  ActivityComment,
  FriendFeedItem,
  ProfileActivityItem,
} from '../types';
import {
  getProfilesByIds,
  getFollowingIdSet,
  toTier,
  toRankingEventType,
  ActivityEventRow,
  ActivityReactionRow,
  ActivityCommentRow,
  RankingActivityEventType,
  RankingActivityPayload,
  manualMediaKey,
} from './profileService';

export async function logRankingActivityEvent(
  userId: string,
  item: RankingActivityPayload,
  eventType: RankingActivityEventType,
): Promise<boolean> {
  const metadata: Record<string, unknown> = {};
  if (item.notes) metadata.notes = item.notes;
  if (item.year) metadata.year = item.year;
  if (item.watchedWithUserIds?.length) metadata.watched_with_user_ids = item.watchedWithUserIds;

  const { error } = await supabase.from('activity_events').insert({
    actor_id: userId,
    event_type: eventType,
    media_tmdb_id: item.id,
    media_title: item.title,
    media_tier: item.tier,
    media_poster_url: item.posterUrl ?? null,
    metadata,
  });

  if (error) {
    console.error('Failed to log ranking activity event:', error);
    return false;
  }
  return true;
}

export async function getFriendFeed(currentUserId: string, limit = 24): Promise<FriendFeedItem[]> {
  const followingIds = await getFollowingIdSet(currentUserId);
  const ids = Array.from(followingIds);
  if (ids.length === 0) return [];

  const { data, error } = await supabase
    .from('activity_events')
    .select('id, actor_id, event_type, media_title, media_tier, media_poster_url, created_at')
    .in('actor_id', ids)
    .in('event_type', ['ranking_add', 'ranking_move', 'ranking_remove'])
    .order('created_at', { ascending: false })
    .limit(limit);

  if (error) {
    console.error('Failed to load friend feed:', error);
    return [];
  }

  const rows = (data ?? []) as ActivityEventRow[];
  const filteredRows = rows.filter((row) => toTier(row.media_tier) && row.media_title);
  const profileMap = await getProfilesByIds(Array.from(new Set(filteredRows.map((row) => row.actor_id))));

  return filteredRows.map((row) => ({
    id: row.id,
    userId: row.actor_id,
    username: profileMap.get(row.actor_id)?.username ?? 'unknown',
    title: row.media_title ?? 'Untitled',
    tier: toTier(row.media_tier)!,
    rankedAt: row.created_at,
    posterUrl: row.media_poster_url ?? undefined,
    eventType: toRankingEventType(row.event_type) ?? undefined,
  }));
}

export async function getRecentProfileActivity(
  targetUserId: string,
  limit = 10,
): Promise<ProfileActivityItem[]> {
  const { data, error } = await supabase
    .from('activity_events')
    .select('id, event_type, media_title, media_tier, media_poster_url, metadata, created_at')
    .eq('actor_id', targetUserId)
    .in('event_type', ['ranking_add', 'ranking_move', 'ranking_remove'])
    .order('created_at', { ascending: false })
    .limit(limit);

  if (error) {
    console.error('Failed to load profile activity:', error);
    return [];
  }

  const rows = (data ?? []) as ActivityEventRow[];
  return rows
    .map((row) => {
      const tier = toTier(row.media_tier);
      if (!tier || !row.media_title) return null;
      const notes = typeof row.metadata?.notes === 'string' ? row.metadata.notes : undefined;
      const year = typeof row.metadata?.year === 'string' ? row.metadata.year : undefined;
      return {
        id: row.id,
        title: row.media_title,
        tier,
        notes,
        year,
        updatedAt: row.created_at,
        posterUrl: row.media_poster_url ?? undefined,
        eventType: toRankingEventType(row.event_type) ?? undefined,
      } as ProfileActivityItem;
    })
    .filter((row): row is ProfileActivityItem => row !== null);
}

export async function getActivityEngagement(
  currentUserId: string,
  eventIds: string[],
): Promise<{
  likedByMe: Set<string>;
  likeCounts: Record<string, number>;
  commentCounts: Record<string, number>;
}> {
  if (eventIds.length === 0) {
    return {
      likedByMe: new Set<string>(),
      likeCounts: {},
      commentCounts: {},
    };
  }

  const [likesRes, commentsRes] = await Promise.all([
    supabase
      .from('activity_reactions')
      .select('event_id, user_id, reaction')
      .in('event_id', eventIds)
      .eq('reaction', 'like'),
    supabase
      .from('activity_comments')
      .select('event_id, id')
      .in('event_id', eventIds),
  ]);

  if (likesRes.error) {
    console.error('Failed to load activity reactions:', likesRes.error);
  }
  if (commentsRes.error) {
    console.error('Failed to load activity comments:', commentsRes.error);
  }

  const likedByMe = new Set<string>();
  const likeCounts: Record<string, number> = {};
  const commentCounts: Record<string, number> = {};

  const likeRows = (likesRes.data ?? []) as ActivityReactionRow[];
  likeRows.forEach((row) => {
    likeCounts[row.event_id] = (likeCounts[row.event_id] ?? 0) + 1;
    if (row.user_id === currentUserId) likedByMe.add(row.event_id);
  });

  const commentRows = (commentsRes.data ?? []) as Array<{ event_id: string }>;
  commentRows.forEach((row) => {
    commentCounts[row.event_id] = (commentCounts[row.event_id] ?? 0) + 1;
  });

  return {
    likedByMe,
    likeCounts,
    commentCounts,
  };
}

export async function toggleActivityLike(
  userId: string,
  eventId: string,
  shouldLike: boolean,
): Promise<boolean> {
  if (shouldLike) {
    const { error } = await supabase.from('activity_reactions').insert({
      event_id: eventId,
      user_id: userId,
      reaction: 'like',
    });
    if (error) {
      console.error('Failed to add like reaction:', error);
      return false;
    }
    return true;
  }

  const { error } = await supabase
    .from('activity_reactions')
    .delete()
    .eq('event_id', eventId)
    .eq('user_id', userId)
    .eq('reaction', 'like');
  if (error) {
    console.error('Failed to remove like reaction:', error);
    return false;
  }
  return true;
}

export async function listActivityComments(
  eventId: string,
  limit = 50,
): Promise<ActivityComment[]> {
  const { data, error } = await supabase
    .from('activity_comments')
    .select('id, event_id, user_id, body, created_at')
    .eq('event_id', eventId)
    .order('created_at', { ascending: true })
    .limit(limit);

  if (error) {
    console.error('Failed to load activity comments:', error);
    return [];
  }

  const rows = (data ?? []) as ActivityCommentRow[];
  const profileMap = await getProfilesByIds(Array.from(new Set(rows.map((row) => row.user_id))));

  return rows.map((row) => {
    const profile = profileMap.get(row.user_id);
    return {
      id: row.id,
      eventId: row.event_id,
      userId: row.user_id,
      username: profile?.username ?? 'unknown',
      displayName: profile?.displayName,
      avatarUrl: profile?.avatarUrl,
      body: row.body,
      createdAt: row.created_at,
    };
  });
}

export async function addActivityComment(
  userId: string,
  eventId: string,
  body: string,
): Promise<boolean> {
  const trimmedBody = body.trim();
  if (!trimmedBody) return false;

  const { error } = await supabase.from('activity_comments').insert({
    event_id: eventId,
    user_id: userId,
    body: trimmedBody,
  });
  if (error) {
    console.error('Failed to add activity comment:', error);
    return false;
  }
  return true;
}

export async function saveActivityMovieToWatchlist(
  userId: string,
  activity: Pick<ProfileActivityItem, 'title' | 'posterUrl' | 'year'>,
): Promise<boolean> {
  const { error } = await supabase.from('watchlist_items').upsert({
    user_id: userId,
    tmdb_id: manualMediaKey(activity.title, activity.year),
    title: activity.title,
    year: activity.year ?? null,
    poster_url: activity.posterUrl ?? null,
    type: 'movie',
    genres: [],
    director: null,
  }, { onConflict: 'user_id,tmdb_id' });

  if (error) {
    console.error('Failed to save activity movie to watchlist:', error);
    return false;
  }
  return true;
}

export async function rankActivityMovie(
  userId: string,
  activity: Pick<ProfileActivityItem, 'title' | 'tier' | 'notes' | 'posterUrl' | 'year'>,
): Promise<boolean> {
  const { data: tierRows, error: tierError } = await supabase
    .from('user_rankings')
    .select('rank_position')
    .eq('user_id', userId)
    .eq('tier', activity.tier)
    .order('rank_position', { ascending: false })
    .limit(1);

  if (tierError) {
    console.error('Failed to load existing tier ranks:', tierError);
    return false;
  }

  const nextRank = tierRows && tierRows.length > 0
    ? Number(tierRows[0].rank_position) + 1
    : 0;

  const { error } = await supabase.from('user_rankings').upsert({
    user_id: userId,
    tmdb_id: manualMediaKey(activity.title, activity.year),
    title: activity.title,
    year: activity.year ?? null,
    poster_url: activity.posterUrl ?? null,
    type: 'movie',
    genres: [],
    director: null,
    tier: activity.tier,
    rank_position: nextRank,
    notes: activity.notes ?? null,
    updated_at: new Date().toISOString(),
  }, { onConflict: 'user_id,tmdb_id' });

  if (error) {
    console.error('Failed to rank activity movie:', error);
    return false;
  }

  await logRankingActivityEvent(
    userId,
    {
      id: manualMediaKey(activity.title, activity.year),
      title: activity.title,
      tier: activity.tier,
      posterUrl: activity.posterUrl,
      notes: activity.notes,
      year: activity.year,
    },
    'ranking_add',
  );

  return true;
}
