/**
 * Letterboxd ZIP export → Spool import service.
 *
 * Flow: ZIP → JSZip → CSV files → parseCSV → merge/dedup →
 *       TMDB resolution → tier mapping → position assignment → DB persist
 */

import JSZip from 'jszip';
import { parseCSV } from './csvParser';
import { TMDB_BASE, TMDB_IMAGE_BASE, GENRE_MAP } from './tmdbService';
import { classifyBracket } from './rankingAlgorithm';
import { supabase } from '../lib/supabase';
import { Tier, Bracket } from '../types';

// ── Types ───────────────────────────────────────────────────────────────────

export interface LetterboxdRawEntry {
  name: string;
  year: number | null;
  letterboxdUri: string | null;
  rating: number | null;       // 0.5–5.0
  watchedDate: string | null;  // YYYY-MM-DD
  reviewText: string | null;
  isRewatch: boolean;
  source: 'ratings' | 'watched' | 'diary' | 'reviews' | 'watchlist';
}

export interface LetterboxdMergedEntry {
  name: string;
  year: number | null;
  letterboxdUri: string | null;
  rating: number | null;
  watchedDate: string | null;
  reviewText: string | null;
  isRewatch: boolean;
}

export interface ResolvedEntry extends LetterboxdMergedEntry {
  tmdbId: number;
  title: string;
  posterUrl: string | null;
  genres: string[];
  yearStr: string;
}

export interface ImportPreview {
  ratedCount: number;
  unratedCount: number;
  watchlistCount: number;
  reviewCount: number;
  diaryCount: number;
  tierDistribution: Record<string, number>;
  sampleTitles: string[];
}

export interface ImportResult {
  rankingsImported: number;
  rankingsSkipped: number;
  watchlistImported: number;
  watchlistSkipped: number;
  journalImported: number;
  failedResolutions: string[];
}

// ── Letterboxd rating → Spool tier mapping ─────────────────────────────────

export function mapRatingToTier(rating: number | null): Tier | null {
  if (rating == null) return null;
  if (rating >= 4.5) return Tier.S;
  if (rating >= 3.5) return Tier.A;
  if (rating >= 2.5) return Tier.B;
  if (rating >= 1.5) return Tier.C;
  return Tier.D;
}

// ── ZIP extraction ─────────────────────────────────────────────────────────

interface ParsedFiles {
  ratings: LetterboxdRawEntry[];
  watched: LetterboxdRawEntry[];
  diary: LetterboxdRawEntry[];
  reviews: LetterboxdRawEntry[];
  watchlist: LetterboxdRawEntry[];
}

export async function extractLetterboxdZip(file: File): Promise<ParsedFiles> {
  const zip = await JSZip.loadAsync(file);
  const result: ParsedFiles = { ratings: [], watched: [], diary: [], reviews: [], watchlist: [] };

  const fileMap: Record<string, keyof ParsedFiles> = {
    'ratings.csv': 'ratings',
    'watched.csv': 'watched',
    'diary.csv': 'diary',
    'reviews.csv': 'reviews',
    'watchlist.csv': 'watchlist',
  };

  for (const [filename, key] of Object.entries(fileMap)) {
    const entry = zip.file(filename);
    if (!entry) continue;

    const text = await entry.async('text');
    const rows = parseCSV(text);

    result[key] = rows.map((row): LetterboxdRawEntry => ({
      name: row['Name'] ?? '',
      year: row['Year'] ? parseInt(row['Year'], 10) : null,
      letterboxdUri: row['Letterboxd URI'] ?? null,
      rating: row['Rating'] ? parseFloat(row['Rating']) : null,
      watchedDate: row['Watched Date'] ?? row['Date'] ?? null,
      reviewText: row['Review'] ?? null,
      isRewatch: (row['Rewatch'] ?? '').toLowerCase() === 'yes',
      source: key,
    })).filter(e => e.name.length > 0);
  }

  return result;
}

// ── Merge & dedup ──────────────────────────────────────────────────────────

const SOURCE_PRIORITY: Record<string, number> = {
  reviews: 4,
  diary: 3,
  ratings: 2,
  watched: 1,
};

export function mergeEntries(parsed: ParsedFiles): {
  merged: LetterboxdMergedEntry[];
  watchlist: LetterboxdMergedEntry[];
} {
  const map = new Map<string, LetterboxdMergedEntry & { priority: number }>();

  const allRated = [...parsed.ratings, ...parsed.watched, ...parsed.diary, ...parsed.reviews];

  for (const entry of allRated) {
    const key = `${entry.name.toLowerCase().trim()}|${entry.year ?? ''}`;
    const priority = SOURCE_PRIORITY[entry.source] ?? 0;
    const existing = map.get(key);

    if (!existing || priority > existing.priority) {
      map.set(key, {
        name: entry.name,
        year: entry.year,
        letterboxdUri: entry.letterboxdUri,
        rating: entry.rating ?? existing?.rating ?? null,
        watchedDate: entry.watchedDate ?? existing?.watchedDate ?? null,
        reviewText: entry.reviewText ?? existing?.reviewText ?? null,
        isRewatch: entry.isRewatch || existing?.isRewatch || false,
        priority,
      });
    } else {
      // Fill gaps from lower-priority source
      if (!existing.rating && entry.rating) existing.rating = entry.rating;
      if (!existing.watchedDate && entry.watchedDate) existing.watchedDate = entry.watchedDate;
      if (!existing.reviewText && entry.reviewText) existing.reviewText = entry.reviewText;
      if (entry.isRewatch) existing.isRewatch = true;
    }
  }

  // Watchlist entries (exclude anything already rated/watched)
  const ratedKeys = new Set(map.keys());
  const watchlist: LetterboxdMergedEntry[] = [];

  for (const entry of parsed.watchlist) {
    const key = `${entry.name.toLowerCase().trim()}|${entry.year ?? ''}`;
    if (ratedKeys.has(key)) continue;
    watchlist.push({
      name: entry.name,
      year: entry.year,
      letterboxdUri: entry.letterboxdUri,
      rating: null,
      watchedDate: null,
      reviewText: null,
      isRewatch: false,
    });
  }

  const merged = Array.from(map.values()).map(({ priority: _, ...rest }) => rest);
  return { merged, watchlist };
}

// ── Preview ────────────────────────────────────────────────────────────────

export function buildPreview(
  merged: LetterboxdMergedEntry[],
  watchlist: LetterboxdMergedEntry[],
  parsed: ParsedFiles,
): ImportPreview {
  const tierDist: Record<string, number> = { S: 0, A: 0, B: 0, C: 0, D: 0 };
  let ratedCount = 0;
  let unratedCount = 0;

  for (const entry of merged) {
    const tier = mapRatingToTier(entry.rating);
    if (tier) {
      tierDist[tier]++;
      ratedCount++;
    } else {
      unratedCount++;
    }
  }

  const reviewCount = merged.filter(e => e.reviewText).length;

  return {
    ratedCount,
    unratedCount,
    watchlistCount: watchlist.length,
    reviewCount,
    diaryCount: parsed.diary.length,
    tierDistribution: tierDist,
    sampleTitles: merged.slice(0, 5).map(e => e.name),
  };
}

// ── TMDB Resolution ────────────────────────────────────────────────────────

const CONCURRENCY = 8;
const BATCH_DELAY_MS = 50;
const MAX_RETRIES = 3;

async function searchTMDB(
  name: string,
  year: number | null,
  apiKey: string,
  signal?: AbortSignal,
): Promise<ResolvedEntry | null> {
  const url = new URL(`${TMDB_BASE}/search/movie`);
  url.searchParams.set('api_key', apiKey);
  url.searchParams.set('query', name);
  url.searchParams.set('include_adult', 'false');
  if (year) url.searchParams.set('year', String(year));

  let lastError: Error | null = null;

  for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
    if (signal?.aborted) return null;

    try {
      const res = await fetch(url.toString(), { signal });

      if (res.status === 429) {
        const backoff = Math.pow(2, attempt) * 1000;
        await new Promise(r => setTimeout(r, backoff));
        continue;
      }

      if (!res.ok) return null;

      const data = await res.json();
      const results = data.results as any[];
      if (!results || results.length === 0) return null;

      // Best match: prefer exact year match
      let best = results[0];
      if (year) {
        const yearMatch = results.find((r: any) =>
          r.release_date && r.release_date.startsWith(String(year))
        );
        if (yearMatch) best = yearMatch;
      }

      const genres = (best.genre_ids as number[] | undefined)
        ?.map((gid: number) => GENRE_MAP[gid])
        .filter(Boolean)
        .slice(0, 3) ?? [];

      return {
        name,
        year,
        letterboxdUri: null,
        rating: null,
        watchedDate: null,
        reviewText: null,
        isRewatch: false,
        tmdbId: best.id,
        title: best.title,
        posterUrl: best.poster_path ? `${TMDB_IMAGE_BASE}${best.poster_path}` : null,
        genres,
        yearStr: best.release_date ? best.release_date.slice(0, 4) : '—',
      };
    } catch (err) {
      if (err instanceof DOMException && err.name === 'AbortError') return null;
      lastError = err as Error;
      const backoff = Math.pow(2, attempt) * 1000;
      await new Promise(r => setTimeout(r, backoff));
    }
  }

  if (lastError) console.error(`TMDB resolution failed for "${name}":`, lastError);
  return null;
}

export async function resolveAllWithTMDB(
  entries: LetterboxdMergedEntry[],
  onProgress?: (completed: number, total: number, currentTitle: string) => void,
  signal?: AbortSignal,
): Promise<{ resolved: ResolvedEntry[]; failed: string[] }> {
  const apiKey = import.meta.env.VITE_TMDB_API_KEY;
  if (!apiKey) throw new Error('TMDB API key not configured');

  const resolved: ResolvedEntry[] = [];
  const failed: string[] = [];
  let completed = 0;

  // Process in batches of CONCURRENCY
  for (let i = 0; i < entries.length; i += CONCURRENCY) {
    if (signal?.aborted) break;

    const batch = entries.slice(i, i + CONCURRENCY);
    const results = await Promise.all(
      batch.map(async (entry) => {
        const result = await searchTMDB(entry.name, entry.year, apiKey, signal);
        completed++;
        onProgress?.(completed, entries.length, entry.name);
        return { entry, result };
      })
    );

    for (const { entry, result } of results) {
      if (result) {
        // Merge original entry data into resolved result
        resolved.push({
          ...result,
          letterboxdUri: entry.letterboxdUri,
          rating: entry.rating,
          watchedDate: entry.watchedDate,
          reviewText: entry.reviewText,
          isRewatch: entry.isRewatch,
        });
      } else {
        failed.push(entry.name);
      }
    }

    // Delay between batches to respect rate limits
    if (i + CONCURRENCY < entries.length) {
      await new Promise(r => setTimeout(r, BATCH_DELAY_MS));
    }
  }

  return { resolved, failed };
}

// ── Position assignment ────────────────────────────────────────────────────

export function assignPositions(
  entries: ResolvedEntry[],
): (ResolvedEntry & { tier: Tier; rankPosition: number; bracket: Bracket })[] {
  const tierGroups: Record<string, ResolvedEntry[]> = { S: [], A: [], B: [], C: [], D: [] };

  for (const entry of entries) {
    const tier = mapRatingToTier(entry.rating);
    if (tier) tierGroups[tier].push(entry);
  }

  const result: (ResolvedEntry & { tier: Tier; rankPosition: number; bracket: Bracket })[] = [];

  for (const [tierKey, group] of Object.entries(tierGroups)) {
    // Sort by rating desc, then alphabetical
    group.sort((a, b) => {
      const rDiff = (b.rating ?? 0) - (a.rating ?? 0);
      if (rDiff !== 0) return rDiff;
      return a.title.localeCompare(b.title);
    });

    for (let i = 0; i < group.length; i++) {
      result.push({
        ...group[i],
        tier: tierKey as Tier,
        rankPosition: i,
        bracket: classifyBracket(group[i].genres),
      });
    }
  }

  return result;
}

// ── DB persist ─────────────────────────────────────────────────────────────

const BATCH_SIZE = 50;

export async function persistImport(
  userId: string,
  ranked: (ResolvedEntry & { tier: Tier; rankPosition: number; bracket: Bracket })[],
  watchlistEntries: ResolvedEntry[],
  existingRankingIds: Set<string>,
  existingWatchlistIds: Set<string>,
): Promise<ImportResult> {
  const result: ImportResult = {
    rankingsImported: 0,
    rankingsSkipped: 0,
    watchlistImported: 0,
    watchlistSkipped: 0,
    journalImported: 0,
    failedResolutions: [],
  };

  // Fetch current tier counts to offset imported positions
  const { data: tierCounts } = await supabase
    .from('user_rankings')
    .select('tier, rank_position')
    .eq('user_id', userId);

  const tierMaxPos: Record<string, number> = { S: -1, A: -1, B: -1, C: -1, D: -1 };
  for (const row of tierCounts ?? []) {
    const pos = Number(row.rank_position);
    if (pos > tierMaxPos[row.tier]) tierMaxPos[row.tier] = pos;
  }

  // Batch upsert rankings
  const rankingsToInsert = ranked.filter(r => !existingRankingIds.has(String(r.tmdbId)));
  result.rankingsSkipped = ranked.length - rankingsToInsert.length;

  for (let i = 0; i < rankingsToInsert.length; i += BATCH_SIZE) {
    const batch = rankingsToInsert.slice(i, i + BATCH_SIZE);
    const rows = batch.map(entry => {
      tierMaxPos[entry.tier]++;
      return {
        user_id: userId,
        tmdb_id: String(entry.tmdbId),
        title: entry.title,
        year: entry.yearStr,
        poster_url: entry.posterUrl,
        type: 'movie' as const,
        genres: entry.genres,
        director: null,
        bracket: entry.bracket,
        tier: entry.tier,
        rank_position: tierMaxPos[entry.tier],
        notes: null,
        updated_at: new Date().toISOString(),
      };
    });

    const { error } = await supabase
      .from('user_rankings')
      .upsert(rows, { onConflict: 'user_id,tmdb_id', ignoreDuplicates: true });

    if (error) {
      console.error('Failed to upsert rankings batch:', error);
    } else {
      result.rankingsImported += batch.length;
    }
  }

  // Batch upsert watchlist (skip items already ranked)
  const allRankedTmdbIds = new Set(ranked.map(r => String(r.tmdbId)));
  const watchlistToInsert = watchlistEntries.filter(
    w => !existingWatchlistIds.has(String(w.tmdbId)) && !allRankedTmdbIds.has(String(w.tmdbId))
  );
  result.watchlistSkipped = watchlistEntries.length - watchlistToInsert.length;

  for (let i = 0; i < watchlistToInsert.length; i += BATCH_SIZE) {
    const batch = watchlistToInsert.slice(i, i + BATCH_SIZE);
    const rows = batch.map(entry => ({
      user_id: userId,
      tmdb_id: String(entry.tmdbId),
      title: entry.title,
      year: entry.yearStr,
      poster_url: entry.posterUrl,
      type: 'movie' as const,
      genres: entry.genres,
      director: null,
    }));

    const { error } = await supabase
      .from('watchlist_items')
      .upsert(rows, { onConflict: 'user_id,tmdb_id', ignoreDuplicates: true });

    if (error) {
      console.error('Failed to upsert watchlist batch:', error);
    } else {
      result.watchlistImported += batch.length;
    }
  }

  // Batch upsert journal entries for movies with review text or watched date
  const journalEntries = ranked.filter(e => e.reviewText || e.watchedDate);

  for (let i = 0; i < journalEntries.length; i += BATCH_SIZE) {
    const batch = journalEntries.slice(i, i + BATCH_SIZE);
    const rows = batch.map(entry => ({
      user_id: userId,
      tmdb_id: String(entry.tmdbId),
      title: entry.title,
      poster_url: entry.posterUrl,
      rating_tier: entry.tier,
      review_text: entry.reviewText ?? null,
      contains_spoilers: false,
      mood_tags: [],
      vibe_tags: [],
      favorite_moments: [],
      standout_performances: [],
      watched_date: entry.watchedDate ?? new Date().toISOString().split('T')[0],
      watched_location: null,
      watched_with_user_ids: [],
      watched_platform: null,
      is_rewatch: entry.isRewatch,
      rewatch_note: null,
      personal_takeaway: null,
      photo_paths: [],
      visibility_override: null,
    }));

    const { error } = await supabase
      .from('journal_entries')
      .upsert(rows, { onConflict: 'user_id,tmdb_id', ignoreDuplicates: true });

    if (error) {
      console.error('Failed to upsert journal batch:', error);
    } else {
      result.journalImported += batch.length;
    }
  }

  return result;
}

// ── Fetch existing IDs ─────────────────────────────────────────────────────

export async function fetchExistingIds(userId: string): Promise<{
  rankingIds: Set<string>;
  watchlistIds: Set<string>;
}> {
  const [rankRes, watchRes] = await Promise.all([
    supabase.from('user_rankings').select('tmdb_id').eq('user_id', userId),
    supabase.from('watchlist_items').select('tmdb_id').eq('user_id', userId),
  ]);

  return {
    rankingIds: new Set((rankRes.data ?? []).map((r: { tmdb_id: string }) => r.tmdb_id)),
    watchlistIds: new Set((watchRes.data ?? []).map((w: { tmdb_id: string }) => w.tmdb_id)),
  };
}
