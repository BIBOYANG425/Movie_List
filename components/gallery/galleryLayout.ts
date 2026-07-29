import { Tier, RankedItem } from '../../types';

// Corridor geometry. The camera walks x = 0 along −Z at eye height; each
// non-empty tier is one room, S→D, separated by an archway segment. All
// distances are world units (1 unit = 1 m). Human-scale pass: posters stand
// ~60% taller than a 1.75 m adult (owner ask); the corridor width and station
// pacing were rescaled with them so the big poster frames cleanly and adjacent
// cases don't crowd. Eye/case *heights* stay human-referenced (the world is
// metric) — only the poster size and horizontal/depth spacing grew.
export const WALL_X = 2.9; // half corridor width; a case hangs on the wall at ±WALL_X
export const EYE_Y = 1.42; // human eye height — unchanged
export const CASE_W = 1.87; // poster plane, 2:3 (= CASE_H × 2/3)
export const CASE_H = 2.8; // ≈1.6× a 1.75 m adult
export const CASE_Y = 1.7; // case center; bottom edge (1.7 − 1.4) hangs 0.3 m above the floor
// How far the eye steps toward the far wall at a full turn (consumed by
// walkTurn.cameraPose, re-exported from there). Lives here because STOP_LEAD's
// frontal-consistency derivation below needs the eye↔case x-separation, and
// the layout module must not import the camera module (that would be a cycle).
export const DRIFT_X = 1.45;
export const ROOM_LEAD = 4.8;
// Single-file station pacing ≈ 1.35× case height (3.8 ≈ 1.35 × 2.8), scaled
// coherently from the pre-human-scale 1.25 at CASE_H 0.93.
export const CASE_SPACING = 3.8;
export const ROOM_TAIL = 6.0;
export const ARCH_DEPTH = 3.6;
export const TIER_ANCHOR_SCALE = 1.15;
// Cases yaw toward the corridor entrance by this bias so they read as a
// three-quarter face while the camera walks past (the owner saw edge-on
// slivers at the old 0.22). The frontal moment is guaranteed at the stop by
// STOP_LEAD below, so the bias is free to favor walk readability.
export const CASE_FACE_BIAS = 0.3;
// Frontal-consistency lead. At a full turn the eye drifts to ±DRIFT_X off a
// ∓WALL_X case, so the eye↔case x-separation is (WALL_X + DRIFT_X); the case's
// normal is tilted CASE_FACE_BIAS toward the entrance. Standing the stop this
// far up-corridor puts the eye exactly on the case's normal line, so the 90°
// turn lands perpendicular — square-on, poster filling the frame. The old flat
// 2.4 was uncoupled from the bias and stood the eye far down-corridor, viewing
// every case obliquely (the "does not focus / half the poster" bug).
export const STOP_LEAD = (WALL_X + DRIFT_X) * Math.tan(CASE_FACE_BIAS);

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
    const endZ =
      startZ - (ROOM_LEAD + tierItems.length * CASE_SPACING + ROOM_TAIL);

    // Single file: one station per case, side alternating L/R, each at its
    // own z (a shared-z pair would make left/right stops indistinguishable
    // to the walk-turn mechanic).
    const roomSlots: CaseSlot[] = tierItems.map((item, i) => {
      const side: 'left' | 'right' = i % 2 === 0 ? 'left' : 'right';
      const z = startZ - ROOM_LEAD - i * CASE_SPACING;
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
      // Camera stop: lead the case up-corridor by STOP_LEAD so the turned eye
      // stands on its normal line and faces it square-on (see STOP_LEAD).
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
