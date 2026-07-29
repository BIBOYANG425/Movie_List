import { describe, it, expect } from 'vitest';
import { dominantStation, cameraPose, TURN_NEAR, TURN_FAR } from '../walkTurn';
import { buildCorridorLayout } from '../galleryLayout';
import { Tier, RankedItem } from '../../../types';

const item = (id: string, tier: Tier, rank: number): RankedItem =>
  ({ id, tier, rank, title: id, genres: [] } as unknown as RankedItem);

const layout = buildCorridorLayout(
  [item('a', Tier.S, 0), item('b', Tier.S, 1), item('c', Tier.S, 2)],
  [Tier.S],
);

describe('dominantStation', () => {
  it('returns full weight when camera stands exactly at a stop', () => {
    const { index, weight } = dominantStation(layout.walkStops[1], layout.walkStops);
    expect(index).toBe(1);
    expect(weight).toBeCloseTo(1, 5);
  });

  it('returns zero weight when between stops beyond TURN_FAR', () => {
    const midpoint = (layout.walkStops[0] + layout.walkStops[1]) / 2;
    const gap = Math.abs(layout.walkStops[0] - layout.walkStops[1]) / 2;
    const { weight } = dominantStation(midpoint, layout.walkStops);
    if (gap >= TURN_FAR) expect(weight).toBe(0);
    else expect(weight).toBeLessThan(1);
  });

  it('weight decays monotonically with distance from the stop', () => {
    // Anchor at the FIRST stop and step in +z (back toward the entrance):
    // stations sit 1.25 apart, so a −z offset of TURN_FAR − 0.05 would land
    // nearer the next station and hand dominance to it.
    const z = layout.walkStops[0];
    const w0 = dominantStation(z, layout.walkStops).weight;
    const w1 = dominantStation(z + TURN_NEAR + 0.2, layout.walkStops).weight;
    const w2 = dominantStation(z + TURN_FAR - 0.05, layout.walkStops).weight;
    expect(w0).toBeGreaterThan(w1);
    expect(w1).toBeGreaterThan(w2);
  });
});

describe('cameraPose', () => {
  it('stays on the centerline with a forward look when no station dominates', () => {
    const pose = cameraPose(layout.walkStops[0] + 40, layout);
    expect(pose.x).toBeCloseTo(0, 3);
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
});
