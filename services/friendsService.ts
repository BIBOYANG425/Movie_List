import { supabase } from '../lib/supabase';
import {
  AppProfile,
  FriendFeedItem,
  FriendProfile,
  ProfileActivityItem,
  Tier,
  UserProfileSummary,
  UserSearchResult,
} from '../types';

export const AVATAR_BUCKET = 'avatars';
export const AVATAR_MAX_FILE_BYTES = 5 * 1024 * 1024;
export const AVATAR_ACCEPTED_MIME_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'];
const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const SUPABASE_ANON_KEY = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

interface ProfileRow {
  id: string;
  username: string;
  display_name?: string | null;
  bio?: string | null;
  avatar_url?: string | null;
  avatar_path?: string | null;
  onboarding_completed?: boolean | null;
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

export interface UpdateMyProfileInput {
  displayName?: string | null;
  bio?: string | null;
  avatarUrl?: string | null;
  avatarPath?: string | null;
  onboardingCompleted?: boolean;
}

function isMissingProfileColumnError(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false;
  const maybeError = error as { code?: string; message?: string };
  const code = maybeError.code ?? '';
  const message = (maybeError.message ?? '').toLowerCase();
  return (
    code === '42703'
    || code === 'PGRST204'
    || message.includes('does not exist')
    || message.includes('schema cache')
  );
}

function sanitizeSearchTerm(raw: string): string {
  return raw.replace(/[%*,()]/g, '').trim();
}

async function searchProfilesViaRest(
  accessToken: string,
  currentUserId: string,
  query: string,
  includeDisplayName: boolean,
): Promise<ProfileRow[] | null> {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return null;

  const safeQuery = sanitizeSearchTerm(query);
  if (!safeQuery) return [];

  const url = new URL(`${SUPABASE_URL}/rest/v1/profiles`);
  url.searchParams.set(
    'select',
    includeDisplayName
      ? 'id,username,display_name,avatar_url,avatar_path'
      : 'id,username,avatar_url',
  );
  if (includeDisplayName) {
    url.searchParams.set('or', `(username.ilike.*${safeQuery}*,display_name.ilike.*${safeQuery}*)`);
  } else {
    url.searchParams.set('username', `ilike.*${safeQuery}*`);
  }
  url.searchParams.set('id', `neq.${currentUserId}`);
  url.searchParams.set('limit', '12');

  const res = await fetch(url.toString(), {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${accessToken}`,
      'Accept-Profile': 'public',
    },
  });

  if (!res.ok) return null;

  const data = await res.json();
  if (!Array.isArray(data)) return null;
  return data as ProfileRow[];
}

async function exactUsernameViaRest(
  accessToken: string,
  currentUserId: string,
  username: string,
): Promise<ProfileRow[] | null> {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return null;
  const safeUsername = sanitizeSearchTerm(username);
  if (!safeUsername) return [];

  const url = new URL(`${SUPABASE_URL}/rest/v1/profiles`);
  url.searchParams.set('select', 'id,username,avatar_url');
  url.searchParams.set('username', `eq.${safeUsername}`);
  url.searchParams.set('id', `neq.${currentUserId}`);
  url.searchParams.set('limit', '1');

  const res = await fetch(url.toString(), {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${accessToken}`,
      'Accept-Profile': 'public',
    },
  });

  if (!res.ok) return null;
  const data = await res.json();
  if (!Array.isArray(data)) return null;
  return data as ProfileRow[];
}

function buildFallbackAvatar(seed: string): string {
  const encoded = encodeURIComponent(seed);
  return `https://api.dicebear.com/8.x/thumbs/svg?seed=${encoded}`;
}

function profileAvatarUrl(row: ProfileRow): string {
  if (row.avatar_url) return row.avatar_url;
  if (row.avatar_path) {
    const { data } = supabase.storage.from(AVATAR_BUCKET).getPublicUrl(row.avatar_path);
    if (data.publicUrl) return data.publicUrl;
  }
  return buildFallbackAvatar(row.username);
}

function optionalText(value: string | null | undefined): string | null {
  if (value === undefined) return null;
  if (value === null) return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function fileExtension(file: File): string {
  if (file.type === 'image/png') return 'png';
  if (file.type === 'image/webp') return 'webp';
  if (file.type === 'image/gif') return 'gif';
  if (file.type === 'image/jpeg') return 'jpg';

  const fromName = file.name.split('.').pop()?.toLowerCase();
  return fromName || 'jpg';
}

function manualMediaKey(title: string): string {
  const slug = title
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80);
  return `manual:${slug || 'movie'}`;
}

function safeUsername(value: string): string {
  const cleaned = value
    .toLowerCase()
    .replace(/[^a-z0-9_]/g, '')
    .slice(0, 24);
  if (cleaned.length >= 3) return cleaned;
  return `${cleaned}user`.slice(0, 3);
}

function mapProfileRow(row: ProfileRow): AppProfile {
  return {
    id: row.id,
    username: row.username,
    displayName: row.display_name ?? undefined,
    bio: row.bio ?? undefined,
    avatarUrl: profileAvatarUrl(row),
    avatarPath: row.avatar_path ?? undefined,
    onboardingCompleted: Boolean(row.onboarding_completed),
  };
}

async function getProfilesByIds(
  ids: string[],
): Promise<Map<string, { username: string; displayName?: string; avatarUrl?: string }>> {
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
        avatarUrl: profileAvatarUrl(row),
      },
    ]),
  );
}

export async function getProfileByUserId(userId: string): Promise<AppProfile | null> {
  let usingLegacySchema = false;

  const initial = await supabase
    .from('profiles')
    .select('id, username, display_name, bio, avatar_url, avatar_path, onboarding_completed')
    .eq('id', userId)
    .maybeSingle();

  let data = initial.data as ProfileRow | null;
  let error = initial.error;

  if (error && isMissingProfileColumnError(error)) {
    usingLegacySchema = true;
    const legacy = await supabase
      .from('profiles')
      .select('id, username, avatar_url')
      .eq('id', userId)
      .maybeSingle();
    data = legacy.data as ProfileRow | null;
    error = legacy.error;
  }

  if (error) {
    console.error('Failed to load own profile:', error);
    return null;
  }

  if (!data) return null;
  if (usingLegacySchema) {
    return {
      id: data.id,
      username: data.username,
      avatarUrl: profileAvatarUrl(data),
      onboardingCompleted: true,
    };
  }
  return mapProfileRow(data as ProfileRow);
}

export async function searchUsers(currentUserId: string, query: string): Promise<UserSearchResult[]> {
  try {
    const trimmed = query.trim();
    if (!trimmed) return [];
    const normalizedUsernameQuery = trimmed.replace(/^@+/, '');
    if (!normalizedUsernameQuery) return [];

    const followingSetPromise = getFollowingIdSet(currentUserId);
    const usernameQuery = await supabase
      .from('profiles')
      .select('id, username, display_name, avatar_url, avatar_path')
      .ilike('username', `%${normalizedUsernameQuery}%`)
      .neq('id', currentUserId)
      .limit(12);

    let profileError: unknown = usernameQuery.error;
    let usernameRows = (usernameQuery.data as ProfileRow[] | null) ?? [];
    let displayRows: ProfileRow[] = [];

    if (profileError && isMissingProfileColumnError(profileError)) {
      const legacyUsernameQuery = await supabase
        .from('profiles')
        .select('id, username, avatar_url')
        .ilike('username', `%${normalizedUsernameQuery}%`)
        .neq('id', currentUserId)
        .limit(12);
      profileError = legacyUsernameQuery.error;
      usernameRows = (legacyUsernameQuery.data as ProfileRow[] | null) ?? [];
    } else if (!profileError) {
      const displayQuery = await supabase
        .from('profiles')
        .select('id, username, display_name, avatar_url, avatar_path')
        .ilike('display_name', `%${trimmed}%`)
        .neq('id', currentUserId)
        .limit(12);

      if (displayQuery.error) {
        if (!isMissingProfileColumnError(displayQuery.error)) {
          profileError = displayQuery.error;
        }
      } else {
        displayRows = (displayQuery.data as ProfileRow[] | null) ?? [];
      }
    }

    const followingSet = await followingSetPromise;

    if (profileError) {
      console.error('Failed to search users:', profileError);
      return [];
    }

    const dedupById = new Map<string, ProfileRow>();
    [...usernameRows, ...displayRows].forEach((row) => dedupById.set(row.id, row));
    let rows = Array.from(dedupById.values());

    if (rows.length === 0) {
      const exactFallback = await supabase
        .from('profiles')
        .select('id, username, avatar_url')
        .eq('username', normalizedUsernameQuery)
        .neq('id', currentUserId)
        .limit(1);

      if (!exactFallback.error) {
        rows = (exactFallback.data as ProfileRow[] | null) ?? [];
      }
    }

    return rows.map((row) => ({
      id: row.id,
      username: row.username,
      displayName: row.display_name ?? undefined,
      avatarUrl: profileAvatarUrl(row),
      isFollowing: followingSet.has(row.id),
    }));
  } catch (error) {
    console.error('Unexpected searchUsers error:', error);
    return [];
  }
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
        displayName: profile?.displayName,
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
        displayName: profile?.displayName,
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
  let usingLegacySchema = false;

  const initial = await supabase
    .from('profiles')
    .select('id, username, display_name, bio, avatar_url, avatar_path, onboarding_completed')
    .eq('id', targetUserId)
    .maybeSingle();

  let profileData = initial.data as ProfileRow | null;
  let profileError = initial.error;

  if (profileError && isMissingProfileColumnError(profileError)) {
    usingLegacySchema = true;
    const legacy = await supabase
      .from('profiles')
      .select('id, username, avatar_url')
      .eq('id', targetUserId)
      .maybeSingle();
    profileData = legacy.data as ProfileRow | null;
    profileError = legacy.error;
  }

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

  const row = profileData as ProfileRow;
  const isFollowing = Boolean(viewerFollowingRows && viewerFollowingRows.length > 0);
  const isFollowedBy = Boolean(viewerFollowedByRows && viewerFollowedByRows.length > 0);

  return {
    id: row.id,
    username: row.username,
    displayName: usingLegacySchema ? undefined : (row.display_name ?? undefined),
    bio: usingLegacySchema ? undefined : (row.bio ?? undefined),
    avatarUrl: profileAvatarUrl(row),
    onboardingCompleted: usingLegacySchema ? true : Boolean(row.onboarding_completed),
    followersCount: followersCount ?? 0,
    followingCount: followingCount ?? 0,
    isSelf: viewerId === targetUserId,
    isFollowing,
    isFollowedBy,
    isMutual: isFollowing && isFollowedBy,
  };
}

export async function uploadAvatarPhoto(
  userId: string,
  file: File,
): Promise<{ avatarPath: string; avatarUrl: string } | null> {
  if (!AVATAR_ACCEPTED_MIME_TYPES.includes(file.type)) {
    console.error('Unsupported avatar file type:', file.type);
    return null;
  }

  if (file.size > AVATAR_MAX_FILE_BYTES) {
    console.error('Avatar file too large:', file.size);
    return null;
  }

  const extension = fileExtension(file);
  const avatarPath = `${userId}/avatar.${extension}`;

  const { error } = await supabase.storage.from(AVATAR_BUCKET).upload(avatarPath, file, {
    upsert: true,
    contentType: file.type,
    cacheControl: '3600',
  });

  if (error) {
    console.error('Failed to upload avatar:', error);
    return null;
  }

  const { data } = supabase.storage.from(AVATAR_BUCKET).getPublicUrl(avatarPath);
  return {
    avatarPath,
    avatarUrl: data.publicUrl,
  };
}

export async function updateMyProfile(userId: string, updates: UpdateMyProfileInput): Promise<boolean> {
  const payload: Record<string, unknown> = {
    updated_at: new Date().toISOString(),
  };

  if ('displayName' in updates) payload.display_name = optionalText(updates.displayName);
  if ('bio' in updates) payload.bio = optionalText(updates.bio);
  if ('avatarUrl' in updates) payload.avatar_url = optionalText(updates.avatarUrl);
  if ('avatarPath' in updates) payload.avatar_path = optionalText(updates.avatarPath);
  if ('onboardingCompleted' in updates) payload.onboarding_completed = updates.onboardingCompleted;

  const { data, error } = await supabase
    .from('profiles')
    .update(payload)
    .eq('id', userId)
    .select('id')
    .maybeSingle();

  if (error && isMissingProfileColumnError(error)) {
    const legacyPayload: Record<string, unknown> = {};
    if ('avatarUrl' in updates) legacyPayload.avatar_url = optionalText(updates.avatarUrl);

    if (Object.keys(legacyPayload).length > 0) {
      const legacyUpdate = await supabase
        .from('profiles')
        .update(legacyPayload)
        .eq('id', userId)
        .select('id')
        .maybeSingle();

      if (legacyUpdate.error) {
        console.error('Failed to update legacy profile:', legacyUpdate.error);
        return false;
      }
      return true;
    }

    return true;
  }

  if (error) {
    console.error('Failed to update profile:', error);
    return false;
  }

  if (!data) {
    const { data: authUser } = await supabase.auth.getUser();
    const emailBase = authUser.user?.email?.split('@')[0] ?? 'user';
    const metaUsername = typeof authUser.user?.user_metadata?.username === 'string'
      ? authUser.user.user_metadata.username
      : '';
    const username = `${safeUsername(metaUsername || emailBase)}_${userId.slice(0, 6)}`;

    const fullUpsert = await supabase.from('profiles').upsert({
      id: userId,
      username: username.slice(0, 32),
      display_name: payload.display_name ?? null,
      bio: payload.bio ?? null,
      avatar_url: payload.avatar_url ?? null,
      avatar_path: payload.avatar_path ?? null,
      onboarding_completed: payload.onboarding_completed ?? false,
    }, { onConflict: 'id' });

    if (fullUpsert.error && isMissingProfileColumnError(fullUpsert.error)) {
      const legacyUpsert = await supabase.from('profiles').upsert({
        id: userId,
        username: username.slice(0, 32),
        avatar_url: payload.avatar_url ?? null,
      }, { onConflict: 'id' });

      if (legacyUpsert.error) {
        console.error('Failed to backfill missing profile row:', legacyUpsert.error);
        return false;
      }
      return true;
    }

    if (fullUpsert.error) {
      console.error('Failed to backfill missing profile row:', fullUpsert.error);
      return false;
    }
  }

  return true;
}

export async function updateProfileAvatar(userId: string, avatarUrl: string): Promise<boolean> {
  return updateMyProfile(userId, { avatarUrl });
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

export async function saveActivityMovieToWatchlist(
  userId: string,
  activity: Pick<ProfileActivityItem, 'title' | 'posterUrl'>,
): Promise<boolean> {
  const { error } = await supabase.from('watchlist_items').upsert({
    user_id: userId,
    tmdb_id: manualMediaKey(activity.title),
    title: activity.title,
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
  activity: Pick<ProfileActivityItem, 'title' | 'tier' | 'notes' | 'posterUrl'>,
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
    tmdb_id: manualMediaKey(activity.title),
    title: activity.title,
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

  return true;
}
