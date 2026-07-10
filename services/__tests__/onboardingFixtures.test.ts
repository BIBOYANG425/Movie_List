/**
 * Spec for the anonymous-onboarding curated fixture pool.
 *
 * The web bundle no longer ships a TMDB key, so the live suggestions/search
 * seams 401 for signed-out users. MovieOnboardingPage falls back to this static
 * pool so the try-before-signup funnel (pick ≥10 → "Create your account") keeps
 * working with zero network calls. That only holds if every pooled entry has the
 * exact shape the onboarding grid + tier modal render:
 *   - id well-formed `tmdb_{n}` and unique
 *   - tmdbId a positive integer matching the id suffix
 *   - non-empty title, year, and a poster URL on the keyless image.tmdb.org CDN
 *   - genres an array
 * These asserts pin the contract; a malformed or duplicate entry would silently
 * break a real signup, so this fails loudly instead.
 */

import { describe, it, expect } from 'vitest';
import {
  ONBOARDING_FIXTURE_MOVIES,
  toTMDBMovie,
  shuffledFixturePool,
} from '../onboardingFixtures';
import { TMDB_IMAGE_BASE } from '../tmdbService';
import { MIN_MOVIES_FOR_SCORES } from '../../constants';

describe('ONBOARDING_FIXTURE_MOVIES', () => {
  it('has enough entries to pick well past the onboarding threshold', () => {
    // The user must pick MIN_MOVIES_FOR_SCORES; a curated pool of ~48 gives ample
    // headroom for "pick ones you know" plus Refresh paging.
    expect(ONBOARDING_FIXTURE_MOVIES.length).toBeGreaterThanOrEqual(
      MIN_MOVIES_FOR_SCORES * 2,
    );
    expect(ONBOARDING_FIXTURE_MOVIES.length).toBeGreaterThanOrEqual(40);
  });

  it('every entry carries the required onboarding fields', () => {
    for (const m of ONBOARDING_FIXTURE_MOVIES) {
      expect(typeof m.id).toBe('string');
      expect(typeof m.tmdbId).toBe('number');
      expect(Number.isInteger(m.tmdbId)).toBe(true);
      expect(m.tmdbId).toBeGreaterThan(0);
      expect(m.title.trim().length).toBeGreaterThan(0);
      expect(m.year.trim().length).toBeGreaterThan(0);
      expect(Array.isArray(m.genres)).toBe(true);
      expect(typeof m.overview).toBe('string');
    }
  });

  it('ids are well-formed tmdb_{n} and agree with tmdbId', () => {
    for (const m of ONBOARDING_FIXTURE_MOVIES) {
      const match = m.id.match(/^tmdb_(\d+)$/);
      expect(match, `id ${m.id} must be tmdb_{n}`).not.toBeNull();
      expect(Number(match![1])).toBe(m.tmdbId);
    }
  });

  it('ids and tmdbIds are unique across the pool', () => {
    const ids = ONBOARDING_FIXTURE_MOVIES.map(m => m.id);
    const tmdbIds = ONBOARDING_FIXTURE_MOVIES.map(m => m.tmdbId);
    expect(new Set(ids).size).toBe(ids.length);
    expect(new Set(tmdbIds).size).toBe(tmdbIds.length);
  });

  it('poster URLs point at the keyless TMDB image CDN', () => {
    for (const m of ONBOARDING_FIXTURE_MOVIES) {
      expect(m.posterUrl.startsWith(TMDB_IMAGE_BASE)).toBe(true);
      // A real poster path, not an empty CDN base.
      expect(m.posterUrl.length).toBeGreaterThan(TMDB_IMAGE_BASE.length + 4);
      expect(m.posterUrl).toMatch(/\.(jpg|png)$/);
    }
  });

  it('spans multiple decades so the grid is not single-era', () => {
    const decades = new Set(
      ONBOARDING_FIXTURE_MOVIES.map(m => m.year.slice(0, 3)),
    );
    expect(decades.size).toBeGreaterThanOrEqual(4);
  });
});

describe('toTMDBMovie', () => {
  it('widens a fixture entry to a full live-suggestion TMDBMovie shape', () => {
    const widened = toTMDBMovie(ONBOARDING_FIXTURE_MOVIES[0]);
    expect(widened.type).toBe('movie');
    expect(widened.backdropUrl).toBeNull();
    expect(widened.id).toBe(ONBOARDING_FIXTURE_MOVIES[0].id);
    expect(widened.tmdbId).toBe(ONBOARDING_FIXTURE_MOVIES[0].tmdbId);
    expect(widened.posterUrl).toBe(ONBOARDING_FIXTURE_MOVIES[0].posterUrl);
  });
});

describe('shuffledFixturePool', () => {
  it('returns every pooled movie exactly once (no drops, no dups)', () => {
    const pool = shuffledFixturePool();
    expect(pool.length).toBe(ONBOARDING_FIXTURE_MOVIES.length);
    expect(new Set(pool.map(m => m.id)).size).toBe(pool.length);
    const expected = new Set(ONBOARDING_FIXTURE_MOVIES.map(m => m.id));
    for (const m of pool) expect(expected.has(m.id)).toBe(true);
  });

  it('does not mutate the source pool', () => {
    const before = ONBOARDING_FIXTURE_MOVIES.map(m => m.id).join(',');
    shuffledFixturePool();
    const after = ONBOARDING_FIXTURE_MOVIES.map(m => m.id).join(',');
    expect(after).toBe(before);
  });

  it('yields full TMDBMovie items ready for the grid', () => {
    for (const m of shuffledFixturePool()) {
      expect(m.type).toBe('movie');
      expect(m.id).toMatch(/^tmdb_\d+$/);
      expect(typeof m.posterUrl).toBe('string');
    }
  });
});
