/**
 * Pure query-variant generator for zero-result typo-retry backoff.
 *
 * TMDB search has no typo tolerance ("shawshenk" → 0 results) but strong prefix
 * matching ("shawsh" → hits). When a primary search returns nothing, callers can
 * retry with these cheap deterministic variants, ordered cheapest-first, and take
 * the first non-empty result set.
 *
 * This module is pure (no I/O) so it is trivially unit-testable and shared by both
 * `searchMovies` and `searchTVShows` in tmdbService.ts.
 */

/** Matches any CJK character (Hiragana/Katakana + CJK Unified Ideographs). */
const CJK_RE = /[぀-ヿ㐀-鿿]/;

const MIN_QUERY_LEN = 4;
const MIN_CHOP_TOKEN_LEN = 4;
const MIN_DROP_REMAINDER_LEN = 3;
const MAX_VARIANTS = 3;

/**
 * Build up to 3 deduped retry variants for *q*, cheapest-first, never including the
 * original normalized query. Returns [] for queries that are too short or CJK
 * (TMDB handles CJK; chopping CJK characters is nonsense).
 *
 * Variant order:
 *   1. inner-whitespace collapse — only when the LAST token is a single stray
 *      char ("matri x" → "matrix"); two legitimate words are never merged
 *   2. last-token trailing chop by 1 then 2 chars — only while the chopped token stays ≥ 4 chars
 *   3. drop the last token entirely — only if ≥ 2 tokens and the remainder is ≥ 3 chars
 */
export function typoRetryVariants(q: string): string[] {
  const normalized = q.trim().replace(/\s+/g, ' ');

  if (normalized.length < MIN_QUERY_LEN) return [];
  if (CJK_RE.test(normalized)) return [];

  const variants: string[] = [];
  const seen = new Set<string>([normalized]);

  const push = (candidate: string) => {
    if (variants.length >= MAX_VARIANTS) return;
    if (!candidate || seen.has(candidate)) return;
    seen.add(candidate);
    variants.push(candidate);
  };

  const tokens = normalized.split(' ');

  // 1. Inner-whitespace collapse for the fat-finger stray-space case (e.g.
  // "matri x" -> "matrix"). We only collapse when the last token is a single
  // stray character; two legitimate words ("dark knigt", "star warz") must NOT
  // be mashed into one blob.
  if (tokens.length >= 2 && tokens[tokens.length - 1].length === 1) {
    push(normalized.replace(/ /g, ''));
  }

  // 2. Progressive trailing-char chop on the last token ("shawshenk" -> "shawshen"
  // -> "shawshe"), stopping once the chopped token would fall below 4 chars.
  const lastToken = tokens[tokens.length - 1];
  const prefix = tokens.slice(0, -1).join(' ');
  for (let chop = 1; chop <= 2; chop++) {
    const chopped = lastToken.slice(0, lastToken.length - chop);
    if (chopped.length < MIN_CHOP_TOKEN_LEN) break;
    push(prefix ? `${prefix} ${chopped}` : chopped);
  }

  // 3. Drop the last token entirely, only for multi-token queries whose remainder
  // still carries enough signal (≥ 3 chars).
  if (tokens.length >= 2 && prefix.length >= MIN_DROP_REMAINDER_LEN) {
    push(prefix);
  }

  return variants.slice(0, MAX_VARIANTS);
}
