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
// And the shape of a TV RANK preselect minted from a search result (B1): the
// UniversalSearch "Rank" path on a whole show must route through season selection
// exactly like the Save path — so the preselect MUST carry the numeric showTmdbId
// (with NO seasonNumber) and normalized genres. Without showTmdbId the modal's
// preselect router (AddTVSeasonModal:204) skips the season grid and the ceremony
// mints a `tv_{showId}` tv_rankings row with show_tmdb_id=0 / season_number=0.
//
// Header last reviewed: 2026-07-10

import type { TMDBTVShow } from './tmdbService';
import { normalizeTVGenres } from './tmdbService';
import { Tier } from '../types';
import type { MediaType, RankedItem, WatchlistItem } from '../types';

/**
 * Decide whether the watchlist bookmark should be removed after a rank attempt.
 * Returns true only when the ranking save succeeded, so a failed save leaves the
 * bookmark intact.
 */
export function shouldRemoveBookmarkAfterRank(saveSucceeded: boolean): boolean {
  return saveSucceeded;
}

/**
 * Dispatch a re-rank gesture to the correct ceremony by media type (B5). The
 * deep-link MediaDetailModal resolves the ranked item across all three
 * collections, so its Re-rank must route by the item's OWN `type` — never
 * unconditionally into the movie ceremony (which would upsert a tv/book id into
 * `user_rankings` + mint a movie stub, cross-writing tables and leaving the real
 * `tv_rankings`/`book_rankings` row orphaned).
 *
 * Exhaustive over MediaType. 'movie' → the movie ceremony (rerankState path),
 * 'tv_season' → the AddTVSeasonModal preselect path, 'book' → RankingFlowModal.
 */
export type RerankTarget = 'movie' | 'tv' | 'book';

export function rerankMediaTarget(type: MediaType): RerankTarget {
  switch (type) {
    case 'tv_season':
      return 'tv';
    case 'book':
      return 'book';
    case 'movie':
      return 'movie';
  }
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

/**
 * Build the RankedItem preselect for the UniversalSearch "Rank" path on a whole
 * TV show (B1). Sets the numeric `showTmdbId` (with NO `seasonNumber`) so the
 * AddTVSeasonModal preselect router routes through the season grid before the
 * tier ceremony, and normalizes compound TV genres. Mirrors
 * `tvWatchlistItemFromShow` (the Save path) so both entry points agree.
 *
 * tier/rank here are inert placeholders: because the preselect goes through
 * season selection, the real tier is chosen in the ceremony and the persisted
 * row is minted from the selected season (composite id + real show_tmdb_id +
 * real season_number), never from this show-level object.
 */
export function tvRankPreselectFromShow(show: TMDBTVShow): RankedItem {
  return {
    id: show.id,
    title: show.name,
    year: show.year,
    posterUrl: show.posterUrl ?? '',
    type: 'tv_season',
    genres: normalizeTVGenres(show.genres ?? []),
    showTmdbId: show.tmdbId,
    tier: Tier.B,
    rank: 0,
  };
}
