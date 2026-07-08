// watchlistRankHelpers — pure decision logic for the rank-from-watchlist flow.
//
// When a user ranks an item that lives on their watchlist, the bookmark should
// be removed ONLY after the ranking save is confirmed. Deleting the bookmark on
// a failed save loses the item entirely (it ends up in neither list) — the B5
// data-loss bug. This helper pins the corrected contract so every call site
// (and the iOS C3 port) shares one source of truth.
//
// Header last reviewed: 2026-07-07

/**
 * Decide whether the watchlist bookmark should be removed after a rank attempt.
 * Returns true only when the ranking save succeeded, so a failed save leaves the
 * bookmark intact.
 */
export function shouldRemoveBookmarkAfterRank(saveSucceeded: boolean): boolean {
  return saveSucceeded;
}
