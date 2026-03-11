import { supabase } from '../lib/supabase';
import {
  FriendActivityItem,
  FriendRecommendation,
  GenreProfileItem,
  MoodTag,
  MovieSocialStats,
  RankingComparison,
  RankingComparisonItem,
  SharedMovieComparison,
  TasteCompatibility,
  Tier,
  TrendingMovie,
} from '../types';
import {
  getProfilesByIds,
  getFollowingIdSet,
  SUPABASE_URL,
  SUPABASE_ANON_KEY,
} from './profileService';

export const TIER_NUMERIC: Record<string, number> = { S: 5, A: 4, B: 3, C: 2, D: 1 };
export const NUMERIC_TIER: Record<number, string> = { 5: 'S', 4: 'A', 3: 'B', 2: 'C', 1: 'D' };

export function tierLabel(numeric: number): string {
  const rounded = Math.round(numeric);
  return NUMERIC_TIER[Math.max(1, Math.min(5, rounded))] || 'C';
}

export interface UserRankingRowPhase1 {
  tmdb_id: string;
  title: string;
  poster_url: string | null;
  tier: string;
  rank_position: number;
}

export async function getTasteCompatibility(
  viewerId: string,
  targetId: string,
): Promise<TasteCompatibility | null> {
  const [viewerRes, targetRes, profileMap] = await Promise.all([
    supabase
      .from('user_rankings')
      .select('tmdb_id, title, poster_url, tier, rank_position')
      .eq('user_id', viewerId),
    supabase
      .from('user_rankings')
      .select('tmdb_id, title, poster_url, tier, rank_position')
      .eq('user_id', targetId),
    getProfilesByIds([targetId]),
  ]);

  if (viewerRes.error || targetRes.error) {
    console.error('Failed to load rankings for taste computation');
    return null;
  }

  const viewerMap = new Map<string, UserRankingRowPhase1>();
  ((viewerRes.data ?? []) as UserRankingRowPhase1[]).forEach(r => viewerMap.set(r.tmdb_id, r));

  const targetMap = new Map<string, UserRankingRowPhase1>();
  ((targetRes.data ?? []) as UserRankingRowPhase1[]).forEach(r => targetMap.set(r.tmdb_id, r));

  const sharedIds = [...viewerMap.keys()].filter(id => targetMap.has(id));
  const targetProfile = profileMap.get(targetId);

  if (sharedIds.length === 0) {
    return {
      targetUserId: targetId,
      targetUsername: targetProfile?.username ?? 'unknown',
      score: 0,
      sharedCount: 0,
      agreements: 0,
      nearAgreements: 0,
      disagreements: 0,
      topShared: [],
      biggestDivergences: [],
    };
  }

  let agreements = 0;
  let nearAgreements = 0;
  let disagreements = 0;
  const scores: number[] = [];
  const shared: (SharedMovieComparison & { _distance: number })[] = [];

  for (const tmdbId of sharedIds) {
    const vr = viewerMap.get(tmdbId)!;
    const tr = targetMap.get(tmdbId)!;
    const vVal = TIER_NUMERIC[vr.tier] ?? 3;
    const tVal = TIER_NUMERIC[tr.tier] ?? 3;
    const distance = Math.abs(vVal - tVal);

    if (distance === 0) { agreements++; scores.push(100); }
    else if (distance === 1) { nearAgreements++; scores.push(60); }
    else if (distance === 2) { disagreements++; scores.push(20); }
    else { disagreements++; scores.push(0); }

    shared.push({
      mediaItemId: tmdbId,
      mediaTitle: vr.title,
      posterUrl: vr.poster_url ?? undefined,
      viewerTier: vr.tier,
      viewerScore: 0,
      targetTier: tr.tier,
      targetScore: 0,
      tierDifference: vVal - tVal,
      _distance: distance,
    });
  }

  const overallScore = Math.round(scores.reduce((a, b) => a + b, 0) / scores.length);

  const topShared = shared
    .filter(s => s._distance === 0)
    .sort((a, b) => (TIER_NUMERIC[b.viewerTier] ?? 0) - (TIER_NUMERIC[a.viewerTier] ?? 0))
    .slice(0, 5)
    .map(({ _distance, ...rest }) => rest);

  const biggestDivergences = [...shared]
    .sort((a, b) => b._distance - a._distance)
    .slice(0, 5)
    .map(({ _distance, ...rest }) => rest);

  return {
    targetUserId: targetId,
    targetUsername: targetProfile?.username ?? 'unknown',
    score: overallScore,
    sharedCount: sharedIds.length,
    agreements,
    nearAgreements,
    disagreements,
    topShared,
    biggestDivergences,
  };
}

export async function getRankingComparison(
  viewerId: string,
  targetId: string,
): Promise<RankingComparison | null> {
  const [viewerRes, targetRes, profileMap] = await Promise.all([
    supabase
      .from('user_rankings')
      .select('tmdb_id, title, poster_url, tier, rank_position')
      .eq('user_id', viewerId),
    supabase
      .from('user_rankings')
      .select('tmdb_id, title, poster_url, tier, rank_position')
      .eq('user_id', targetId),
    getProfilesByIds([targetId]),
  ]);

  if (viewerRes.error || targetRes.error) {
    console.error('Failed to load rankings for comparison');
    return null;
  }

  const viewerRows = (viewerRes.data ?? []) as UserRankingRowPhase1[];
  const targetRows = (targetRes.data ?? []) as UserRankingRowPhase1[];
  const targetProfile = profileMap.get(targetId);

  const viewerMap = new Map<string, UserRankingRowPhase1>();
  viewerRows.forEach(r => viewerMap.set(r.tmdb_id, r));
  const targetMap = new Map<string, UserRankingRowPhase1>();
  targetRows.forEach(r => targetMap.set(r.tmdb_id, r));

  const allIds = new Set([...viewerMap.keys(), ...targetMap.keys()]);
  const sharedIds = new Set([...viewerMap.keys()].filter(id => targetMap.has(id)));

  const items: RankingComparisonItem[] = [];
  for (const id of allIds) {
    const vr = viewerMap.get(id);
    const tr = targetMap.get(id);
    items.push({
      mediaItemId: id,
      mediaTitle: (vr?.title ?? tr?.title) || 'Unknown',
      posterUrl: vr?.poster_url ?? tr?.poster_url ?? undefined,
      viewerTier: vr?.tier,
      viewerScore: undefined,
      viewerRankPosition: vr?.rank_position,
      targetTier: tr?.tier,
      targetScore: undefined,
      targetRankPosition: tr?.rank_position,
      isShared: sharedIds.has(id),
    });
  }

  const tierOrder: Record<string, number> = { S: 0, A: 1, B: 2, C: 3, D: 4 };
  items.sort((a, b) => {
    if (a.isShared !== b.isShared) return a.isShared ? -1 : 1;
    return (tierOrder[a.viewerTier ?? ''] ?? 5) - (tierOrder[b.viewerTier ?? ''] ?? 5);
  });

  return {
    targetUserId: targetId,
    targetUsername: targetProfile?.username ?? 'unknown',
    viewerTotal: viewerRows.length,
    targetTotal: targetRows.length,
    sharedCount: sharedIds.size,
    items,
  };
}

/**
 * Get movies that friends ranked S/A tier but the user hasn't ranked or watchlisted.
 */
export async function getFriendRecommendations(
  userId: string,
  limit = 20,
): Promise<FriendRecommendation[]> {
  // 1. Get following IDs
  const { data: follows } = await supabase
    .from('friend_follows')
    .select('following_id')
    .eq('follower_id', userId);
  const friendIds = follows?.map((f: { following_id: string }) => f.following_id) ?? [];
  if (friendIds.length === 0) return [];

  // 2. Get user's own ranked + watchlisted movie IDs
  const [rankedRes, watchlistRes] = await Promise.all([
    supabase.from('user_rankings').select('tmdb_id').eq('user_id', userId),
    supabase.from('watchlist_items').select('tmdb_id').eq('user_id', userId),
  ]);
  const myMovieIds = new Set([
    ...(rankedRes.data?.map((r: { tmdb_id: string }) => r.tmdb_id) ?? []),
    ...(watchlistRes.data?.map((w: { tmdb_id: string }) => w.tmdb_id) ?? []),
  ]);

  // 3. Get friends' S/A-tier rankings
  const { data: friendRankings } = await supabase
    .from('user_rankings')
    .select('tmdb_id, title, poster_url, year, genres, tier, user_id')
    .in('user_id', friendIds)
    .in('tier', ['S', 'A']);

  if (!friendRankings || friendRankings.length === 0) return [];

  // 4. Aggregate by movie, excluding user's own
  const movieMap = new Map<string, {
    title: string;
    posterUrl: string | null;
    year: string | null;
    genres: string[];
    tiers: number[];
    userIds: Set<string>;
  }>();

  for (const r of friendRankings) {
    if (myMovieIds.has(r.tmdb_id)) continue;
    const existing = movieMap.get(r.tmdb_id);
    if (existing) {
      existing.tiers.push(TIER_NUMERIC[r.tier] ?? 3);
      existing.userIds.add(r.user_id);
    } else {
      movieMap.set(r.tmdb_id, {
        title: r.title,
        posterUrl: r.poster_url,
        year: r.year,
        genres: r.genres ?? [],
        tiers: [TIER_NUMERIC[r.tier] ?? 3],
        userIds: new Set([r.user_id]),
      });
    }
  }

  // 5. Get friend profiles for avatars
  const allFriendIds = [...new Set(friendRankings.map((r: { user_id: string }) => r.user_id))];
  const { data: profiles } = await supabase
    .from('profiles')
    .select('id, username, avatar_path')
    .in('id', allFriendIds);
  const profileMap = new Map(
    (profiles ?? []).map((p: { id: string; username: string; avatar_path?: string }) => [p.id, p]),
  );

  // 6. Build and sort results
  const results: FriendRecommendation[] = [];
  for (const [tmdbId, data] of movieMap) {
    const avg = data.tiers.reduce((a, b) => a + b, 0) / data.tiers.length;
    const friendList = [...data.userIds].slice(0, 5);
    const avatars = friendList.map((id) => {
      const p = profileMap.get(id);
      if (!p?.avatar_path) return '';
      return `${SUPABASE_URL}/storage/v1/object/public/avatars/${p.avatar_path}`;
    });
    const usernames = friendList.map(
      (id) => (profileMap.get(id) as { username: string } | undefined)?.username ?? '',
    );

    results.push({
      tmdbId,
      title: data.title,
      posterUrl: data.posterUrl ?? undefined,
      year: data.year ?? undefined,
      genres: data.genres,
      avgTier: tierLabel(avg),
      avgTierNumeric: Math.round(avg * 10) / 10,
      friendCount: data.userIds.size,
      friendAvatars: avatars,
      friendUsernames: usernames,
      topTier: NUMERIC_TIER[Math.max(...data.tiers)] ?? 'C',
    });
  }

  results.sort((a, b) => b.friendCount - a.friendCount || b.avgTierNumeric - a.avgTierNumeric);
  return results.slice(0, limit);
}

/**
 * Get most-ranked movies among friends in the last N days.
 */
export async function getTrendingAmongFriends(
  userId: string,
  limit = 15,
  days = 30,
): Promise<TrendingMovie[]> {
  const { data: follows } = await supabase
    .from('friend_follows')
    .select('following_id')
    .eq('follower_id', userId);
  const friendIds = follows?.map((f: { following_id: string }) => f.following_id) ?? [];
  if (friendIds.length === 0) return [];

  const cutoff = new Date(Date.now() - days * 86_400_000).toISOString();

  const { data: recentRankings } = await supabase
    .from('user_rankings')
    .select('tmdb_id, title, poster_url, year, genres, tier, user_id')
    .in('user_id', friendIds)
    .gte('updated_at', cutoff);

  if (!recentRankings || recentRankings.length === 0) return [];

  // Aggregate
  const movieMap = new Map<string, {
    title: string;
    posterUrl: string | null;
    year: string | null;
    genres: string[];
    tiers: number[];
    rankerIds: Set<string>;
  }>();

  for (const r of recentRankings) {
    const existing = movieMap.get(r.tmdb_id);
    if (existing) {
      existing.tiers.push(TIER_NUMERIC[r.tier] ?? 3);
      existing.rankerIds.add(r.user_id);
    } else {
      movieMap.set(r.tmdb_id, {
        title: r.title,
        posterUrl: r.poster_url,
        year: r.year,
        genres: r.genres ?? [],
        tiers: [TIER_NUMERIC[r.tier] ?? 3],
        rankerIds: new Set([r.user_id]),
      });
    }
  }

  // Get ranker profiles
  const allRankerIds = [...new Set(recentRankings.map((r: { user_id: string }) => r.user_id))];
  const { data: rankerProfiles } = await supabase
    .from('profiles')
    .select('id, username')
    .in('id', allRankerIds);
  const usernameMap = new Map(
    (rankerProfiles ?? []).map((p: { id: string; username: string }) => [p.id, p.username]),
  );

  const results: TrendingMovie[] = [];
  for (const [tmdbId, data] of movieMap) {
    if (data.rankerIds.size < 2) continue; // Need 2+ friends
    const avg = data.tiers.reduce((a, b) => a + b, 0) / data.tiers.length;
    const rankerNames = [...data.rankerIds].slice(0, 5).map(
      (id) => usernameMap.get(id) ?? '',
    );

    results.push({
      tmdbId,
      title: data.title,
      posterUrl: data.posterUrl ?? undefined,
      year: data.year ?? undefined,
      genres: data.genres,
      rankerCount: data.rankerIds.size,
      avgTier: tierLabel(avg),
      avgTierNumeric: Math.round(avg * 10) / 10,
      recentRankers: rankerNames,
    });
  }

  results.sort((a, b) => b.rankerCount - a.rankerCount || b.avgTierNumeric - a.avgTierNumeric);
  return results.slice(0, limit);
}

/**
 * Get genre distribution from a user's rankings.
 */
export async function getGenreProfile(
  userId: string,
  mediaType: 'movie' | 'tv_season' = 'movie',
): Promise<GenreProfileItem[]> {
  const rankingTable = mediaType === 'tv_season' ? 'tv_rankings' : 'user_rankings';
  const { data: rankings } = await supabase
    .from(rankingTable)
    .select('genres, tier')
    .eq('user_id', userId);

  if (!rankings || rankings.length === 0) return [];

  const genreTiers = new Map<string, number[]>();
  const total = rankings.length;

  for (const r of rankings) {
    const genres: string[] = r.genres ?? [];
    const tierVal = TIER_NUMERIC[r.tier] ?? 3;
    for (const g of genres) {
      if (!g || typeof g !== 'string') continue;
      const trimmed = g.trim();
      const existing = genreTiers.get(trimmed);
      if (existing) {
        existing.push(tierVal);
      } else {
        genreTiers.set(trimmed, [tierVal]);
      }
    }
  }

  const items: GenreProfileItem[] = [];
  for (const [genre, tiers] of genreTiers) {
    const count = tiers.length;
    const avg = tiers.reduce((a, b) => a + b, 0) / count;
    items.push({
      genre,
      count,
      percentage: Math.round((count / total) * 1000) / 10,
      avgTier: tierLabel(avg),
      avgTierNumeric: Math.round(avg * 10) / 10,
    });
  }

  items.sort((a, b) => b.count - a.count);
  return items;
}

async function getMediaSocialStats(
  currentUserId: string,
  tmdbId: string,
  rankingTable: 'user_rankings' | 'tv_rankings',
): Promise<MovieSocialStats | null> {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return null;

  try {
    const { data: follows, error: followsError } = await supabase
      .from('friend_follows')
      .select('following_id')
      .eq('follower_id', currentUserId);

    if (followsError || !follows) return null;

    const friendIds = follows.map((f) => f.following_id);
    if (friendIds.length === 0) {
      return {
        movieId: tmdbId,
        timesRanked: 0,
        friendsWatched: 0,
        friendAvatars: [],
        moodConsensus: [],
      };
    }

    const { data: friendRankings, error: rankingsError } = await supabase
      .from(rankingTable)
      .select('user_id, rank_position, tier, profiles:user_id(username, avatar_url)')
      .eq('tmdb_id', tmdbId)
      .in('user_id', friendIds);

    if (rankingsError) return null;

    const friendsWatched = friendRankings?.length || 0;
    const friendAvatars = (friendRankings || [])
      .map((r) => (r.profiles as any)?.avatar_url)
      .filter(Boolean)
      .slice(0, 5);

    let avgFriendRankPosition: number | undefined;
    if (friendsWatched > 0) {
      const sum = friendRankings!.reduce((acc, r) => acc + r.rank_position, 0);
      avgFriendRankPosition = Math.round(sum / friendsWatched);
    }

    const { data: friendReviews } = await supabase
      .from('movie_reviews')
      .select('user_id, body, profiles:user_id(username, avatar_url)')
      .eq('media_item_id', tmdbId)
      .in('user_id', friendIds)
      .order('like_count', { ascending: false })
      .limit(1);

    let topFriendReview;
    if (friendReviews && friendReviews.length > 0) {
      const rev = friendReviews[0];
      const rankData = friendRankings?.find((r) => r.user_id === rev.user_id);
      topFriendReview = {
        userId: rev.user_id,
        username: (rev.profiles as any).username,
        avatarUrl: (rev.profiles as any).avatar_url,
        body: rev.body,
        rankPosition: rankData?.rank_position ?? 0,
        tier: rankData?.tier ?? Tier.C,
      };
    }

    const moodConsensus: MoodTag[] = [];

    const { count: timesRanked } = await supabase
      .from(rankingTable)
      .select('*', { count: 'exact', head: true })
      .eq('tmdb_id', tmdbId);

    const { data: activityData, error: activityError } = await supabase
      .from('activity_events')
      .select('id, actor_id, event_type, media_tier, created_at, profiles:actor_id(username, avatar_url)')
      .eq('media_tmdb_id', tmdbId)
      .in('actor_id', friendIds)
      .order('created_at', { ascending: false })
      .limit(10);

    const recentActivity: FriendActivityItem[] = [];
    if (!activityError && activityData) {
      activityData.forEach((event) => {
        let action: FriendActivityItem['action'] | null = null;

        if (event.event_type === 'ranking_add' || event.event_type === 'ranking_move') action = 'ranked';
        else if (event.event_type === 'review' || event.event_type === 'review_add') action = 'reviewed';
        else if (event.event_type === 'watchlist_add') action = 'bookmarked';

        if (action) {
          recentActivity.push({
            id: event.id,
            userId: event.actor_id,
            username: (event.profiles as any)?.username || 'A friend',
            avatarUrl: (event.profiles as any)?.avatar_url,
            action,
            tier: event.media_tier as Tier | undefined,
            timestamp: event.created_at,
          });
        }
      });
    }

    return {
      movieId: tmdbId,
      timesRanked: timesRanked || 0,
      friendsWatched,
      friendAvatars,
      avgFriendRankPosition,
      topFriendReview,
      moodConsensus,
      divisiveMatchup: undefined,
      globalAvgRankPosition: undefined,
      recentActivity,
    };
  } catch (err) {
    console.error('Failed to fetch media social stats:', err);
    return null;
  }
}

export async function getMovieSocialStats(currentUserId: string, tmdbId: string): Promise<MovieSocialStats | null> {
  return getMediaSocialStats(currentUserId, tmdbId, 'user_rankings');
}

export async function getTVSocialStats(currentUserId: string, tmdbId: string): Promise<MovieSocialStats | null> {
  return getMediaSocialStats(currentUserId, tmdbId, 'tv_rankings');
}
