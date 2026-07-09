// services/tierOrder.ts
//
// Pure tier-order computation helpers + the thin `set_tier_order` RPC wrapper.
// This is the single client-side surface for the C4 position-integrity work
// (docs/plans/2026-07-09-c4-blocking-fixes-plan.md, Task 2; audit findings
// B1/B2/B6). Views compute the intended FULL tier membership (an ordered
// tmdb_id[]) from current UI state via these pure helpers, then persist the
// positions through `setTierOrder` — which delegates to the positions-only,
// delete-aware, UPDATE-only `set_tier_order` RPC. No full-row upsert of
// tier-mates ever happens for a reorder/move/delete-compaction again (that was
// the B6 resurrect surface).
//
// FULL-MEMBERSHIP contract (mirrors the RPC header): the arrays produced here
// are the tier's ENTIRE intended membership in the desired order. The RPC only
// touches rows whose id appears in the array; unlisted rows keep their stale
// positions. A cross-tier move therefore emits TWO calls — source (minus the
// departed id) and target (plus the arriving id) — which is exactly what
// `ordersAfterCrossTierMove` returns.
//
// Persisted title-locale pin: these helpers carry only ids, never titles, so
// they cannot leak a localized title into persistence (audit B4 lives in the
// re-rank handler, not here).

import { supabase } from '../lib/supabase';

/** Which media table the RPC branch targets. */
export type TierOrderMedia = 'movie' | 'tv' | 'book';

/**
 * Return a new ordered id[] with the item at `fromIndex` moved to `toIndex`.
 * Pure; never mutates the input. Out-of-range indices are clamped so callers
 * never throw on a stale index (the RPC recomputes positions server-side
 * anyway). A move to the same index yields an unchanged-order copy — callers
 * use that to suppress no-op events (audit B1).
 */
export function tierOrderAfterReorder(
  ids: readonly string[],
  fromIndex: number,
  toIndex: number,
): string[] {
  const result = [...ids];
  if (fromIndex < 0 || fromIndex >= result.length) return result;
  const [moved] = result.splice(fromIndex, 1);
  const clampedTo = Math.max(0, Math.min(toIndex, result.length));
  result.splice(clampedTo, 0, moved);
  return result;
}

/**
 * Return a new ordered id[] with `removedId` gone, preserving the order of the
 * survivors. Absent id → an unchanged-order copy. Pure.
 */
export function tierOrderAfterRemoval(
  ids: readonly string[],
  removedId: string,
): string[] {
  return ids.filter((id) => id !== removedId);
}

/**
 * Compute the two full-membership arrays for a cross-tier move. `sourceIds` is
 * the source tier's current membership (INCLUDING `movedId`); `targetIds` is
 * the target tier's current membership (EXCLUDING `movedId`). Returns:
 *   - source: `sourceIds` with `movedId` removed,
 *   - target: `targetIds` with `movedId` spliced in at `targetIndex` (clamped),
 *     de-duplicated so a stale `targetIds` that already names `movedId` still
 *     lists it exactly once.
 * Pure; never mutates the inputs.
 */
export function ordersAfterCrossTierMove(
  sourceIds: readonly string[],
  targetIds: readonly string[],
  movedId: string,
  targetIndex: number,
): { source: string[]; target: string[] } {
  const source = sourceIds.filter((id) => id !== movedId);
  const targetWithout = targetIds.filter((id) => id !== movedId);
  const clampedIndex = Math.max(0, Math.min(targetIndex, targetWithout.length));
  const target = [...targetWithout];
  target.splice(clampedIndex, 0, movedId);
  return { source, target };
}

/**
 * Thin wrapper over the `set_tier_order` RPC. Sends the full intended tier
 * membership (`ids`) and lets the server recompute contiguous positions.
 * Error is passed straight through so callers can revert optimistic UI + toast.
 */
export async function setTierOrder(
  media: TierOrderMedia,
  tier: string,
  ids: readonly string[],
): Promise<{ error: unknown }> {
  const { error } = await supabase.rpc('set_tier_order', {
    p_media: media,
    p_tier: tier,
    p_tmdb_ids: ids as string[],
  });
  return { error: error ?? null };
}
