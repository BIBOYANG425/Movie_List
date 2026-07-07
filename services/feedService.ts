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

/**
 * Batch-fetch live scores for ranking cards via the `get_feed_ranking_scores`
 * RPC (supabase/migrations/20260707_feed_ranking_scores_rpc.sql) — one round
 * trip instead of the old ~100-query per-user/per-tier loop. The RPC runs
 * `security invoker`, so ranking-table RLS still decides which scores the
 * viewer can see; pairs with no visible ranking simply return no row.
 * Returns a map keyed by `${userId}:${tmdbId}` → computed score.
 */
async function getRankingScores(
  pairs: { userId: string; tmdbId: string }[],
): Promise<Map<string, number>> {
  const scoreMap = new Map<string, number>();
  if (pairs.length === 0) return scoreMap;

  // Dedupe pairs so the payload stays minimal
  const seen = new Set<string>();
  const rpcPairs: { user_id: string; tmdb_id: string }[] = [];
  for (const { userId, tmdbId } of pairs) {
    const key = `${userId}:${tmdbId}`;
    if (seen.has(key)) continue;
    seen.add(key);
    rpcPairs.push({ user_id: userId, tmdb_id: tmdbId });
  }

  const { data, error } = await supabase.rpc('get_feed_ranking_scores', {
    pairs: rpcPairs,
  });

  if (error) {
    console.error('Failed to load ranking scores:', error);
    return scoreMap;
  }

  for (const row of (data ?? []) as { user_id: string; tmdb_id: string; score: number }[]) {
    scoreMap.set(`${row.user_id}:${row.tmdb_id}`, Number(row.score));
  }

  return scoreMap;
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

/** Epoch-ms lower bound for a time-range filter, from the client clock (as before). */
function timeRangeCutoffMs(timeRange?: string): number | null {
  if (!timeRange || timeRange === 'all') return null;
  const now = Date.now();
  if (timeRange === '24h') return now - 24 * 60 * 60 * 1000;
  if (timeRange === '7d') return now - 7 * 24 * 60 * 60 * 1000;
  if (timeRange === '30d') return now - 30 * 24 * 60 * 60 * 1000;
  return null;
}

// ── Keyset Pagination (get_feed_page RPC) ───────────────────────────────────

/** Keyset cursor into the boosted feed ordering: last consumed row's (boosted_ts, id). */
export interface FeedCursor {
  boostedTs: string;
  id: string;
}

/** activity_events row + the server-computed ordering key, as returned by get_feed_page. */
interface FeedPageRow extends EventRow {
  boosted_ts: string;
}

/**
 * Build the keyset cursor from a get_feed_page row. The ordering key —
 * the windowless review boost, see supabase/migrations/20260707_feed_page_rpc.sql:
 *
 *   boosted_ts = created_at + interval '2 hours' * (event_type = 'review')::int
 *
 * — is computed SERVER-side and returned as the boosted_ts column, so the
 * cursor copies it VERBATIM (byte-exact, Postgres µs precision preserved)
 * and the client never recomputes the ordering key. Deterministic per row:
 * no now(), no session anchor, cursors never expire. Pinned by
 * services/__tests__/feedPagination.test.ts.
 */
export function cursorFromFeedRow(row: { id: string; boosted_ts: string }): FeedCursor {
  return { boostedTs: row.boosted_ts, id: row.id };
}

/** Serialize a cursor (session storage / iOS-shared wire format). */
export function encodeFeedCursor(cursor: FeedCursor): string {
  return JSON.stringify({ boostedTs: cursor.boostedTs, id: cursor.id });
}

/** Parse an encoded cursor; malformed input yields null (restart from the top). */
export function decodeFeedCursor(encoded: string): FeedCursor | null {
  try {
    const parsed: unknown = JSON.parse(encoded);
    if (
      parsed !== null &&
      typeof parsed === 'object' &&
      !Array.isArray(parsed) &&
      typeof (parsed as { boostedTs?: unknown }).boostedTs === 'string' &&
      (parsed as { boostedTs: string }).boostedTs.length > 0 &&
      typeof (parsed as { id?: unknown }).id === 'string' &&
      (parsed as { id: string }).id.length > 0
    ) {
      const { boostedTs, id } = parsed as { boostedTs: string; id: string };
      return { boostedTs, id };
    }
    return null;
  } catch {
    return null;
  }
}

/**
 * SocialFeedView pages by offset (offset = cards.length, PAGE_SIZE = 20)
 * while the RPC pages by keyset cursor; this module-level session bridges
 * the two. A call with offset 0 starts a fresh session (cursor at the top);
 * a call at exactly the offset the session expects resumes from the stored
 * cursor; any other offset (stale component state, remount) falls back to
 * walking forward from the top of the stream.
 */
interface FeedPageSession {
  key: string;
  nextOffset: number;
  cursor: string | null; // encodeFeedCursor form; null = top of stream
  exhausted: boolean;
}

let feedPageSession: FeedPageSession | null = null;

function feedSessionKey(userId: string, filters: FeedFilters): string {
  return [
    userId,
    filters.tab,
    filters.cardType ?? 'all',
    filters.tier ?? 'all',
    filters.timeRange ?? 'all',
    filters.bracket ?? 'all',
  ].join('|');
}

/** Raw get_feed_page calls allowed per getFeedCards call (refill bound). */
const MAX_FEED_RPC_PAGES = 10;

// ── Core Feed Functions ─────────────────────────────────────────────────────

export async function getFeedCards(
  userId: string,
  filters: FeedFilters,
  offset: number = 0,
  limit: number = 20,
): Promise<FeedCard[]> {
  const mode = filters.tab === 'friends' ? 'friends' : 'explore';
  const sessionKey = feedSessionKey(userId, filters);

  // Load mutes to filter out. User mutes are applied client-side in BOTH
  // modes now: actor scoping moved into the get_feed_page RPC (friends =
  // follower EXISTS, explore = RLS), so there is no actor-id list to
  // pre-shrink anymore. Same visible result as before.
  const mutes = await getMutes(userId);
  const mutedUserIds = new Set(mutes.filter(m => m.muteType === 'user').map(m => m.targetId));
  const mutedMovieIds = new Set(mutes.filter(m => m.muteType === 'movie').map(m => m.targetId));

  // Client-side row filters (the RPC pages the raw event stream unfiltered)
  const eventTypes = new Set(getEventTypesForFilter(filters.cardType));
  const cutoffMs = timeRangeCutoffMs(filters.timeRange);

  // Resolve the pagination session (offset -> cursor bridge)
  let cursor: FeedCursor | null = null;
  let exhausted = false;
  let skipCount = 0; // already-delivered cards to skip when walking from the top

  const resumable =
    offset > 0 &&
    feedPageSession !== null &&
    feedPageSession.key === sessionKey &&
    feedPageSession.nextOffset === offset;

  if (resumable && feedPageSession) {
    cursor = feedPageSession.cursor ? decodeFeedCursor(feedPageSession.cursor) : null;
    exhausted = feedPageSession.exhausted;
  } else {
    // Fresh session (page 1) or cold resume at an unexpected offset: restart
    // from the top of the stream and skip the first `offset` post-filter
    // cards. (The ordering key is deterministic per row, so restarting is
    // always safe — there is no per-session anchor to lose.)
    skipCount = offset;
  }

  // Fetch raw keyset pages and refill until the requested page is full or the
  // stream ends. Client-side filters (event types, tier, time range, mutes,
  // bracket, milestone throttle) shorten raw pages; because the cursor
  // advances over every CONSUMED raw row — kept or dropped — refilling never
  // duplicates or skips cards, and a heavily-filtered page no longer ends the
  // feed prematurely (audit B4c).
  const keptRows: EventRow[] = [];
  const keptCursors: FeedCursor[] = [];
  const wanted = skipCount + limit;
  // Milestone 3/day cap, counted over the rows this call consumes. NOTE: this
  // is a (deliberate) change from the legacy prefix semantics — the old code
  // re-fetched the whole feed prefix every page and counted milestones across
  // it, so later pages saw prefix-inflated counts; here each resumed call
  // counts from its cursor onward.
  const milestoneCounts = new Map<string, number>(); // UTC date -> count
  const maxRpcPages = MAX_FEED_RPC_PAGES + Math.ceil(skipCount / limit);
  let rpcPages = 0;

  while (!exhausted && keptRows.length < wanted && rpcPages < maxRpcPages) {
    rpcPages += 1;
    const { data, error } = await supabase.rpc('get_feed_page', {
      mode,
      cursor_rank: cursor?.boostedTs ?? null,
      cursor_id: cursor?.id ?? null,
      page_size: limit,
    });

    if (error) {
      console.error('Failed to load feed page:', error);
      break;
    }

    const raw = (data ?? []) as FeedPageRow[];
    const hasMore = raw.length === limit; // short raw page = end of stream
    if (!hasMore) exhausted = true;

    for (const row of raw) {
      if (keptRows.length >= wanted) break; // unconsumed tail is re-fetched next call

      const rowCursor = cursorFromFeedRow(row); // server-computed boosted_ts, verbatim

      // Time range: the boost only ever lifts rows, so once the ordered
      // stream sinks below the cutoff nothing later can pass — stop paging.
      if (cutoffMs !== null && Date.parse(rowCursor.boostedTs) < cutoffMs) {
        exhausted = true;
        break;
      }

      cursor = rowCursor; // row consumed (kept or dropped) — advance the keyset

      if (!eventTypes.has(row.event_type)) continue;
      if (filters.tier && filters.tier !== 'all' && row.media_tier !== filters.tier) continue;
      if (cutoffMs !== null && Date.parse(row.created_at) < cutoffMs) continue; // boosted review older than cutoff
      if (row.media_tmdb_id && mutedMovieIds.has(row.media_tmdb_id)) continue;
      if (mutedUserIds.has(row.actor_id)) continue;
      if (filters.bracket && filters.bracket !== 'all') {
        const bracket = row.metadata?.bracket as string | undefined;
        if (bracket !== filters.bracket) continue;
      }
      // Throttle milestones to max 3/day across all friends
      if (row.event_type === 'milestone') {
        const dateKey = row.created_at.slice(0, 10);
        const count = milestoneCounts.get(dateKey) ?? 0;
        if (count >= 3) continue;
        milestoneCounts.set(dateKey, count + 1);
      }

      keptRows.push(row);
      keptCursors.push(rowCursor);
    }
  }

  const rows = keptRows.slice(skipCount, wanted);

  // Persist the session so the next sequential call resumes from the last
  // RETURNED card's cursor (rows dropped after it are re-fetched and
  // re-dropped deterministically).
  const lastReturnedCursor = rows.length > 0 ? keptCursors[skipCount + rows.length - 1] : cursor;
  feedPageSession = {
    key: sessionKey,
    nextOffset: offset + rows.length,
    cursor: lastReturnedCursor ? encodeFeedCursor(lastReturnedCursor) : null,
    exhausted,
  };

  if (rows.length === 0) return [];

  // Batch load profiles and engagement
  const actorIdSet = new Set(rows.map(r => r.actor_id));
  // Also collect watched-with user IDs for resolution
  for (const row of rows) {
    const ww = (row.metadata as Record<string, unknown> | null)?.watched_with_user_ids;
    if (Array.isArray(ww)) ww.forEach((id: unknown) => { if (typeof id === 'string') actorIdSet.add(id); });
  }
  const eventIds = rows.map(r => r.id);

  // Collect ranking card pairs for live score lookup
  const rankingPairs: { userId: string; tmdbId: string }[] = [];
  for (const row of rows) {
    const ct = toFeedCardType(row.event_type);
    if ((ct === 'ranking' || ct === 'review') && row.media_tmdb_id) {
      rankingPairs.push({ userId: row.actor_id, tmdbId: row.media_tmdb_id });
    }
  }

  const [profileMap, engagementMap, scoreMap] = await Promise.all([
    getProfilesByIds(Array.from(actorIdSet)),
    getReactionsForEvents(userId, eventIds),
    getRankingScores(rankingPairs),
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
      mediaScore: row.media_tmdb_id ? scoreMap.get(`${row.actor_id}:${row.media_tmdb_id}`) : undefined,
      bracket: metadata.bracket as string | undefined,
      reactionCounts: engagement?.counts ?? emptyReactionCounts(),
      commentCount: engagement?.commentCount ?? 0,
      myReactions: engagement?.myReactions ?? [],
    };

    // Watched-with usernames (ranking cards)
    const wwIds = metadata.watched_with_user_ids;
    if (Array.isArray(wwIds) && wwIds.length > 0) {
      card.watchedWithUsernames = wwIds
        .map((id: unknown) => typeof id === 'string' ? profileMap.get(id)?.username : undefined)
        .filter((u): u is string => Boolean(u));
    }

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
