// services/agentShowtimesFragment.ts
//
// Pure parsing for the /agent-showtimes URL fragment (S2b).
//
// The agent composes:  https://rankspool.com/agent-showtimes#c=<uuid>
// where the card row id rides in the fragment (`#...`) — the same shape as
// /agent-rank, minus the JWT (this route reads PUBLIC data with the anon
// client, so no token is carried). We keep the id in the fragment for symmetry
// with /agent-rank and so it never lands in server logs.
//
// Pure (no window, no fetch) so it is unit-testable in isolation. The page reads
// location.hash and calls parseShowtimesFragment.
//
// Header last reviewed: 2026-07-12

// RFC 4122 UUID (any version), case-insensitive. gen_random_uuid() emits v4.
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface ParsedShowtimesFragment {
  /** the agent_showtimes_cards row id. */
  cardId: string;
}

/**
 * Parse a location.hash string into the card id.
 *
 * Accepts a leading `#` (as `window.location.hash` provides) or a bare param
 * string. Returns null when `c` is missing/empty or is not a well-formed UUID —
 * the page renders the friendly not-found state for any null.
 */
export function parseShowtimesFragment(hash: string): ParsedShowtimesFragment | null {
  if (!hash) return null;

  const raw = hash.startsWith('#') ? hash.slice(1) : hash;
  if (!raw) return null;

  const params = new URLSearchParams(raw);
  const cardId = params.get('c');

  if (!cardId || !UUID_RE.test(cardId)) return null;

  return { cardId };
}
