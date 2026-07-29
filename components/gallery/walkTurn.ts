// The Curator's Walk turn mechanic. Pure math — no three.js imports so it
// stays unit-testable. Constants derived from the design-session prototype
// (docs/plans/2026-07-28-curators-walk-design.md). The turn window is scoped
// to the case spacing: TURN_FAR is a fraction of CASE_SPACING so adjacent
// influence zones stay disjoint — the camera returns most of the way to the
// centerline mid-gap (weight ≈ 0.02) instead of overlapping into the next
// station. TURN_NEAR is an absolute distance because it describes how close
// "standing at the stop" is, independent of how far apart the stops sit.
import { CorridorLayout, EYE_Y, CASE_SPACING } from './galleryLayout';

/**
 * Camera fully faces the case within this distance of its walk stop. Absolute
 * (not a spacing ratio): it is about arriving at the stop, not about the gap.
 */
export const TURN_NEAR = 0.35;
/**
 * No turn influence beyond this distance. Kept below half of CASE_SPACING so
 * neighbouring turn zones never overlap (mid-gap weight stays near zero).
 */
export const TURN_FAR = CASE_SPACING * 0.52;
/** How far the camera steps toward the opposite wall for a full turn. */
export const DRIFT_X = 1.05;
/** How far ahead the camera looks while simply walking. */
export const LOOK_AHEAD = 6;
/** Station weight at which the head starts turning toward the case. */
export const LOOK_BLEND_START = 0.12;
/** Station weight at which the look locks fully onto the case. */
export const LOOK_BLEND_END = 0.9;
/** Fraction of the body drift the walking look inherits (keeps the
 *  corridor-ahead gaze from swinging as fast as the feet). */
export const AHEAD_X_DAMP = 0.3;

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
  // The walking look sits at eye height; slot.y is the real case height.
  const lookBlend = smoothstep(LOOK_BLEND_START, LOOK_BLEND_END, w);
  const ahead = { x: x * AHEAD_X_DAMP, y: EYE_Y, z: camZ - LOOK_AHEAD };
  const look = slot
    ? {
        x: ahead.x + (slot.x - ahead.x) * lookBlend,
        y: ahead.y + (slot.y - ahead.y) * lookBlend,
        z: ahead.z + (slot.z - ahead.z) * lookBlend,
      }
    : ahead;

  return { x, look, station };
}
