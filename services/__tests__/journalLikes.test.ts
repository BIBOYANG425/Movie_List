import { describe, it, expect, vi, beforeEach } from 'vitest';

// journalService imports the supabase client (needs import.meta.env) at module
// scope (directly and via feedService) — mock it so the pure helpers and the
// toggle dispatcher can be exercised in the node test environment. No network.
const mocks = vi.hoisted(() => ({ from: vi.fn(), rpc: vi.fn() }));
vi.mock('../../lib/supabase', () => ({ supabase: { from: mocks.from, rpc: mocks.rpc } }));

import {
  applyLikeToggle,
  buildLikeInsertPayload,
  buildSearchRpcArgs,
  toggleJournalLike,
  getLikedEntryIds,
} from '../journalService';
import type { LikeToggleState } from '../journalService';

/**
 * Chainable PostgREST-builder fake: every method returns the chain itself,
 * and awaiting the chain resolves to `result` (thenable).
 */
function chain(result: unknown) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const c: any = {};
  for (const m of ['insert', 'upsert', 'delete', 'select', 'eq', 'in', 'maybeSingle']) {
    c[m] = vi.fn(() => c);
  }
  c.then = (onFulfilled: (v: unknown) => unknown) =>
    Promise.resolve(result).then(onFulfilled);
  return c;
}

beforeEach(() => {
  mocks.from.mockReset();
  mocks.rpc.mockReset();
});

// ── applyLikeToggle — pure optimistic-toggle reducer (B3 UI half) ───────────

describe('applyLikeToggle', () => {
  it('likes an unliked entry: liked=true, count +1', () => {
    const state: LikeToggleState = { liked: false, likeCount: 2 };
    expect(applyLikeToggle(state)).toEqual({ liked: true, likeCount: 3 });
  });

  it('unlikes a liked entry: liked=false, count -1', () => {
    const state: LikeToggleState = { liked: true, likeCount: 3 };
    expect(applyLikeToggle(state)).toEqual({ liked: false, likeCount: 2 });
  });

  it('clamps the count at 0 when unliking with a drifted zero count', () => {
    // Server-side counts were historically drifted (audit B3); the optimistic
    // UI must never render a negative count.
    const state: LikeToggleState = { liked: true, likeCount: 0 };
    expect(applyLikeToggle(state)).toEqual({ liked: false, likeCount: 0 });
  });

  it('double-toggle round-trips to the original state', () => {
    const state: LikeToggleState = { liked: false, likeCount: 5 };
    expect(applyLikeToggle(applyLikeToggle(state))).toEqual(state);
  });

  it('does not mutate its input', () => {
    const state: LikeToggleState = { liked: false, likeCount: 1 };
    applyLikeToggle(state);
    expect(state).toEqual({ liked: false, likeCount: 1 });
  });
});

// ── Payload shapes ───────────────────────────────────────────────────────────

describe('buildLikeInsertPayload', () => {
  it('produces exactly the journal_entry_likes column pair (snake_case)', () => {
    const payload = buildLikeInsertPayload('entry-1', 'user-1');
    expect(payload).toEqual({ entry_id: 'entry-1', user_id: 'user-1' });
    expect(Object.keys(payload).sort()).toEqual(['entry_id', 'user_id']);
  });

  it('never includes a count column — counts are trigger-derived (B3)', () => {
    const payload = buildLikeInsertPayload('entry-1', 'user-1');
    expect(payload).not.toHaveProperty('like_count');
    expect(payload).not.toHaveProperty('created_at');
  });
});

describe('buildSearchRpcArgs', () => {
  it('keeps the search_journal_entries wire signature (API compat, B1)', () => {
    // target_user_id survives as a FILTER, not a trust boundary — the rewritten
    // RPC is security invoker and rows are gated by journal_entries RLS.
    const args = buildSearchRpcArgs('user-9', 'heist movies');
    expect(args).toEqual({ search_query: 'heist movies', target_user_id: 'user-9' });
    expect(Object.keys(args).sort()).toEqual(['search_query', 'target_user_id']);
  });
});

// ── toggleJournalLike — insert/delete against journal_entry_likes, no RPCs ──

describe('toggleJournalLike', () => {
  it('likes via idempotent upsert into journal_entry_likes and never calls an RPC', async () => {
    const c = chain({ error: null });
    mocks.from.mockReturnValue(c);

    const ok = await toggleJournalLike('user-1', 'entry-1', true);

    expect(ok).toBe(true);
    expect(mocks.from).toHaveBeenCalledWith('journal_entry_likes');
    expect(c.upsert).toHaveBeenCalledWith(
      { entry_id: 'entry-1', user_id: 'user-1' },
      { onConflict: 'entry_id,user_id', ignoreDuplicates: true },
    );
    // B3: increment_journal_likes / decrement_journal_likes are dropped —
    // the client must never touch counter RPCs again.
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it('unlikes via delete scoped to (entry_id, user_id) and never calls an RPC', async () => {
    const c = chain({ error: null });
    mocks.from.mockReturnValue(c);

    const ok = await toggleJournalLike('user-1', 'entry-1', false);

    expect(ok).toBe(true);
    expect(mocks.from).toHaveBeenCalledWith('journal_entry_likes');
    expect(c.delete).toHaveBeenCalled();
    expect(c.eq).toHaveBeenCalledWith('entry_id', 'entry-1');
    expect(c.eq).toHaveBeenCalledWith('user_id', 'user-1');
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it('returns false when the write fails', async () => {
    const c = chain({ error: { message: 'nope' } });
    mocks.from.mockReturnValue(c);

    expect(await toggleJournalLike('user-1', 'entry-1', true)).toBe(false);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});

// ── getLikedEntryIds — per-card liked-state load (B3 UI half) ────────────────

describe('getLikedEntryIds', () => {
  it('returns the set of entry ids the viewer has liked', async () => {
    const c = chain({ data: [{ entry_id: 'e1' }, { entry_id: 'e3' }], error: null });
    mocks.from.mockReturnValue(c);

    const liked = await getLikedEntryIds('viewer-1', ['e1', 'e2', 'e3']);

    expect(mocks.from).toHaveBeenCalledWith('journal_entry_likes');
    expect(c.eq).toHaveBeenCalledWith('user_id', 'viewer-1');
    expect(c.in).toHaveBeenCalledWith('entry_id', ['e1', 'e2', 'e3']);
    expect(liked).toEqual(new Set(['e1', 'e3']));
  });

  it('short-circuits without a query when there is nothing to check', async () => {
    expect(await getLikedEntryIds('viewer-1', [])).toEqual(new Set());
    expect(await getLikedEntryIds('', ['e1'])).toEqual(new Set());
    expect(mocks.from).not.toHaveBeenCalled();
  });

  it('returns an empty set on query error', async () => {
    const c = chain({ data: null, error: { message: 'nope' } });
    mocks.from.mockReturnValue(c);
    expect(await getLikedEntryIds('viewer-1', ['e1'])).toEqual(new Set());
  });
});
