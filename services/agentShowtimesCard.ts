// services/agentShowtimesCard.ts
//
// The frozen payload contract for the /agent-showtimes web card (S2b) plus the
// PURE view-model derivation the page renders. The agent (spool-agent) is built
// against `ShowtimesCardPayloadV1` verbatim and writes it into
// `agent_showtimes_cards.payload`; the web route reads it back with the anon
// client and hands it to `buildShowtimesView`.
//
// Keeping the derivation pure (no window, no fetch, no React) mirrors
// agentRankFragment.ts: the page is a thin JSX map over this view model, and the
// interesting logic (cinema sort, distance format, single-film header elision,
// chip linkouts, empty/loaded branching) is unit-testable in the node test env.
//
// Contract doc: docs/contracts/shared-payloads.md (§ agent_showtimes_cards).
//
// Header last reviewed: 2026-07-12

import { ticketLinkout } from '../lib/ticketLinkout';

// ── The frozen payload (v1) ──────────────────────────────────────────────────

/** A single screening time. `label` is the pre-formatted display string. */
export interface ShowtimeV1 {
  /** ISO start timestamp of the screening. */
  start: string;
  /** the display string for the chip, e.g. "7:30 PM". */
  label: string;
}

/** A film's screenings at one cinema. */
export interface CinemaFilmV1 {
  movieGluId: number;
  title: string;
  times: ShowtimeV1[];
}

/** A cinema and every film it is showing (for this card). */
export interface CinemaV1 {
  cinemaId: number;
  name: string;
  /** distance in miles, or null when the fetch could not place it. */
  distance: number | null;
  films: CinemaFilmV1[];
}

/** The single film a card is anchored to, or null for a "what's nearby" card. */
export interface ShowtimesFilmV1 {
  title: string;
  movieGluId: number;
  poster?: string;
}

/** The full jsonb payload written to `agent_showtimes_cards.payload`. */
export interface ShowtimesCardPayloadV1 {
  v: 1;
  /** ISO timestamp of the listings fetch. */
  asOf: string;
  /** 'XX' sandbox | 'US' live. */
  territory: string;
  location: { lat: number; lng: number; label?: string };
  /** the anchor film, or null → a "what's playing near you" card. */
  film: ShowtimesFilmV1 | null;
  cinemas: CinemaV1[];
}

// ── The derived view model the page renders ──────────────────────────────────

/** A single tappable time chip. */
export interface ShowtimeChipVM {
  label: string;
  start: string;
  /** the ticketing linkout for this chip (see lib/ticketLinkout.ts). */
  href: string;
}

/** A film's row within a cinema card. */
export interface CinemaFilmVM {
  movieGluId: number;
  title: string;
  chips: ShowtimeChipVM[];
}

/** A cinema card. */
export interface CinemaVM {
  cinemaId: number;
  name: string;
  /** pre-formatted distance ("2.3 mi") or null when unknown. */
  distanceLabel: string | null;
  films: CinemaFilmVM[];
}

/**
 * The loaded view model:
 *  - `singleFilm` true → the card is anchored to one film; the page skips the
 *    per-cinema film header (it would just repeat the page header).
 *  - `cinemas` empty (kind === 'empty') → the page renders the empty state.
 */
export type ShowtimesView =
  | {
      kind: 'loaded';
      /**
       * the anchor film's title for a single-film card, else null (a "what's
       * nearby" card). The page composes the heading from this so the wording
       * stays translatable via the i18n table.
       */
      filmTitle: string | null;
      /** the anchor film's poster, when present. */
      poster: string | null;
      /** true when the card is a single-film card (elide per-cinema headers). */
      singleFilm: boolean;
      /** location.label when the payload carries one, else null. */
      locationLabel: string | null;
      /** the raw asOf ISO (page formats it to local time). */
      asOf: string;
      cinemas: CinemaVM[];
    }
  | { kind: 'empty' };

// ── Pure helpers ─────────────────────────────────────────────────────────────

/**
 * Format a miles distance for display. `null` → null (page shows nothing).
 * One decimal, always with the "mi" unit, e.g. 2.34 → "2.3 mi", 3 → "3.0 mi".
 */
export function formatDistance(distance: number | null): string | null {
  if (distance == null || !Number.isFinite(distance)) return null;
  return `${distance.toFixed(1)} mi`;
}

/**
 * Sort cinemas by distance ascending, with unknown distances (null) last.
 * Stable for equal distances (preserves the payload's cinema order). Does not
 * mutate the input.
 */
export function sortCinemasByDistance(cinemas: CinemaV1[]): CinemaV1[] {
  return cinemas
    .map((c, i) => ({ c, i }))
    .sort((a, b) => {
      const da = a.c.distance;
      const db = b.c.distance;
      if (da == null && db == null) return a.i - b.i;
      if (da == null) return 1;
      if (db == null) return -1;
      if (da === db) return a.i - b.i;
      return da - db;
    })
    .map((x) => x.c);
}

/**
 * Build the render-ready view model from a raw payload.
 *
 * `filmTitle` is the anchor film's title for a single-film card (the page reads
 * "showtimes <title>") or null for a "what's nearby" card (the page reads its
 * translated nearby heading). Chip linkouts always use the FILM row's title, so
 * a "what's nearby" card still links each film to its own Fandango search.
 *
 * An empty `cinemas` array collapses to `{ kind: 'empty' }` so the page can
 * render the not-found-style "nothing showing near you right now" state.
 */
export function buildShowtimesView(payload: ShowtimesCardPayloadV1): ShowtimesView {
  if (!payload.cinemas || payload.cinemas.length === 0) {
    return { kind: 'empty' };
  }

  const singleFilm = payload.film != null;

  const cinemas: CinemaVM[] = sortCinemasByDistance(payload.cinemas).map((cinema) => ({
    cinemaId: cinema.cinemaId,
    name: cinema.name,
    distanceLabel: formatDistance(cinema.distance),
    films: (cinema.films ?? []).map((film) => ({
      movieGluId: film.movieGluId,
      title: film.title,
      chips: (film.times ?? []).map((time) => ({
        label: time.label,
        start: time.start,
        href: ticketLinkout(film.title),
      })),
    })),
  }));

  return {
    kind: 'loaded',
    filmTitle: payload.film?.title ?? null,
    poster: payload.film?.poster ?? null,
    singleFilm,
    locationLabel: payload.location?.label ?? null,
    asOf: payload.asOf,
    cinemas,
  };
}

/**
 * Format the `asOf` ISO timestamp as a short local time (e.g. "7:30 PM"), used
 * in the header subline. Falsy/invalid input → null so the page drops the
 * subline rather than showing "Invalid Date".
 */
export function formatAsOfTime(asOf: string, locale?: string): string | null {
  if (!asOf) return null;
  const date = new Date(asOf);
  if (Number.isNaN(date.getTime())) return null;
  return date.toLocaleTimeString(locale, { hour: 'numeric', minute: '2-digit' });
}
