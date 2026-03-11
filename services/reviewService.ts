import { supabase } from '../lib/supabase';
import { MovieReview } from '../types';
import {
  getProfilesByIds,
  getFollowingIdSet,
  toTier,
} from './profileService';
import { upsertJournalEntry } from './journalService';

export interface ReviewRow {
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

export interface ReviewLikeRow {
  review_id: string;
  user_id: string;
}

/** @deprecated Use upsertJournalEntry from journalService instead */
export async function createOrUpdateReview(
  userId: string,
  tmdbId: string,
  title: string,
  body: string,
  containsSpoilers: boolean = false,
  posterUrl?: string,
): Promise<MovieReview | null> {
  // Delegate to journal service
  const entry = await upsertJournalEntry(userId, tmdbId, {
    title,
    posterUrl,
    reviewText: body,
    containsSpoilers,
  });

  if (!entry) return null;

  const profileMap = await getProfilesByIds([userId]);
  const profile = profileMap.get(userId);

  return {
    id: entry.id,
    userId: entry.userId,
    username: profile?.username ?? 'unknown',
    displayName: profile?.displayName,
    avatarUrl: profile?.avatarUrl,
    mediaItemId: entry.tmdbId,
    mediaTitle: entry.title,
    body: entry.reviewText ?? '',
    ratingTier: entry.ratingTier,
    containsSpoilers: entry.containsSpoilers,
    likeCount: entry.likeCount,
    isLikedByViewer: false,
    createdAt: entry.createdAt,
    updatedAt: entry.updatedAt,
  };
}

export async function getReviewsForMovie(
  tmdbId: string,
  currentUserId: string,
  limit = 20,
): Promise<MovieReview[]> {
  // Query from journal_entries instead of movie_reviews
  const { data, error } = await supabase
    .from('journal_entries')
    .select('*')
    .eq('tmdb_id', tmdbId)
    .not('review_text', 'is', null)
    .order('created_at', { ascending: false })
    .limit(limit);

  if (error) {
    console.error('Failed to load reviews:', error);
    return [];
  }

  const rows = (data ?? []) as { id: string; user_id: string; tmdb_id: string; title: string; review_text: string; rating_tier: string | null; contains_spoilers: boolean; like_count: number; created_at: string; updated_at: string }[];
  const userIds = [...new Set(rows.map(r => r.user_id))];
  const profileMap = await getProfilesByIds(userIds);

  // Get likes by current user
  const entryIds = rows.map(r => r.id);
  const likedSet = new Set<string>();
  if (entryIds.length > 0) {
    const { data: likes } = await supabase
      .from('journal_likes')
      .select('entry_id')
      .eq('user_id', currentUserId)
      .in('entry_id', entryIds);
    (likes ?? []).forEach((l: { entry_id: string }) => likedSet.add(l.entry_id));
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
      body: row.review_text,
      ratingTier: toTier(row.rating_tier) ?? undefined,
      containsSpoilers: row.contains_spoilers,
      likeCount: row.like_count,
      isLikedByViewer: likedSet.has(row.id),
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  });

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
  // Query from journal_entries instead of movie_reviews
  const { data, error } = await supabase
    .from('journal_entries')
    .select('*')
    .eq('user_id', targetUserId)
    .not('review_text', 'is', null)
    .order('created_at', { ascending: false })
    .limit(limit);

  if (error) {
    console.error('Failed to load user reviews:', error);
    return [];
  }

  const rows = (data ?? []) as { id: string; user_id: string; tmdb_id: string; title: string; review_text: string; rating_tier: string | null; contains_spoilers: boolean; like_count: number; created_at: string; updated_at: string }[];
  const profileMap = await getProfilesByIds([targetUserId]);
  const profile = profileMap.get(targetUserId);

  const entryIds = rows.map(r => r.id);
  const likedSet = new Set<string>();
  if (entryIds.length > 0) {
    const { data: likes } = await supabase
      .from('journal_likes')
      .select('entry_id')
      .eq('user_id', currentUserId)
      .in('entry_id', entryIds);
    (likes ?? []).forEach((l: { entry_id: string }) => likedSet.add(l.entry_id));
  }

  return rows.map((row) => ({
    id: row.id,
    userId: row.user_id,
    username: profile?.username ?? 'unknown',
    displayName: profile?.displayName,
    avatarUrl: profile?.avatarUrl,
    mediaItemId: row.tmdb_id,
    mediaTitle: row.title,
    body: row.review_text,
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
