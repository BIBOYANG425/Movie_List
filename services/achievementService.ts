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

// Milestone feed-card copy per badge (icon + human description). Kept client-side
// because the activity_events milestone card shape lives on the client; the RPC
// only decides WHICH badges are newly granted.
const BADGE_MILESTONE_COPY: Record<string, { icon: string; description: string }> = {
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
  first_list: { icon: '📋', description: 'Created their first list' },
  genre_5: { icon: '🎭', description: 'Explored 5 genres' },
  genre_10: { icon: '🌈', description: 'Explored 10 genres' },
  s_tier_10: { icon: '💎', description: '10 movies in S tier' },
  d_tier_5: { icon: '🗑️', description: '5 movies in D tier' },
};

/**
 * Grants any newly-earned badges for the current user SERVER-SIDE (B2/B3).
 *
 * All rule evaluation and inserts moved into the `grant_achievements()`
 * SECURITY DEFINER RPC (20260711_achievements_server_grant.sql): it recomputes
 * thresholds from the caller's own rows, inserts ON CONFLICT DO NOTHING, writes
 * one `badge_unlock` notification per new grant, and returns the newly-granted
 * badge keys. Clients have NO insert path to `user_achievements` anymore.
 *
 * Fire-and-forget: errors are logged, never thrown. Milestone feed events fire
 * ONLY for the RPC's returned new badge ids (fixes B3's fire-regardless bug).
 *
 * Only ever called for the signed-in user's OWN profile — `userId` is that user
 * (== auth.uid()), used as the milestone event's actor_id (activity_events INSERT
 * RLS requires auth.uid() = actor_id).
 *
 * @param userId the current (own-profile) user; must equal auth.uid().
 * @returns the newly-granted badge keys (empty on error or nothing new).
 */
export async function checkAndGrantBadges(userId: string): Promise<string[]> {
  const { data, error } = await supabase.rpc('grant_achievements');
  if (error) {
    console.error('grant_achievements RPC failed:', error);
    return [];
  }

  const newBadges: string[] = Array.isArray(data) ? data : [];

  // Milestone feed events ONLY for badges actually granted on this call.
  for (const key of newBadges) {
    const info = BADGE_MILESTONE_COPY[key] ?? { icon: '🏅', description: `Unlocked: ${key}` };
    await logMilestoneEvent(userId, {
      badgeKey: key,
      badgeIcon: info.icon,
      description: info.description,
    });
  }

  return newBadges;
}
