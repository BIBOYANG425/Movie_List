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
// interesting logic (cinema sort, distance format, hero runtime/rating line,
// per-format section grouping with a flat-times fallback, single-film header
// elision, chip linkouts, empty/loaded branching) is unit-testable in the node
// test env.
//
// Contract doc: docs/contracts/shared-payloads.md (§ agent_showtimes_cards).
//
// Header last reviewed: 2026-07-13

import { ticketLinkout } from '../lib/ticketLinkout';

// ── The frozen payload (v1) ──────────────────────────────────────────────────

/** A single screening time. `label` is the pre-formatted display string. */
export interface ShowtimeV1 {
  /** ISO start timestamp of the screening. */
  start: string;
  /** the display string for the chip, e.g. "7:30 PM". */
  label: string;
  /** per-showtime purchase deep link (AMC purchaseUrl), when the agent ships
   *  one. The chip opens THIS exact showing's checkout. Optional — old
   *  payloads and link-less sources omit it. */
  ticketUrl?: string;
}

/** A film's screenings at one cinema in a single presentation format. */
export interface ShowingV1 {
  /** the raw format string from the agent, e.g. "Standard", "IMAX", "Dolby Atmos". */
  format: string;
  times: ShowtimeV1[];
}

/** A film's screenings at one cinema. */
export interface CinemaFilmV1 {
  movieGluId: number;
  title: string;
  /** flat times (all formats mixed) — always present; the fallback for old payloads. */
  times: ShowtimeV1[];
  /**
   * format-grouped screenings, when the agent ships them. When present the page
   * renders one section per format (in payload order); when absent it falls back
   * to the flat `times` chips.
   */
  showings?: ShowingV1[];
}

/** A cinema and every film it is showing (for this card). */
export interface CinemaV1 {
  cinemaId: number;
  name: string;
  /** distance in miles, or null when the fetch could not place it. */
  distance: number | null;
  /** the cinema's street address, when the fetch carries one. */
  address?: string;
  /** cinema-level ticketing link — the chips' fallback when a showtime has no
   *  per-time deep link. Optional — old payloads omit it. */
  ticketUrl?: string;
  films: CinemaFilmV1[];
}

/** The single film a card is anchored to, or null for a "what's nearby" card. */
export interface ShowtimesFilmV1 {
  title: string;
  movieGluId: number;
  poster?: string;
  /** runtime in whole minutes, e.g. 115 → "1 HR 55 MIN". */
  runtimeMinutes?: number;
  /** MPAA-style rating, e.g. "PG-13". */
  rating?: string;
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

/**
 * A format section within a film row: a display header (e.g. "IMAX",
 * "DOLBY CINEMA") over a wrapped row of time chips. `label` is null for the
 * flat-times fallback (old payloads), in which case the page renders the chips
 * with NO header.
 */
export interface FormatSectionVM {
  /** the uppercase display label ("IMAX", "DOLBY CINEMA"), or null (no header). */
  label: string | null;
  chips: ShowtimeChipVM[];
}

/** A film's row within a cinema card. */
export interface CinemaFilmVM {
  movieGluId: number;
  title: string;
  /**
   * one section per presentation format (payload order), or a single
   * header-less section holding the flat `times` chips for old payloads.
   */
  sections: FormatSectionVM[];
}

/** A cinema card. */
export interface CinemaVM {
  cinemaId: number;
  name: string;
  /** pre-formatted distance ("2.3 mi") or null when unknown. */
  distanceLabel: string | null;
  /** the cinema's street address, or null when absent. */
  address: string | null;
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
      /**
       * the anchor film's metadata line ("1 HR 55 MIN | PG"), or null when the
       * film carries neither a runtime nor a rating (page omits the whole line).
       */
      filmMeta: string | null;
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
 * Format a whole-minutes runtime as "H HR MM MIN" (the AMC-style hero line):
 *   115 → "1 HR 55 MIN", 60 → "1 HR", 45 → "45 MIN", 120 → "2 HR".
 * Drops the empty half (no "0 MIN", no "0 HR"). Non-positive/non-finite → null.
 */
export function formatRuntime(minutes: number | null | undefined): string | null {
  if (minutes == null || !Number.isFinite(minutes) || minutes <= 0) return null;
  const total = Math.round(minutes);
  const hours = Math.floor(total / 60);
  const mins = total % 60;
  const parts: string[] = [];
  if (hours > 0) parts.push(`${hours} HR`);
  if (mins > 0) parts.push(`${mins} MIN`);
  return parts.length > 0 ? parts.join(' ') : null;
}

/**
 * Build the hero metadata line from a film's runtime + rating, joined by a thin
 * bar with spaces: "1 HR 55 MIN | PG". Either piece may be absent; when both are
 * absent the line is null and the page omits it entirely.
 */
export function formatFilmMeta(
  film: { runtimeMinutes?: number; rating?: string } | null | undefined,
): string | null {
  if (!film) return null;
  const runtime = formatRuntime(film.runtimeMinutes);
  const rating = film.rating?.trim() || null;
  const parts = [runtime, rating].filter((p): p is string => Boolean(p));
  return parts.length > 0 ? parts.join(' | ') : null;
}

/**
 * Map a raw payload format string to its uppercase display label:
 *   'Standard' → 'STANDARD', 'IMAX' → 'IMAX', anything containing 'dolby'
 *   (case-insensitive, e.g. "Dolby Atmos", "Dolby Cinema") → 'DOLBY CINEMA',
 *   else the raw string uppercased ('3D' → '3D', 'ScreenX' → 'SCREENX').
 */
export function formatDisplayFormat(format: string): string {
  const raw = format.trim();
  if (/dolby/i.test(raw)) return 'DOLBY CINEMA';
  return raw.toUpperCase();
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
 * translated nearby heading). Chips deep-link the exact showing when the
 * payload carries per-showtime ticket URLs; the film-title search is only the
 * legacy fallback for old payloads.
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
    address: cinema.address?.trim() || null,
    films: (cinema.films ?? []).map((film) => ({
      movieGluId: film.movieGluId,
      title: film.title,
      sections: buildFilmSections(film, cinema.ticketUrl),
    })),
  }));

  return {
    kind: 'loaded',
    filmTitle: payload.film?.title ?? null,
    poster: payload.film?.poster ?? null,
    filmMeta: formatFilmMeta(payload.film),
    singleFilm,
    locationLabel: payload.location?.label ?? null,
    asOf: payload.asOf,
    cinemas,
  };
}

/**
 * Build a film row's format sections. When the film carries `showings`, emit one
 * section per format (in payload order) with an uppercase display header. When
 * it does not (old flat payloads), emit a single header-less section holding the
 * flat `times` chips.
 *
 * Chip href priority (prod 2026-07-13 — the pills opened a Fandango title
 * search and could not purchase anything):
 *   1. the showtime's own ticketUrl (AMC per-showing checkout deep link)
 *   2. the cinema's ticketUrl (source-level fallback)
 *   3. ticketLinkout(film title) — legacy title search, old payloads only
 */
function buildFilmSections(film: CinemaFilmV1, cinemaTicketUrl?: string): FormatSectionVM[] {
  const chip = (time: ShowtimeV1): ShowtimeChipVM => ({
    label: time.label,
    start: time.start,
    href: time.ticketUrl?.trim() || cinemaTicketUrl?.trim() || ticketLinkout(film.title),
  });

  if (film.showings && film.showings.length > 0) {
    return film.showings.map((showing) => ({
      label: formatDisplayFormat(showing.format),
      chips: (showing.times ?? []).map(chip),
    }));
  }

  return [{ label: null, chips: (film.times ?? []).map(chip) }];
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

/**
 * Format the `asOf` ISO timestamp as a weekday + short date (e.g.
 * "Sun, Jul 13"), used as the first item in the context bar. Falsy/invalid
 * input → null so the page drops the piece rather than showing "Invalid Date".
 */
export function formatAsOfDate(asOf: string, locale?: string): string | null {
  if (!asOf) return null;
  const date = new Date(asOf);
  if (Number.isNaN(date.getTime())) return null;
  return date.toLocaleDateString(locale, {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
  });
}
