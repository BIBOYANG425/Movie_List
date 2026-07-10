/**
 * B4 regression spec: fetchLocalizedTitle only reaches the proxy for ids that
 * actually map to a TMDB entry.
 *
 * In zh mode useLocalizedItems fires fetchLocalizedTitle for EVERY ranked /
 * bookmarked id. Books (`ol_…`) and legacy manual entries (`manual:…`) have no
 * TMDB record, so a request for them was rewritten to `movie/ol_…` /
 * `movie/manual:…`, 403'd at the proxy path rule, was never cached (successes
 * only), and re-fired on every render — starving the shared 30 req/min bucket.
 *
 * The fix is a prefix ALLOWLIST inside fetchLocalizedTitle: only `tv_…` and
 * `tmdb_…` ids hit the proxy; everything else returns null without a fetch.
 * This test pins that seam by counting fetch calls per id shape — a signed-in
 * session is mocked so the only thing that can stop a fetch is the id guard.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Signed-in session so proxyRequest does NOT short-circuit on the 401 gate;
// the ONLY thing that can prevent a network call is the id-prefix allowlist.
vi.mock('../../lib/supabase', () => ({
  supabase: {
    auth: {
      getSession: async () => ({ data: { session: { access_token: 'test-token' } } }),
    },
  },
}));

import { fetchLocalizedTitle } from '../tmdbService';

const okMovie = () =>
  new Response(JSON.stringify({ title: '标题', overview: '简介' }), { status: 200 });
const okTv = () =>
  new Response(JSON.stringify({ name: '剧名', overview: '简介' }), { status: 200 });

describe('fetchLocalizedTitle proxy allowlist (B4)', () => {
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    // The tmdb path is packed into the proxy `path` param; branch on it.
    fetchSpy = vi.fn(async (url: string) => (url.includes('tv%2F') ? okTv() : okMovie()));
    vi.stubGlobal('fetch', fetchSpy);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('skips the proxy for book ids (ol_)', async () => {
    const result = await fetchLocalizedTitle('ol_OL27448W', 'zh-CN');
    expect(result).toBeNull();
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('skips the proxy for legacy manual ids', async () => {
    const result = await fetchLocalizedTitle('manual:the-matrix:1999', 'zh-CN');
    expect(result).toBeNull();
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('skips the proxy for any unknown non-TMDB shape', async () => {
    const result = await fetchLocalizedTitle('something-else', 'zh-CN');
    expect(result).toBeNull();
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('hits the proxy for movie ids (tmdb_) and returns the localized title', async () => {
    const result = await fetchLocalizedTitle('tmdb_603', 'zh-CN');
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(fetchSpy.mock.calls[0][0]).toContain('movie%2F603');
    expect(result).toEqual({ title: '标题', overview: '简介' });
  });

  it('hits the proxy for tv ids (tv_) at the SHOW level, ignoring the season suffix', async () => {
    const result = await fetchLocalizedTitle('tv_1399_s2', 'zh-CN');
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(fetchSpy.mock.calls[0][0]).toContain('tv%2F1399');
    expect(fetchSpy.mock.calls[0][0]).not.toContain('s2');
    expect(result).toEqual({ title: '剧名', overview: '简介' });
  });
});
