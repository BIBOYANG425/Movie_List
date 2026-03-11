import { supabase } from '../lib/supabase';

export async function followUser(currentUserId: string, targetUserId: string): Promise<boolean> {
  const { error } = await supabase
    .from('friend_follows')
    .insert({ follower_id: currentUserId, following_id: targetUserId });

  if (error) {
    console.error('Failed to follow user:', error);
    return false;
  }

  // Create notification for the followed user
  await supabase.from('notifications').insert({
    user_id: targetUserId,
    type: 'new_follower',
    title: 'started following you',
    actor_id: currentUserId,
    reference_id: currentUserId,
  }).then(({ error }) => {
    if (error) console.error('Failed to create follow notification:', error);
  });

  return true;
}

export async function unfollowUser(currentUserId: string, targetUserId: string): Promise<boolean> {
  const { error } = await supabase
    .from('friend_follows')
    .delete()
    .eq('follower_id', currentUserId)
    .eq('following_id', targetUserId);

  if (error) {
    console.error('Failed to unfollow user:', error);
    return false;
  }

  return true;
}

export async function getMutualFollowCount(
  viewerId: string,
  targetId: string,
): Promise<number> {
  const [viewerFollowing, targetFollowers] = await Promise.all([
    supabase.from('friend_follows').select('following_id').eq('follower_id', viewerId),
    supabase.from('friend_follows').select('follower_id').eq('following_id', targetId),
  ]);

  const viewerSet = new Set(
    (viewerFollowing.data ?? []).map((r: { following_id: string }) => r.following_id)
  );
  const targetSet = new Set(
    (targetFollowers.data ?? []).map((r: { follower_id: string }) => r.follower_id)
  );

  let count = 0;
  for (const id of viewerSet) {
    if (targetSet.has(id) && id !== viewerId && id !== targetId) count++;
  }
  return count;
}
