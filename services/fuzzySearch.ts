import { computeEditDistance } from './correctionService';
import { TMDBMovie } from './tmdbService';

/** True when the string contains any non-ASCII character (e.g. CJK). */
function hasNonAscii(s: string): boolean {
  for (let i = 0; i < s.length; i++) {
    if (s.charCodeAt(i) > 127) return true;
  }
  return false;
}

/**
 * Whether a query is long enough to fuzzy-match.
 * ASCII queries need at least 3 characters (typos on 1–2 letters are too noisy),
 * but CJK/non-ASCII queries carry more meaning per character, so 2 is allowed.
 */
function passesLengthGate(q: string): boolean {
  const min = hasNonAscii(q) ? 2 : 3;
  return q.length >= min;
}

/** Lowercase, trim, and strip a single leading article ("the ", "a ", "an "). */
function stripLeadingArticle(s: string): string {
  return s.toLowerCase().trim().replace(/^(the|a|an)\s+/, '');
}

/**
 * Build the candidate comparison windows for a title against a query of length
 * `qLen`. Windows are same-length prefixes of the normalized title and of each
 * word-start suffix, so a query can align against the raw title, the
 * article-stripped title, or any interior word ("redemption" in
 * "The Shawshank Redemption").
 */
function comparisonWindows(rawTitle: string, qLen: number): string[] {
  const windows = new Set<string>();
  const normalized = rawTitle.toLowerCase().trim();
  const stripped = stripLeadingArticle(rawTitle);

  const wordStarts = new Set<string>([normalized, stripped]);
  // Each interior word start (handles later words like "Redemption").
  for (const base of [normalized, stripped]) {
    let idx = base.indexOf(' ');
    while (idx !== -1) {
      wordStarts.add(base.slice(idx + 1));
      idx = base.indexOf(' ', idx + 1);
    }
  }

  for (const start of wordStarts) {
    if (!start) continue;
    // Same-length window (+1 slack) so a slightly longer/shorter typo still aligns.
    windows.add(start.length > qLen ? start.slice(0, qLen + 1) : start);
  }
  return Array.from(windows);
}

/** Best normalized edit-distance score (0..1, lower is better) of `q` against any window. */
function bestWindowScore(rawTitle: string, q: string): { score: number; distance: number } {
  let bestScore = Infinity;
  let bestDistance = Infinity;

  for (const window of comparisonWindows(rawTitle, q.length)) {
    const distance = computeEditDistance(q, window);
    const maxLen = Math.max(q.length, window.length) || 1;
    const score = distance / maxLen;
    if (score < bestScore) {
      bestScore = score;
      bestDistance = distance;
    }
  }
  return { score: bestScore, distance: bestDistance };
}

/**
 * Fuzzy-filter a list of items against a query string using Levenshtein distance.
 * Returns matches sorted by edit distance (best first).
 * Skips queries shorter than 3 chars (ASCII) or 2 chars (non-ASCII/CJK).
 */
export function fuzzyFilterLocal<T>(
  query: string,
  items: T[],
  titleExtractor: (item: T) => string,
  threshold = 0.3,
): T[] {
  const q = query.toLowerCase().trim();
  if (!passesLengthGate(q) || items.length === 0) return [];

  const qStripped = stripLeadingArticle(query);
  const scored: { item: T; distance: number }[] = [];

  for (const item of items) {
    const rawTitle = titleExtractor(item);
    const title = rawTitle.toLowerCase().trim();
    if (!title) continue;

    const titleStripped = stripLeadingArticle(rawTitle);

    // Check substring match first (cheap). Compare against both the raw and the
    // article-stripped forms of each side so "matrix" hits "The Matrix".
    // Only treat query-contains-title as a match when the title is long enough
    // relative to the query, to avoid short titles like "It" matching "limitless".
    const titleContainsQuery = title.includes(q) || titleStripped.includes(qStripped);
    const queryContainsTitle =
      (q.includes(title) || qStripped.includes(titleStripped)) &&
      titleStripped.length >= 4 &&
      titleStripped.length >= qStripped.length * 0.5;
    if (titleContainsQuery || queryContainsTitle) {
      scored.push({ item, distance: 0 });
      continue;
    }

    // Compare against the best same-length window (whole title, article-stripped
    // title, or any interior word start) for partial/typo matching.
    const { score, distance } = bestWindowScore(rawTitle, q);
    if (score <= threshold) {
      scored.push({ item, distance });
    }
  }

  scored.sort((a, b) => a.distance - b.distance);
  return scored.map(s => s.item);
}

/**
 * Find the closest matching title from a list of known titles.
 * Returns the best match if within threshold, or null.
 * Scores against the best-matching word-window of each candidate title, so a
 * short query can still correct against a much longer title.
 */
export function getBestCorrectedQuery(
  query: string,
  titles: string[],
  threshold = 0.3,
): string | null {
  const q = query.toLowerCase().trim();
  if (!passesLengthGate(q) || titles.length === 0) return null;

  let bestTitle: string | null = null;
  let bestDistance = Infinity;

  for (const title of titles) {
    const t = title.toLowerCase().trim();
    if (!t || t === q) continue;

    const { score, distance } = bestWindowScore(title, q);
    if (score <= threshold && distance < bestDistance) {
      bestDistance = distance;
      bestTitle = title;
    }
  }

  return bestTitle;
}

/**
 * Merge and deduplicate search results by tmdbId or normalized title.
 * Limits output to 12 items.
 */
export function mergeAndDedupSearchResults(results: TMDBMovie[]): TMDBMovie[] {
  const byKey = new Map<string, TMDBMovie>();

  for (const movie of results) {
    const key = movie.tmdbId > 0
      ? `tmdb:${movie.tmdbId}`
      : `title:${movie.title.toLowerCase().trim()}`;
    if (!byKey.has(key)) byKey.set(key, movie);
  }

  return Array.from(byKey.values()).slice(0, 12);
}
