// The Curator's Walk turn mechanic. Pure math — no three.js imports so it
// stays unit-testable. Constants validated in the design-session prototype
// (docs/plans/2026-07-28-curators-walk-design.md).
import { CorridorLayout } from './galleryLayout';

/** Camera fully faces the case within this distance of its walk stop. */
export const TURN_NEAR = 0.35;
/** No turn influence beyond this distance. */
export const TURN_FAR = 1.4;
/** How far the camera steps toward the opposite wall for a full turn. */
export const DRIFT_X = 1.05;
/** How far ahead the camera looks while simply walking. */
export const LOOK_AHEAD = 6;

function smoothstep(edge0: number, edge1: number, x: number): number {
  const t = Math.min(1, Math.max(0, (x - edge0) / (edge1 - edge0)));
  return t * t * (3 - 2 * t);
}

export interface StationHit {
  index: number;
  weight: number; // 0 walking … 1 standing at the stop, fully turned
}

export function dominantStation(camZ: number, walkStops: number[]): StationHit {
  let index = 0;
  let best = Infinity;
  for (let i = 0; i < walkStops.length; i++) {
    const d = Math.abs(camZ - walkStops[i]);
    if (d < best) { best = d; index = i; }
  }
  const weight = 1 - smoothstep(TURN_NEAR, TURN_FAR, best);
  return { index, weight };
}

export interface CameraPose {
  x: number;
  look: { x: number; y: number; z: number };
  station: StationHit;
}

export function cameraPose(camZ: number, layout: CorridorLayout): CameraPose {
  const station = dominantStation(camZ, layout.walkStops);
  const slot = layout.slots[station.index];
  const w = station.weight;

  const x = slot ? -Math.sign(slot.x) * DRIFT_X * w : 0;

  // Blend look: corridor-ahead → case center. The look blend leads the
  // drift (smoothstep re-shaping) so the head turns before the feet plant.
  // look.y of 0 means "eye height" to the caller (the engine substitutes
  // EYE_Y); slot.y is the real case height.
  const lookBlend = smoothstep(0.12, 0.9, w);
  const ahead = { x: x * 0.3, y: 0, z: camZ - LOOK_AHEAD };
  const look = slot
    ? {
        x: ahead.x + (slot.x - ahead.x) * lookBlend,
        y: ahead.y + (slot.y - ahead.y) * lookBlend,
        z: ahead.z + (slot.z - ahead.z) * lookBlend,
      }
    : ahead;

  return { x, look, station };
}
