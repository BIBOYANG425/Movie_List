import { supabase } from '../lib/supabase';
import {
  FeedCard,
  FeedCardType,
  FeedComment,
  FeedFilters,
  FeedMute,
  ReactionType,
  Tier,
} from '../types';

const REACTION_TYPES: ReactionType[] = ['fire', 'agree', 'disagree', 'want_to_watch', 'love'];

function emptyReactionCounts(): Record<ReactionType, number> {
  return { fire: 0, agree: 0, disagree: 0, want_to_watch: 0, love: 0 };
}

interface EventRow {
  id: string;
  actor_id: string;
  event_type: string;
  media_tmdb_id?: string | null;
  media_title?: string | null;
  media_tier?: string | null;
  media_poster_url?: string | null;
  metadata?: Record<string, unknown> | null;
  created_at: string;
}

interface ProfileInfo {
  username: string;
  displayName?: string;
  avatarUrl?: string;
}

async function getFollowingIds(userId: string): Promise<string[]> {
  const { data, error } = await supabase
    .from('friend_follows')
    .select('following_id')
    .eq('follower_id', userId);

  if (error) {
    console.error('Failed to load following IDs:', error);
    return [];
  }
  return (data ?? []).map((row: { following_id: string }) => row.following_id);
}

async function getProfilesByIds(
  ids: string[],
): Promise<Map<string, ProfileInfo>> {
  if (ids.length === 0) return new Map();

  const { data, error } = await supabase
    .from('profiles')
    .select('id, username, display_name, avatar_url, avatar_path')
    .in('id', ids);

  if (error) {
    console.error('Failed to load profiles:', error);
    return new Map();
  }

  return new Map(
    (data ?? []).map((row: any) => [
      row.id,
      {
        username: row.username,
        displayName: row.display_name ?? undefined,
        avatarUrl: row.avatar_url ?? (row.avatar_path
          ? supabase.storage.from('avatars').getPublicUrl(row.avatar_path).data.publicUrl
          : `https://api.dicebear.com/8.x/thumbs/svg?seed=${encodeURIComponent(row.username)}`),
      },
    ]),
  );
}

function toFeedCardType(eventType: string): FeedCardType | null {
  if (eventType === 'ranking_add' || eventType === 'ranking_move') return 'ranking';
  if (eventType === 'review') return 'review';
  if (eventType === 'milestone') return 'milestone';
  if (eventType === 'list_create') return 'list';
  return null;
}

function toTier(value?: string | null): Tier | undefined {
  if (value && ['S', 'A', 'B', 'C', 'D'].includes(value)) return value as Tier;
  return undefined;
}

function applyTimeFilter(query: any, timeRange?: string) {
  if (!timeRange || timeRange === 'all') return query;

  const now = new Date();
  let cutoff: Date;
  if (timeRange === '24h') cutoff = new Date(now.getTime() - 24 * 60 * 60 * 1000);
  else if (timeRange === '7d') cutoff = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);
  else if (timeRange === '30d') cutoff = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000);
  else return query;

  return query.gte('created_at', cutoff.toISOString());
}

// ── Core Feed Functions ─────────────────────────────────────────────────────

export async function getFeedCards(
  userId: string,
  filters: FeedFilters,
  offset: number = 0,
  limit: number = 20,
): Promise<FeedCard[]> {
  const isFriendsFeed = filters.tab === 'friends';

  // Determine which actor IDs to query
  let actorIds: string[] | null = null;
  if (isFriendsFeed) {
    actorIds = await getFollowingIds(userId);
    if (actorIds.length === 0) return [];
  }

  // Load mutes to filter out
  const mutes = await getMutes(userId);
  const mutedUserIds = new Set(mutes.filter(m => m.muteType === 'user').map(m => m.targetId));
  const mutedMovieIds = new Set(mutes.filter(m => m.muteType === 'movie').map(m => m.targetId));

  // Filter actor IDs by mutes
  if (actorIds) {
    actorIds = actorIds.filter(id => !mutedUserIds.has(id));
    if (actorIds.length === 0) return [];
  }

  // Determine event types to query
  const eventTypes = getEventTypesForFilter(filters.cardType);

  // Build query
  let query = supabase
    .from('activity_events')
    .select('id, actor_id, event_type, media_tmdb_id, media_title, media_tier, media_poster_url, metadata, created_at')
    .in('event_type', eventTypes)
    .order('created_at', { ascending: false });

  if (actorIds) {
    query = query.in('actor_id', actorIds);
  }

  // Apply tier filter
  if (filters.tier && filters.tier !== 'all') {
    query = query.eq('media_tier', filters.tier);
  }

  query = applyTimeFilter(query, filters.timeRange);

  // Fetch more than needed to account for mutes and throttling
  const fetchLimit = limit + offset + 20;
  query = query.limit(fetchLimit);

  const { data, error } = await query;

  if (error) {
    console.error('Failed to load feed events:', error);
    return [];
  }

  let rows = (data ?? []) as EventRow[];

  // Apply mutes: filter out muted movies
  rows = rows.filter(row => {
    if (row.media_tmdb_id && mutedMovieIds.has(row.media_tmdb_id)) return false;
    if (!actorIds && mutedUserIds.has(row.actor_id)) return false;
    return true;
  });

  // Apply bracket filter client-side (bracket stored in metadata)
  if (filters.bracket && filters.bracket !== 'all') {
    rows = rows.filter(row => {
      const bracket = row.metadata?.bracket as string | undefined;
      return bracket === filters.bracket;
    });
  }

  // Throttle milestones to max 3/day across all friends
  rows = throttleMilestones(rows);

  // Apply review boost for prioritization
  rows = applyReviewBoost(rows);

  // Paginate
  rows = rows.slice(offset, offset + limit);

  if (rows.length === 0) return [];

  // Batch load profiles and engagement
  const actorIdSet = new Set(rows.map(r => r.actor_id));
  const eventIds = rows.map(r => r.id);

  const [profileMap, engagementMap] = await Promise.all([
    getProfilesByIds(Array.from(actorIdSet)),
    getReactionsForEvents(userId, eventIds),
  ]);

  // Map rows to FeedCards
  return rows.map(row => {
    const profile = profileMap.get(row.actor_id);
    const engagement = engagementMap.get(row.id);
    const cardType = toFeedCardType(row.event_type) ?? 'ranking';
    const metadata = row.metadata ?? {};

    const card: FeedCard = {
      id: row.id,
      userId: row.actor_id,
      username: profile?.username ?? 'unknown',
      displayName: profile?.displayName,
      avatarUrl: profile?.avatarUrl,
      cardType,
      createdAt: row.created_at,
      mediaTmdbId: row.media_tmdb_id ?? undefined,
      mediaTitle: row.media_title ?? undefined,
      mediaPosterUrl: row.media_poster_url ?? undefined,
      mediaTier: toTier(row.media_tier),
      bracket: metadata.bracket as string | undefined,
      reactionCounts: engagement?.counts ?? emptyReactionCounts(),
      commentCount: engagement?.commentCount ?? 0,
      myReactions: engagement?.myReactions ?? [],
    };

    // Card-type specific fields from metadata
    if (cardType === 'review') {
      card.reviewBody = metadata.reviewBody as string | undefined;
      card.containsSpoilers = metadata.containsSpoilers as boolean | undefined;
    } else if (cardType === 'milestone') {
      card.badgeKey = metadata.badgeKey as string | undefined;
      card.badgeIcon = metadata.badgeIcon as string | undefined;
      card.milestoneDescription = metadata.milestoneDescription as string | undefined;
    } else if (cardType === 'list') {
      card.listId = metadata.listId as string | undefined;
      card.listTitle = metadata.listTitle as string | undefined;
      card.listPosterUrls = metadata.listPosterUrls as string[] | undefined;
      card.listItemCount = metadata.listItemCount as number | undefined;
    }

    return card;
  });
}

function getEventTypesForFilter(cardType?: FeedCardType | 'all'): string[] {
  if (!cardType || cardType === 'all') {
    return ['ranking_add', 'ranking_move', 'review', 'list_create', 'milestone'];
  }
  if (cardType === 'ranking') return ['ranking_add', 'ranking_move'];
  if (cardType === 'review') return ['review'];
  if (cardType === 'milestone') return ['milestone'];
  if (cardType === 'list') return ['list_create'];
  return ['ranking_add', 'ranking_move', 'review', 'list_create', 'milestone'];
}

function throttleMilestones(rows: EventRow[]): EventRow[] {
  const milestoneCounts = new Map<string, number>(); // date -> count
  return rows.filter(row => {
    if (row.event_type !== 'milestone') return true;
    const dateKey = row.created_at.slice(0, 10);
    const count = milestoneCounts.get(dateKey) ?? 0;
    if (count >= 3) return false;
    milestoneCounts.set(dateKey, count + 1);
    return true;
  });
}

function applyReviewBoost(rows: EventRow[]): EventRow[] {
  const BOOST_MS = 2 * 60 * 60 * 1000; // 2 hours

  return rows
    .map(row => ({
      row,
      sortTime: row.event_type === 'review'
        ? new Date(row.created_at).getTime() + BOOST_MS
        : new Date(row.created_at).getTime(),
    }))
    .sort((a, b) => b.sortTime - a.sortTime)
    .map(entry => entry.row);
}

// ── Reactions ───────────────────────────────────────────────────────────────

export async function toggleReaction(
  userId: string,
  eventId: string,
  reaction: ReactionType,
  shouldAdd: boolean,
): Promise<boolean> {
  if (shouldAdd) {
    const { error } = await supabase.from('activity_reactions').insert({
      event_id: eventId,
      user_id: userId,
      reaction,
    });
    if (error) {
      console.error('Failed to add reaction:', error);
      return false;
    }
    return true;
  }

  const { error } = await supabase
    .from('activity_reactions')
    .delete()
    .eq('event_id', eventId)
    .eq('user_id', userId)
    .eq('reaction', reaction);
  if (error) {
    console.error('Failed to remove reaction:', error);
    return false;
  }
  return true;
}

export async function getReactionsForEvents(
  userId: string,
  eventIds: string[],
): Promise<Map<string, { counts: Record<ReactionType, number>; commentCount: number; myReactions: ReactionType[] }>> {
  const result = new Map<string, { counts: Record<ReactionType, number>; commentCount: number; myReactions: ReactionType[] }>();

  if (eventIds.length === 0) return result;

  const [reactionsRes, commentsRes] = await Promise.all([
    supabase
      .from('activity_reactions')
      .select('event_id, user_id, reaction')
      .in('event_id', eventIds),
    supabase
      .from('activity_comments')
      .select('event_id')
      .in('event_id', eventIds),
  ]);

  if (reactionsRes.error) console.error('Failed to load reactions:', reactionsRes.error);
  if (commentsRes.error) console.error('Failed to load comment counts:', commentsRes.error);

  // Initialize all events
  for (const id of eventIds) {
    result.set(id, { counts: emptyReactionCounts(), commentCount: 0, myReactions: [] });
  }

  // Tally reactions
  for (const row of (reactionsRes.data ?? []) as { event_id: string; user_id: string; reaction: string }[]) {
    const entry = result.get(row.event_id);
    if (!entry) continue;
    const reaction = row.reaction as ReactionType;
    if (REACTION_TYPES.includes(reaction)) {
      entry.counts[reaction] = (entry.counts[reaction] ?? 0) + 1;
      if (row.user_id === userId) {
        entry.myReactions.push(reaction);
      }
    }
  }

  // Tally comments
  for (const row of (commentsRes.data ?? []) as { event_id: string }[]) {
    const entry = result.get(row.event_id);
    if (entry) entry.commentCount += 1;
  }

  return result;
}

// ── Comments ────────────────────────────────────────────────────────────────

export async function listFeedComments(eventId: string): Promise<FeedComment[]> {
  const { data, error } = await supabase
    .from('activity_comments')
    .select('id, event_id, user_id, body, parent_comment_id, created_at')
    .eq('event_id', eventId)
    .order('created_at', { ascending: true })
    .limit(100);

  if (error) {
    console.error('Failed to load feed comments:', error);
    return [];
  }

  const rows = data ?? [];
  const userIds = [...new Set(rows.map((r: any) => r.user_id))];
  const profileMap = await getProfilesByIds(userIds);

  const allComments: FeedComment[] = rows.map((row: any) => {
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
      parentCommentId: row.parent_comment_id ?? undefined,
      replies: [],
    };
  });

  // Nest replies under parents (1 level only)
  const topLevel: FeedComment[] = [];
  const replyMap = new Map<string, FeedComment[]>();

  for (const comment of allComments) {
    if (comment.parentCommentId) {
      const existing = replyMap.get(comment.parentCommentId) ?? [];
      existing.push(comment);
      replyMap.set(comment.parentCommentId, existing);
    } else {
      topLevel.push(comment);
    }
  }

  for (const comment of topLevel) {
    comment.replies = replyMap.get(comment.id) ?? [];
  }

  return topLevel;
}

export async function addFeedComment(
  userId: string,
  eventId: string,
  body: string,
  parentCommentId?: string,
): Promise<boolean> {
  const insertData: Record<string, unknown> = {
    event_id: eventId,
    user_id: userId,
    body: body.slice(0, 500),
  };
  if (parentCommentId) {
    insertData.parent_comment_id = parentCommentId;
  }

  const { error } = await supabase.from('activity_comments').insert(insertData);
  if (error) {
    console.error('Failed to add feed comment:', error);
    return false;
  }
  return true;
}

export async function deleteFeedComment(userId: string, commentId: string): Promise<boolean> {
  const { error } = await supabase
    .from('activity_comments')
    .delete()
    .eq('id', commentId)
    .eq('user_id', userId);

  if (error) {
    console.error('Failed to delete feed comment:', error);
    return false;
  }
  return true;
}

// ── Mutes ───────────────────────────────────────────────────────────────────

export async function getMutes(userId: string): Promise<FeedMute[]> {
  const { data, error } = await supabase
    .from('feed_mutes')
    .select('id, mute_type, target_id')
    .eq('user_id', userId);

  if (error) {
    console.error('Failed to load mutes:', error);
    return [];
  }

  return (data ?? []).map((row: any) => ({
    id: row.id,
    muteType: row.mute_type as 'user' | 'movie',
    targetId: row.target_id,
  }));
}

export async function addMute(
  userId: string,
  muteType: 'user' | 'movie',
  targetId: string,
): Promise<boolean> {
  const { error } = await supabase.from('feed_mutes').insert({
    user_id: userId,
    mute_type: muteType,
    target_id: targetId,
  });
  if (error) {
    console.error('Failed to add mute:', error);
    return false;
  }
  return true;
}

export async function removeMute(userId: string, muteId: string): Promise<boolean> {
  const { error } = await supabase
    .from('feed_mutes')
    .delete()
    .eq('id', muteId)
    .eq('user_id', userId);

  if (error) {
    console.error('Failed to remove mute:', error);
    return false;
  }
  return true;
}

// ── Activity Event Logging ──────────────────────────────────────────────────

export async function logReviewActivityEvent(
  userId: string,
  review: {
    tmdbId: string;
    title: string;
    posterUrl?: string;
    tier?: Tier;
    body: string;
    containsSpoilers: boolean;
  },
): Promise<boolean> {
  const { error } = await supabase.from('activity_events').insert({
    actor_id: userId,
    event_type: 'review',
    media_tmdb_id: review.tmdbId,
    media_title: review.title,
    media_tier: review.tier ?? null,
    media_poster_url: review.posterUrl ?? null,
    metadata: {
      reviewBody: review.body,
      containsSpoilers: review.containsSpoilers,
    },
  });

  if (error) {
    console.error('Failed to log review activity event:', error);
    return false;
  }
  return true;
}

export async function logListCreatedEvent(
  userId: string,
  list: {
    listId: string;
    title: string;
    posterUrls: string[];
    itemCount: number;
  },
): Promise<boolean> {
  const { error } = await supabase.from('activity_events').insert({
    actor_id: userId,
    event_type: 'list_create',
    metadata: {
      listId: list.listId,
      listTitle: list.title,
      listPosterUrls: list.posterUrls.slice(0, 4),
      listItemCount: list.itemCount,
    },
  });

  if (error) {
    console.error('Failed to log list created event:', error);
    return false;
  }
  return true;
}

export async function logMilestoneEvent(
  userId: string,
  badge: {
    badgeKey: string;
    badgeIcon: string;
    description: string;
  },
): Promise<boolean> {
  const { error } = await supabase.from('activity_events').insert({
    actor_id: userId,
    event_type: 'milestone',
    metadata: {
      badgeKey: badge.badgeKey,
      badgeIcon: badge.badgeIcon,
      milestoneDescription: badge.description,
    },
  });

  if (error) {
    console.error('Failed to log milestone event:', error);
    return false;
  }
  return true;
}
