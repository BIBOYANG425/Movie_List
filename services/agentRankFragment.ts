// services/agentRankFragment.ts
//
// Pure parsing for the /agent-rank URL fragment (P3-B, task B1).
//
// The agent composes:  https://rankspool.com/agent-rank#t=<jwt>&m=<media_id>
// where the fragment (`#...`) NEVER reaches servers/logs. `t` is a short-TTL
// per-user Supabase JWT; `m` is the media id the ceremony pre-seeds, in the
// app's own id shape: `tmdb_<n>` for a movie, `tv_<n>` for a TV title.
//
// This module is pure (no window, no fetch) so it is unit-testable in isolation.
// The page reads location.hash, calls parseRankFragment, then strips the hash
// from the address bar (history.replaceState) so the token never lingers.
//
// Header last reviewed: 2026-07-12

export type RankMediaKind = 'movie' | 'tv';

export interface ParsedRankFragment {
  /** the short-TTL JWT (raw, exactly as sent). */
  token: string;
  /** the raw media id as sent, e.g. `tmdb_603` or `tv_1396`. */
  mediaId: string;
  /** which media table the id targets. */
  kind: RankMediaKind;
  /** the numeric TMDB id parsed out of `mediaId`. */
  tmdbNumericId: number;
}

/**
 * Parse a location.hash string into the token + media descriptor.
 *
 * Accepts a leading `#` (as `window.location.hash` provides) or a bare param
 * string. Returns null when the token is missing/empty, the media id is
 * missing, or the media id is not a recognized `tmdb_<n>` / `tv_<n>` shape —
 * the page renders a friendly "needs a fresh link" state for any null.
 */
export function parseRankFragment(hash: string): ParsedRankFragment | null {
  if (!hash) return null;

  const raw = hash.startsWith('#') ? hash.slice(1) : hash;
  if (!raw) return null;

  const params = new URLSearchParams(raw);
  const token = params.get('t');
  const mediaId = params.get('m');

  if (!token || !mediaId) return null;

  const media = parseMediaId(mediaId);
  if (!media) return null;

  return { token, mediaId, kind: media.kind, tmdbNumericId: media.tmdbNumericId };
}

/**
 * Split a media id into { kind, tmdbNumericId }. `tmdb_<n>` → movie,
 * `tv_<n>` → tv. Returns null for any other shape or a non-positive id.
 */
export function parseMediaId(
  mediaId: string,
): { kind: RankMediaKind; tmdbNumericId: number } | null {
  const movie = /^tmdb_(\d+)$/.exec(mediaId);
  if (movie) {
    const n = Number(movie[1]);
    return n > 0 ? { kind: 'movie', tmdbNumericId: n } : null;
  }

  const tv = /^tv_(\d+)$/.exec(mediaId);
  if (tv) {
    const n = Number(tv[1]);
    return n > 0 ? { kind: 'tv', tmdbNumericId: n } : null;
  }

  return null;
}
