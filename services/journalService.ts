import { supabase } from '../lib/supabase';
import { JournalEntry, JournalEntryCard, JournalFilters, JournalStats, Tier } from '../types';
import { JOURNAL_PHOTO_BUCKET } from '../constants';
import { logReviewActivityEvent } from './feedService';

// ── Helpers ─────────────────────────────────────────────────────────────────

function toTier(val: string | null | undefined): Tier | undefined {
  if (val && Object.values(Tier).includes(val as Tier)) return val as Tier;
  return undefined;
}

interface JournalRow {
  id: string;
  user_id: string;
  tmdb_id: string;
  title: string;
  poster_url: string | null;
  rating_tier: string | null;
  review_text: string | null;
  contains_spoilers: boolean;
  mood_tags: string[];
  vibe_tags: string[];
  favorite_moments: string[];
  standout_performances: unknown;
  watched_date: string | null;
  watched_location: string | null;
  watched_with_user_ids: string[];
  watched_platform: string | null;
  is_rewatch: boolean;
  rewatch_note: string | null;
  personal_takeaway: string | null;
  photo_paths: string[];
  visibility_override: string | null;
  like_count: number;
  created_at: string;
  updated_at: string;
}

function mapRow(row: JournalRow): JournalEntry {
  return {
    id: row.id,
    userId: row.user_id,
    tmdbId: row.tmdb_id,
    title: row.title,
    posterUrl: row.poster_url ?? undefined,
    ratingTier: toTier(row.rating_tier),
    reviewText: row.review_text ?? undefined,
    containsSpoilers: row.contains_spoilers,
    moodTags: row.mood_tags ?? [],
    vibeTags: row.vibe_tags ?? [],
    favoriteMoments: row.favorite_moments ?? [],
    standoutPerformances: Array.isArray(row.standout_performances) ? row.standout_performances as JournalEntry['standoutPerformances'] : [],
    watchedDate: row.watched_date ?? undefined,
    watchedLocation: row.watched_location ?? undefined,
    watchedWithUserIds: row.watched_with_user_ids ?? [],
    watchedPlatform: row.watched_platform ?? undefined,
    isRewatch: row.is_rewatch,
    rewatchNote: row.rewatch_note ?? undefined,
    personalTakeaway: row.personal_takeaway ?? undefined,
    photoPaths: row.photo_paths ?? [],
    visibilityOverride: row.visibility_override as JournalEntry['visibilityOverride'],
    likeCount: row.like_count,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

// ── CRUD ────────────────────────────────────────────────────────────────────

export interface UpsertJournalData {
  title: string;
  posterUrl?: string;
  reviewText?: string;
  containsSpoilers?: boolean;
  moodTags?: string[];
  vibeTags?: string[];
  favoriteMoments?: string[];
  standoutPerformances?: JournalEntry['standoutPerformances'];
  watchedDate?: string;
  watchedLocation?: string;
  watchedWithUserIds?: string[];
  watchedPlatform?: string;
  isRewatch?: boolean;
  rewatchNote?: string;
  personalTakeaway?: string;
  photoPaths?: string[];
  visibilityOverride?: JournalEntry['visibilityOverride'];
}

export async function upsertJournalEntry(
  userId: string,
  tmdbId: string,
  data: UpsertJournalData,
): Promise<JournalEntry | null> {
  // Look up tier from user_rankings
  const { data: rankingRow } = await supabase
    .from('user_rankings')
    .select('tier')
    .eq('user_id', userId)
    .eq('tmdb_id', tmdbId)
    .maybeSingle();

  const ratingTier = rankingRow?.tier ?? null;

  const { data: row, error } = await supabase
    .from('journal_entries')
    .upsert({
      user_id: userId,
      tmdb_id: tmdbId,
      title: data.title,
      poster_url: data.posterUrl ?? null,
      rating_tier: ratingTier,
      review_text: data.reviewText ?? null,
      contains_spoilers: data.containsSpoilers ?? false,
      mood_tags: data.moodTags ?? [],
      vibe_tags: data.vibeTags ?? [],
      favorite_moments: data.favoriteMoments ?? [],
      standout_performances: data.standoutPerformances ?? [],
      watched_date: data.watchedDate ?? new Date().toISOString().split('T')[0],
      watched_location: data.watchedLocation ?? null,
      watched_with_user_ids: data.watchedWithUserIds ?? [],
      watched_platform: data.watchedPlatform ?? null,
      is_rewatch: data.isRewatch ?? false,
      rewatch_note: data.rewatchNote ?? null,
      personal_takeaway: data.personalTakeaway ?? null,
      photo_paths: data.photoPaths ?? [],
      visibility_override: data.visibilityOverride ?? null,
    }, { onConflict: 'user_id,tmdb_id' })
    .select()
    .single();

  if (error) {
    console.error('Failed to upsert journal entry:', error);
    return null;
  }

  const entry = mapRow(row as JournalRow);

  // Log review activity event if review text is present and visibility allows
  if (data.reviewText && data.visibilityOverride !== 'private') {
    try {
      await logReviewActivityEvent(userId, {
        tmdbId,
        title: data.title,
        posterUrl: data.posterUrl,
        tier: toTier(ratingTier),
        body: data.reviewText,
        containsSpoilers: data.containsSpoilers ?? false,
      });
    } catch (err) {
      console.error('Failed to log journal review activity:', err);
    }
  }

  // Send journal_tag notifications to tagged friends
  if (data.watchedWithUserIds && data.watchedWithUserIds.length > 0) {
    try {
      const notifications = data.watchedWithUserIds.map((friendId) => ({
        user_id: friendId,
        type: 'journal_tag',
        title: `watched ${data.title} with you`,
        body: data.reviewText ? data.reviewText.slice(0, 100) : undefined,
        actor_id: userId,
        reference_id: entry.id,
      }));
      await supabase.from('notifications').insert(notifications);
    } catch (err) {
      console.error('Failed to send journal tag notifications:', err);
    }
  }

  return entry;
}

export async function getJournalEntry(
  userId: string,
  tmdbId: string,
): Promise<JournalEntry | null> {
  const { data, error } = await supabase
    .from('journal_entries')
    .select('*')
    .eq('user_id', userId)
    .eq('tmdb_id', tmdbId)
    .maybeSingle();

  if (error || !data) return null;
  return mapRow(data as JournalRow);
}

export async function getJournalEntryById(
  entryId: string,
): Promise<JournalEntry | null> {
  const { data, error } = await supabase
    .from('journal_entries')
    .select('*')
    .eq('id', entryId)
    .maybeSingle();

  if (error || !data) return null;
  return mapRow(data as JournalRow);
}

export async function deleteJournalEntry(
  userId: string,
  entryId: string,
): Promise<boolean> {
  // First get the entry to clean up photos
  const { data: entry } = await supabase
    .from('journal_entries')
    .select('photo_paths')
    .eq('id', entryId)
    .eq('user_id', userId)
    .maybeSingle();

  if (entry?.photo_paths?.length) {
    await supabase.storage.from(JOURNAL_PHOTO_BUCKET).remove(entry.photo_paths);
  }

  const { error } = await supabase
    .from('journal_entries')
    .delete()
    .eq('id', entryId)
    .eq('user_id', userId);

  if (error) {
    console.error('Failed to delete journal entry:', error);
    return false;
  }
  return true;
}

// ── List & Search ───────────────────────────────────────────────────────────

export async function listJournalEntries(
  userId: string,
  filters: JournalFilters = {},
  offset = 0,
  limit = 20,
): Promise<JournalEntryCard[]> {
  let query = supabase
    .from('journal_entries')
    .select('*, profiles!journal_entries_user_id_fkey(username, display_name, avatar_url, avatar_path)')
    .eq('user_id', userId)
    .order('created_at', { ascending: false })
    .range(offset, offset + limit - 1);

  if (filters.mood) {
    query = query.contains('mood_tags', [filters.mood]);
  }
  if (filters.vibe) {
    query = query.contains('vibe_tags', [filters.vibe]);
  }
  if (filters.tier) {
    query = query.eq('rating_tier', filters.tier);
  }
  if (filters.platform) {
    query = query.eq('watched_platform', filters.platform);
  }
  if (filters.dateFrom) {
    query = query.gte('watched_date', filters.dateFrom);
  }
  if (filters.dateTo) {
    query = query.lte('watched_date', filters.dateTo);
  }

  const { data, error } = await query;

  if (error) {
    console.error('Failed to list journal entries:', error);
    return [];
  }

  return (data ?? []).map((row: Record<string, unknown>) => {
    const profile = row.profiles as { username: string; display_name?: string; avatar_url?: string; avatar_path?: string } | null;
    const entry = mapRow(row as unknown as JournalRow);
    return {
      ...entry,
      username: profile?.username ?? 'unknown',
      displayName: profile?.display_name ?? undefined,
      avatarUrl: profile?.avatar_url ?? undefined,
    };
  });
}

export async function searchJournalEntries(
  userId: string,
  query: string,
): Promise<JournalEntry[]> {
  const { data, error } = await supabase
    .rpc('search_journal_entries', {
      search_query: query,
      target_user_id: userId,
    });

  if (error) {
    console.error('Failed to search journal entries:', error);
    return [];
  }

  return (data ?? []).map((row: JournalRow) => mapRow(row));
}

// ── Stats ───────────────────────────────────────────────────────────────────

export async function getJournalStats(userId: string): Promise<JournalStats> {
  const { data, error } = await supabase
    .from('journal_entries')
    .select('mood_tags, review_text, watched_date, watched_with_user_ids')
    .eq('user_id', userId)
    .order('watched_date', { ascending: true });

  if (error || !data) {
    return { totalEntries: 0, entriesWithReview: 0, currentStreak: 0, longestStreak: 0 };
  }

  const totalEntries = data.length;
  const entriesWithReview = data.filter((r) => r.review_text).length;

  // Most common mood
  const moodCounts: Record<string, number> = {};
  for (const row of data) {
    for (const tag of (row.mood_tags ?? [])) {
      moodCounts[tag] = (moodCounts[tag] || 0) + 1;
    }
  }
  const mostCommonMood = Object.entries(moodCounts).sort((a, b) => b[1] - a[1])[0]?.[0];

  // Most tagged friend
  const friendCounts: Record<string, number> = {};
  for (const row of data) {
    for (const id of (row.watched_with_user_ids ?? [])) {
      friendCounts[id] = (friendCounts[id] || 0) + 1;
    }
  }
  const mostTaggedFriendId = Object.entries(friendCounts).sort((a, b) => b[1] - a[1])[0]?.[0];

  // Streak calculation (consecutive days with an entry)
  const uniqueDates = [...new Set(data.map((r) => r.watched_date).filter(Boolean))].sort();
  let currentStreak = 0;
  let longestStreak = 0;
  let streak = 0;

  for (let i = 0; i < uniqueDates.length; i++) {
    if (i === 0) {
      streak = 1;
    } else {
      const prev = new Date(uniqueDates[i - 1]);
      const curr = new Date(uniqueDates[i]);
      const diffDays = (curr.getTime() - prev.getTime()) / (1000 * 60 * 60 * 24);
      streak = diffDays === 1 ? streak + 1 : 1;
    }
    longestStreak = Math.max(longestStreak, streak);
  }

  // Check if current streak is active (last entry was today or yesterday)
  if (uniqueDates.length > 0) {
    const lastDate = new Date(uniqueDates[uniqueDates.length - 1]);
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    lastDate.setHours(0, 0, 0, 0);
    const daysSinceLast = (today.getTime() - lastDate.getTime()) / (1000 * 60 * 60 * 24);
    currentStreak = daysSinceLast <= 1 ? streak : 0;
  }

  return {
    totalEntries,
    entriesWithReview,
    mostCommonMood,
    mostTaggedFriendId,
    currentStreak,
    longestStreak,
  };
}

// ── Photos ──────────────────────────────────────────────────────────────────

export async function uploadJournalPhoto(
  userId: string,
  entryId: string,
  file: File,
  index: number,
): Promise<string | null> {
  const ext = file.name.split('.').pop() ?? 'jpg';
  const path = `${userId}/${entryId}/${index}.${ext}`;

  const { error } = await supabase.storage.from(JOURNAL_PHOTO_BUCKET).upload(path, file, {
    upsert: true,
    contentType: file.type,
    cacheControl: '3600',
  });

  if (error) {
    console.error('Failed to upload journal photo:', error);
    return null;
  }

  return path;
}

export async function deleteJournalPhoto(
  userId: string,
  _entryId: string,
  path: string,
): Promise<boolean> {
  // Verify path belongs to the user
  if (!path.startsWith(`${userId}/`)) return false;

  const { error } = await supabase.storage.from(JOURNAL_PHOTO_BUCKET).remove([path]);
  if (error) {
    console.error('Failed to delete journal photo:', error);
    return false;
  }
  return true;
}

// ── Likes ───────────────────────────────────────────────────────────────────

export async function toggleJournalLike(
  userId: string,
  entryId: string,
  shouldLike: boolean,
): Promise<boolean> {
  if (shouldLike) {
    const { error } = await supabase
      .from('journal_likes')
      .upsert({ entry_id: entryId, user_id: userId }, { onConflict: 'entry_id,user_id' });
    if (error) {
      console.error('Failed to like journal entry:', error);
      return false;
    }
    await supabase.rpc('increment_journal_likes', { entry_id_param: entryId });
  } else {
    const { error } = await supabase
      .from('journal_likes')
      .delete()
      .eq('entry_id', entryId)
      .eq('user_id', userId);
    if (error) {
      console.error('Failed to unlike journal entry:', error);
      return false;
    }
    await supabase.rpc('decrement_journal_likes', { entry_id_param: entryId });
  }
  return true;
}
