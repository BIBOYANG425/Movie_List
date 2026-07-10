/**
 * tmdb-proxy/rules.ts — PURE allowlist + query-safelist logic (server-side).
 *
 * This module is import-clean: NO Deno globals, NO URL-scheme imports, plain TS.
 * It is imported by BOTH:
 *   - `supabase/functions/tmdb-proxy/index.ts` (the Deno HTTP shell), and
 *   - `services/__tests__/tmdbProxyRules.test.ts` (the vitest web suite).
 *
 * The proxy accepts an authenticated GET with `?path=<tmdb path + query>`,
 * validates the path against a HARD allowlist (regex-anchored; path-traversal,
 * encoded slashes, and absolute/protocol-relative URLs are rejected), strips
 * every query param outside a small safelist (esp. `api_key` — the client never
 * sends it; the function injects `TMDB_API_KEY` from the secret store), and
 * forwards the rebuilt request to TMDB. Non-allowlisted → 403; the attempted
 * path is never echoed beyond a generic message.
 *
 * Security invariants:
 *   - allowPath is deny-by-default: only an exact regex match returns true.
 *   - No decoding is performed before matching, so `%2e`/`%2f`/`%5c` smuggling
 *     never resolves into a slash or a `..` segment — encoded bytes simply fail
 *     the `[A-Za-z0-9_]`/digit character classes and are rejected.
 *   - sanitizeQuery is an allowlist too; `append_to_response` is further pinned
 *     to the `watch/providers` + `credits` value set.
 */

// ── Path allowlist ───────────────────────────────────────────────────────────

/**
 * Exact TMDB path allowlist (audit §2.4). Each entry is fully anchored (^…$).
 * `\d+` guards the numeric-id slots; the fixed segments are literal so nothing
 * outside this set can match. A single optional leading slash is tolerated
 * (some callers build `/movie/603`); everything else — extra slashes, dots,
 * backslashes, encoded bytes, query/fragment chars, whitespace — falls through
 * to the deny path because those characters are not in any pattern.
 */
const ALLOWED_PATH_PATTERNS: RegExp[] = [
  /^search\/movie$/,
  /^search\/tv$/,
  /^search\/person$/,
  /^movie\/\d+$/,
  /^movie\/\d+\/similar$/,
  /^movie\/\d+\/recommendations$/,
  /^movie\/now_playing$/,
  /^movie\/upcoming$/,
  /^tv\/\d+$/,
  /^tv\/\d+\/season\/\d+$/,
  /^person\/\d+$/,
  /^person\/\d+\/movie_credits$/,
  /^trending\/(movie|tv)\/(day|week)$/,
  /^discover\/movie$/,
  /^discover\/tv$/,
];

/**
 * True iff `path` is an exact allowlist match. Deny-by-default. The path must
 * be the bare TMDB path with NO query string and NO leading host — the caller
 * separates `?path=` from the rest before calling this. A single leading slash
 * is stripped; anything with `..`, encoded slashes/dots, backslashes, or an
 * absolute/protocol-relative prefix fails every pattern and returns false.
 */
export function allowPath(path: string): boolean {
  if (typeof path !== 'string' || path.length === 0) return false;

  // Reject anything that looks like an absolute or protocol-relative URL, a
  // backslash traversal, or a raw traversal segment before we even test the
  // patterns. (The anchored regexes would reject these anyway; this is an
  // explicit, auditable early-out so intent is unambiguous.)
  if (path.includes('..')) return false;
  if (path.includes('\\')) return false;
  if (path.includes('://')) return false;
  if (path.startsWith('//')) return false;
  // No percent-encoding is allowed in the path — decoding could reintroduce a
  // slash or dot-dot. TMDB paths are plain ASCII segments, so reject any '%'.
  if (path.includes('%')) return false;
  // Query/fragment must have been split off already; their presence here means
  // someone tried to smuggle a path. Reject.
  if (path.includes('?') || path.includes('#')) return false;
  // Whitespace has no place in a canonical path.
  if (/\s/.test(path)) return false;

  const normalized = path.startsWith('/') ? path.slice(1) : path;
  return ALLOWED_PATH_PATTERNS.some((re) => re.test(normalized));
}

// ── Query param safelist ─────────────────────────────────────────────────────

/**
 * TMDB query params the proxy forwards. Everything else is stripped, including
 * `api_key` (injected by the function), session/account params, and JSONP
 * callbacks. Dotted range filters are listed explicitly.
 */
const SAFE_PARAMS: ReadonlySet<string> = new Set([
  'query',
  'page',
  'language',
  'include_adult',
  'year',
  'primary_release_year',
  'with_genres',
  'sort_by',
  'vote_count.gte',
  'vote_average.gte',
  'primary_release_date.gte',
  'primary_release_date.lte',
  'first_air_date.gte',
  'first_air_date.lte',
  'region',
  'append_to_response',
]);

/**
 * The only sub-responses a client may request via `append_to_response`. The
 * value is a comma-separated list; every element must be in this set or the
 * whole param is dropped (never partially forwarded).
 */
const APPEND_TO_RESPONSE_ALLOWED: ReadonlySet<string> = new Set([
  'watch/providers',
  'credits',
]);

function appendToResponseOk(value: string): boolean {
  const parts = value.split(',').map((s) => s.trim());
  if (parts.length === 0) return false;
  return parts.every((p) => APPEND_TO_RESPONSE_ALLOWED.has(p));
}

/**
 * Return a fresh URLSearchParams containing only safelisted params with their
 * values copied verbatim (re-encoding happens on `.toString()`). `api_key` and
 * any unknown key are dropped; `append_to_response` is dropped unless every
 * comma-separated element is in the allowed sub-response set.
 *
 * Uses `params.forEach` (not `Object.entries`) so keys like `__proto__` are
 * handled as plain string keys and never touch prototype chains.
 */
export function sanitizeQuery(params: URLSearchParams): URLSearchParams {
  const out = new URLSearchParams();
  params.forEach((value, key) => {
    if (!SAFE_PARAMS.has(key)) return;
    if (key === 'append_to_response' && !appendToResponseOk(value)) return;
    out.append(key, value);
  });
  return out;
}
