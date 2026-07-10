/**
 * tmdb-proxy — authenticated, allowlisted TMDB passthrough.
 *
 * Covers everything the client still hits TMDB for directly (search / details /
 * person / season / discover / trending / now_playing / upcoming, audit §2.4).
 * With the `suggestions` function (Task 1) this retires the last TMDB key from
 * both app bundles: the key lives ONLY in this function's secret store as
 * `TMDB_API_KEY` and is injected server-side. Tasks 3+5 route the web + iOS
 * clients through this endpoint.
 *
 * Contract: authenticated GET
 *   `{SUPABASE_URL}/functions/v1/tmdb-proxy?path=<tmdb path + query>`
 *   - Same JWT auth as `suggestions` (401 missing/invalid; per-user in-memory
 *     token bucket, ~30 req/min per isolate).
 *   - `path` is validated against a HARD allowlist (allowPath) — non-allowlisted,
 *     traversal (`..`), encoded slashes, and absolute/protocol-relative URLs →
 *     403 with a generic message (the attempted path is never echoed).
 *   - Query params are stripped to a safelist (sanitizeQuery); `api_key` from
 *     the client is always dropped — the function injects the secret.
 *   - 5s upstream timeout; upstream non-2xx → 502 generic (TMDB bodies never
 *     echoed); 2xx JSON is passed through with the same status. CORS mirrors
 *     `suggestions`.
 *   Pure logic (allowPath / sanitizeQuery) lives in ./rules.ts (import-clean;
 *   exercised by services/__tests__/tmdbProxyRules.test.ts under vitest).
 *
 * ── Deployment (implementers NEVER deploy; the controller does) ──
 *   Redeploy:  `supabase functions deploy tmdb-proxy`
 *              (or MCP `deploy_edge_function` name="tmdb-proxy").
 *   Secret:    TMDB_API_KEY  (already set by the owner in the function store;
 *              shared with the `suggestions` function).
 *   Rollback:  delete the function (`supabase functions delete tmdb-proxy`
 *              or MCP delete_edge_function). Old clients don't call it, so
 *              deletion is safe until the client migration (Tasks 3+5) lands.
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { allowPath, sanitizeQuery } from './rules.ts'

const TMDB_BASE = 'https://api.themoviedb.org/3'
const UPSTREAM_TIMEOUT_MS = 5000

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
}

// ── Per-user in-memory token bucket (~30 req/min per isolate) ────────────────
// Mirrors the suggestions function's bucket approach.

const RATE_LIMIT = 30
const RATE_WINDOW_MS = 60_000
const buckets = new Map<string, { count: number; resetAt: number }>()

function rateLimited(userId: string): boolean {
  const now = Date.now()
  const b = buckets.get(userId)
  if (!b || now >= b.resetAt) {
    buckets.set(userId, { count: 1, resetAt: now + RATE_WINDOW_MS })
    return false
  }
  if (b.count >= RATE_LIMIT) return true
  b.count++
  return false
}

// ── HTTP helper ──────────────────────────────────────────────────────────────

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  if (req.method !== 'GET') {
    return json({ error: 'Method not allowed' }, 405)
  }

  try {
    // --- Auth: verify the forwarded Supabase JWT (same pattern as suggestions) ---
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return json({ error: 'Missing Authorization header' }, 401)
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')
    if (!supabaseUrl || !supabaseAnonKey) {
      throw new Error('Supabase environment variables are not configured')
    }

    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    })

    const {
      data: { user },
      error: authError,
    } = await userClient.auth.getUser()

    if (authError || !user) {
      return json({ error: 'Invalid or expired token' }, 401)
    }

    // --- Rate limit (per-user, in-memory) ---
    if (rateLimited(user.id)) {
      return json({ error: 'Rate limit exceeded' }, 429)
    }

    // --- TMDB secret ---
    const apiKey = Deno.env.get('TMDB_API_KEY')
    if (!apiKey) {
      throw new Error('TMDB_API_KEY is not configured')
    }

    // --- Parse `?path=` and its embedded query string ---
    // We read the raw value so we control decoding ourselves. The path segment
    // (before any '?') is allowlist-checked WITHOUT decoding, so encoded-slash
    // smuggling can't resolve into a real slash. The query part is re-parsed and
    // stripped to the safelist.
    const reqUrl = new URL(req.url)
    const rawPath = reqUrl.searchParams.get('path')
    if (rawPath === null || rawPath.length === 0) {
      return json({ error: 'Missing path parameter' }, 400)
    }

    // Split path from an embedded query string (the client sends the full TMDB
    // path + query as one `path=` value, URL-encoded by the URL constructor).
    const qIdx = rawPath.indexOf('?')
    const pathPart = qIdx === -1 ? rawPath : rawPath.slice(0, qIdx)
    const queryPart = qIdx === -1 ? '' : rawPath.slice(qIdx + 1)

    if (!allowPath(pathPart)) {
      // Generic message — never echo the attempted path.
      return json({ error: 'Path not allowed' }, 403)
    }

    const cleanPath = pathPart.startsWith('/') ? pathPart.slice(1) : pathPart
    const safeParams = sanitizeQuery(new URLSearchParams(queryPart))
    safeParams.set('api_key', apiKey)

    const upstreamUrl = `${TMDB_BASE}/${cleanPath}?${safeParams.toString()}`

    // --- Fetch upstream with a 5s timeout ---
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT_MS)
    let upstream: Response
    try {
      upstream = await fetch(upstreamUrl, {
        signal: controller.signal,
        headers: { accept: 'application/json' },
      })
    } catch {
      // Timeout / network error — generic upstream error, never leak details.
      return json({ error: 'upstream error' }, 502)
    } finally {
      clearTimeout(timeout)
    }

    if (!upstream.ok) {
      // Non-2xx from TMDB — never echo the upstream body (may contain the key
      // path, error codes, or account hints). Generic 502.
      return json({ error: 'upstream error' }, 502)
    }

    // Pass through the upstream JSON on 2xx with the same status.
    let payload: unknown
    try {
      payload = await upstream.json()
    } catch {
      return json({ error: 'upstream error' }, 502)
    }
    return json(payload, upstream.status)
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Internal server error'
    console.error('tmdb-proxy error:', err)
    return json({ error: message }, 500)
  }
})
