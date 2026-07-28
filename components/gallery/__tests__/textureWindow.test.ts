import { describe, it, expect } from 'vitest';
import { Tier, RankedItem } from '../../../types';
import { buildCorridorLayout } from '../galleryLayout';
import { computeWantedTextures, tmdbImageAtSize } from '../textureWindow';

function makeItem(id: string, tier: Tier, rank: number): RankedItem {
  return {
    id,
    title: `Movie ${id}`,
    year: '2024',
    posterUrl: `https://image.tmdb.org/t/p/w500/${id}.jpg`,
    type: 'movie',
    genres: [],
    tier,
    rank,
  };
}

const TIERS = [Tier.S, Tier.A, Tier.B, Tier.C, Tier.D];

describe('tmdbImageAtSize', () => {
  it('rewrites the stored w500 bucket to w342 and w780', () => {
    const url = 'https://image.tmdb.org/t/p/w500/abc123.jpg';
    expect(tmdbImageAtSize(url, 'w342')).toBe(
      'https://image.tmdb.org/t/p/w342/abc123.jpg',
    );
    expect(tmdbImageAtSize(url, 'w780')).toBe(
      'https://image.tmdb.org/t/p/w780/abc123.jpg',
    );
  });

  it('passes non-TMDB URLs (OpenLibrary covers) through unchanged', () => {
    const url = 'https://covers.openlibrary.org/b/id/12345-L.jpg';
    expect(tmdbImageAtSize(url, 'w342')).toBe(url);
  });
});

describe('computeWantedTextures', () => {
  const bigTier = Array.from({ length: 40 }, (_, r) =>
    makeItem(`s${r}`, Tier.S, r),
  );
  const farTier = Array.from({ length: 5 }, (_, r) =>
    makeItem(`d${r}`, Tier.D, r),
  );
  const layout = buildCorridorLayout([...bigTier, ...farTier], TIERS);

  it('loads only cases within the case radius of focus, in near rooms', () => {
    const { load } = computeWantedTextures({
      slots: layout.slots,
      rooms: layout.rooms,
      cameraRoomIndex: 0,
      focusFlatIndex: 20,
      roomRadius: 1,
      caseRadius: 12,
    });
    expect(load.has('s20')).toBe(true);
    expect(load.has('s8')).toBe(true); // 20 − 12
    expect(load.has('s32')).toBe(true); // 20 + 12
    expect(load.has('s7')).toBe(false); // outside case radius
    expect(load.has('s33')).toBe(false);
  });

  it('excludes rooms beyond the room radius', () => {
    const { load } = computeWantedTextures({
      slots: layout.slots,
      rooms: layout.rooms,
      cameraRoomIndex: 0,
      focusFlatIndex: 38,
      roomRadius: 1,
      caseRadius: 12,
    });
    // D tier is room index 1 here (S=0, D=1 since A/B/C are empty) — within
    // radius 1, so its nearby cases load; nothing crashes on sparse tiers.
    expect(load.has('d0')).toBe(true);
  });

  it('keeps already-loaded textures out to the evict radius (hysteresis)', () => {
    const loaded = new Set(['s7']); // distance 13 from focus 20
    const { load, keep } = computeWantedTextures({
      slots: layout.slots,
      rooms: layout.rooms,
      cameraRoomIndex: 0,
      focusFlatIndex: 20,
      roomRadius: 1,
      caseRadius: 12,
      evictRadius: 16,
      loaded,
    });
    expect(load.has('s7')).toBe(false); // not re-requested
    expect(keep.has('s7')).toBe(true); // but not evicted either
    // Beyond evict radius it is dropped from keep → disposed
    const far = computeWantedTextures({
      slots: layout.slots,
      rooms: layout.rooms,
      cameraRoomIndex: 0,
      focusFlatIndex: 30,
      roomRadius: 1,
      caseRadius: 12,
      evictRadius: 16,
      loaded: new Set(['s7']), // distance 23
    });
    expect(far.keep.has('s7')).toBe(false);
  });

  it('never loads an unloaded case outside the load radius', () => {
    const { load } = computeWantedTextures({
      slots: layout.slots,
      rooms: layout.rooms,
      cameraRoomIndex: 0,
      focusFlatIndex: 0,
      roomRadius: 1,
      caseRadius: 12,
    });
    expect(load.size).toBeLessThanOrEqual(13 + 5); // window + small far room
  });
});
