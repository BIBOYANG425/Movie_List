import { describe, it, expect, vi, beforeEach } from 'vitest';

// tierOrder.ts imports the supabase client (needs import.meta.env at module
// scope) only for the setTierOrder wrapper — mock it so the pure helpers and
// the wrapper can both be exercised in the node test environment.
const mocks = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock('../../lib/supabase', () => ({ supabase: { rpc: mocks.rpc } }));

import {
  tierOrderAfterReorder,
  tierOrderAfterRemoval,
  ordersAfterCrossTierMove,
  setTierOrder,
} from '../tierOrder';

// ─── tierOrderAfterReorder ──────────────────────────────────────────────────

describe('tierOrderAfterReorder', () => {
  it('moves an item earlier in the list', () => {
    expect(tierOrderAfterReorder(['a', 'b', 'c', 'd'], 2, 0)).toEqual([
      'c',
      'a',
      'b',
      'd',
    ]);
  });

  it('moves an item later in the list', () => {
    expect(tierOrderAfterReorder(['a', 'b', 'c', 'd'], 0, 2)).toEqual([
      'b',
      'c',
      'a',
      'd',
    ]);
  });

  it('moving an item to its own index is a no-op (order unchanged)', () => {
    const ids = ['a', 'b', 'c'];
    expect(tierOrderAfterReorder(ids, 1, 1)).toEqual(['a', 'b', 'c']);
  });

  it('moves to the end when toIndex is the last index', () => {
    expect(tierOrderAfterReorder(['a', 'b', 'c'], 0, 2)).toEqual([
      'b',
      'c',
      'a',
    ]);
  });

  it('does not mutate the input array', () => {
    const ids = ['a', 'b', 'c'];
    tierOrderAfterReorder(ids, 0, 2);
    expect(ids).toEqual(['a', 'b', 'c']);
  });

  it('returns a copy for out-of-range indices rather than throwing', () => {
    expect(tierOrderAfterReorder(['a', 'b'], 5, 0)).toEqual(['a', 'b']);
    expect(tierOrderAfterReorder(['a', 'b'], 0, 5)).toEqual(['b', 'a']);
  });
});

// ─── tierOrderAfterRemoval ──────────────────────────────────────────────────

describe('tierOrderAfterRemoval', () => {
  it('removes the id and preserves the order of the rest', () => {
    expect(tierOrderAfterRemoval(['a', 'b', 'c'], 'b')).toEqual(['a', 'c']);
  });

  it('removes the first id', () => {
    expect(tierOrderAfterRemoval(['a', 'b', 'c'], 'a')).toEqual(['b', 'c']);
  });

  it('removes the last id', () => {
    expect(tierOrderAfterRemoval(['a', 'b', 'c'], 'c')).toEqual(['a', 'b']);
  });

  it('is a no-op copy when the id is absent', () => {
    expect(tierOrderAfterRemoval(['a', 'b'], 'z')).toEqual(['a', 'b']);
  });

  it('empties a single-element list', () => {
    expect(tierOrderAfterRemoval(['a'], 'a')).toEqual([]);
  });

  it('does not mutate the input array', () => {
    const ids = ['a', 'b', 'c'];
    tierOrderAfterRemoval(ids, 'b');
    expect(ids).toEqual(['a', 'b', 'c']);
  });
});

// ─── ordersAfterCrossTierMove ───────────────────────────────────────────────

describe('ordersAfterCrossTierMove', () => {
  it('removes the moved id from source and inserts it into target at the index', () => {
    const { source, target } = ordersAfterCrossTierMove(
      ['a', 'b', 'c'], // source membership (includes movedId)
      ['x', 'y'], // target membership (excludes movedId)
      'b',
      1,
    );
    expect(source).toEqual(['a', 'c']);
    expect(target).toEqual(['x', 'b', 'y']);
  });

  it('inserts at the front when targetIndex is 0', () => {
    const { source, target } = ordersAfterCrossTierMove(
      ['a', 'b'],
      ['x', 'y'],
      'a',
      0,
    );
    expect(source).toEqual(['b']);
    expect(target).toEqual(['a', 'x', 'y']);
  });

  it('appends to the end when targetIndex is the target length', () => {
    const { source, target } = ordersAfterCrossTierMove(
      ['a', 'b'],
      ['x', 'y'],
      'a',
      2,
    );
    expect(source).toEqual(['b']);
    expect(target).toEqual(['x', 'y', 'a']);
  });

  it('clamps an over-large targetIndex to append', () => {
    const { target } = ordersAfterCrossTierMove(['a'], ['x'], 'a', 99);
    expect(target).toEqual(['x', 'a']);
  });

  it('moves into an empty target tier', () => {
    const { source, target } = ordersAfterCrossTierMove(['a', 'b'], [], 'a', 0);
    expect(source).toEqual(['b']);
    expect(target).toEqual(['a']);
  });

  it('does not duplicate the moved id if the target already contains it', () => {
    // Defensive: target membership passed in should exclude movedId, but if a
    // stale snapshot includes it, the result must still list it exactly once.
    const { target } = ordersAfterCrossTierMove(
      ['a', 'b'],
      ['a', 'x'],
      'a',
      1,
    );
    expect(target.filter((id) => id === 'a')).toHaveLength(1);
  });

  it('does not mutate the input arrays', () => {
    const src = ['a', 'b'];
    const tgt = ['x'];
    ordersAfterCrossTierMove(src, tgt, 'a', 1);
    expect(src).toEqual(['a', 'b']);
    expect(tgt).toEqual(['x']);
  });
});

// ─── setTierOrder (thin RPC wrapper) ────────────────────────────────────────

describe('setTierOrder', () => {
  beforeEach(() => {
    mocks.rpc.mockReset();
  });

  it('calls set_tier_order with the documented arg names', async () => {
    mocks.rpc.mockResolvedValue({ data: 2, error: null });
    await setTierOrder('movie', 'S', ['a', 'b']);
    expect(mocks.rpc).toHaveBeenCalledWith('set_tier_order', {
      p_media: 'movie',
      p_tier: 'S',
      p_tmdb_ids: ['a', 'b'],
    });
  });

  it('passes the media discriminator through (tv, book)', async () => {
    mocks.rpc.mockResolvedValue({ data: 0, error: null });
    await setTierOrder('tv', 'A', ['x']);
    expect(mocks.rpc).toHaveBeenCalledWith('set_tier_order', {
      p_media: 'tv',
      p_tier: 'A',
      p_tmdb_ids: ['x'],
    });
    await setTierOrder('book', 'B', ['y']);
    expect(mocks.rpc).toHaveBeenLastCalledWith('set_tier_order', {
      p_media: 'book',
      p_tier: 'B',
      p_tmdb_ids: ['y'],
    });
  });

  it('returns the error from the RPC for the caller to handle (passthrough)', async () => {
    const error = { message: 'boom' };
    mocks.rpc.mockResolvedValue({ data: null, error });
    const result = await setTierOrder('movie', 'S', ['a']);
    expect(result.error).toBe(error);
  });

  it('returns a null error on success', async () => {
    mocks.rpc.mockResolvedValue({ data: 3, error: null });
    const result = await setTierOrder('movie', 'S', ['a', 'b', 'c']);
    expect(result.error).toBeNull();
  });
});
