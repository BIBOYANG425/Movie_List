import { describe, it, expect } from 'vitest';
import { Tier } from '../../../types';
import {
  buildCorridorLayout,
  roomIndexAtZ,
  TIER_ANCHOR_SCALE,
} from '../galleryLayout';
import { makeItem } from './fixtures';

const TIERS = [Tier.S, Tier.A, Tier.B, Tier.C, Tier.D];

describe('buildCorridorLayout', () => {
  it('skips empty tiers entirely — no room, no slots', () => {
    const items = [
      makeItem('a', Tier.S, 0),
      makeItem('b', Tier.C, 0),
      makeItem('c', Tier.C, 1),
    ];
    const layout = buildCorridorLayout(items, TIERS);
    expect(layout.rooms.map((r) => r.tier)).toEqual([Tier.S, Tier.C]);
    expect(layout.slots).toHaveLength(3);
  });

  it('preserves rank order across alternating walls', () => {
    const items = [0, 1, 2, 3, 4].map((r) => makeItem(`s${r}`, Tier.S, r));
    const layout = buildCorridorLayout(items, TIERS);
    expect(layout.slots.map((s) => s.itemId)).toEqual([
      's0',
      's1',
      's2',
      's3',
      's4',
    ]);
    expect(layout.slots.map((s) => s.side)).toEqual([
      'left',
      'right',
      'left',
      'right',
      'left',
    ]);
    // single file: every case has its own station, advancing down −Z
    expect(layout.slots[1].z).toBeLessThan(layout.slots[0].z);
    expect(layout.slots[2].z).toBeLessThan(layout.slots[1].z);
  });

  it('flags only the first item of each tier as anchor with the larger case', () => {
    const items = [
      makeItem('s0', Tier.S, 0),
      makeItem('s1', Tier.S, 1),
      makeItem('a0', Tier.A, 0),
    ];
    const layout = buildCorridorLayout(items, TIERS);
    const anchors = layout.slots.filter((s) => s.isTierAnchor);
    expect(anchors.map((s) => s.itemId)).toEqual(['s0', 'a0']);
    anchors.forEach((s) => {
      expect(s.scale).toBeGreaterThan(TIER_ANCHOR_SCALE * 0.97);
    });
    expect(layout.slots[1].scale).toBeLessThan(1.03);
  });

  it('applies deterministic jitter of at most ~2%', () => {
    const items = Array.from({ length: 20 }, (_, r) =>
      makeItem(`s${r}`, Tier.S, r),
    );
    const a = buildCorridorLayout(items, TIERS);
    const b = buildCorridorLayout(items, TIERS);
    a.slots.forEach((slot, i) => {
      expect(slot.scale).toBeCloseTo(b.slots[i].scale, 10); // deterministic
      const base = slot.isTierAnchor ? TIER_ANCHOR_SCALE : 1;
      expect(Math.abs(slot.scale / base - 1)).toBeLessThanOrEqual(0.02);
    });
  });

  it('produces monotonically non-increasing walk stops along −Z', () => {
    const items = [
      ...Array.from({ length: 7 }, (_, r) => makeItem(`s${r}`, Tier.S, r)),
      ...Array.from({ length: 4 }, (_, r) => makeItem(`a${r}`, Tier.A, r)),
    ];
    const layout = buildCorridorLayout(items, TIERS);
    for (let i = 1; i < layout.walkStops.length; i++) {
      expect(layout.walkStops[i]).toBeLessThanOrEqual(
        layout.walkStops[i - 1] + 1e-9,
      );
    }
  });

  it('handles a 150-item tier with sane length and full coverage', () => {
    const items = Array.from({ length: 150 }, (_, r) =>
      makeItem(`s${r}`, Tier.S, r),
    );
    const layout = buildCorridorLayout(items, TIERS);
    expect(layout.slots).toHaveLength(150);
    expect(layout.walkStops).toHaveLength(150);
    expect(layout.totalLength).toBeGreaterThan(80); // 150 stations × 1.25 spacing
    expect(layout.totalLength).toBeLessThan(200);
  });

  it('maps camera z back to the correct room', () => {
    const items = [
      makeItem('s0', Tier.S, 0),
      makeItem('a0', Tier.A, 0),
    ];
    const layout = buildCorridorLayout(items, TIERS);
    expect(roomIndexAtZ(layout, layout.rooms[0].labelZ)).toBe(0);
    expect(roomIndexAtZ(layout, layout.rooms[1].labelZ)).toBe(1);
    expect(roomIndexAtZ(layout, 5)).toBe(0); // before the corridor
    expect(roomIndexAtZ(layout, layout.rooms[1].endZ - 10)).toBe(1); // past the end
  });
});
