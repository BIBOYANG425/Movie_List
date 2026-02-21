import { supabase } from '../lib/supabase';
import {
  FriendFeedItem,
  FriendProfile,
  ProfileActivityItem,
  Tier,
  UserProfileSummary,
  UserSearchResult,
} from '../types';

interface ProfileRow {
  id: string;
  username: string;
  avatar_url?: string | null;
}

interface FollowRow {
  following_id?: string;
  follower_id?: string;
  created_at: string;
}

interface RankingRow {
  id: string;
  user_id: string;
  title: string;
  tier: Tier;
  notes?: string | null;
  updated_at: string;
  poster_url: string | null;
}

function buildFallbackAvatar(seed: string): string {
  const encoded = encodeURIComponent(seed);
  return `https://api.dicebear.com/8.x/thumbs/svg?seed=${encoded}`;
}

async function getProfilesByIds(ids: string[]): Promise<Map<string, { username: string; avatarUrl?: string }>> {
  if (ids.length === 0) return new Map();

  const { data, error } = await supabase
    .from('profiles')
    .select('id, username, avatar_url')
    .in('id', ids);

  if (error) {
    console.error('Failed to load profiles:', error);
    return new Map();
  }

  return new Map(
    (data as ProfileRow[]).map((row) => [
      row.id,
      {
        username: row.username,
        avatarUrl: row.avatar_url ?? buildFallbackAvatar(row.username),
      },
    ]),
  );
}

export async function searchUsers(currentUserId: string, query: string): Promise<UserSearchResult[]> {
  const trimmed = query.trim();
  if (!trimmed) return [];

  const [{ data: profileData, error: profileError }, followingSet] = await Promise.all([
    supabase
      .from('profiles')
      .select('id, username, avatar_url')
      .ilike('username', `%${trimmed}%`)
      .neq('id', currentUserId)
      .limit(12),
    getFollowingIdSet(currentUserId),
  ]);

  if (profileError) {
    console.error('Failed to search users:', profileError);
    return [];
  }

  return (profileData as ProfileRow[]).map((row) => ({
    id: row.id,
    username: row.username,
    avatarUrl: row.avatar_url ?? buildFallbackAvatar(row.username),
    isFollowing: followingSet.has(row.id),
  }));
}

export async function getFollowingIdSet(currentUserId: string): Promise<Set<string>> {
  const { data, error } = await supabase
    .from('friend_follows')
    .select('following_id')
    .eq('follower_id', currentUserId);

  if (error) {
    console.error('Failed to load following IDs:', error);
    return new Set();
  }

  const ids = (data as FollowRow[])
    .map((row) => row.following_id)
    .filter((id): id is string => Boolean(id));
  return new Set(ids);
}

export async function getFollowingProfilesForUser(targetUserId: string): Promise<FriendProfile[]> {
  const { data, error } = await supabase
    .from('friend_follows')
    .select('following_id, created_at')
    .eq('follower_id', targetUserId)
    .order('created_at', { ascending: false });

  if (error) {
    console.error('Failed to load following:', error);
    return [];
  }

  const rows = data as FollowRow[];
  const followingIds = rows
    .map((row) => row.following_id)
    .filter((id): id is string => Boolean(id));
  const profileMap = await getProfilesByIds(followingIds);

  return rows
    .map((row) => {
      if (!row.following_id) return null;
      const profile = profileMap.get(row.following_id);
      return {
        id: row.following_id,
        username: profile?.username ?? 'unknown',
        avatarUrl: profile?.avatarUrl ?? buildFallbackAvatar(row.following_id),
        followedAt: row.created_at,
      };
    })
    .filter((row): row is FriendProfile => row !== null);
}

export async function getFollowerProfilesForUser(targetUserId: string): Promise<FriendProfile[]> {
  const { data, error } = await supabase
    .from('friend_follows')
    .select('follower_id, created_at')
    .eq('following_id', targetUserId)
    .order('created_at', { ascending: false });

  if (error) {
    console.error('Failed to load followers:', error);
    return [];
  }

  const rows = data as FollowRow[];
  const followerIds = rows
    .map((row) => row.follower_id)
    .filter((id): id is string => Boolean(id));
  const profileMap = await getProfilesByIds(followerIds);

  return rows
    .map((row) => {
      if (!row.follower_id) return null;
      const profile = profileMap.get(row.follower_id);
      return {
        id: row.follower_id,
        username: profile?.username ?? 'unknown',
        avatarUrl: profile?.avatarUrl ?? buildFallbackAvatar(row.follower_id),
        followedAt: row.created_at,
      };
    })
    .filter((row): row is FriendProfile => row !== null);
}

export async function getFollowingProfiles(currentUserId: string): Promise<FriendProfile[]> {
  return getFollowingProfilesForUser(currentUserId);
}

export async function getFollowerProfiles(currentUserId: string): Promise<FriendProfile[]> {
  return getFollowerProfilesForUser(currentUserId);
}

export async function getProfileSummary(
  viewerId: string,
  targetUserId: string,
): Promise<UserProfileSummary | null> {
  const { data: profileData, error: profileError } = await supabase
    .from('profiles')
    .select('id, username, avatar_url')
    .eq('id', targetUserId)
    .maybeSingle();

  if (profileError) {
    console.error('Failed to load profile:', profileError);
    return null;
  }

  if (!profileData) return null;

  const [
    { count: followersCount },
    { count: followingCount },
    { data: viewerFollowingRows },
    { data: viewerFollowedByRows },
  ] = await Promise.all([
    supabase
      .from('friend_follows')
      .select('*', { count: 'exact', head: true })
      .eq('following_id', targetUserId),
    supabase
      .from('friend_follows')
      .select('*', { count: 'exact', head: true })
      .eq('follower_id', targetUserId),
    supabase
      .from('friend_follows')
      .select('id')
      .eq('follower_id', viewerId)
      .eq('following_id', targetUserId)
      .limit(1),
    supabase
      .from('friend_follows')
      .select('id')
      .eq('follower_id', targetUserId)
      .eq('following_id', viewerId)
      .limit(1),
  ]);

  const isFollowing = Boolean(viewerFollowingRows && viewerFollowingRows.length > 0);
  const isFollowedBy = Boolean(viewerFollowedByRows && viewerFollowedByRows.length > 0);

  return {
    id: profileData.id,
    username: profileData.username,
    avatarUrl: profileData.avatar_url ?? buildFallbackAvatar(profileData.username),
    followersCount: followersCount ?? 0,
    followingCount: followingCount ?? 0,
    isSelf: viewerId === targetUserId,
    isFollowing,
    isFollowedBy,
    isMutual: isFollowing && isFollowedBy,
  };
}

export async function updateProfileAvatar(userId: string, avatarUrl: string): Promise<boolean> {
  const cleaned = avatarUrl.trim();
  const { error } = await supabase
    .from('profiles')
    .update({ avatar_url: cleaned || null })
    .eq('id', userId);

  if (error) {
    console.error('Failed to update avatar:', error);
    return false;
  }
  return true;
}

export async function followUser(currentUserId: string, targetUserId: string): Promise<boolean> {
  const { error } = await supabase
    .from('friend_follows')
    .insert({ follower_id: currentUserId, following_id: targetUserId });

  if (error) {
    console.error('Failed to follow user:', error);
    return false;
  }

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

export async function getFriendFeed(currentUserId: string, limit = 24): Promise<FriendFeedItem[]> {
  const followingIds = await getFollowingIdSet(currentUserId);
  const ids = Array.from(followingIds);
  if (ids.length === 0) return [];

  const { data, error } = await supabase
    .from('user_rankings')
    .select('id, user_id, title, tier, updated_at, poster_url')
    .in('user_id', ids)
    .order('updated_at', { ascending: false })
    .limit(limit);

  if (error) {
    console.error('Failed to load friend feed:', error);
    return [];
  }

  const rows = data as RankingRow[];
  const profileMap = await getProfilesByIds(Array.from(new Set(rows.map((row) => row.user_id))));

  return rows.map((row) => ({
    id: row.id,
    userId: row.user_id,
    username: profileMap.get(row.user_id)?.username ?? 'unknown',
    title: row.title,
    tier: row.tier,
    rankedAt: row.updated_at,
    posterUrl: row.poster_url ?? undefined,
  }));
}

export async function getRecentProfileActivity(
  targetUserId: string,
  limit = 10,
): Promise<ProfileActivityItem[]> {
  const { data, error } = await supabase
    .from('user_rankings')
    .select('id, title, tier, notes, updated_at, poster_url')
    .eq('user_id', targetUserId)
    .order('updated_at', { ascending: false })
    .limit(limit);

  if (error) {
    console.error('Failed to load profile activity:', error);
    return [];
  }

  const rows = (data ?? []) as Array<{
    id: string;
    title: string;
    tier: Tier;
    notes?: string | null;
    updated_at: string;
    poster_url?: string | null;
  }>;

  return rows.map((row) => ({
    id: row.id,
    title: row.title,
    tier: row.tier,
    notes: row.notes ?? undefined,
    updatedAt: row.updated_at,
    posterUrl: row.poster_url ?? undefined,
  }));
}
