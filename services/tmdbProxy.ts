/**
 * tmdb-proxy client seam (pure URL builder).
 *
 * The web bundle no longer holds a TMDB key. Every TMDB request is rewritten to
 * an authenticated GET against the `tmdb-proxy` edge function:
 *
 *   {SUPABASE_URL}/functions/v1/tmdb-proxy?path=<tmdb path + query, URL-encoded>
 *
 * The whole TMDB path *and its query string* are packed into a single `path`
 * param. The proxy splits `path` on the first '?', allowlist-checks the path
 * segment, and re-parses the query against its own safelist (dropping `api_key`,
 * which it injects server-side from the secret store). This builder mirrors that
 * contract: it packs everything into `path` and NEVER emits sibling query params,
 * and it defensively drops any `api_key` a caller left on the path so the secret
 * never touches the wire.
 *
 * This module is pure (no fetch, no env, no Deno) so it is unit-testable in
 * isolation — see services/__tests__/tmdbProxyUrl.test.ts.
 */

/**
 * Strip an `api_key` param from a bare TMDB path+query, if present. The client
 * must never send it; the proxy injects the real key. Preserves the rest of the
 * query verbatim (order-preserving).
 */
function stripApiKey(tmdbPath: string): string {
  const qIdx = tmdbPath.indexOf('?');
  if (qIdx === -1) return tmdbPath;

  const pathPart = tmdbPath.slice(0, qIdx);
  const queryPart = tmdbPath.slice(qIdx + 1);
  if (!queryPart) return pathPart;

  const kept = queryPart
    .split('&')
    .filter((pair) => pair !== '' && pair.split('=')[0] !== 'api_key');

  return kept.length > 0 ? `${pathPart}?${kept.join('&')}` : pathPart;
}

/**
 * Build the authenticated proxy URL for a bare TMDB path (with optional query).
 *
 * @param supabaseUrl  the project URL (VITE_SUPABASE_URL); a trailing slash is tolerated.
 * @param tmdbPath     e.g. `search/movie?query=matrix&page=1` or `/movie/603`.
 *                     A leading slash is preserved inside the `path` value.
 */
export function buildProxyUrl(supabaseUrl: string, tmdbPath: string): string {
  const base = supabaseUrl.replace(/\/+$/, '');
  const packed = stripApiKey(tmdbPath);
  const params = new URLSearchParams();
  params.set('path', packed);
  return `${base}/functions/v1/tmdb-proxy?${params.toString()}`;
}
