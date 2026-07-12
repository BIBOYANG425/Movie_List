/**
 * agent-link — shared-pool number assignment + link-code mint (P1 M2a).
 *
 * Backend for the iOS Settings "Text Chris" sheet. On Photon's free plan there
 * is NO static agent phone number: each user's phone must be registered as a
 * Photon "shared" user, and the API returns THAT user's personal
 * assignedPhoneNumber — the number they specifically text. This function:
 *   POST   { phone } → normalize to E.164 → registerSharedUser via Photon →
 *          mint a 6-char link code by calling rpc/mint_agent_link_code with the
 *          CALLER's forwarded Authorization (preserves auth.uid, no service
 *          role) → 200 { assignedPhoneNumber, code, expiresAt, alreadyRegistered }
 *          so the app opens `sms:{assignedPhoneNumber}&body={code}`.
 *   GET    → rpc/get_agent_link_status (forwarded auth) → { links: [{phone, linkedAt}] }.
 *   DELETE → rpc/unlink_agent (forwarded auth) → 204.
 * One endpoint for the whole sheet (mint / status / unlink).
 *
 * Auth: verify_jwt ON — the platform validates the JWT before this function
 * runs (set at deploy time, see below). We ALSO verify in-function via
 * userClient.auth.getUser() (the repo's tmdb-proxy / suggestions pattern) and
 * forward the caller's Authorization straight to PostgREST so every RPC runs as
 * auth.uid() under RLS. NO service-role key anywhere in this path.
 *
 * Pure logic (phone normalizer, Photon registration + outcome classifier,
 * response mappers) lives in ./_shared.ts (import-clean; exercised by
 * services/__tests__/agentLinkShared.test.ts under vitest).
 *
 * ── Deployment (implementers NEVER deploy; the controller does) ──
 *   Redeploy:  `supabase functions deploy agent-link`
 *              (or MCP deploy_edge_function name="agent-link").
 *   verify_jwt: ON. There is no repo config.toml; verify_jwt is a deploy-time
 *              flag. The CLI defaults verify_jwt=true (matching tmdb-proxy /
 *              suggestions, which rely on the forwarded JWT); with MCP
 *              deploy_edge_function, do NOT pass any no-verify-jwt override.
 *   Secrets:   SPECTRUM_PROJECT_ID, SPECTRUM_PROJECT_SECRET (owner sets in the
 *              function secret store). SUPABASE_URL / SUPABASE_ANON_KEY are
 *              auto-injected by the edge runtime.
 *   Rollback:  delete the function (`supabase functions delete agent-link`).
 *              The iOS sheet (M2b) is the only caller.
 */

import { registerSharedUser } from './_shared.ts'
import {
  buildLinkResponse,
  buildStatusResponse,
  classifyMintError,
  normalizePhone,
  outcomeToHttp,
} from './_shared.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

/**
 * Call a PostgREST RPC as the CALLER: forward the incoming Authorization header
 * (preserves auth.uid under RLS) + the anon apikey. No service role.
 */
async function callRpc(
  supabaseUrl: string,
  anonKey: string,
  authHeader: string,
  fn: string,
): Promise<Response> {
  return await fetch(`${supabaseUrl}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: anonKey,
      Authorization: authHeader,
    },
    body: '{}',
    signal: AbortSignal.timeout(10_000),
  })
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  const method = req.method
  if (method !== 'POST' && method !== 'GET' && method !== 'DELETE') {
    return json({ error: 'Method not allowed' }, 405)
  }

  try {
    // --- Auth: the forwarded Supabase JWT (verify_jwt also gates upstream). ---
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return json({ error: 'Missing Authorization header' }, 401)
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
    if (!supabaseUrl || !anonKey) {
      throw new Error('Supabase environment variables are not configured')
    }

    // ── GET: link status ──────────────────────────────────────────────────────
    if (method === 'GET') {
      const res = await callRpc(supabaseUrl, anonKey, authHeader, 'get_agent_link_status')
      if (res.status === 401) return json({ error: 'Invalid or expired token' }, 401)
      if (!res.ok) {
        console.error('agent-link get_agent_link_status failed:', res.status)
        return json({ error: 'status_failed' }, 500)
      }
      const rows = (await res.json().catch(() => [])) as Array<{
        phone: string
        linked_at: string
      }>
      return json(buildStatusResponse(rows), 200)
    }

    // ── DELETE: unlink ────────────────────────────────────────────────────────
    if (method === 'DELETE') {
      const res = await callRpc(supabaseUrl, anonKey, authHeader, 'unlink_agent')
      if (res.status === 401) return json({ error: 'Invalid or expired token' }, 401)
      if (!res.ok) {
        console.error('agent-link unlink_agent failed:', res.status)
        return json({ error: 'unlink_failed' }, 500)
      }
      return new Response(null, { status: 204, headers: corsHeaders })
    }

    // ── POST: register + mint ─────────────────────────────────────────────────
    const spectrumProjectId = Deno.env.get('SPECTRUM_PROJECT_ID')
    const spectrumProjectSecret = Deno.env.get('SPECTRUM_PROJECT_SECRET')
    if (!spectrumProjectId || !spectrumProjectSecret) {
      console.error('agent-link: SPECTRUM_PROJECT_ID / SPECTRUM_PROJECT_SECRET not set')
      return json({ error: 'not_configured' }, 500)
    }

    let body: unknown
    try {
      body = await req.json()
    } catch {
      return json({ error: 'invalid_phone' }, 400)
    }
    const rawPhone = (body as Record<string, unknown>)?.phone
    if (typeof rawPhone !== 'string') {
      return json({ error: 'invalid_phone' }, 400)
    }
    const phoneE164 = normalizePhone(rawPhone)
    if (!phoneE164) {
      return json({ error: 'invalid_phone' }, 400)
    }

    // --- Register with Photon (shared pool). ---
    const outcome = await registerSharedUser(phoneE164, {
      projectId: spectrumProjectId,
      projectSecret: spectrumProjectSecret,
    })
    const errHttp = outcomeToHttp(outcome)
    if (errHttp) return json(errHttp.body, errHttp.status)
    if (!outcome.ok) {
      // Unreachable (outcomeToHttp handles !ok), but narrows the type.
      return json({ error: 'spectrum_error' }, 502)
    }

    // --- Mint the code AS THE CALLER (forwarded auth, RLS-scoped). ---
    const mintRes = await callRpc(supabaseUrl, anonKey, authHeader, 'mint_agent_link_code')
    if (mintRes.status === 401) return json({ error: 'Invalid or expired token' }, 401)
    if (!mintRes.ok) {
      let message: string | undefined
      try {
        const err = await mintRes.json()
        message = err?.message ?? err?.error ?? err?.hint
      } catch {
        // non-JSON body; classifyMintError falls back to 500
      }
      const mapped = classifyMintError(message)
      console.error('agent-link mint_agent_link_code failed:', mintRes.status, message)
      return json(mapped.body, mapped.status)
    }

    // The RPC "returns table (code, expires_at)" → PostgREST yields an array of rows.
    const rows = (await mintRes.json().catch(() => [])) as Array<{
      code: string
      expires_at: string
    }>
    const minted = Array.isArray(rows) ? rows[0] : (rows as { code: string; expires_at: string })
    if (!minted?.code || !minted?.expires_at) {
      console.error('agent-link: mint RPC returned no row')
      return json({ error: 'mint_failed' }, 500)
    }

    return json(buildLinkResponse(outcome, minted.code, minted.expires_at), 200)
  } catch (err) {
    console.error('agent-link error:', err)
    return json({ error: 'internal_error' }, 500)
  }
})
