import Foundation

/// Pure tier-order computation helpers for the C4 ranking-management ops
/// (reorder / cross-tier move / delete-compaction). Swift port of the web
/// source of truth `services/tierOrder.ts` — the three functions here mirror
/// its `tierOrderAfterReorder` / `tierOrderAfterRemoval` / `ordersAfterCrossTierMove`
/// semantics byte-for-byte, and the tests (`TierOrderTests`) are ported from
/// `services/__tests__/tierOrder.test.ts`.
///
/// FULL-MEMBERSHIP contract (see `docs/contracts/shared-payloads.md`
/// § `user_rankings ordering`): every array these helpers return is the tier's
/// ENTIRE intended membership in the desired order — exactly what the
/// `set_tier_order` RPC needs. The RPC only touches rows whose id appears in
/// the array and compacts them to a contiguous `0..n-1`; unlisted rows keep
/// their stale positions (the loud footgun). A cross-tier move therefore emits
/// TWO calls — source (minus the departed id) and target (plus the arriving
/// id) — which is exactly what `ordersAfterCrossTierMove` returns.
///
/// These helpers carry only ids, never titles, so they cannot leak a localized
/// title into persistence (web B4 lives in the re-rank handler, not here).
///
/// Header last reviewed: 2026-07-09
public enum TierOrder {

    /// Return a NEW ordered id list with the item at `from` moved to `to`.
    /// Pure; never mutates the input. Out-of-range indices are CLAMPED so a
    /// stale index never throws (the RPC recomputes positions server-side
    /// anyway). A move to the same index yields an unchanged-order copy —
    /// callers use that to suppress no-op events (audit B1).
    ///
    /// Mirrors web `tierOrderAfterReorder`: a `from` outside `0..<count`
    /// returns a copy untouched; `to` is clamped to `0...(count-1)` of the
    /// list with the moved element removed.
    public static func tierOrderAfterReorder(_ ids: [String], from: Int, to: Int) -> [String] {
        var result = ids
        guard from >= 0, from < result.count else { return result }
        let moved = result.remove(at: from)
        let clampedTo = min(max(to, 0), result.count)
        result.insert(moved, at: clampedTo)
        return result
    }

    /// Return a NEW ordered id list with `removedId` gone, preserving the
    /// order of the survivors. An absent id yields an unchanged-order copy.
    /// Pure. Mirrors web `tierOrderAfterRemoval`.
    public static func tierOrderAfterRemoval(_ ids: [String], removedId: String) -> [String] {
        ids.filter { $0 != removedId }
    }

    /// Compute the two full-membership arrays for a cross-tier move. `source`
    /// is the source tier's current membership (INCLUDING `movedId`); `target`
    /// is the target tier's current membership (EXCLUDING `movedId`). Returns:
    ///   - source: `source` with `movedId` removed,
    ///   - target: `target` with `movedId` spliced in at `targetIndex`
    ///     (clamped), de-duplicated so a stale `target` that already names
    ///     `movedId` still lists it exactly once.
    /// Pure; never mutates the inputs. Mirrors web `ordersAfterCrossTierMove`.
    public static func ordersAfterCrossTierMove(
        source: [String], target: [String], movedId: String, targetIndex: Int
    ) -> (source: [String], target: [String]) {
        let newSource = source.filter { $0 != movedId }
        var newTarget = target.filter { $0 != movedId }
        let clampedIndex = min(max(targetIndex, 0), newTarget.count)
        newTarget.insert(movedId, at: clampedIndex)
        return (source: newSource, target: newTarget)
    }
}
