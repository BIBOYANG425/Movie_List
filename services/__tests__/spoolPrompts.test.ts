import { describe, it, expect } from 'vitest';
import { getComparisonPrompt } from '../spoolPrompts';
import { Tier } from '../../types';

describe('getComparisonPrompt', () => {
  it('returns genre prompt when both movies share a known genre', () => {
    const prompt = getComparisonPrompt(Tier.A, 'Horror', 'Horror', 'probe');
    expect(prompt).toBe('Which one unsettled you more?');
  });

  it('returns tier prompt for cross-genre phase', () => {
    const prompt = getComparisonPrompt(Tier.A, 'Horror', 'Drama', 'cross_genre');
    expect(prompt).toBe('Which experience stayed with you longer?');
  });

  it('returns tier prompt when genres differ in non-cross-genre phase', () => {
    const prompt = getComparisonPrompt(Tier.B, 'Horror', 'Comedy', 'probe');
    expect(prompt).toBe('Which one did you enjoy more in the moment?');
  });

  it('returns tier prompt for unknown genre', () => {
    const prompt = getComparisonPrompt(Tier.S, 'Western', 'Western', 'probe');
    expect(prompt).toBe('Which one changed something in you?');
  });

  it('returns correct prompts for each tier', () => {
    expect(getComparisonPrompt(Tier.S, 'Drama', 'Drama', 'probe')).toContain('closer to home');
    expect(getComparisonPrompt(Tier.D, 'Drama', 'Drama', 'probe')).toContain('forgettable');
  });
});
