import { supabase } from '../lib/supabase';
import { MovieStub, StubMediaType, Tier } from '../types';
import ColorThief from 'color-thief-browser';

// ── Helpers ────────────────────────────────────────────────────────

function mapRow(r: Record<string, unknown>): MovieStub {
  return {
    id: r.id as string,
    userId: r.user_id as string,
    mediaType: r.media_type as StubMediaType,
    tmdbId: r.tmdb_id as string,
    title: r.title as string,
    posterPath: (r.poster_path as string) ?? undefined,
    tier: r.tier as Tier,
    watchedDate: r.watched_date as string,
    moodTags: (r.mood_tags as string[]) ?? [],
    stubLine: (r.stub_line as string) ?? undefined,
    isAiEnriched: r.is_ai_enriched as boolean,
    palette: (r.palette as string[]) ?? [],
    templateId: r.template_id as string,
    sharedExternally: r.shared_externally as boolean,
    journalEntryId: (r.journal_entry_id as string) ?? undefined,
    createdAt: r.created_at as string,
    updatedAt: r.updated_at as string,
  };
}

function rgbToHex(r: number, g: number, b: number): string {
  return `#${r.toString(16).padStart(2, '0')}${g.toString(16).padStart(2, '0')}${b.toString(16).padStart(2, '0')}`;
}

/**
 * Format a Date as yyyy-MM-dd in the runtime's LOCAL timezone.
 * Never use UTC methods / toISOString here — watched_date is a plain
 * calendar date in the user's local terms (see C0 audit finding B2).
 */
export function localDateString(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

// ── Palette Extraction ─────────────────────────────────────────────

export async function extractPalette(posterUrl: string): Promise<string[]> {
  try {
    const img = new Image();
    img.crossOrigin = 'anonymous';
    // Use small poster size for faster extraction
    img.src = posterUrl.startsWith('http')
      ? posterUrl
      : `https://image.tmdb.org/t/p/w185${posterUrl}`;

    return await new Promise<string[]>((resolve) => {
      img.onload = () => {
        try {
          const ct = new ColorThief();
          const palette = ct.getPalette(img, 3);
          resolve(palette.map(([r, g, b]: [number, number, number]) => rgbToHex(r, g, b)));
        } catch {
          resolve([]);
        }
      };
      img.onerror = () => resolve([]);
      // Timeout after 5 seconds
      setTimeout(() => resolve([]), 5000);
    });
  } catch {
    return [];
  }
}

// ── CRUD ───────────────────────────────────────────────────────────

export interface CreateStubInput {
  mediaType: StubMediaType;
  tmdbId: string;
  title: string;
  posterPath?: string;
  tier: Tier;
  watchedDate?: string;
}

/**
 * Build the movie_stubs upsert payload.
 *
 * Contract (C0 audit, §1.1 write contract):
 * - `palette` must NOT appear here: on conflict, PostgREST merge-duplicates
 *   updates every column present, so including `palette: []` wiped an
 *   existing stub's palette on every re-rank (finding B1). Fresh inserts
 *   get the DB default `'{}'` (20260325_movie_stubs.sql:28).
 * - `watched_date` is always sent as the user's LOCAL calendar day (or the
 *   caller-provided date). Relying on DB DEFAULT CURRENT_DATE used the UTC
 *   date, landing evening ranks on tomorrow (finding B2).
 */
export function buildStubUpsertPayload(
  userId: string,
  input: CreateStubInput,
  now: Date = new Date(),
): Record<string, unknown> {
  return {
    user_id: userId,
    media_type: input.mediaType,
    tmdb_id: input.tmdbId,
    title: input.title,
    poster_path: input.posterPath ?? null,
    tier: input.tier,
    template_id: input.tier === 'S' ? 's_tier_gold' : 'default',
    updated_at: now.toISOString(),
    watched_date: input.watchedDate ?? localDateString(now),
  };
}

export async function createStub(
  userId: string,
  input: CreateStubInput,
): Promise<MovieStub | null> {
  const payload = buildStubUpsertPayload(userId, input);

  const { data, error } = await supabase
    .from('movie_stubs')
    .upsert(payload, { onConflict: 'user_id,media_type,tmdb_id', ignoreDuplicates: false })
    .select()
    .single();

  if (error || !data) {
    console.error('Failed to create stub:', error);
    return null;
  }

  // Extract palette in background — don't block the caller
  if (input.posterPath) {
    extractPalette(input.posterPath).then((palette) => {
      if (palette.length > 0) {
        supabase
          .from('movie_stubs')
          .update({ palette })
          .eq('id', data.id)
          .then(({ error: updateErr }) => {
            if (updateErr) console.error('Failed to update stub palette:', updateErr);
          });
      }
    });
  }

  return mapRow(data);
}

export async function getStubsForMonth(
  userId: string,
  year: number,
  month: number,
): Promise<MovieStub[]> {
  const startDate = `${year}-${String(month).padStart(2, '0')}-01`;
  const lastDay = new Date(year, month, 0).getDate();
  const endDate = `${year}-${String(month).padStart(2, '0')}-${String(lastDay).padStart(2, '0')}`;

  const { data, error } = await supabase
    .from('movie_stubs')
    .select('*')
    .eq('user_id', userId)
    .gte('watched_date', startDate)
    .lte('watched_date', endDate)
    .order('watched_date', { ascending: true });

  if (error) {
    throw new Error(`getStubsForMonth failed for user ${userId} (${year}-${month}): ${error.message}`);
  }
  return (data ?? []).map(mapRow);
}

export async function getAllStubs(userId: string): Promise<MovieStub[]> {
  const { data, error } = await supabase
    .from('movie_stubs')
    .select('*')
    .eq('user_id', userId)
    .order('watched_date', { ascending: false });

  if (error) {
    throw new Error(`getAllStubs failed for user ${userId}: ${error.message}`);
  }
  return (data ?? []).map(mapRow);
}

export async function updateStubWatchedDate(
  stubId: string,
  watchedDate: string,
): Promise<boolean> {
  const { data, error } = await supabase
    .from('movie_stubs')
    .update({ watched_date: watchedDate, updated_at: new Date().toISOString() })
    .eq('id', stubId)
    .select('id')
    .single();
  if (error || !data) {
    console.error('updateStubWatchedDate failed:', error?.message ?? 'no row updated (RLS denied?)');
    return false;
  }
  return true;
}

export async function deleteStubByRanking(
  userId: string,
  mediaType: StubMediaType,
  tmdbId: string,
): Promise<boolean> {
  const { error } = await supabase
    .from('movie_stubs')
    .delete()
    .eq('user_id', userId)
    .eq('media_type', mediaType)
    .eq('tmdb_id', tmdbId);
  return !error;
}

// ── Backfill ───────────────────────────────────────────────────────

export async function backfillStubs(
  userId: string,
  onProgress?: (done: number, total: number) => void,
): Promise<number> {
  const [movieRes, tvRes, stubRes] = await Promise.all([
    supabase
      .from('user_rankings')
      .select('tmdb_id, title, poster_url, tier, created_at')
      .eq('user_id', userId),
    supabase
      .from('tv_rankings')
      .select('tmdb_id, title, poster_url, tier, created_at')
      .eq('user_id', userId),
    supabase
      .from('movie_stubs')
      .select('media_type, tmdb_id')
      .eq('user_id', userId),
  ]);

  if (movieRes.error) throw new Error(`backfillStubs: failed to fetch movie rankings for ${userId}: ${movieRes.error.message}`);
  if (tvRes.error) throw new Error(`backfillStubs: failed to fetch TV rankings for ${userId}: ${tvRes.error.message}`);
  if (stubRes.error) throw new Error(`backfillStubs: failed to fetch existing stubs for ${userId}: ${stubRes.error.message}`);

  const movieRankings = movieRes.data;
  const tvRankings = tvRes.data;
  const existingStubs = stubRes.data;

  const existingSet = new Set(
    (existingStubs ?? []).map((s: { media_type: string; tmdb_id: string }) => `${s.media_type}:${s.tmdb_id}`),
  );

  const toCreate: CreateStubInput[] = [];

  for (const r of movieRankings ?? []) {
    const key = `movie:${r.tmdb_id}`;
    if (!existingSet.has(key)) {
      toCreate.push({
        mediaType: 'movie',
        tmdbId: r.tmdb_id,
        title: r.title,
        posterPath: r.poster_url ?? undefined,
        tier: r.tier as Tier,
        // created_at is a timestamptz — convert to the user's LOCAL calendar
        // day; splitting the ISO string would take the UTC date (audit B2)
        watchedDate: r.created_at ? localDateString(new Date(r.created_at)) : undefined,
      });
    }
  }

  for (const r of tvRankings ?? []) {
    const key = `tv_season:${r.tmdb_id}`;
    if (!existingSet.has(key)) {
      toCreate.push({
        mediaType: 'tv_season',
        tmdbId: r.tmdb_id,
        title: r.title,
        posterPath: r.poster_url ?? undefined,
        tier: r.tier as Tier,
        // created_at is a timestamptz — convert to the user's LOCAL calendar
        // day; splitting the ISO string would take the UTC date (audit B2)
        watchedDate: r.created_at ? localDateString(new Date(r.created_at)) : undefined,
      });
    }
  }

  // Process in chunks of 5 to avoid overwhelming the browser
  let created = 0;
  const chunkSize = 5;
  for (let i = 0; i < toCreate.length; i += chunkSize) {
    const chunk = toCreate.slice(i, i + chunkSize);
    const results = await Promise.allSettled(
      chunk.map((input) => createStub(userId, input)),
    );
    created += results.filter((r) => r.status === 'fulfilled' && r.value !== null).length;
    onProgress?.(Math.min(i + chunkSize, toCreate.length), toCreate.length);
  }

  return created;
}
