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

  it('matches a typo across a leading article ("shawshenk" → "The Shawshank Redemption")', () => {
    const items = [
      { title: 'The Shawshank Redemption' },
      { title: 'The Dark Knight' },
    ];

    const results = fuzzyFilterLocal('shawshenk', items, item => item.title);

    expect(results.map(item => item.title)).toContain('The Shawshank Redemption');
  });

  it('matches an exact query against a title behind a leading article ("matrix" → "The Matrix")', () => {
    const items = [
      { title: 'The Matrix' },
      { title: 'Inception' },
    ];

    const results = fuzzyFilterLocal('matrix', items, item => item.title);

    expect(results.map(item => item.title)).toContain('The Matrix');
  });

  it('matches a partial typo against a later word of the title ("redemtion" → "The Shawshank Redemption")', () => {
    const items = [
      { title: 'The Shawshank Redemption' },
      { title: 'The Dark Knight' },
    ];

    const results = fuzzyFilterLocal('redemtion', items, item => item.title);

    expect(results.map(item => item.title)).toContain('The Shawshank Redemption');
  });

  it('rejects unrelated titles at the 0.3 threshold', () => {
    const items = [
      { title: 'The Godfather' },
      { title: 'Pulp Fiction' },
      { title: 'Interstellar' },
    ];

    const results = fuzzyFilterLocal('shawshenk', items, item => item.title);

    expect(results).toEqual([]);
  });

  it('accepts a 2-char query when it contains non-ASCII (CJK)', () => {
    const items = [
      { title: '你好世界' },
      { title: 'The Matrix' },
    ];

    const results = fuzzyFilterLocal('你好', items, item => item.title);

    expect(results.map(item => item.title)).toContain('你好世界');
  });

  it('still rejects a 2-char ASCII query at the gate', () => {
    const items = [
      { title: 'It' },
      { title: 'The Matrix' },
    ];

    const results = fuzzyFilterLocal('it', items, item => item.title);

    expect(results).toEqual([]);
  });
});

describe('getBestCorrectedQuery', () => {
  it('returns the closest known title for a typo', () => {
    const corrected = getBestCorrectedQuery('godfatr', ['Godfather', 'Jaws']);

    expect(corrected).toBe('Godfather');
  });

  it('corrects a short query against a longer title via best word-window ("shawshenk" → "The Shawshank Redemption")', () => {
    const corrected = getBestCorrectedQuery('shawshenk', [
      'The Shawshank Redemption',
      'The Dark Knight',
    ]);

    expect(corrected).toBe('The Shawshank Redemption');
  });

  it('corrects across a leading article ("matrx" → "The Matrix")', () => {
    const corrected = getBestCorrectedQuery('matrx', ['The Matrix', 'Inception']);

    expect(corrected).toBe('The Matrix');
  });

  it('returns null when nothing is within the threshold', () => {
    const corrected = getBestCorrectedQuery('shawshenk', ['Pulp Fiction', 'Interstellar']);

    expect(corrected).toBeNull();
  });
});
