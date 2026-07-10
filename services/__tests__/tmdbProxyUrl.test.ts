/**
 * RED-first spec for the pure client-side tmdb-proxy URL builder.
 *
 * The web client no longer talks to api.themoviedb.org directly. Every TMDB
 * request is rewritten to an authenticated GET against the tmdb-proxy edge
 * function:  {SUPABASE_URL}/functions/v1/tmdb-proxy?path=<encoded tmdb path+query>.
 *
 * `buildProxyUrl` owns exactly one job: take a bare TMDB path (with its own
 * query string, minus api_key) and produce the proxy URL with the whole thing
 * packed into a single, correctly-encoded `path` param. It must NOT smuggle the
 * embedded query as sibling params on the proxy URL (the proxy re-parses `path`).
 */

import { describe, it, expect } from 'vitest';
import { buildProxyUrl } from '../tmdbProxy';

const BASE = 'https://proj.supabase.co';

describe('buildProxyUrl', () => {
  it('packs a bare path into a single ?path= param', () => {
    const url = buildProxyUrl(BASE, 'movie/603');
    expect(url).toBe(
      'https://proj.supabase.co/functions/v1/tmdb-proxy?path=movie%2F603',
    );
  });

  it('keeps the embedded query string inside the path value, not as siblings', () => {
    const url = buildProxyUrl(BASE, 'search/movie?query=matrix&page=1');
    const parsed = new URL(url);
    // Only ONE query param on the proxy URL — `path`. The tmdb query must be
    // encoded *inside* it, never leaked as top-level params.
    expect([...parsed.searchParams.keys()]).toEqual(['path']);
    expect(parsed.searchParams.get('path')).toBe('search/movie?query=matrix&page=1');
    expect(parsed.pathname).toBe('/functions/v1/tmdb-proxy');
  });

  it('round-trips special characters through the path param', () => {
    const url = buildProxyUrl(BASE, 'search/movie?query=amélie & co&page=2');
    const parsed = new URL(url);
    // Decoded value the proxy will read back is byte-identical to what we sent.
    expect(parsed.searchParams.get('path')).toBe('search/movie?query=amélie & co&page=2');
  });

  it('tolerates a leading slash on the tmdb path', () => {
    const url = buildProxyUrl(BASE, '/movie/603?append_to_response=credits');
    const parsed = new URL(url);
    expect(parsed.searchParams.get('path')).toBe('/movie/603?append_to_response=credits');
  });

  it('strips a trailing slash from the supabase base url before joining', () => {
    const url = buildProxyUrl('https://proj.supabase.co/', 'movie/603');
    expect(url).toBe(
      'https://proj.supabase.co/functions/v1/tmdb-proxy?path=movie%2F603',
    );
  });

  it('never forwards an api_key that a caller accidentally left on the path', () => {
    // Defense in depth: the builder must drop api_key so the secret never even
    // reaches the wire. (The proxy also strips it, but the client must not send it.)
    const url = buildProxyUrl(BASE, 'movie/603?api_key=LEAK&language=en-US');
    const parsed = new URL(url);
    const packed = parsed.searchParams.get('path')!;
    expect(packed).not.toContain('api_key');
    expect(packed).toContain('language=en-US');
  });
});
