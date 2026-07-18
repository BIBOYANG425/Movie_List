// services/agentSeatsFragment.ts
//
// Pure parsing for the /agent-seats URL fragment (seat hunt).
//
// The agent composes:  https://rankspool.com/agent-seats#h=<uuid>
// where the agent_seat_holds row id rides in the fragment. Same shape as
// /agent-showtimes (#c=), minus any JWT — the seat card reads with the anon
// client (seats/price/purchase-url are not sensitive; the row id is an
// unguessable UUID). Pure (no window, no fetch) so it is unit-testable.
//
// Header last reviewed: 2026-07-18

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface ParsedSeatsFragment {
  /** the agent_seat_holds row id. */
  holdId: string;
}

/**
 * Parse a location.hash into the hold id. Accepts a leading `#` or a bare param
 * string. Returns null when `h` is missing/empty or not a well-formed UUID.
 */
export function parseSeatsFragment(hash: string): ParsedSeatsFragment | null {
  if (!hash) return null;
  const raw = hash.startsWith('#') ? hash.slice(1) : hash;
  if (!raw) return null;
  const holdId = new URLSearchParams(raw).get('h');
  if (!holdId || !UUID_RE.test(holdId)) return null;
  return { holdId };
}
