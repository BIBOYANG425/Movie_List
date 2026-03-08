import { describe, expect, it } from 'vitest';
import { fuzzyFilterLocal, getBestCorrectedQuery } from '../fuzzySearch';

describe('fuzzyFilterLocal', () => {
  it('does not treat short embedded titles as perfect matches', () => {
    const items = [
      { title: 'It' },
      { title: 'Limitless' },
      { title: 'The Italian Job' },
    ];

    const results = fuzzyFilterLocal('limitless', items, item => item.title);

    expect(results.map(item => item.title)).toEqual(['Limitless']);
  });

  it('still allows longer partial titles contained in the query', () => {
    const items = [
      { title: 'Godfather' },
      { title: 'Jaws' },
    ];

    const results = fuzzyFilterLocal('godfather ii', items, item => item.title);

    expect(results.map(item => item.title)).toContain('Godfather');
  });
});

describe('getBestCorrectedQuery', () => {
  it('returns the closest known title for a typo', () => {
    const corrected = getBestCorrectedQuery('godfatr', ['Godfather', 'Jaws']);

    expect(corrected).toBe('Godfather');
  });
});
