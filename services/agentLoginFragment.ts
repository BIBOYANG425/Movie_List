// services/agentLoginFragment.ts
//
// Pure parsing for the /agent-login URL fragment (P4 / Slice B2).
//
// The agent "Chris" composes:  https://rankspool.com/agent-login#lt=<token>
// where the login token rides in the fragment (`#...`) — the SAME reason as
// /agent-rank's JWT: a single-use secret must never reach servers, OG scrapers,
// or logs (query strings do, fragments do not). `lt` is a single-use, ~15-min
// login token minted agent-side into hana.login_links; it is NOT a JWT (the
// user is not yet signed in when the link is tapped).
//
// Pure (no window, no fetch) so it is unit-testable in isolation. The page reads
// location.hash, calls parseLoginFragment, then strips the hash from the address
// bar (history.replaceState) so the token never lingers — mirroring
// AgentRankPage.
//
// Header last reviewed: 2026-07-12

export interface ParsedLoginFragment {
  /** the single-use login token (raw, exactly as sent). */
  token: string;
}

/**
 * Parse a location.hash string into the login token.
 *
 * Accepts a leading `#` (as `window.location.hash` provides) or a bare param
 * string. Returns null when `lt` is missing or empty — the page renders the
 * friendly "needs a fresh link" state for any null.
 */
export function parseLoginFragment(hash: string): ParsedLoginFragment | null {
  if (!hash) return null;

  const raw = hash.startsWith('#') ? hash.slice(1) : hash;
  if (!raw) return null;

  const params = new URLSearchParams(raw);
  const token = params.get('lt');

  if (!token) return null;

  return { token };
}
