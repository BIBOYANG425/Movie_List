import { describe, it, expect, vi } from 'vitest';

// stubService imports the supabase client (needs import.meta.env) and a
// browser-only color lib at module scope — mock both so the pure helpers
// can be imported in the node test environment.
vi.mock('../../lib/supabase', () => ({ supabase: {} }));
vi.mock('color-thief-browser', () => ({ default: class ColorThief {} }));

import { buildStubUpsertPayload, localDateString } from '../stubService';
import type { CreateStubInput } from '../stubService';
import { Tier } from '../../types';

const baseInput: CreateStubInput = {
  mediaType: 'movie',
  tmdbId: '603',
  title: 'The Matrix',
  posterPath: 'https://image.tmdb.org/t/p/w500/abc.jpg',
  tier: Tier.S,
};

describe('localDateString', () => {
  it('formats a Date as yyyy-MM-dd using LOCAL components', () => {
    // Constructed from local components — getFullYear/getMonth/getDate return
    // exactly these values in every timezone, so this passes anywhere.
    const d = new Date(2026, 6, 6, 23, 30); // local July 6, 11:30pm
    expect(localDateString(d)).toBe('2026-07-06');
  });

  it('zero-pads month and day', () => {
    const d = new Date(2026, 0, 5); // local Jan 5
    expect(localDateString(d)).toBe('2026-01-05');
  });

  it('uses the local calendar day across an evening-UTC boundary', () => {
    // 23:30 UTC — in UTC this is still July 6, in UTC-behind zones (e.g. PT)
    // it is also July 6 local, but in UTC-ahead zones it is already July 7.
    // Compare against the Date's OWN local components so the assertion is
    // correct in any runtime timezone, including CI's UTC.
    const d = new Date('2026-07-06T23:30:00Z');
    const expected = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    expect(localDateString(d)).toBe(expected);
  });
});

describe('buildStubUpsertPayload', () => {
  const now = new Date(2026, 6, 6, 19, 30, 0);

  it('never includes palette (B1 — upsert must not clobber an existing palette)', () => {
    const payload = buildStubUpsertPayload('user-1', baseInput, now);
    expect(payload).not.toHaveProperty('palette');
    // Even with an explicit watchedDate, palette stays absent.
    const withDate = buildStubUpsertPayload('user-1', { ...baseInput, watchedDate: '2026-05-01' }, now);
    expect(withDate).not.toHaveProperty('palette');
  });

  it('always includes watched_date as the user-local calendar day (B2)', () => {
    const payload = buildStubUpsertPayload('user-1', baseInput, now);
    expect(payload.watched_date).toBe(localDateString(now));
    expect(payload.watched_date).toBe('2026-07-06');
  });

  it('uses an explicitly provided watchedDate verbatim', () => {
    const payload = buildStubUpsertPayload('user-1', { ...baseInput, watchedDate: '2026-04-18' }, now);
    expect(payload.watched_date).toBe('2026-04-18');
  });

  it('keeps every other field identical to the audited write contract', () => {
    const payload = buildStubUpsertPayload('user-1', baseInput, now);
    expect(payload).toEqual({
      user_id: 'user-1',
      media_type: 'movie',
      tmdb_id: '603',
      title: 'The Matrix',
      poster_path: 'https://image.tmdb.org/t/p/w500/abc.jpg',
      tier: 'S',
      template_id: 's_tier_gold',
      updated_at: now.toISOString(),
      watched_date: '2026-07-06',
    });
  });

  it('maps non-S tiers to the default template and missing poster to null', () => {
    const payload = buildStubUpsertPayload('user-2', {
      mediaType: 'tv_season',
      tmdbId: 'tv_100_s2',
      title: 'Some Show S2',
      tier: Tier.B,
    }, now);
    expect(payload.template_id).toBe('default');
    expect(payload.poster_path).toBeNull();
    expect(payload.media_type).toBe('tv_season');
  });
});
