// lib/agentSupabase.ts
//
// A SECOND supabase client factory for the /agent-rank route (P3-B, task B1).
//
// The rank ceremony opens INSIDE iMessage via a Photon mini-app card, carrying a
// short-TTL per-user Supabase JWT in the URL fragment (never a persisted app
// session). This factory builds a client scoped to that raw access token: it
// sets the `Authorization: Bearer <token>` header so PostgREST + RPC calls run
// as that user under RLS, and it disables session persistence / auto-refresh so
// it never touches localStorage, never collides with the app's real session,
// and never tries to refresh a token it has no refresh token for.
//
// The pure `createTokenClient(url, anon, token)` form takes explicit url/anon so
// it is unit-testable without `import.meta.env`. `createTokenClientFromEnv` is
// the runtime convenience that reads the Vite env like lib/supabase.ts does.
//
// Header last reviewed: 2026-07-12

import { createClient, type SupabaseClient } from '@supabase/supabase-js';

/**
 * Build a token-scoped supabase client (no session persistence, no refresh).
 *
 * @param supabaseUrl  the project URL (VITE_SUPABASE_URL).
 * @param anonKey      the anon/publishable key (VITE_SUPABASE_ANON_KEY) — used
 *                     as the `apikey`; the Bearer token below carries identity.
 * @param accessToken  the raw short-TTL JWT minted by the agent (from the URL
 *                     fragment). Every PostgREST/RPC request rides as this user.
 */
export function createTokenClient(
  supabaseUrl: string,
  anonKey: string,
  accessToken: string,
): SupabaseClient {
  return createClient(supabaseUrl, anonKey, {
    global: {
      headers: { Authorization: `Bearer ${accessToken}` },
    },
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });
}

/**
 * Runtime convenience: build the token client from the Vite env (same source as
 * lib/supabase.ts). Kept separate from the pure factory so tests can exercise
 * the config without a Vite/import.meta.env harness.
 */
export function createTokenClientFromEnv(accessToken: string): SupabaseClient {
  const supabaseUrl = import.meta.env.VITE_SUPABASE_URL as string;
  const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string;
  return createTokenClient(supabaseUrl, anonKey, accessToken);
}
