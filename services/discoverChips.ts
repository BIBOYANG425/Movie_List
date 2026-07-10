/**
 * discoverChips — pure provenance-chip mapping for the Discover engine grid.
 *
 * The `suggestions` edge function tags every item with a `pool` provenance
 * (§1.3): similar | taste | trending | variety | friend | generic | backfill |
 * new_release. The merged Discover surface (DiscoverView) renders a small chip
 * on each engine card explaining WHY it surfaced. This module owns the single
 * mapping from a raw pool string → the i18n key for that chip's copy, so the
 * copy lives in the translation tables (i18n/en.ts, i18n/zh.ts) and the mapping
 * stays unit-testable in isolation (services/__tests__/discoverChips.test.ts).
 *
 * Fallback rule: any unrecognized / missing pool (including `backfill`, which
 * carries no distinct user-facing story) maps to the safe generic/"popular"
 * chip so a new server pool never renders a raw enum or a blank chip.
 */

import type { TranslationKey } from '../i18n';

/** The i18n key for a provenance chip's user-facing copy. */
export type DiscoverChipKey = Extract<TranslationKey, `discover.chip.${string}`>;

/** Safe fallback used for unknown pools and the storyless `backfill` pool. */
const GENERIC_CHIP: DiscoverChipKey = 'discover.chip.generic';

/** pool → chip i18n key. Only pools with a distinct story get their own chip. */
const POOL_TO_CHIP: Record<string, DiscoverChipKey> = {
  friend: 'discover.chip.friend',
  taste: 'discover.chip.taste',
  similar: 'discover.chip.similar',
  trending: 'discover.chip.trending',
  variety: 'discover.chip.variety',
  generic: 'discover.chip.generic',
  new_release: 'discover.chip.new_release',
  // `backfill` is a padding pool with no distinct provenance story → generic.
  backfill: 'discover.chip.generic',
};

/**
 * Every chip key this mapper can emit. Exported so the i18n coverage test can
 * assert each has copy in both locales, and so callers can style per chip.
 */
export const DISCOVER_CHIP_KEYS: readonly DiscoverChipKey[] = [
  'discover.chip.friend',
  'discover.chip.taste',
  'discover.chip.similar',
  'discover.chip.trending',
  'discover.chip.variety',
  'discover.chip.generic',
  'discover.chip.new_release',
];

/**
 * Map an item's `pool` provenance to its chip i18n key.
 * Unknown / missing pools fall back to the generic "popular" chip.
 */
export function chipLabelKeyForPool(pool: string | undefined | null): DiscoverChipKey {
  if (!pool) return GENERIC_CHIP;
  return POOL_TO_CHIP[pool] ?? GENERIC_CHIP;
}
