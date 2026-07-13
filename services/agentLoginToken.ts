// services/agentLoginToken.ts
//
// The sessionStorage handoff for the /agent-login token (P4 / Slice B2).
//
// The login token arrives in the /agent-login fragment. Email/password auth
// stays on-page, but Google OAuth navigates AWAY (to Google, then back to
// /auth/callback), which drops the fragment. To survive that round-trip we
// stash the token in sessionStorage the moment we parse it, and /auth/callback
// checks for it so it can route back to /agent-login (instead of /app) to run
// the consume step. sessionStorage (not localStorage) so the token dies with
// the tab and never outlives the one-shot flow.
//
// Header last reviewed: 2026-07-12

export const AGENT_LOGIN_TOKEN_KEY = 'spool.agentLoginToken';

/** Best-effort persist — a storage failure (private mode, quota) is non-fatal;
 *  the on-page email/password path still works from the parsed fragment. */
export function stashAgentLoginToken(token: string): void {
  try {
    window.sessionStorage.setItem(AGENT_LOGIN_TOKEN_KEY, token);
  } catch {
    /* no-op */
  }
}

export function readAgentLoginToken(): string | null {
  try {
    return window.sessionStorage.getItem(AGENT_LOGIN_TOKEN_KEY);
  } catch {
    return null;
  }
}

export function clearAgentLoginToken(): void {
  try {
    window.sessionStorage.removeItem(AGENT_LOGIN_TOKEN_KEY);
  } catch {
    /* no-op */
  }
}
