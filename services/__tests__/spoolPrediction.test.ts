import { describe, it, expect } from 'vitest';
import { predictScore, computePredictionSignals } from '../spoolPrediction';
import { Tier, Bracket, PredictionSignals } from '../../types';

describe('computePredictionSignals', () => {
  const makeItem = (id: string, tier: Tier, rank: number, genres: string[], bracket?: Bracket, globalScore?: number) => ({
    id, title: id, year: '2020', posterUrl: '', type: 'movie' as const,
    genres, tier, rank, bracket, globalScore,
  });

  it('computes genre affinity from same-genre movies', () => {
    const items = [
      makeItem('1', Tier.A, 0, ['Horror'], Bracket.Commercial),
      makeItem('2', Tier.A, 1, ['Horror'], Bracket.Commercial),
      makeItem('3', Tier.B, 0, ['Comedy'], Bracket.Commercial),
    ];
    const signals = computePredictionSignals(items, 'Horror', Bracket.Commercial, undefined, Tier.A);
    expect(signals.genreAffinity).toBeGreaterThan(7);
    expect(signals.genreAffinity).toBeLessThan(9);
  });

  it('returns null genre affinity when no same-genre movies exist', () => {
    const items = [
      makeItem('1', Tier.A, 0, ['Comedy'], Bracket.Commercial),
    ];
    const signals = computePredictionSignals(items, 'Horror', Bracket.Commercial, undefined, Tier.A);
    expect(signals.genreAffinity).toBeNull();
  });

  it('returns global score mapped to tier range', () => {
    const signals = computePredictionSignals([], 'Horror', Bracket.Commercial, 7.5, Tier.A);
    expect(signals.globalScore).toBe(7.5);
  });

  it('clamps global score to tier range', () => {
    const signals = computePredictionSignals([], 'Horror', Bracket.Commercial, 9.5, Tier.A);
    expect(signals.globalScore).toBe(8.9);
  });

  it('returns null global score when undefined', () => {
    const signals = computePredictionSignals([], 'Horror', Bracket.Commercial, undefined, Tier.A);
    expect(signals.globalScore).toBeNull();
  });

  it('tracks totalRanked', () => {
    const items = [
      makeItem('1', Tier.A, 0, ['Horror'], Bracket.Commercial),
      makeItem('2', Tier.B, 0, ['Comedy'], Bracket.Commercial),
    ];
    const signals = computePredictionSignals(items, 'Horror', Bracket.Commercial, undefined, Tier.A);
    expect(signals.totalRanked).toBe(2);
  });
});

describe('predictScore', () => {
  it('uses all three signals with correct weights', () => {
    const signals: PredictionSignals = {
      genreAffinity: 8.0,
      globalScore: 7.5,
      bracketAffinity: 7.0,
      totalRanked: 20,
    };
    // 8.0*0.45 + 7.5*0.35 + 7.0*0.20 = 3.6 + 2.625 + 1.4 = 7.625
    const score = predictScore(signals, Tier.A);
    expect(score).toBeCloseTo(7.625, 1);
  });

  it('falls back to globalScore only for new users (<15 movies)', () => {
    const signals: PredictionSignals = {
      genreAffinity: 8.5,
      globalScore: 7.0,
      bracketAffinity: 8.0,
      totalRanked: 10,
    };
    const score = predictScore(signals, Tier.A);
    expect(score).toBe(7.0);
  });

  it('uses tier midpoint when no signals available for new user', () => {
    const signals: PredictionSignals = {
      genreAffinity: null,
      globalScore: null,
      bracketAffinity: null,
      totalRanked: 5,
    };
    const score = predictScore(signals, Tier.A);
    // A-tier midpoint: (7.0 + 8.9) / 2 = 7.95
    expect(score).toBeCloseTo(7.95, 1);
  });

  it('redistributes weights when some signals are null', () => {
    const signals: PredictionSignals = {
      genreAffinity: null,
      globalScore: 8.0,
      bracketAffinity: 7.0,
      totalRanked: 20,
    };
    // genreAffinity null -> redistribute 0.45 weight proportionally
    // globalScore weight: 0.35 / (0.35+0.20) = 0.636...
    // bracketAffinity weight: 0.20 / (0.35+0.20) = 0.363...
    // 8.0*0.636 + 7.0*0.364 = 5.091 + 2.545 = 7.636
    const score = predictScore(signals, Tier.A);
    expect(score).toBeCloseTo(7.636, 1);
  });

  it('clamps result to tier bounds', () => {
    const signals: PredictionSignals = {
      genreAffinity: 10.0,
      globalScore: 10.0,
      bracketAffinity: 10.0,
      totalRanked: 20,
    };
    const score = predictScore(signals, Tier.A);
    expect(score).toBeLessThanOrEqual(8.9);
    expect(score).toBeGreaterThanOrEqual(7.0);
  });
});
