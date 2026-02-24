import { supabase } from '../lib/supabase';
import {
  ActivityComment,
  AppNotification,
  AppProfile,
  FriendFeedItem,
  FriendProfile,
  FriendRecommendation,
  GenreProfileItem,
  GroupRanking,
  GroupRankingEntry,
  MovieList,
  MovieListItem,
  MoviePoll,
  MoviePollOption,
  MovieReview,
  ProfileActivityItem,
  RankingComparison,
  RankingComparisonItem,
  RsvpStatus,
  SharedMovieComparison,
  SharedWatchlist,
  SharedWatchlistItem,
  SharedWatchlistMember,
  TasteCompatibility,
  Tier,
  TrendingMovie,
  MoodTag,
  MovieSocialStats,
  UserAchievement,
  UserProfileSummary,
  UserSearchResult,
  WatchParty,
  WatchPartyMember,
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

interface ActivityEventRow {
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

interface ActivityReactionRow {
  event_id: string;
  user_id: string;
  reaction: string;
}

interface ActivityCommentRow {
  id: string;
  event_id: string;
  user_id: string;
  body: string;
  created_at: string;
}

export interface UpdateMyProfileInput {
  displayName?: string | null;
  bio?: string | null;
  avatarUrl?: string | null;
  avatarPath?: string | null;
  onboardingCompleted?: boolean;
}

export type RankingActivityEventType = 'ranking_add' | 'ranking_move' | 'ranking_remove';

export interface RankingActivityPayload {
  id: string;
  title: string;
  tier: Tier;
  posterUrl?: string;
  notes?: string;
  year?: string;
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

function manualMediaKey(title: string, year?: string | number | null): string {
  const slug = title
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80);
  const yearToken = String(year ?? '').trim();
  if (/^\d{4}$/.test(yearToken)) {
    return `manual:${slug || 'movie'}:${yearToken}`;
  }
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
    .select('id, username, display_name, avatar_url, avatar_path')
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
        displayName: row.display_name ?? undefined,
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
    .map((row): FriendProfile | null => {
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
    .map((row): FriendProfile | null => {
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

function toTier(value: string | null | undefined): Tier | null {
  if (value === Tier.S || value === Tier.A || value === Tier.B || value === Tier.C || value === Tier.D) {
    return value;
  }
  return null;
}

function toRankingEventType(value: string): 'ranking_add' | 'ranking_move' | 'ranking_remove' | null {
  if (value === 'ranking_add' || value === 'ranking_move' || value === 'ranking_remove') {
    return value;
  }
  return null;
}

export async function logRankingActivityEvent(
  userId: string,
  item: RankingActivityPayload,
  eventType: RankingActivityEventType,
): Promise<boolean> {
  const metadata: Record<string, unknown> = {};
  if (item.notes) metadata.notes = item.notes;
  if (item.year) metadata.year = item.year;

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

// ═══════════════════════════════════════════════════════════════════════════════
// Phase 1: Movie Reviews
// ═══════════════════════════════════════════════════════════════════════════════

interface ReviewRow {
  id: string;
  user_id: string;
  tmdb_id: string;
  title: string;
  poster_url: string | null;
  body: string;
  rating_tier: string | null;
  contains_spoilers: boolean;
  like_count: number;
  created_at: string;
  updated_at: string;
}

interface ReviewLikeRow {
  review_id: string;
  user_id: string;
}

export async function createOrUpdateReview(
  userId: string,
  tmdbId: string,
  title: string,
  body: string,
  containsSpoilers: boolean = false,
  posterUrl?: string,
): Promise<MovieReview | null> {
  // Get user's tier for this movie
  const { data: rankingRow } = await supabase
    .from('user_rankings')
    .select('tier')
    .eq('user_id', userId)
    .eq('tmdb_id', tmdbId)
    .maybeSingle();

  const ratingTier = rankingRow?.tier ?? null;

  const { data, error } = await supabase
    .from('movie_reviews')
    .upsert({
      user_id: userId,
      tmdb_id: tmdbId,
      title,
      body,
      rating_tier: ratingTier,
      contains_spoilers: containsSpoilers,
      poster_url: posterUrl ?? null,
      updated_at: new Date().toISOString(),
    }, { onConflict: 'user_id,tmdb_id' })
    .select()
    .single();

  if (error) {
    console.error('Failed to create/update review:', error);
    return null;
  }

  const profileMap = await getProfilesByIds([userId]);
  const profile = profileMap.get(userId);
  const row = data as ReviewRow;

  return {
    id: row.id,
    userId: row.user_id,
    username: profile?.username ?? 'unknown',
    displayName: profile?.displayName,
    avatarUrl: profile?.avatarUrl,
    mediaItemId: row.tmdb_id,
    mediaTitle: row.title,
    body: row.body,
    ratingTier: toTier(row.rating_tier) ?? undefined,
    containsSpoilers: row.contains_spoilers,
    likeCount: row.like_count,
    isLikedByViewer: false,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export async function getReviewsForMovie(
  tmdbId: string,
  currentUserId: string,
  limit = 20,
): Promise<MovieReview[]> {
  const { data, error } = await supabase
    .from('movie_reviews')
    .select('*')
    .eq('tmdb_id', tmdbId)
    .order('created_at', { ascending: false })
    .limit(limit);

  if (error) {
    console.error('Failed to load reviews:', error);
    return [];
  }

  const rows = (data ?? []) as ReviewRow[];
  const userIds = [...new Set(rows.map(r => r.user_id))];
  const profileMap = await getProfilesByIds(userIds);

  // Get likes by current user
  const reviewIds = rows.map(r => r.id);
  const likedSet = new Set<string>();
  if (reviewIds.length > 0) {
    const { data: likes } = await supabase
      .from('review_likes')
      .select('review_id')
      .eq('user_id', currentUserId)
      .in('review_id', reviewIds);
    (likes ?? []).forEach((l: ReviewLikeRow) => likedSet.add(l.review_id));
  }

  // Sort: friends first
  const followingSet = await getFollowingIdSet(currentUserId);

  const reviews = rows.map((row) => {
    const profile = profileMap.get(row.user_id);
    return {
      id: row.id,
      userId: row.user_id,
      username: profile?.username ?? 'unknown',
      displayName: profile?.displayName,
      avatarUrl: profile?.avatarUrl,
      mediaItemId: row.tmdb_id,
      mediaTitle: row.title,
      body: row.body,
      ratingTier: toTier(row.rating_tier) ?? undefined,
      containsSpoilers: row.contains_spoilers,
      likeCount: row.like_count,
      isLikedByViewer: likedSet.has(row.id),
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  });

  // Sort friends first, then self, then others
  reviews.sort((a, b) => {
    const aFriend = followingSet.has(a.userId) ? 0 : a.userId === currentUserId ? 1 : 2;
    const bFriend = followingSet.has(b.userId) ? 0 : b.userId === currentUserId ? 1 : 2;
    return aFriend - bFriend;
  });

  return reviews;
}

export async function getReviewsByUser(
  targetUserId: string,
  currentUserId: string,
  limit = 20,
): Promise<MovieReview[]> {
  const { data, error } = await supabase
    .from('movie_reviews')
    .select('*')
    .eq('user_id', targetUserId)
    .order('created_at', { ascending: false })
    .limit(limit);

  if (error) {
    console.error('Failed to load user reviews:', error);
    return [];
  }

  const rows = (data ?? []) as ReviewRow[];
  const profileMap = await getProfilesByIds([targetUserId]);
  const profile = profileMap.get(targetUserId);

  const reviewIds = rows.map(r => r.id);
  const likedSet = new Set<string>();
  if (reviewIds.length > 0) {
    const { data: likes } = await supabase
      .from('review_likes')
      .select('review_id')
      .eq('user_id', currentUserId)
      .in('review_id', reviewIds);
    (likes ?? []).forEach((l: ReviewLikeRow) => likedSet.add(l.review_id));
  }

  return rows.map((row) => ({
    id: row.id,
    userId: row.user_id,
    username: profile?.username ?? 'unknown',
    displayName: profile?.displayName,
    avatarUrl: profile?.avatarUrl,
    mediaItemId: row.tmdb_id,
    mediaTitle: row.title,
    body: row.body,
    ratingTier: toTier(row.rating_tier) ?? undefined,
    containsSpoilers: row.contains_spoilers,
    likeCount: row.like_count,
    isLikedByViewer: likedSet.has(row.id),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  }));
}

export async function deleteReview(reviewId: string, userId: string): Promise<boolean> {
  const { error } = await supabase
    .from('movie_reviews')
    .delete()
    .eq('id', reviewId)
    .eq('user_id', userId);
  if (error) {
    console.error('Failed to delete review:', error);
    return false;
  }
  return true;
}

export async function toggleReviewLike(
  reviewId: string,
  userId: string,
  shouldLike: boolean,
): Promise<boolean> {
  if (shouldLike) {
    const { error } = await supabase.from('review_likes').insert({
      review_id: reviewId,
      user_id: userId,
    });
    if (error) {
      console.error('Failed to like review:', error);
      return false;
    }
    // Increment like count
    await supabase.rpc('increment_review_likes', { review_id_param: reviewId });
  } else {
    const { error } = await supabase
      .from('review_likes')
      .delete()
      .eq('review_id', reviewId)
      .eq('user_id', userId);
    if (error) {
      console.error('Failed to unlike review:', error);
      return false;
    }
    await supabase.rpc('decrement_review_likes', { review_id_param: reviewId });
  }
  return true;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Phase 1: Taste Compatibility (computed client-side from shared rankings)
// ═══════════════════════════════════════════════════════════════════════════════

const TIER_NUMERIC: Record<string, number> = { S: 5, A: 4, B: 3, C: 2, D: 1 };
const NUMERIC_TIER: Record<number, string> = { 5: 'S', 4: 'A', 3: 'B', 2: 'C', 1: 'D' };

function tierLabel(numeric: number): string {
  const rounded = Math.round(numeric);
  return NUMERIC_TIER[Math.max(1, Math.min(5, rounded))] || 'C';
}

interface UserRankingRowPhase1 {
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

// ═══════════════════════════════════════════════════════════════════════════════
// Phase 1: Shared Watchlists
// ═══════════════════════════════════════════════════════════════════════════════

interface SharedWatchlistRow {
  id: string;
  name: string;
  created_by: string;
  created_at: string;
}

interface SharedWLMemberRow {
  watchlist_id: string;
  user_id: string;
  joined_at: string;
}

interface SharedWLItemRow {
  id: string;
  watchlist_id: string;
  tmdb_id: string;
  title: string;
  poster_url: string | null;
  added_by: string;
  vote_count: number;
  added_at: string;
}

interface SharedWLVoteRow {
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

// ── Phase 2: Discovery & Recommendations ────────────────────────────────────
// (Reuses TIER_NUMERIC, NUMERIC_TIER, tierLabel from Phase 1 section above)


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
  const { data: profiles } = await supabase
    .from('profiles')
    .select('id, username')
    .in('id', allRankerIds);
  const usernameMap = new Map(
    (profiles ?? []).map((p: { id: string; username: string }) => [p.id, p.username]),
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
): Promise<GenreProfileItem[]> {
  const { data: rankings } = await supabase
    .from('user_rankings')
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

// ── Phase 3: Watch Parties ──────────────────────────────────────────────────

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

// ── Phase 3: Group Rankings ─────────────────────────────────────────────────

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

// ── Phase 3: Movie Polls ────────────────────────────────────────────────────

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

// ── Phase 4: Notifications ──────────────────────────────────────────────────

export async function getNotifications(userId: string, limit = 30): Promise<AppNotification[]> {
  const { data } = await supabase
    .from('notifications')
    .select('*')
    .eq('user_id', userId)
    .order('created_at', { ascending: false })
    .limit(limit);
  if (!data) return [];

  // Get actor profiles
  const actorIds = [...new Set(data.filter((n: any) => n.actor_id).map((n: any) => n.actor_id))];
  let profileMap = new Map<string, any>();
  if (actorIds.length > 0) {
    const { data: profiles } = await supabase.from('profiles').select('id, username, avatar_path').in('id', actorIds);
    profileMap = new Map((profiles ?? []).map((p: any) => [p.id, p]));
  }

  return data.map((n: any) => {
    const actor = n.actor_id ? profileMap.get(n.actor_id) : null;
    return {
      id: n.id,
      userId: n.user_id,
      type: n.type,
      title: n.title,
      body: n.body,
      actorId: n.actor_id,
      actorUsername: actor?.username,
      actorAvatar: actor?.avatar_path ? `${SUPABASE_URL}/storage/v1/object/public/avatars/${actor.avatar_path}` : undefined,
      referenceId: n.reference_id,
      isRead: n.is_read,
      createdAt: n.created_at,
    };
  });
}

export async function markNotificationsRead(ids: string[]): Promise<boolean> {
  const { error } = await supabase
    .from('notifications')
    .update({ is_read: true })
    .in('id', ids);
  return !error;
}

export async function getUnreadCount(userId: string): Promise<number> {
  const { count } = await supabase
    .from('notifications')
    .select('id', { count: 'exact', head: true })
    .eq('user_id', userId)
    .eq('is_read', false);
  return count ?? 0;
}

// ── Phase 4: Movie Lists ────────────────────────────────────────────────────

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

// ── Phase 4: Achievements ───────────────────────────────────────────────────

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
  }

  return newBadges;
}

// ── Phase 9: Full Movie Card (Detail View) ───────────────────────────────────

export async function getMovieSocialStats(currentUserId: string, tmdbId: string): Promise<MovieSocialStats | null> {
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return null;

  try {
    // 1. Get user's following list
    const { data: follows, error: followsError } = await supabase
      .from('follows')
      .select('following_id')
      .eq('follower_id', currentUserId);

    if (followsError || !follows) return null;

    const friendIds = follows.map(f => f.following_id);
    if (friendIds.length === 0) {
      return {
        movieId: tmdbId,
        timesRanked: 0,
        friendsWatched: 0,
        friendAvatars: [],
        moodConsensus: [],
      };
    }

    // 2. Get friends' rankings for this movie
    const { data: friendRankings, error: rankingsError } = await supabase
      .from('user_rankings')
      .select('user_id, rank_position, tier, profiles:user_id(username, avatar_url)')
      .eq('tmdb_id', tmdbId)
      .in('user_id', friendIds);

    if (rankingsError) return null;

    const friendsWatched = friendRankings?.length || 0;
    const friendAvatars = (friendRankings || [])
      .map(r => (r.profiles as any)?.avatar_url)
      .filter(Boolean)
      .slice(0, 5);

    let avgFriendRankPosition: number | undefined = undefined;
    if (friendsWatched > 0) {
      const sum = friendRankings!.reduce((acc, r) => acc + r.rank_position, 0);
      avgFriendRankPosition = Math.round(sum / friendsWatched);
    }

    // 3. Get friends' reviews for this movie
    const { data: friendReviews, error: reviewsError } = await supabase
      .from('movie_reviews')
      .select('user_id, body, profiles:user_id(username, avatar_url)')
      .eq('media_item_id', tmdbId)
      .in('user_id', friendIds)
      .order('like_count', { ascending: false })
      .limit(1);

    let topFriendReview;
    if (friendReviews && friendReviews.length > 0) {
      const rev = friendReviews[0];
      const rankData = friendRankings?.find(r => r.user_id === rev.user_id);
      topFriendReview = {
        userId: rev.user_id,
        username: (rev.profiles as any).username,
        avatarUrl: (rev.profiles as any).avatar_url,
        body: rev.body,
        rankPosition: rankData?.rank_position ?? 0,
        tier: rankData?.tier ?? Tier.C,
      };
    }

    // 4. (stub) Global metrics and mood consensus
    // In a real app, mood consensus would parse the review body for emojis or 
    // fetch from a `movie_moods` table.
    const moodConsensus: MoodTag[] = [];

    // Global average rank and times ranked would ideally be aggregated offline 
    // or via a database view/RPC. For now, we'll fetch a small count to simulate it.
    const { count: timesRanked } = await supabase
      .from('user_rankings')
      .select('*', { count: 'exact', head: true })
      .eq('tmdb_id', tmdbId);

    // Divisive matchup would also be a complex query. Stubbed for MVP.
    const divisiveMatchup = undefined;

    return {
      movieId: tmdbId,
      timesRanked: timesRanked || 0,
      friendsWatched,
      friendAvatars,
      avgFriendRankPosition,
      topFriendReview,
      moodConsensus,
      divisiveMatchup,
      globalAvgRankPosition: undefined, // Stubbed for now
    };
  } catch (err) {
    console.error('Failed to fetch movie social stats:', err);
    return null;
  }
}
