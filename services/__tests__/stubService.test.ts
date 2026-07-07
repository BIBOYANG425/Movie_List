import { describe, it, expect, vi, beforeEach } from 'vitest';

// stubService imports the supabase client (needs import.meta.env) and a
// browser-only color lib at module scope — mock both so the helpers can be
// imported and the dispatcher exercised in the node test environment.
const mocks = vi.hoisted(() => ({ from: vi.fn() }));
vi.mock('../../lib/supabase', () => ({ supabase: { from: mocks.from } }));
vi.mock('color-thief-browser', () => ({ default: class ColorThief {} }));

import {
  buildStubInsertPayload,
  buildStubConflictUpdatePayload,
  insertStubOrUpdateOnConflict,
  localDateString,
} from '../stubService';
import type { CreateStubInput } from '../stubService';
import { Tier } from '../../types';

const baseInput: CreateStubInput = {
  mediaType: 'movie',
  tmdbId: '603',
  title: 'The Matrix',
  posterPath: 'https://image.tmdb.org/t/p/w500/abc.jpg',
  tier: Tier.S,
};

/**
 * Chainable PostgREST-builder fake: every method returns the chain itself,
 * and awaiting the chain resolves to `result` (thenable).
 */
function chain(result: unknown) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const c: any = {};
  for (const m of ['insert', 'update', 'select', 'single', 'eq']) {
    c[m] = vi.fn(() => c);
  }
  c.then = (onFulfilled: (v: unknown) => unknown) =>
    Promise.resolve(result).then(onFulfilled);
  return c;
}

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

describe('buildStubInsertPayload', () => {
  const now = new Date(2026, 6, 6, 19, 30, 0);

  it('never includes palette (B1 — DB default covers fresh inserts)', () => {
    const payload = buildStubInsertPayload('user-1', baseInput, now);
    expect(payload).not.toHaveProperty('palette');
    const withDate = buildStubInsertPayload('user-1', { ...baseInput, watchedDate: '2026-05-01' }, now);
    expect(withDate).not.toHaveProperty('palette');
  });

  it('always includes watched_date as the user-local calendar day (B2)', () => {
    const payload = buildStubInsertPayload('user-1', baseInput, now);
    expect(payload.watched_date).toBe(localDateString(now));
    expect(payload.watched_date).toBe('2026-07-06');
  });

  it('uses an explicitly provided watchedDate verbatim', () => {
    const payload = buildStubInsertPayload('user-1', { ...baseInput, watchedDate: '2026-04-18' }, now);
    expect(payload.watched_date).toBe('2026-04-18');
  });

  it('keeps every other field identical to the audited write contract', () => {
    const payload = buildStubInsertPayload('user-1', baseInput, now);
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
    const payload = buildStubInsertPayload('user-2', {
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

describe('buildStubConflictUpdatePayload', () => {
  const now = new Date(2026, 6, 6, 19, 30, 0);

  it('contains ONLY the re-rank-refreshable columns (audit §1.2)', () => {
    const payload = buildStubConflictUpdatePayload(baseInput, now);
    expect(payload).toEqual({
      title: 'The Matrix',
      poster_path: 'https://image.tmdb.org/t/p/w500/abc.jpg',
      tier: 'S',
      template_id: 's_tier_gold',
      updated_at: now.toISOString(),
    });
  });

  it('preserves watched_date, palette, mood_tags, stub_line by omission', () => {
    // Even when the caller provides a watchedDate (backfill shape), a
    // conflict-update must not touch the existing row's date.
    const payload = buildStubConflictUpdatePayload({ ...baseInput, watchedDate: '2026-05-01' }, now);
    expect(payload).not.toHaveProperty('watched_date');
    expect(payload).not.toHaveProperty('palette');
    expect(payload).not.toHaveProperty('mood_tags');
    expect(payload).not.toHaveProperty('stub_line');
  });
});

describe('insertStubOrUpdateOnConflict', () => {
  const now = new Date(2026, 6, 6, 19, 30, 0);
  const row = { id: 'stub-1', user_id: 'user-1', tmdb_id: '603' };

  beforeEach(() => {
    mocks.from.mockReset();
  });

  it('returns the INSERT result on success without issuing an update', async () => {
    const insertChain = chain({ data: row, error: null });
    mocks.from.mockReturnValueOnce(insertChain);

    const res = await insertStubOrUpdateOnConflict('user-1', baseInput, now);

    expect(res.data).toBe(row);
    expect(res.error).toBeNull();
    expect(mocks.from).toHaveBeenCalledTimes(1);
    expect(mocks.from).toHaveBeenCalledWith('movie_stubs');
    expect(insertChain.insert).toHaveBeenCalledWith(buildStubInsertPayload('user-1', baseInput, now));
    expect(insertChain.update).not.toHaveBeenCalled();
  });

  it('falls back to the conflict UPDATE on unique violation 23505', async () => {
    const insertChain = chain({ data: null, error: { code: '23505', message: 'duplicate key value' } });
    const updateChain = chain({ data: row, error: null });
    mocks.from.mockReturnValueOnce(insertChain).mockReturnValueOnce(updateChain);

    const res = await insertStubOrUpdateOnConflict('user-1', baseInput, now);

    expect(res.data).toBe(row);
    expect(res.error).toBeNull();
    expect(mocks.from).toHaveBeenCalledTimes(2);
    expect(updateChain.update).toHaveBeenCalledWith(buildStubConflictUpdatePayload(baseInput, now));
    expect(updateChain.eq).toHaveBeenCalledWith('user_id', 'user-1');
    expect(updateChain.eq).toHaveBeenCalledWith('media_type', 'movie');
    expect(updateChain.eq).toHaveBeenCalledWith('tmdb_id', '603');
  });

  it('does NOT update on a non-conflict insert error', async () => {
    const insertChain = chain({ data: null, error: { code: '42501', message: 'RLS denied' } });
    mocks.from.mockReturnValueOnce(insertChain);

    const res = await insertStubOrUpdateOnConflict('user-1', baseInput, now);

    expect(res.data).toBeNull();
    expect(res.error?.code).toBe('42501');
    expect(mocks.from).toHaveBeenCalledTimes(1);
  });
});
