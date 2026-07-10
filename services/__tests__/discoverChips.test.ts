import { describe, it, expect } from 'vitest';
import { chipLabelKeyForPool, DISCOVER_CHIP_KEYS } from '../discoverChips';
import en from '../../i18n/en';
import zh from '../../i18n/zh';

describe('chipLabelKeyForPool', () => {
  it('maps every engine pool key to its provenance-chip i18n key', () => {
    expect(chipLabelKeyForPool('friend')).toBe('discover.chip.friend');
    expect(chipLabelKeyForPool('taste')).toBe('discover.chip.taste');
    expect(chipLabelKeyForPool('similar')).toBe('discover.chip.similar');
    expect(chipLabelKeyForPool('trending')).toBe('discover.chip.trending');
    expect(chipLabelKeyForPool('variety')).toBe('discover.chip.variety');
    expect(chipLabelKeyForPool('generic')).toBe('discover.chip.generic');
    expect(chipLabelKeyForPool('new_release')).toBe('discover.chip.new_release');
  });

  it('maps the backfill pool to the safe generic/popular chip', () => {
    expect(chipLabelKeyForPool('backfill')).toBe('discover.chip.generic');
  });

  it('falls back to the generic/popular chip for an unknown pool', () => {
    expect(chipLabelKeyForPool('mystery-pool')).toBe('discover.chip.generic');
    expect(chipLabelKeyForPool(undefined)).toBe('discover.chip.generic');
    expect(chipLabelKeyForPool('')).toBe('discover.chip.generic');
  });

  it('exposes every chip key it can return in DISCOVER_CHIP_KEYS', () => {
    // Guards the i18n coverage test below: every value the mapper can emit must
    // be enumerated here so the copy tables can be checked exhaustively.
    const emitted = new Set(
      [
        'friend',
        'taste',
        'similar',
        'trending',
        'variety',
        'generic',
        'new_release',
        'backfill',
        'unknown',
        undefined,
      ].map((p) => chipLabelKeyForPool(p as string | undefined)),
    );
    for (const key of emitted) {
      expect(DISCOVER_CHIP_KEYS).toContain(key);
    }
  });
});

describe('discoverChips i18n coverage', () => {
  it('every DISCOVER_CHIP_KEYS entry has a non-empty string in both en and zh tables', () => {
    for (const key of DISCOVER_CHIP_KEYS) {
      expect(en[key as keyof typeof en], `en missing "${key}"`).toBeTruthy();
      expect(zh[key], `zh missing "${key}"`).toBeTruthy();
    }
  });
});
