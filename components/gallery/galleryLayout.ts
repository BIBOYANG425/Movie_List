import { Tier, RankedItem } from '../../types';

// Corridor geometry. The camera walks x = 0 along −Z at eye height; each
// non-empty tier is one room, S→D, separated by an archway segment. All
// distances are world units (~meters). Values tuned during the perf spike.
export const WALL_X = 2.1;
export const EYE_Y = 1.42;
export const CASE_Y = 1.5;
export const CASE_W = 0.62; // poster plane, 2:3
export const CASE_H = 0.93;
export const ROOM_LEAD = 1.6;
export const CASE_SPACING = 1.15;
export const ROOM_TAIL = 2.0;
export const ARCH_DEPTH = 1.2;
export const TIER_ANCHOR_SCALE = 1.15;
// Cases angle partway toward the corridor entrance so they read while
// walking (a flat ±90° hang is edge-on and invisible from the walk line —
// confirmed by headless smoke test). Stops stand ~2.4m before each pair.
export const CASE_FACE_BIAS = 0.42;
export const STOP_LEAD = 2.4;

export interface CaseSlot {
  itemId: string;
  tier: Tier;
  indexInTier: number;
  flatIndex: number;
  side: 'left' | 'right';
  x: number;
  y: number;
  z: number;
  /** Rotation about Y so the case faces the corridor center line. */
  yawY: number;
  scale: number;
  isTierAnchor: boolean;
}

export interface RoomLayout {
  tier: Tier;
  roomIndex: number;
  startZ: number;
  endZ: number;
  labelZ: number;
  archwayZ: number;
  slots: CaseSlot[];
}

export interface CorridorLayout {
  rooms: RoomLayout[];
  /** Every slot in walk order (tier order, then rank order). */
  slots: CaseSlot[];
  totalLength: number;
  /** Camera z per flat slot index — the soft-snap targets. */
  walkStops: number[];
}

// Deterministic ±~1.5% presentation jitter so a wall of identical cases
// doesn't read as stamped (5-index cycle; no randomness, so re-layouts of
// the same list are stable frame to frame).
function jitterScale(i: number): number {
  return 1 + ((i % 5) - 2) * 0.006;
}
function jitterY(i: number): number {
  return ((i % 5) - 2) * 0.008;
}

export function buildCorridorLayout(
  items: RankedItem[],
  tiers: Tier[],
): CorridorLayout {
  const rooms: RoomLayout[] = [];
  const slots: CaseSlot[] = [];
  const walkStops: number[] = [];

  let cursorZ = 0;
  let flatIndex = 0;

  tiers.forEach((tier) => {
    const tierItems = items
      .filter((i) => i.tier === tier)
      .sort((a, b) => a.rank - b.rank);
    if (tierItems.length === 0) return; // empty tiers get no room

    const roomIndex = rooms.length;
    const startZ = cursorZ;
    const pairCount = Math.ceil(tierItems.length / 2);
    const endZ = startZ - (ROOM_LEAD + pairCount * CASE_SPACING + ROOM_TAIL);

    const roomSlots: CaseSlot[] = tierItems.map((item, i) => {
      const side: 'left' | 'right' = i % 2 === 0 ? 'left' : 'right';
      const pair = Math.floor(i / 2);
      const z = startZ - ROOM_LEAD - pair * CASE_SPACING;
      const slot: CaseSlot = {
        itemId: item.id,
        tier,
        indexInTier: i,
        flatIndex: flatIndex + i,
        side,
        x: side === 'left' ? -WALL_X : WALL_X,
        y: CASE_Y + jitterY(i),
        z,
        yawY:
          side === 'left'
            ? Math.PI / 2 - CASE_FACE_BIAS
            : -(Math.PI / 2 - CASE_FACE_BIAS),
        scale: (i === 0 ? TIER_ANCHOR_SCALE : 1) * jitterScale(i),
        isTierAnchor: i === 0,
      };
      // Camera stop: stand back from the case so it sits in the frustum.
      walkStops.push(z + STOP_LEAD);
      return slot;
    });

    flatIndex += tierItems.length;
    slots.push(...roomSlots);
    rooms.push({
      tier,
      roomIndex,
      startZ,
      endZ,
      labelZ: startZ - ROOM_LEAD * 0.5,
      archwayZ: endZ,
      slots: roomSlots,
    });
    cursorZ = endZ - ARCH_DEPTH;
  });

  return { rooms, slots, totalLength: -cursorZ, walkStops };
}

export function roomIndexAtZ(layout: CorridorLayout, z: number): number {
  for (let i = 0; i < layout.rooms.length; i++) {
    const room = layout.rooms[i];
    if (z <= room.startZ && z >= room.endZ - ARCH_DEPTH) return i;
  }
  return z > 0 ? 0 : Math.max(0, layout.rooms.length - 1);
}
