import { describe, it, expect, vi, beforeEach } from 'vitest';

// The token-scoped supabase client factory (P3-B, task B1). We mock supabase-js
// so we can assert EXACTLY the config the /agent-rank route relies on: the
// Bearer header carrying the fragment JWT, and no session persistence / no auto
// refresh (there is no refresh token, and it must never collide with the app's
// real session or touch localStorage).

const mocks = vi.hoisted(() => ({ createClient: vi.fn(() => ({ __client: true })) }));
vi.mock('@supabase/supabase-js', () => ({ createClient: mocks.createClient }));

import { createTokenClient } from '../../lib/agentSupabase';

describe('createTokenClient', () => {
  beforeEach(() => {
    mocks.createClient.mockClear();
  });

  it('passes url + anon key straight through', () => {
    createTokenClient('https://proj.supabase.co', 'anon-key', 'jwt');
    const [url, key] = mocks.createClient.mock.calls[0];
    expect(url).toBe('https://proj.supabase.co');
    expect(key).toBe('anon-key');
  });

  it('sets the Authorization Bearer header from the access token', () => {
    createTokenClient('https://proj.supabase.co', 'anon-key', 'the.jwt.token');
    const options = mocks.createClient.mock.calls[0][2];
    expect(options.global.headers.Authorization).toBe('Bearer the.jwt.token');
  });

  it('disables session persistence and auto-refresh', () => {
    createTokenClient('https://proj.supabase.co', 'anon-key', 'jwt');
    const options = mocks.createClient.mock.calls[0][2];
    expect(options.auth.persistSession).toBe(false);
    expect(options.auth.autoRefreshToken).toBe(false);
  });

  it('returns the client supabase-js builds', () => {
    const client = createTokenClient('https://proj.supabase.co', 'anon-key', 'jwt');
    expect(client).toEqual({ __client: true });
  });
});
