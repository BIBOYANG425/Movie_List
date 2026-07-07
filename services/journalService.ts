import { supabase } from '../lib/supabase';
import { JournalEntry, JournalEntryCard, JournalFilters, JournalStats, Tier } from '../types';
import { JOURNAL_PHOTO_BUCKET } from '../constants';
import { logReviewActivityEvent } from './feedService';

// ── Helpers ─────────────────────────────────────────────────────────────────

function toTier(val: string | null | undefined): Tier | undefined {
  if (val && Object.values(Tier).includes(val as Tier)) return val as Tier;
  return undefined;
}

// ── Visibility resolution (audit B2/B6) ──────────────────────────────────────

export type ResolvedJournalVisibility = 'public' | 'friends' | 'private';

/**
 * Resolve an entry's effective visibility — the adjudicated C2 model, and the
 * exact TS mirror of the RLS policy in
 * supabase/migrations/20260708_journal_visibility_model.sql
 * (`COALESCE(visibility_override, profiles.profile_visibility)`):
 *
 *   - explicit override ('public' | 'friends' | 'private') always wins;
 *   - NULL/undefined override ("Default" in the UI) inherits the author's
 *     profiles.profile_visibility (B2: this was world-readable before);
 *   - unknown/missing profile visibility fails closed to 'friends' (the DB
 *     default; profiles.profile_visibility is NOT NULL) — never 'public';
 *   - an invalid explicit override fails closed to 'private' (mirrors the SQL
 *     policy, where a value matching neither branch grants nothing).
 */
export function resolveVisibility(
  override: string | null | undefined,
  profileVisibility: string | null | undefined,
): ResolvedJournalVisibility {
  if (override === 'public' || override === 'friends' || override === 'private') {
    return override;
  }
  if (override != null) return 'private';
  if (
    profileVisibility === 'public'
    || profileVisibility === 'friends'
    || profileVisibility === 'private'
  ) {
    return profileVisibility;
  }
  return 'friends';
}

/**
 * B6 gate: a `review` activity event may be emitted only when the entry's
 * RESOLVED visibility is 'public'. activity_events rows escape the journal's
 * own RLS — the C1 explore policy shows them to ALL authenticated users when
 * the author's profile is public — so the previous `!== 'private'` gate leaked
 * 'friends'-only review bodies into explore.
 */
export function shouldEmitReviewEvent(
  reviewText: string | null | undefined,
  override: string | null | undefined,
  profileVisibility: string | null | undefined,
): boolean {
  return !!reviewText && resolveVisibility(override, profileVisibility) === 'public';
}

// ── Column lists (audit B5) ──────────────────────────────────────────────────

/**
 * Every journal_entries contract column EXCEPT owner-only personal_takeaway
 * (and the internal search_vector). Matches the Task 1 search RPC's return
 * set exactly (20260708_journal_search_likes_hardening.sql §3). Use this for
 * any read that can serve another user's entries; owner-scoped reads keep
 * select('*') so the composer can round-trip the takeaway.
 */
export const JOURNAL_ENTRY_SHARED_COLUMN_LIST = [
  'id',
  'user_id',
  'tmdb_id',
  'title',
  'poster_url',
  'rating_tier',
  'review_text',
  'contains_spoilers',
  'mood_tags',
  'vibe_tags',
  'favorite_moments',
  'standout_performances',
  'watched_date',
  'watched_location',
  'watched_with_user_ids',
  'watched_platform',
  'is_rewatch',
  'rewatch_note',
  'photo_paths',
  'visibility_override',
  'like_count',
  'created_at',
  'updated_at',
] as const;

export const JOURNAL_ENTRY_SHARED_COLUMNS: string = JOURNAL_ENTRY_SHARED_COLUMN_LIST.join(', ');

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
  // Optional: cross-user reads (search RPC, JOURNAL_ENTRY_SHARED_COLUMNS
  // selects) omit personal_takeaway (audit B5 — owner-only field); only
  // owner-scoped select('*') paths include it.
  personal_takeaway?: string | null;
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

  // B6: emit the review activity event only when the entry's RESOLVED
  // visibility is 'public' (was `!== 'private'`, which leaked 'friends'-only
  // review bodies into explore via activity_events). Resolution needs the
  // author's profiles.profile_visibility only when there is no explicit
  // override — fetched here, at emission time, so no caller can forget it;
  // a failed lookup resolves to the DB default ('friends') and fails closed.
  if (data.reviewText) {
    const override = data.visibilityOverride ?? null;
    let profileVisibility: string | null = null;
    if (override === null) {
      const { data: prof } = await supabase
        .from('profiles')
        .select('profile_visibility')
        .eq('id', userId)
        .maybeSingle();
      profileVisibility = prof?.profile_visibility ?? null;
    }
    if (shouldEmitReviewEvent(data.reviewText, override, profileVisibility)) {
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

/**
 * OWNER path: every caller passes the signed-in user's own id (composer
 * edit/probe, isOwnProfile-guarded StubDetailModal), so the full row —
 * including owner-only personal_takeaway — is kept (select '*', audit B5).
 */
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

/**
 * Probe-vs-prop seam for the composer's edit flow. Rows passed into the
 * composer from the journal grid/search come from cross-user reads that
 * EXCLUDE owner-only personal_takeaway (audit B5), and the save path is a
 * full-replace upsert — populating the form from such a row would silently
 * wipe the owner's takeaway on save. The freshly probed owner row
 * (getJournalEntry, which keeps select('*')) therefore always wins; the
 * passed row is only a fallback for a failed probe, and null means "no entry
 * yet" (composer starts the chat phase).
 */
export function pickEntryForEdit(
  probed: JournalEntry | null,
  passed?: JournalEntry | null,
): JournalEntry | null {
  return probed ?? passed ?? null;
}

/**
 * Id-addressed fetch with no owner scoping — cross-user capable, so it reads
 * the shared column list (no personal_takeaway, audit B5). Owner flows that
 * need the takeaway use getJournalEntry.
 */
export async function getJournalEntryById(
  entryId: string,
): Promise<JournalEntry | null> {
  const { data, error } = await supabase
    .from('journal_entries')
    .select(JOURNAL_ENTRY_SHARED_COLUMNS)
    .eq('id', entryId)
    .maybeSingle();

  if (error || !data) return null;
  return mapRow(data as unknown as JournalRow);
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
  // Serves other users' journal tabs as well as the owner's — cross-user
  // read, so personal_takeaway stays out of the select (audit B5). No list
  // consumer renders it (JournalEntryCard never did); owner detail/edit paths
  // go through getJournalEntry, which keeps it.
  let query = supabase
    .from('journal_entries')
    .select(`${JOURNAL_ENTRY_SHARED_COLUMNS}, profiles!journal_entries_user_id_fkey(username, display_name, avatar_url, avatar_path)`)
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

  // The select string is built at runtime (shared column list + join), so
  // supabase-js cannot infer the row type — cast to the known shape.
  const rows = (data ?? []) as unknown as Record<string, unknown>[];
  return rows.map((row) => {
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

/**
 * RPC argument shape for search_journal_entries. The wire signature is
 * unchanged for API compat (audit B1 fix), but target_user_id is now a
 * FILTER, not a trust boundary: the rewritten RPC is security invoker, so
 * journal_entries RLS decides which of that user's rows the caller may see.
 */
export function buildSearchRpcArgs(
  targetUserId: string,
  query: string,
): { search_query: string; target_user_id: string } {
  return { search_query: query, target_user_id: targetUserId };
}

export async function searchJournalEntries(
  userId: string,
  query: string,
): Promise<JournalEntry[]> {
  // Rows come back without personal_takeaway (owner-only per audit B5) —
  // mapRow yields personalTakeaway: undefined, which no search consumer renders.
  const { data, error } = await supabase
    .rpc('search_journal_entries', buildSearchRpcArgs(userId, query));

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
// Audit B3: likes are backed by the journal_entry_likes table (unique
// (entry_id, user_id), RLS: own-row insert/delete, entry-visible select).
// journal_entries.like_count is trigger-maintained from actual rows — the
// increment/decrement RPCs are dropped and must never be called again.
// See supabase/migrations/20260708_journal_search_likes_hardening.sql.

/** Payload shape for a journal_entry_likes insert (snake_case table columns). */
export function buildLikeInsertPayload(
  entryId: string,
  userId: string,
): { entry_id: string; user_id: string } {
  return { entry_id: entryId, user_id: userId };
}

export interface LikeToggleState {
  liked: boolean;
  likeCount: number;
}

/**
 * Pure optimistic-toggle reducer for the like button. Clamps at 0 so a
 * historically drifted server count (audit B3) can never render negative.
 */
export function applyLikeToggle(state: LikeToggleState): LikeToggleState {
  return state.liked
    ? { liked: false, likeCount: Math.max(0, state.likeCount - 1) }
    : { liked: true, likeCount: state.likeCount + 1 };
}

export async function toggleJournalLike(
  userId: string,
  entryId: string,
  shouldLike: boolean,
): Promise<boolean> {
  if (shouldLike) {
    // ignoreDuplicates → INSERT ... ON CONFLICT DO NOTHING: idempotent, and a
    // repeat like can no longer inflate the count (trigger derives it from rows).
    const { error } = await supabase
      .from('journal_entry_likes')
      .upsert(buildLikeInsertPayload(entryId, userId), {
        onConflict: 'entry_id,user_id',
        ignoreDuplicates: true,
      });
    if (error) {
      console.error('Failed to like journal entry:', error);
      return false;
    }
  } else {
    const { error } = await supabase
      .from('journal_entry_likes')
      .delete()
      .eq('entry_id', entryId)
      .eq('user_id', userId);
    if (error) {
      console.error('Failed to unlike journal entry:', error);
      return false;
    }
  }
  return true;
}

/**
 * Batch liked-state load for the viewer (audit B3: cards previously never
 * loaded initial like state, so re-likes double-incremented across sessions).
 */
export async function getLikedEntryIds(
  viewerId: string,
  entryIds: string[],
): Promise<Set<string>> {
  if (!viewerId || entryIds.length === 0) return new Set();

  const { data, error } = await supabase
    .from('journal_entry_likes')
    .select('entry_id')
    .eq('user_id', viewerId)
    .in('entry_id', entryIds);

  if (error) {
    console.error('Failed to load journal like state:', error);
    return new Set();
  }
  return new Set((data ?? []).map((r: { entry_id: string }) => r.entry_id));
}
