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

export async function createStub(
  userId: string,
  input: CreateStubInput,
): Promise<MovieStub | null> {
  // Extract palette from poster (non-blocking, falls back to empty)
  const palette = input.posterPath ? await extractPalette(input.posterPath) : [];
  const templateId = input.tier === 'S' ? 's_tier_gold' : 'default';

  const { data, error } = await supabase
    .from('movie_stubs')
    .upsert(
      {
        user_id: userId,
        media_type: input.mediaType,
        tmdb_id: input.tmdbId,
        title: input.title,
        poster_path: input.posterPath ?? null,
        tier: input.tier,
        watched_date: input.watchedDate ?? new Date().toISOString().split('T')[0],
        palette,
        template_id: templateId,
        updated_at: new Date().toISOString(),
      },
      { onConflict: 'user_id,media_type,tmdb_id', ignoreDuplicates: false },
    )
    .select()
    .single();

  if (error || !data) {
    console.error('Failed to create stub:', error);
    return null;
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

  const { data } = await supabase
    .from('movie_stubs')
    .select('*')
    .eq('user_id', userId)
    .gte('watched_date', startDate)
    .lte('watched_date', endDate)
    .order('watched_date', { ascending: true });

  return (data ?? []).map(mapRow);
}

export async function getAllStubs(userId: string): Promise<MovieStub[]> {
  const { data } = await supabase
    .from('movie_stubs')
    .select('*')
    .eq('user_id', userId)
    .order('watched_date', { ascending: false });

  return (data ?? []).map(mapRow);
}

export async function updateStubWatchedDate(
  stubId: string,
  watchedDate: string,
): Promise<boolean> {
  const { error } = await supabase
    .from('movie_stubs')
    .update({ watched_date: watchedDate, updated_at: new Date().toISOString() })
    .eq('id', stubId);
  return !error;
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
  // Fetch all movie rankings
  const { data: movieRankings } = await supabase
    .from('user_rankings')
    .select('tmdb_id, title, poster_url, tier, created_at')
    .eq('user_id', userId);

  // Fetch all TV rankings
  const { data: tvRankings } = await supabase
    .from('tv_rankings')
    .select('tmdb_id, title, poster_url, tier, created_at')
    .eq('user_id', userId);

  // Fetch existing stubs to avoid duplicates
  const { data: existingStubs } = await supabase
    .from('movie_stubs')
    .select('media_type, tmdb_id')
    .eq('user_id', userId);

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
        watchedDate: r.created_at ? new Date(r.created_at).toISOString().split('T')[0] : undefined,
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
        watchedDate: r.created_at ? new Date(r.created_at).toISOString().split('T')[0] : undefined,
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
