import { CaseSlot, RoomLayout } from './galleryLayout';

/**
 * Rewrite a TMDB image URL to a specific size bucket. Stored posterUrls are
 * minted at w500 (TMDB_IMAGE_BASE); the hall wants w342, inspect wants w780.
 * Non-TMDB URLs (OpenLibrary book covers) pass through unchanged.
 */
export function tmdbImageAtSize(url: string, size: 'w342' | 'w780'): string {
  return url.replace(
    /(https?:\/\/image\.tmdb\.org\/t\/p\/)w\d+\//,
    `$1${size}/`,
  );
}

export interface TextureWindowArgs {
  slots: CaseSlot[];
  rooms: RoomLayout[];
  cameraRoomIndex: number;
  focusFlatIndex: number;
  /** Rooms within ± this of the camera's room load textures. */
  roomRadius?: number;
  /** Cases within ± this many flat indices of focus load textures. */
  caseRadius?: number;
  /** Hysteresis: loaded textures survive out to this radius before eviction. */
  evictRadius?: number;
  /** Item ids currently holding live textures (for hysteresis). */
  loaded?: ReadonlySet<string>;
}

export interface TextureWindow {
  /** Item ids that should have textures loaded now. */
  load: Set<string>;
  /** Superset of `load`: anything loaded but outside keep gets disposed. */
  keep: Set<string>;
}

export function computeWantedTextures(args: TextureWindowArgs): TextureWindow {
  const {
    slots,
    rooms,
    cameraRoomIndex,
    focusFlatIndex,
    roomRadius = 1,
    caseRadius = 12,
    evictRadius = 16,
    loaded = new Set<string>(),
  } = args;

  const roomOk = (slot: CaseSlot, radius: number) => {
    const room = rooms.find((r) => r.tier === slot.tier);
    if (!room) return false;
    return Math.abs(room.roomIndex - cameraRoomIndex) <= radius;
  };

  const load = new Set<string>();
  const keep = new Set<string>();

  slots.forEach((slot) => {
    const caseDistance = Math.abs(slot.flatIndex - focusFlatIndex);
    if (roomOk(slot, roomRadius) && caseDistance <= caseRadius) {
      load.add(slot.itemId);
      keep.add(slot.itemId);
    } else if (
      loaded.has(slot.itemId) &&
      roomOk(slot, roomRadius) &&
      caseDistance <= evictRadius
    ) {
      keep.add(slot.itemId); // hysteresis: near the boundary, don't thrash
    }
  });

  return { load, keep };
}
