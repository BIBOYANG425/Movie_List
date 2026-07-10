import { describe, it, expect } from 'vitest';

import {
  shouldRemoveBookmarkAfterRank,
  shouldEmitRankingEventAfterSave,
  tvWatchlistItemFromShow,
  tvRankPreselectFromShow,
  rerankMediaTarget,
  canonicalMovieTmdbId,
  isRerankCompletion,
  resolveTVPreselectRoute,
  healTVPreselect,
} from '../watchlistRankHelpers';
import type { TMDBTVShow } from '../tmdbService';
import { Tier } from '../../types';
import type { RankedItem } from '../../types';

// Pins the CORRECTED rank-from-watchlist contract (B5 data-loss fix): the
// bookmark is removed only when the ranking save succeeded. iOS C3 must copy
// these semantics, not the shipped web behavior that deleted unconditionally.
describe('shouldRemoveBookmarkAfterRank', () => {
  it('removes the bookmark when the save succeeded', () => {
    expect(shouldRemoveBookmarkAfterRank(true)).toBe(true);
  });

  it('keeps the bookmark when the save failed', () => {
    expect(shouldRemoveBookmarkAfterRank(false)).toBe(false);
  });
});

// Pins the B4 broadcast gate: the ranking_add/ranking_move activity event and
// the tv_season stub emit ONLY after a confirmed save. addTVItem/addBookItem
// used to run logRankingActivityEvent (and createStub for TV) unconditionally,
// so a silently-failed upsert or set_tier_order RPC error still spawned a
// phantom feed card (and orphan tv stub) for a rank that never landed — while
// the watchlist bookmark correctly stayed (shouldRemoveBookmarkAfterRank keys on
// the same boolean). The movie path (addItem) returns false BEFORE the event/
// stub; this seam pins that parity for tv/book and for the iOS port.
describe('shouldEmitRankingEventAfterSave', () => {
  it('emits the event/stub when the save succeeded', () => {
    expect(shouldEmitRankingEventAfterSave(true)).toBe(true);
  });

  it('suppresses the event/stub when the save failed (no phantom feed card / orphan stub)', () => {
    expect(shouldEmitRankingEventAfterSave(false)).toBe(false);
  });

  it('agrees with the bookmark-removal gate for the same save outcome (one confirmed-save decision)', () => {
    // Both broadcast-a-rank side effects share one "only after confirmed save"
    // decision so the three verticals can never drift: a failed save keeps the
    // bookmark AND suppresses the event; a succeeded save removes the bookmark
    // AND emits the event.
    expect(shouldEmitRankingEventAfterSave(true)).toBe(shouldRemoveBookmarkAfterRank(true));
    expect(shouldEmitRankingEventAfterSave(false)).toBe(shouldRemoveBookmarkAfterRank(false));
  });
});

// Pins the CORRECTED TV-search-save shape (B2/D5): a whole-show bookmark carries
// the numeric showTmdbId (so ranking it later routes through season selection
// instead of minting a season-less tv_rankings row) and normalized, non-compound
// genres (so classifyBracket recognizes them at rank time).
describe('tvWatchlistItemFromShow', () => {
  const show: TMDBTVShow = {
    id: 'tv_1396',
    tmdbId: 1396,
    name: 'Breaking Bad',
    year: '2008',
    posterUrl: '/poster.jpg',
    genres: ['Action & Adventure', 'Sci-Fi & Fantasy', 'Drama'],
    overview: '',
    seasonCount: 5,
    status: 'Ended',
    creators: ['Vince Gilligan'],
  };

  it('carries the numeric showTmdbId', () => {
    expect(tvWatchlistItemFromShow(show, '2026-07-07T00:00:00.000Z').showTmdbId).toBe(1396);
  });

  it('normalizes compound TV genres', () => {
    expect(tvWatchlistItemFromShow(show, '2026-07-07T00:00:00.000Z').genres).toEqual([
      'Action',
      'Adventure',
      'Sci-Fi',
    ]);
  });

  it('does not set a seasonNumber (whole-show bookmark)', () => {
    expect(tvWatchlistItemFromShow(show, '2026-07-07T00:00:00.000Z').seasonNumber).toBeUndefined();
  });

  it('coalesces a null posterUrl to empty string', () => {
    const noPoster: TMDBTVShow = { ...show, posterUrl: null };
    expect(tvWatchlistItemFromShow(noPoster, '2026-07-07T00:00:00.000Z').posterUrl).toBe('');
  });

  it('carries the passed addedAt and tv_season type', () => {
    const item = tvWatchlistItemFromShow(show, '2026-07-07T00:00:00.000Z');
    expect(item.addedAt).toBe('2026-07-07T00:00:00.000Z');
    expect(item.type).toBe('tv_season');
  });
});

// Pins the CORRECTED UniversalSearch "Rank TV" preselect shape (B1): ranking a
// whole show from search must route through season selection, exactly like Save.
// The preselect therefore carries the numeric showTmdbId and NO seasonNumber —
// which AddTVSeasonModal's preselect router (showTmdbId set + seasonNumber falsy)
// sends to the season grid. If showTmdbId were absent the ceremony would mint a
// `tv_{showId}` tv_rankings row with show_tmdb_id=0 / season_number=0 (the C3
// corruption class). Genres are normalized so classifyBracket recognizes them.
describe('tvRankPreselectFromShow', () => {
  const show: TMDBTVShow = {
    id: 'tv_1396',
    tmdbId: 1396,
    name: 'Breaking Bad',
    year: '2008',
    posterUrl: '/poster.jpg',
    genres: ['Action & Adventure', 'Sci-Fi & Fantasy', 'Drama'],
    overview: '',
    seasonCount: 5,
    status: 'Ended',
    creators: ['Vince Gilligan'],
  };

  it('carries the numeric showTmdbId (routes through the season grid)', () => {
    expect(tvRankPreselectFromShow(show).showTmdbId).toBe(1396);
  });

  it('does NOT set a seasonNumber (whole-show preselect → season selection)', () => {
    expect(tvRankPreselectFromShow(show).seasonNumber).toBeUndefined();
  });

  it('satisfies the preselect-router season-grid predicate (showTmdbId set, seasonNumber falsy)', () => {
    const p = tvRankPreselectFromShow(show);
    // Mirrors AddTVSeasonModal:204 — this is the exact branch condition that
    // routes to the season grid instead of straight-to-tier.
    expect(Boolean(p.showTmdbId) && !p.seasonNumber).toBe(true);
  });

  it('normalizes compound TV genres', () => {
    expect(tvRankPreselectFromShow(show).genres).toEqual(['Action', 'Adventure', 'Sci-Fi']);
  });

  it('keeps the show id and tv_season type', () => {
    const p = tvRankPreselectFromShow(show);
    expect(p.id).toBe('tv_1396');
    expect(p.type).toBe('tv_season');
  });

  it('coalesces a null posterUrl to empty string', () => {
    expect(tvRankPreselectFromShow({ ...show, posterUrl: null }).posterUrl).toBe('');
  });
});

// Pins the CORRECTED deep-link re-rank dispatch (B5): re-rank routes by the
// item's OWN media type, never unconditionally into the movie ceremony (which
// would cross-write user_rankings + mint a movie stub for a tv/book id). The
// dispatch is exhaustive over MediaType.
describe('rerankMediaTarget', () => {
  it('routes a movie to the movie ceremony', () => {
    expect(rerankMediaTarget('movie')).toBe('movie');
  });

  it('routes a tv_season to the TV modal path (not the movie ceremony)', () => {
    expect(rerankMediaTarget('tv_season')).toBe('tv');
  });

  it('routes a book to the book modal path (not the movie ceremony)', () => {
    expect(rerankMediaTarget('book')).toBe('book');
  });
});

// Pins the canonical movie tmdb_id write-time contract (B1 preventive): Letterboxd
// import must write `tmdb_{n}`, never bare `{n}`, or engine exclusion, the
// taste-profile /tmdb_(\d+)/ regex, and cross-user comparison all break, and a
// second watchlist row can be minted for a movie a bare-id row already represents.
// Behavior matches DiscoverView.normalizeTmdbId (prefix iff not already prefixed;
// no numeric validation).
describe('canonicalMovieTmdbId', () => {
  it('leaves an already-prefixed id unchanged (idempotent)', () => {
    expect(canonicalMovieTmdbId('tmdb_603')).toBe('tmdb_603');
  });

  it('prefixes a bare numeric string', () => {
    expect(canonicalMovieTmdbId('603')).toBe('tmdb_603');
  });

  it('prefixes a numeric value', () => {
    expect(canonicalMovieTmdbId(603)).toBe('tmdb_603');
  });

  it('is idempotent when applied twice', () => {
    expect(canonicalMovieTmdbId(canonicalMovieTmdbId('603'))).toBe('tmdb_603');
    expect(canonicalMovieTmdbId(canonicalMovieTmdbId('tmdb_603'))).toBe('tmdb_603');
  });

  it('passes through non-numeric input by prefixing (matches DiscoverView.normalizeTmdbId, no validation)', () => {
    // DiscoverView.normalizeTmdbId only checks the `tmdb_` prefix; it never
    // validates the payload, so a non-numeric raw id is prefixed verbatim rather
    // than rejected. This helper reproduces that exact guard.
    expect(canonicalMovieTmdbId('abc')).toBe('tmdb_abc');
  });
});

// Pins the id-guarded re-rank completion decision (C4 movie lesson ported to
// tv/book, B2/B3): a completion is a re-rank MOVE only when a marker is set AND
// its id matches the item the user actually confirmed. A stale marker for a
// DIFFERENT id must never misclassify a fresh first-add as a move (which would
// suppress the ranking_add + wrongly compact a source tier). No marker → add.
describe('isRerankCompletion', () => {
  const mk = (id: string): RankedItem => ({
    id,
    title: 't',
    year: '2020',
    posterUrl: '',
    type: 'tv_season',
    genres: [],
    tier: Tier.B,
    rank: 0,
  });

  it('is false when no marker is set (plain first add)', () => {
    expect(isRerankCompletion(null, mk('tv_1_s1'))).toBe(false);
  });

  it('is true when the marker id matches the completed item', () => {
    expect(isRerankCompletion(mk('tv_1_s1'), mk('tv_1_s1'))).toBe(true);
  });

  it('is false when a stale marker points at a DIFFERENT id', () => {
    // User navigated back and ranked a different item — that item gets a genuine
    // first add (ranking_add), not a move against the stale marker's tier.
    expect(isRerankCompletion(mk('tv_1_s1'), mk('tv_2_s1'))).toBe(false);
  });
});

// Pins the hardened AddTVSeasonModal preselect router (audit B1 defense-in-depth):
// a whole-show preselect (`^tv_\d+$`, no seasonNumber) routes to the season grid
// with the show id DERIVED FROM THE ID even when showTmdbId is 0/absent (legacy
// corrupt rows). A season preselect (`^tv_\d+_s\d+$`) with showTmdbId=0 derives
// the show id from the id too, so re-ranking a corrupt row never mints MORE
// corruption (show_tmdb_id must be the real numeric show id, never 0).
describe('resolveTVPreselectRoute', () => {
  it('returns null for no preselect', () => {
    expect(resolveTVPreselectRoute(null)).toBeNull();
    expect(resolveTVPreselectRoute(undefined)).toBeNull();
  });

  it('routes a whole-show preselect (showTmdbId set, no season) to the season grid', () => {
    const r = resolveTVPreselectRoute({ id: 'tv_1399', showTmdbId: 1399 });
    expect(r).toEqual({ route: 'season-grid', showTmdbId: 1399 });
  });

  it('derives showTmdbId FROM a `tv_{n}` id when the field is absent', () => {
    const r = resolveTVPreselectRoute({ id: 'tv_1399' });
    expect(r).toEqual({ route: 'season-grid', showTmdbId: 1399 });
  });

  it('derives showTmdbId FROM a `tv_{n}` id when the field is 0 (legacy corrupt)', () => {
    const r = resolveTVPreselectRoute({ id: 'tv_1399', showTmdbId: 0 });
    expect(r).toEqual({ route: 'season-grid', showTmdbId: 1399 });
  });

  it('routes a full season preselect (season set) directly to tier', () => {
    const r = resolveTVPreselectRoute({ id: 'tv_1399_s2', showTmdbId: 1399, seasonNumber: 2 });
    expect(r).toEqual({ route: 'tier', showTmdbId: 1399 });
  });

  it('derives showTmdbId from a `tv_{n}_s{k}` id when showTmdbId is 0 (no more corruption)', () => {
    // A legacy corrupt season row (show_tmdb_id=0) still routes to tier, but the
    // derived show id feeds the global-score fetch instead of 0 — re-ranking it
    // never re-mints a 0 show id.
    const r = resolveTVPreselectRoute({ id: 'tv_1399_s2', showTmdbId: 0, seasonNumber: 2 });
    expect(r).toEqual({ route: 'tier', showTmdbId: 1399 });
  });

  it('routes a season preselect with a valid showTmdbId directly to tier', () => {
    const r = resolveTVPreselectRoute({ id: 'tv_1399_s2', showTmdbId: 1399, seasonNumber: 2 });
    expect(r?.route).toBe('tier');
  });

  it('leaves showTmdbId undefined when a season preselect id is not derivable and field is absent', () => {
    // Non-`tv_`-shaped id with no showTmdbId: nothing to derive; route to tier
    // with no show id (the global-score fetch is skipped, as before).
    const r = resolveTVPreselectRoute({ id: 'legacy_weird_id', seasonNumber: 2 });
    expect(r).toEqual({ route: 'tier', showTmdbId: undefined });
  });
});

// Pins the C5-Task-2 season-class self-heal seam (healTVPreselect). A legacy
// corrupt row (show_tmdb_id=0, id=`tv_123_s2`) reaches the tier step via
// resolveTVPreselectRoute which derives showTmdbId=123. Without healTVPreselect
// the component seeded the raw preselect (showTmdbId=0) verbatim — completion
// would then persist show_tmdb_id=0, re-minting corruption. healTVPreselect
// stamps the derived id back onto the item so the tier step and every downstream
// consumer (proceedFromNotes → onAdd → DB write) carry the real showTmdbId.
describe('healTVPreselect', () => {
  const mkItem = (id: string, showTmdbId: number): RankedItem => ({
    id,
    title: 'Test Show',
    year: '2020',
    posterUrl: '/p.jpg',
    type: 'tv_season',
    genres: ['Drama'],
    showTmdbId,
    seasonNumber: 2,
    tier: Tier.B,
    rank: 0,
  });

  it('stamps the derived show id onto a season-class corrupt item (showTmdbId=0)', () => {
    // Core assertion: this is the C5-Task-2 regression pin.
    const corrupt = mkItem('tv_123_s2', 0);
    const route = resolveTVPreselectRoute(corrupt);
    // route.showTmdbId must be 123 (derived from the id)
    expect(route?.showTmdbId).toBe(123);
    // healTVPreselect must flow that id back onto the item
    const healed = healTVPreselect(corrupt, route);
    expect(healed.showTmdbId).toBe(123);
  });

  it('preserves a valid showTmdbId when it is already correct (no-op)', () => {
    const good = mkItem('tv_123_s2', 123);
    const route = resolveTVPreselectRoute(good);
    const healed = healTVPreselect(good, route);
    expect(healed.showTmdbId).toBe(123);
  });

  it('returns the original object reference when no healing is needed', () => {
    const good = mkItem('tv_123_s2', 123);
    const route = resolveTVPreselectRoute(good);
    // No mutation: same reference
    expect(healTVPreselect(good, route)).toBe(good);
  });

  it('is a no-op when route is null', () => {
    const corrupt = mkItem('tv_123_s2', 0);
    expect(healTVPreselect(corrupt, null)).toBe(corrupt);
  });

  it('heals a whole-show corrupt item too (showTmdbId=0, id=tv_{n})', () => {
    const wholeShow: RankedItem = {
      id: 'tv_456',
      title: 'Show',
      year: '2019',
      posterUrl: '',
      type: 'tv_season',
      genres: [],
      showTmdbId: 0,
      tier: Tier.B,
      rank: 0,
    };
    const route = resolveTVPreselectRoute(wholeShow);
    const healed = healTVPreselect(wholeShow, route);
    expect(healed.showTmdbId).toBe(456);
  });

  it('does not mutate the original item (pure function)', () => {
    const corrupt = mkItem('tv_123_s2', 0);
    const original = { ...corrupt };
    const route = resolveTVPreselectRoute(corrupt);
    healTVPreselect(corrupt, route);
    expect(corrupt.showTmdbId).toBe(original.showTmdbId);
  });
});
