import { describe, it, expect, vi, beforeEach } from 'vitest';

// digestPreferencesService reads/writes public.agent_preferences via the supabase
// client (needs import.meta.env at module scope) — mock the client so the pure
// helpers and the read/write paths run in the node test environment. No network.
const mocks = vi.hoisted(() => ({ from: vi.fn() }));
vi.mock('../../lib/supabase', () => ({ supabase: { from: mocks.from } }));

import {
  clampHour,
  clockLabel,
  getDigestPreferences,
  saveDigestPreferences,
  DIGEST_DEFAULTS,
} from '../digestPreferencesService';

/**
 * Chainable PostgREST-builder fake: select/eq/upsert return the chain; the
 * terminal maybeSingle resolves to `result`.
 */
function chain(result: unknown) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const c: any = {};
  for (const m of ['select', 'eq', 'upsert']) c[m] = vi.fn(() => c);
  c.maybeSingle = vi.fn(() => Promise.resolve(result));
  return c;
}

describe('clampHour', () => {
  it('passes valid hours through', () => {
    expect(clampHour(0)).toBe(0);
    expect(clampHour(9)).toBe(9);
    expect(clampHour(23)).toBe(23);
  });

  it('clamps out-of-range values into 0..23', () => {
    expect(clampHour(-5)).toBe(0);
    expect(clampHour(99)).toBe(23);
  });

  it('truncates fractional hours and defaults non-finite input', () => {
    expect(clampHour(9.7)).toBe(9);
    expect(clampHour(NaN)).toBe(DIGEST_DEFAULTS.hour);
  });
});

describe('clockLabel', () => {
  it('formats morning hours', () => {
    expect(clockLabel(9)).toBe('9am');
    expect(clockLabel(1)).toBe('1am');
  });

  it('formats midnight as 12am and noon as 12pm', () => {
    expect(clockLabel(0)).toBe('12am');
    expect(clockLabel(12)).toBe('12pm');
  });

  it('formats afternoon/evening hours', () => {
    expect(clockLabel(13)).toBe('1pm');
    expect(clockLabel(17)).toBe('5pm');
    expect(clockLabel(23)).toBe('11pm');
  });

  it('clamps out-of-range before formatting', () => {
    expect(clockLabel(25)).toBe('11pm');
    expect(clockLabel(-2)).toBe('12am');
  });
});

describe('getDigestPreferences', () => {
  beforeEach(() => mocks.from.mockReset());

  it('maps a stored row into typed prefs', async () => {
    mocks.from.mockReturnValue(
      chain({ data: { trade_digest_cadence: 'weekly', digest_hour: 7, timezone: 'America/New_York' }, error: null }),
    );
    const prefs = await getDigestPreferences('user-1');
    expect(prefs).toEqual({ cadence: 'weekly', hour: 7, timezone: 'America/New_York' });
  });

  it('returns null when there is no row (missing row is not an error)', async () => {
    mocks.from.mockReturnValue(chain({ data: null, error: null }));
    expect(await getDigestPreferences('user-1')).toBeNull();
  });

  it('returns null on a query error', async () => {
    mocks.from.mockReturnValue(chain({ data: null, error: { message: 'boom' } }));
    expect(await getDigestPreferences('user-1')).toBeNull();
  });

  it('coerces an unknown cadence to the default and clamps the hour', async () => {
    mocks.from.mockReturnValue(
      chain({ data: { trade_digest_cadence: 'hourly', digest_hour: 40, timezone: 'UTC' }, error: null }),
    );
    const prefs = await getDigestPreferences('user-1');
    expect(prefs?.cadence).toBe(DIGEST_DEFAULTS.cadence);
    expect(prefs?.hour).toBe(23);
  });
});

describe('saveDigestPreferences', () => {
  beforeEach(() => mocks.from.mockReset());

  it('upserts on user_id with cadence, clamped hour, and a browser timezone', async () => {
    const c = chain({ data: { user_id: 'user-1' }, error: null });
    mocks.from.mockReturnValue(c);

    const ok = await saveDigestPreferences('user-1', 'daily', 30);
    expect(ok).toBe(true);
    expect(mocks.from).toHaveBeenCalledWith('agent_preferences');

    const [payload, options] = c.upsert.mock.calls[0];
    expect(payload.user_id).toBe('user-1');
    expect(payload.trade_digest_cadence).toBe('daily');
    expect(payload.digest_hour).toBe(23); // clamped from 30
    expect(typeof payload.timezone).toBe('string');
    expect(payload.timezone.length).toBeGreaterThan(0);
    expect(typeof payload.updated_at).toBe('string');
    expect(options).toEqual({ onConflict: 'user_id' });
  });

  it('returns false when the upsert errors', async () => {
    mocks.from.mockReturnValue(chain({ data: null, error: { message: 'rls' } }));
    expect(await saveDigestPreferences('user-1', 'off', 9)).toBe(false);
  });
});
