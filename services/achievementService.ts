import { supabase } from '../lib/supabase';
import { UserAchievement } from '../types';
import { logMilestoneEvent } from './feedService';

export async function getUserAchievements(userId: string): Promise<UserAchievement[]> {
  const { data } = await supabase
    .from('user_achievements')
    .select('badge_key, unlocked_at')
    .eq('user_id', userId)
    .order('unlocked_at', { ascending: false });
  return (data ?? []).map((a: any) => ({ badgeKey: a.badge_key, unlockedAt: a.unlocked_at }));
}

export async function checkAndGrantBadges(userId: string): Promise<string[]> {
  const newBadges: string[] = [];

  // Get existing badges
  const existing = await getUserAchievements(userId);
  const has = new Set(existing.map((a) => a.badgeKey));

  // Get counts
  const [rankRes, reviewRes, followingRes, followerRes, partyRes, pollRes, listRes] = await Promise.all([
    supabase.from('user_rankings').select('id', { count: 'exact', head: true }).eq('user_id', userId),
    supabase.from('movie_reviews').select('id', { count: 'exact', head: true }).eq('user_id', userId),
    supabase.from('friend_follows').select('id', { count: 'exact', head: true }).eq('follower_id', userId),
    supabase.from('friend_follows').select('id', { count: 'exact', head: true }).eq('following_id', userId),
    supabase.from('watch_parties').select('id', { count: 'exact', head: true }).eq('host_id', userId),
    supabase.from('movie_polls').select('id', { count: 'exact', head: true }).eq('created_by', userId),
    supabase.from('movie_lists').select('id', { count: 'exact', head: true }).eq('created_by', userId),
  ]);

  const rankCount = rankRes.count ?? 0;
  const reviewCount = reviewRes.count ?? 0;
  const followingCount = followingRes.count ?? 0;
  const followerCount = followerRes.count ?? 0;
  const partyCount = partyRes.count ?? 0;
  const pollCount = pollRes.count ?? 0;
  const listCount = listRes.count ?? 0;

  // Check milestone badges
  const milestones: [string, number, number][] = [
    ['first_rank', rankCount, 1],
    ['rank_10', rankCount, 10],
    ['rank_25', rankCount, 25],
    ['rank_50', rankCount, 50],
    ['rank_100', rankCount, 100],
    ['first_review', reviewCount, 1],
    ['review_10', reviewCount, 10],
  ];

  const socials: [string, number, number][] = [
    ['first_follow', followingCount, 1],
    ['followers_10', followerCount, 10],
    ['followers_50', followerCount, 50],
    ['first_party', partyCount, 1],
    ['first_poll', pollCount, 1],
    ['first_list', listCount, 1],
  ];

  for (const [key, count, threshold] of [...milestones, ...socials]) {
    if (!has.has(key) && count >= threshold) {
      newBadges.push(key);
    }
  }

  // Check genre badges
  if (!has.has('genre_5') || !has.has('genre_10')) {
    const { data: rankings } = await supabase.from('user_rankings').select('genres').eq('user_id', userId);
    const genres = new Set<string>();
    for (const r of (rankings ?? [])) {
      for (const g of (r.genres ?? [])) {
        if (g && typeof g === 'string') genres.add(g.trim());
      }
    }
    if (!has.has('genre_5') && genres.size >= 5) newBadges.push('genre_5');
    if (!has.has('genre_10') && genres.size >= 10) newBadges.push('genre_10');
  }

  // Check tier badges
  if (!has.has('s_tier_10') || !has.has('d_tier_5')) {
    const { data: tierCounts } = await supabase.from('user_rankings').select('tier').eq('user_id', userId);
    let sCount = 0, dCount = 0;
    for (const r of (tierCounts ?? [])) {
      if (r.tier === 'S') sCount++;
      if (r.tier === 'D') dCount++;
    }
    if (!has.has('s_tier_10') && sCount >= 10) newBadges.push('s_tier_10');
    if (!has.has('d_tier_5') && dCount >= 5) newBadges.push('d_tier_5');
  }

  // Grant new badges
  if (newBadges.length > 0) {
    const rows = newBadges.map((key) => ({ user_id: userId, badge_key: key }));
    await supabase.from('user_achievements').insert(rows);

    // Log milestone activity events for the social feed
    try {
      const badgeDescriptions: Record<string, { icon: string; description: string }> = {
        first_rank: { icon: '🎬', description: 'Ranked their first movie' },
        rank_10: { icon: '🎯', description: 'Ranked 10 movies' },
        rank_25: { icon: '🏅', description: 'Ranked 25 movies' },
        rank_50: { icon: '🏆', description: 'Ranked 50 movies' },
        rank_100: { icon: '👑', description: 'Ranked 100 movies' },
        first_review: { icon: '✍️', description: 'Wrote their first review' },
        review_10: { icon: '📝', description: 'Wrote 10 reviews' },
        first_follow: { icon: '🤝', description: 'Followed their first friend' },
        followers_10: { icon: '⭐', description: 'Reached 10 followers' },
        followers_50: { icon: '🌟', description: 'Reached 50 followers' },
        first_party: { icon: '🎉', description: 'Hosted their first watch party' },
        first_poll: { icon: '🗳️', description: 'Created their first poll' },
        first_list: { icon: '📋', description: 'Created their first list' },
        genre_5: { icon: '🎭', description: 'Explored 5 genres' },
        genre_10: { icon: '🌈', description: 'Explored 10 genres' },
        s_tier_10: { icon: '💎', description: '10 movies in S tier' },
        d_tier_5: { icon: '🗑️', description: '5 movies in D tier' },
      };
      for (const key of newBadges) {
        const info = badgeDescriptions[key] ?? { icon: '🏅', description: `Unlocked: ${key}` };
        await logMilestoneEvent(userId, {
          badgeKey: key,
          badgeIcon: info.icon,
          description: info.description,
        });
      }
    } catch (err) {
      console.error('Failed to log milestone events:', err);
    }
  }

  return newBadges;
}
