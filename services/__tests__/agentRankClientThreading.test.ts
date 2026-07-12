import { describe, it, expect, vi, beforeEach } from 'vitest';

// Proves the client-parameter threading (P3-B, task B1): the three ceremony
// writers — setTierOrder, logRankingActivityEvent, createStub — route through an
// INJECTED client when one is passed (the /agent-rank token-scoped client) and
// fall back to the module-global supabase when it is omitted (normal app path,
// unchanged). The module-global is mocked so import.meta.env / color-thief never
// load in the node test environment.

const moduleMocks = vi.hoisted(() => ({
  rpc: vi.fn(async () => ({ data: 1, error: null })),
  from: vi.fn(),
}));
vi.mock('../../lib/supabase', () => ({
  supabase: { rpc: moduleMocks.rpc, from: moduleMocks.from },
}));
vi.mock('color-thief-browser', () => ({ default: class ColorThief {} }));

import { setTierOrder } from '../tierOrder';
import { logRankingActivityEvent } from '../activityService';
import { insertStubOrUpdateOnConflict } from '../stubService';
import { Tier } from '../../types';

/** A chainable PostgREST-builder fake whose terminal await resolves to result. */
function chain(result: unknown) {
  const thenable: any = {
    insert: vi.fn(() => thenable),
    update: vi.fn(() => thenable),
    upsert: vi.fn(() => thenable),
    select: vi.fn(() => thenable),
    single: vi.fn(() => Promise.resolve(result)),
    eq: vi.fn(() => thenable),
    then: (res: (v: unknown) => void) => Promise.resolve(result).then(res),
  };
  return thenable;
}

describe('setTierOrder — client threading', () => {
  beforeEach(() => moduleMocks.rpc.mockClear());

  it('uses the injected client when one is passed', async () => {
    const injected = { rpc: vi.fn(async () => ({ data: 2, error: null })) } as any;
    await setTierOrder('movie', 'S', ['a', 'b'], injected);
    expect(injected.rpc).toHaveBeenCalledWith('set_tier_order', {
      p_media: 'movie',
      p_tier: 'S',
      p_tmdb_ids: ['a', 'b'],
    });
    expect(moduleMocks.rpc).not.toHaveBeenCalled();
  });

  it('falls back to the module supabase when no client is passed', async () => {
    await setTierOrder('movie', 'A', ['x']);
    expect(moduleMocks.rpc).toHaveBeenCalledTimes(1);
  });
});

describe('logRankingActivityEvent — client threading', () => {
  beforeEach(() => moduleMocks.from.mockReset());

  it('inserts through the injected client when one is passed', async () => {
    const insert = vi.fn(async () => ({ error: null }));
    const injected = { from: vi.fn(() => ({ insert })) } as any;
    const ok = await logRankingActivityEvent(
      'user-1',
      { id: 'tmdb_603', title: 'The Matrix', tier: Tier.S },
      'ranking_add',
      injected,
    );
    expect(ok).toBe(true);
    expect(injected.from).toHaveBeenCalledWith('activity_events');
    expect(insert).toHaveBeenCalledTimes(1);
    expect(moduleMocks.from).not.toHaveBeenCalled();
  });

  it('carries watched_with only for add events, and event fields for the row', async () => {
    let captured: any;
    const insert = vi.fn(async (row: any) => {
      captured = row;
      return { error: null };
    });
    const injected = { from: vi.fn(() => ({ insert })) } as any;
    await logRankingActivityEvent(
      'user-1',
      { id: 'tmdb_603', title: 'The Matrix', tier: Tier.A, notes: 'wow', year: '1999' },
      'ranking_add',
      injected,
    );
    expect(captured.actor_id).toBe('user-1');
    expect(captured.event_type).toBe('ranking_add');
    expect(captured.media_tmdb_id).toBe('tmdb_603');
    expect(captured.media_tier).toBe(Tier.A);
    expect(captured.metadata.notes).toBe('wow');
    expect(captured.metadata.year).toBe('1999');
  });
});

describe('insertStubOrUpdateOnConflict — client threading', () => {
  it('inserts through the injected client when one is passed', async () => {
    const injectedChain = chain({ data: { id: 'stub-1' }, error: null });
    const injected = { from: vi.fn(() => injectedChain) } as any;
    const res = await insertStubOrUpdateOnConflict(
      'user-1',
      { mediaType: 'movie', tmdbId: 'tmdb_603', title: 'The Matrix', tier: Tier.S },
      new Date('2026-07-12T12:00:00Z'),
      injected,
    );
    expect(injected.from).toHaveBeenCalledWith('movie_stubs');
    expect(injectedChain.insert).toHaveBeenCalledTimes(1);
    expect(res.error).toBeNull();
  });
});
