import { describe, it, expect } from 'vitest';
import {
  detectCorrectionType,
  computeEditDistance,
  computeArrayDiff,
  hasChanged,
} from '../correctionService';

describe('detectCorrectionType', () => {
  it('returns accept for identical strings', () => {
    expect(detectCorrectionType('hello', 'hello', 'text')).toBe('accept');
  });

  it('returns add for empty to content', () => {
    expect(detectCorrectionType('', 'new content', 'text')).toBe('add');
  });

  it('returns remove for content to empty', () => {
    expect(detectCorrectionType('some content', '', 'text')).toBe('remove');
  });

  it('returns edit for small changes', () => {
    expect(detectCorrectionType('hello world', 'hello there', 'text')).toBe('edit');
  });

  it('returns rewrite for >80% different text', () => {
    expect(detectCorrectionType('hello', 'completely different text here', 'text')).toBe('rewrite');
  });

  it('returns rewrite for completely different arrays', () => {
    // For arrays, the original and final are JSON stringified arrays
    expect(detectCorrectionType(
      JSON.stringify(['a', 'b', 'c']),
      JSON.stringify(['x', 'y', 'z']),
      'array'
    )).toBe('rewrite');
  });

  it('returns edit for partially changed arrays', () => {
    expect(detectCorrectionType(
      JSON.stringify(['a', 'b', 'c']),
      JSON.stringify(['a', 'b', 'd']),
      'array'
    )).toBe('edit');
  });

  it('returns accept for identical arrays', () => {
    expect(detectCorrectionType(
      JSON.stringify(['a', 'b']),
      JSON.stringify(['a', 'b']),
      'array'
    )).toBe('accept');
  });

  it('returns add for empty array to non-empty array', () => {
    expect(detectCorrectionType(
      JSON.stringify([]),
      JSON.stringify(['a', 'b']),
      'array'
    )).toBe('add');
  });

  it('returns remove for non-empty array to empty array', () => {
    expect(detectCorrectionType(
      JSON.stringify(['a', 'b']),
      JSON.stringify([]),
      'array'
    )).toBe('remove');
  });
});

describe('computeEditDistance', () => {
  it('returns 0 for identical strings', () => {
    expect(computeEditDistance('hello', 'hello')).toBe(0);
  });

  it('returns 1 for single char difference', () => {
    expect(computeEditDistance('hello', 'hallo')).toBe(1);
  });

  it('returns correct distance for completely different strings', () => {
    expect(computeEditDistance('abc', 'xyz')).toBe(3);
  });

  it('handles empty strings', () => {
    expect(computeEditDistance('', 'hello')).toBe(5);
    expect(computeEditDistance('hello', '')).toBe(5);
  });

  it('returns 0 for two empty strings', () => {
    expect(computeEditDistance('', '')).toBe(0);
  });

  it('handles insertion at end', () => {
    expect(computeEditDistance('hello', 'hellos')).toBe(1);
  });

  it('handles deletion', () => {
    expect(computeEditDistance('hellos', 'hello')).toBe(1);
  });
});

describe('computeArrayDiff', () => {
  it('returns all kept for identical arrays', () => {
    const result = computeArrayDiff(['a', 'b'], ['a', 'b']);
    expect(result.kept).toEqual(['a', 'b']);
    expect(result.added).toEqual([]);
    expect(result.removed).toEqual([]);
  });

  it('detects added items', () => {
    const result = computeArrayDiff(['a'], ['a', 'b']);
    expect(result.added).toEqual(['b']);
  });

  it('detects removed items', () => {
    const result = computeArrayDiff(['a', 'b'], ['a']);
    expect(result.removed).toEqual(['b']);
  });

  it('handles mixed changes', () => {
    const result = computeArrayDiff(['a', 'b', 'c'], ['a', 'd']);
    expect(result.kept).toEqual(['a']);
    expect(result.added).toEqual(['d']);
    expect(result.removed).toEqual(['b', 'c']);
  });

  it('handles empty original', () => {
    const result = computeArrayDiff([], ['a', 'b']);
    expect(result.kept).toEqual([]);
    expect(result.added).toEqual(['a', 'b']);
    expect(result.removed).toEqual([]);
  });

  it('handles empty final', () => {
    const result = computeArrayDiff(['a', 'b'], []);
    expect(result.kept).toEqual([]);
    expect(result.added).toEqual([]);
    expect(result.removed).toEqual(['a', 'b']);
  });

  it('handles both empty', () => {
    const result = computeArrayDiff([], []);
    expect(result.kept).toEqual([]);
    expect(result.added).toEqual([]);
    expect(result.removed).toEqual([]);
  });
});

describe('hasChanged', () => {
  it('returns false for identical strings', () => {
    expect(hasChanged('same', 'same')).toBe(false);
  });

  it('returns true for different strings', () => {
    expect(hasChanged('original', 'modified')).toBe(true);
  });

  it('returns false for two empty strings', () => {
    expect(hasChanged('', '')).toBe(false);
  });

  it('returns true when original is empty and final has content', () => {
    expect(hasChanged('', 'content')).toBe(true);
  });
});
