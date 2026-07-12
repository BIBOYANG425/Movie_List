import { describe, it, expect, vi } from 'vitest';
import { mapMovieDetailToRankedItem, fetchAgentRankMovie } from '../agentRankMovie';

// Movie-detail mapping + proxy fetch for /agent-rank (P3-B, task B1). The mapper
// must produce the SAME RankedItem shape the ceremony pre-seeds (id `tmdb_<n>`,
// title, year, posterUrl, genres, director, bracket) so the ranking modal and
// the subsequent user_rankings upsert see identical fields.

const RAW_MOVIE = {
  id: 603,
  title: 'The Matrix',
  release_date: '1999-03-30',
  poster_path: '/poster.jpg',
  vote_average: 8.2,
  genres: [
    { id: 28, name: 'Action' },
    { id: 878, name: 'Sci-Fi' },
  ],
  credits: {
    crew: [
      { job: 'Editor', name: 'Zach Staenberg' },
      { job: 'Director', name: 'Lana Wachowski' },
    ],
  },
};

describe('mapMovieDetailToRankedItem', () => {
  it('maps a full TMDB detail payload to the ceremony RankedItem shape', () => {
    const item = mapMovieDetailToRankedItem(RAW_MOVIE)!;
    expect(item.id).toBe('tmdb_603');
    expect(item.title).toBe('The Matrix');
    expect(item.year).toBe('1999');
    expect(item.type).toBe('movie');
    expect(item.posterUrl).toBe('https://image.tmdb.org/t/p/w500/poster.jpg');
    expect(item.genres).toEqual(['Action', 'Sci-Fi']);
    expect(item.director).toBe('Lana Wachowski');
    expect(item.globalScore).toBe(8.2);
    expect(item.bracket).toBeDefined();
  });

  it('handles genre_ids (list-shaped) payloads too', () => {
    const item = mapMovieDetailToRankedItem({
      id: 1,
      title: 'X',
      poster_path: '/p.jpg',
      genre_ids: [35],
    })!;
    expect(item.genres).toEqual(['Comedy']);
  });

  it('returns null when the poster is missing (unrenderable, like the app)', () => {
    expect(mapMovieDetailToRankedItem({ id: 1, title: 'X' })).toBeNull();
    expect(mapMovieDetailToRankedItem(null)).toBeNull();
  });

  it('caps genres at three', () => {
    const item = mapMovieDetailToRankedItem({
      id: 2,
      title: 'Y',
      poster_path: '/p.jpg',
      genres: [
        { id: 28, name: 'Action' },
        { id: 12, name: 'Adventure' },
        { id: 16, name: 'Animation' },
        { id: 35, name: 'Comedy' },
      ],
    })!;
    expect(item.genres).toHaveLength(3);
  });

  it('leaves year empty when release_date is absent', () => {
    const item = mapMovieDetailToRankedItem({ id: 3, title: 'Z', poster_path: '/p.jpg' })!;
    expect(item.year).toBe('');
  });
});

describe('fetchAgentRankMovie', () => {
  it('hits the tmdb-proxy with the Bearer token and maps the result', async () => {
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      json: async () => RAW_MOVIE,
    })) as unknown as typeof fetch;

    const item = await fetchAgentRankMovie(
      'https://proj.supabase.co',
      'anon-key',
      'the.jwt',
      603,
      'en-US',
      fetchImpl,
    );

    expect(item?.id).toBe('tmdb_603');

    const [url, init] = (fetchImpl as any).mock.calls[0];
    // Routes through the tmdb-proxy edge function, packing the path.
    expect(url).toContain('/functions/v1/tmdb-proxy?path=');
    expect(url).toContain('movie%2F603');
    // Carries the fragment JWT as the Bearer + anon key as apikey.
    expect(init.headers.Authorization).toBe('Bearer the.jwt');
    expect(init.headers.apikey).toBe('anon-key');
  });

  it('returns null on a non-2xx proxy response (expired/denied)', async () => {
    const fetchImpl = vi.fn(async () => ({
      ok: false,
      status: 401,
      json: async () => ({ error: 'unauthorized' }),
    })) as unknown as typeof fetch;

    const item = await fetchAgentRankMovie(
      'https://proj.supabase.co',
      'anon-key',
      'expired.jwt',
      603,
      'en-US',
      fetchImpl,
    );
    expect(item).toBeNull();
  });

  it('returns null when the fetch throws (network failure)', async () => {
    const fetchImpl = vi.fn(async () => {
      throw new Error('offline');
    }) as unknown as typeof fetch;

    const item = await fetchAgentRankMovie(
      'https://proj.supabase.co',
      'anon-key',
      'jwt',
      603,
      'en-US',
      fetchImpl,
    );
    expect(item).toBeNull();
  });
});
