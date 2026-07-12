// lib/ticketLinkout.ts
//
// The SINGLE place that turns a film title into a ticketing URL for the
// /agent-showtimes card's time chips (S2b). Deliberately one module: a future
// affiliate wrap (FlexOffers) changes ONLY this file, and every chip on the
// card routes through it, so the swap is atomic. Today it points at a Fandango
// title search; the chips open it with target="_blank" rel="noopener".
//
// Pure (no window, no fetch) so it is unit-testable in the node test env.
//
// Header last reviewed: 2026-07-12

/**
 * Build the ticketing linkout URL for a film title.
 *
 * @param filmTitle  the display title of the film, e.g. "Dune: Part Two".
 * @returns a Fandango search URL with the title URI-encoded. When a future
 *          affiliate program lands, wrap the return here and nothing else moves.
 */
export function ticketLinkout(filmTitle: string): string {
  return `https://www.fandango.com/search?q=${encodeURIComponent(filmTitle)}`;
}
