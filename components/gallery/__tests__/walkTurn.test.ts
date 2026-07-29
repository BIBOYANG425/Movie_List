import { describe, it, expect } from 'vitest';
import {
  dominantStation,
  cameraPose,
  snapTargetFor,
  TURN_NEAR,
  TURN_FAR,
} from '../walkTurn';
import { buildCorridorLayout, EYE_Y } from '../galleryLayout';
import { Tier } from '../../../types';
import { makeItem } from './fixtures';

const layout = buildCorridorLayout(
  [makeItem('a', Tier.S, 0), makeItem('b', Tier.S, 1), makeItem('c', Tier.S, 2)],
  [Tier.S],
);

describe('dominantStation', () => {
  it('returns full weight when camera stands exactly at a stop', () => {
    const { index, weight } = dominantStation(layout.walkStops[1], layout.walkStops);
    expect(index).toBe(1);
    expect(weight).toBeCloseTo(1, 5);
  });

  it('returns zero weight beyond TURN_FAR', () => {
    expect(dominantStation(TURN_FAR + 0.01, [0]).weight).toBe(0);
  });

  it('never reaches full weight mid-gap in the real layout', () => {
    const midpoint = (layout.walkStops[0] + layout.walkStops[1]) / 2;
    expect(dominantStation(midpoint, layout.walkStops).weight).toBeLessThan(1);
  });

  it('returns index 0 with zero weight when there are no stops', () => {
    expect(dominantStation(3.7, [])).toEqual({ index: 0, weight: 0 });
  });

  it('weight decays monotonically with distance from the stop', () => {
    // Anchor at the FIRST stop and step in +z (back toward the entrance) so
    // station 0 stays the nearest stop at every sample — stepping in −z would
    // eventually hand dominance to the next station down the corridor.
    const z = layout.walkStops[0];
    const w0 = dominantStation(z, layout.walkStops).weight;
    const w1 = dominantStation(z + TURN_NEAR + 0.2, layout.walkStops).weight;
    const w2 = dominantStation(z + TURN_FAR - 0.05, layout.walkStops).weight;
    expect(w0).toBeGreaterThan(w1);
    expect(w1).toBeGreaterThan(w2);
  });
});

describe('snapTargetFor', () => {
  it('rounds to the station the target is heading for, not the current one', () => {
    // A travel from 0 → 12 that is only partway there (target already 12)
    // must resolve to 12, never back toward 0.
    expect(snapTargetFor(12)).toBe(12);
    expect(snapTargetFor(11.6)).toBe(12);
    expect(snapTargetFor(6.4)).toBe(6);
  });

  it('is a fixed point at every station so a settled idle target never drifts', () => {
    for (const station of [0, 1, 5, 12, 42]) {
      expect(snapTargetFor(station)).toBe(station);
    }
  });

  it('depends only on the target — no current-position argument to fight it', () => {
    expect(snapTargetFor.length).toBe(1);
  });
});

describe('cameraPose', () => {
  it('stays on the centerline with a forward eye-height look when no station dominates', () => {
    const pose = cameraPose(layout.walkStops[0] + 40, layout);
    expect(pose.x).toBeCloseTo(0, 3);
    expect(pose.look.y).toBeCloseTo(EYE_Y, 5);
    expect(pose.look.z).toBeLessThan(layout.walkStops[0] + 40);
  });

  it('drifts opposite the case wall and looks at the case at a stop', () => {
    const slot = layout.slots[0]; // side 'left', x < 0
    const pose = cameraPose(layout.walkStops[0], layout);
    expect(pose.x).toBeGreaterThan(0.5);
    expect(pose.look.x).toBeCloseTo(slot.x, 1);
    expect(pose.look.z).toBeCloseTo(slot.z, 1);
  });

  it('is symmetric for a right-wall case', () => {
    const pose = cameraPose(layout.walkStops[1], layout);
    expect(pose.x).toBeLessThan(-0.5);
  });

  it('returns centerline and a forward look for an empty layout', () => {
    const empty = buildCorridorLayout([], [Tier.S]);
    const pose = cameraPose(-3, empty);
    expect(pose.x).toBe(0);
    expect(pose.look.x).toBe(0);
    expect(pose.look.y).toBeCloseTo(EYE_Y, 5);
    expect(pose.look.z).toBeLessThan(-3);
  });
});
