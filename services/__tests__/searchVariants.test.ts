import { describe, expect, it } from 'vitest';
import { typoRetryVariants } from '../searchVariants';

describe('typoRetryVariants', () => {
  it('collapses an inner space first for "matri x"', () => {
    const variants = typoRetryVariants('matri x');
    expect(variants[0]).toBe('matrix');
  });

  it('progressively chops the trailing chars of a single-token typo', () => {
    // "shawshenk" -> chop 1 -> "shawshen", chop 2 -> "shawshe" (both >= 4 chars).
    // Single token, so no drop-last-token variant.
    expect(typoRetryVariants('shawshenk')).toEqual(['shawshen', 'shawshe']);
  });

  it('for multi-word "dark knigt": no collapse, chops the last token then drops it', () => {
    // No inner-only space to collapse (single space between two words is normal).
    // Last token "knigt" (5) -> "knig" (4). Chop-2 would be "kni" (3 < 4) so skipped.
    // Then drop-last-token -> "dark" (remainder >= 3 chars, >= 2 tokens).
    expect(typoRetryVariants('dark knigt')).toEqual(['dark knig', 'dark']);
  });

  it('returns [] for queries shorter than 4 chars', () => {
    expect(typoRetryVariants('ab')).toEqual([]);
  });

  it('returns [] for CJK-containing queries', () => {
    expect(typoRetryVariants('肖申克')).toEqual([]);
  });

  it('never includes the original query', () => {
    const q = 'shawshenk';
    expect(typoRetryVariants(q)).not.toContain(q);
  });

  it('dedupes when the collapse result equals the chop result', () => {
    // "matri x" -> collapse "matrix" (6). Chop last token "x" is trivial but the
    // collapsed form should never be duplicated by any later variant.
    const variants = typoRetryVariants('matri x');
    const unique = new Set(variants);
    expect(unique.size).toBe(variants.length);
  });

  it('trims and single-space normalizes before generating', () => {
    // Leading/trailing/interior extra whitespace should be normalized.
    expect(typoRetryVariants('  dark   knigt  ')).toEqual(['dark knig', 'dark']);
  });

  it('caps the number of variants at 3', () => {
    const variants = typoRetryVariants('interstellarr galaxy quest');
    expect(variants.length).toBeLessThanOrEqual(3);
  });

  it('does not chop when the last token would drop below 4 chars', () => {
    // "star warz" -> last token "warz" (4). Chop-1 -> "war" (3 < 4) skipped.
    // So no chop variants; drop-last-token -> "star" (>= 3).
    expect(typoRetryVariants('star warz')).toEqual(['star']);
  });

  it('does not drop the last token when the remainder is under 3 chars', () => {
    // "it knigt" -> last token "knigt" chops to "knig". Drop-last would leave "it" (2 < 3), skip.
    expect(typoRetryVariants('it knigt')).toEqual(['it knig']);
  });
});
