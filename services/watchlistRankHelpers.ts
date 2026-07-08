// watchlistRankHelpers — pure decision + shape logic for the rank-from-watchlist flow.
//
// When a user ranks an item that lives on their watchlist, the bookmark should
// be removed ONLY after the ranking save is confirmed. Deleting the bookmark on
// a failed save loses the item entirely (it ends up in neither list) — the B5
// data-loss bug. This helper pins the corrected contract so every call site
// (and the iOS C3 port) shares one source of truth.
//
// It also owns the shape of a TV watchlist bookmark minted from a search result
// (B2/D5): a whole-show bookmark MUST carry the numeric showTmdbId and normalized
// (non-compound) genres, otherwise addToTVWatchlist stores show_tmdb_id=0 and
// ranking the row later mints a season-less tv_rankings row that violates the
// season-id contract.
//
// Header last reviewed: 2026-07-07

import type { TMDBTVShow } from './tmdbService';
import { normalizeTVGenres } from './tmdbService';
import type { WatchlistItem } from '../types';

/**
 * Decide whether the watchlist bookmark should be removed after a rank attempt.
 * Returns true only when the ranking save succeeded, so a failed save leaves the
 * bookmark intact.
 */
export function shouldRemoveBookmarkAfterRank(saveSucceeded: boolean): boolean {
  return saveSucceeded;
}

/**
 * Canonicalize a movie tmdb_id to the `tmdb_{n}` form used everywhere else in
 * the app (tmdbService `tmdb_${m.id}`, DiscoverView.normalizeTmdbId). Idempotent:
 * an already-prefixed id is returned unchanged, a bare numeric string/number is
 * prefixed. Matches DiscoverView.normalizeTmdbId's guard (prefix iff not already
 * `tmdb_`-prefixed) so it does not validate or reject non-numeric input; it only
 * prefixes. Accepts number or string; used at Letterboxd import write time so a
 * bare `String(entry.tmdbId)` can never land in user_rankings/watchlist_items and
 * corrupt engine exclusion, taste-profile regex, or cross-user comparison (B1).
 */
export function canonicalMovieTmdbId(rawId: string | number): string {
  const s = String(rawId);
  return s.startsWith('tmdb_') ? s : `tmdb_${s}`;
}

/**
 * Build the WatchlistItem for a whole-show TV bookmark minted from a search
 * result. Sets `showTmdbId` (the numeric show id) so ranking the row later routes
 * through season selection, and normalizes compound TV genres so classifyBracket
 * recognizes them. Mirrors the in-modal bookmark path (AddTVSeasonModal).
 */
export function tvWatchlistItemFromShow(
  show: TMDBTVShow,
  addedAt: string,
): WatchlistItem {
  return {
    id: show.id,
    title: show.name,
    year: show.year,
    posterUrl: show.posterUrl ?? '',
    type: 'tv_season',
    genres: normalizeTVGenres(show.genres ?? []),
    showTmdbId: show.tmdbId,
    addedAt,
  };
}
