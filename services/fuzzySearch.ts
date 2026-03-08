import { computeEditDistance } from './correctionService';
import { TMDBMovie } from './tmdbService';

/**
 * Fuzzy-filter a list of items against a query string using Levenshtein distance.
 * Returns matches sorted by edit distance (best first).
 * Skips queries shorter than 3 characters.
 */
export function fuzzyFilterLocal<T>(
  query: string,
  items: T[],
  titleExtractor: (item: T) => string,
  threshold = 0.3,
): T[] {
  const q = query.toLowerCase().trim();
  if (q.length < 3 || items.length === 0) return [];

  const scored: { item: T; distance: number }[] = [];

  for (const item of items) {
    const title = titleExtractor(item).toLowerCase().trim();
    if (!title) continue;

    // Check substring match first (cheap).
    // Only treat query-contains-title as a match when the title is long enough
    // relative to the query, to avoid short titles like "It" matching "limitless".
    if (title.includes(q) || (q.includes(title) && title.length >= 4 && title.length >= q.length * 0.5)) {
      scored.push({ item, distance: 0 });
      continue;
    }

    // Compare against the query-length prefix of the title for better partial matching
    const compareTarget = title.length > q.length ? title.slice(0, q.length + 2) : title;
    const distance = computeEditDistance(q, compareTarget);
    const maxLen = Math.max(q.length, compareTarget.length);
    const normalized = distance / maxLen;

    if (normalized <= threshold) {
      scored.push({ item, distance });
    }
  }

  scored.sort((a, b) => a.distance - b.distance);
  return scored.map(s => s.item);
}

/**
 * Find the closest matching title from a list of known titles.
 * Returns the best match if within threshold, or null.
 */
export function getBestCorrectedQuery(
  query: string,
  titles: string[],
  threshold = 0.3,
): string | null {
  const q = query.toLowerCase().trim();
  if (q.length < 3 || titles.length === 0) return null;

  let bestTitle: string | null = null;
  let bestDistance = Infinity;

  for (const title of titles) {
    const t = title.toLowerCase().trim();
    if (!t || t === q) continue;

    const distance = computeEditDistance(q, t);
    const maxLen = Math.max(q.length, t.length);
    const normalized = distance / maxLen;

    if (normalized <= threshold && distance < bestDistance) {
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
