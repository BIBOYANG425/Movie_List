# The Curator's Walk Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebuild Gallery mode as a fullscreen night-museum walk where the camera turns to face each poster fully, with a bright pull-forward inspect.

**Architecture:** Evolve the merged `GalleryEngine` (PR #81) rather than rewrite: the corridor, texture windowing, fallbacks, and inspect flight stay. Three additions: (1) a pure `walkTurn.ts` module computing per-frame camera drift + look-blend toward the dominant station, (2) a `GalleryOverlay` fullscreen portal replacing the embedded canvas, (3) a diagnosed-and-guarded fix for the near-black inspected poster. Layout math stays in pure, unit-tested modules; the engine consumes them.

**Tech Stack:** React 18 + TypeScript + Vite, three.js (lazy chunk), vitest, existing `components/gallery/*` modules.

**Design doc:** `docs/plans/2026-07-28-curators-walk-design.md`. Interaction prototype from the design session: scratchpad `concepts/walk3d.html` (turn/drift constants live there).

---

### Task 0: Branch

**Step 1:** `git checkout -b feature/curators-walk` from up-to-date `main`.
**Step 2:** Commit the two docs in `docs/plans/2026-07-28-curators-walk*.md`:
```bash
git add docs/plans/2026-07-28-curators-walk-design.md docs/plans/2026-07-28-curators-walk.md
git commit -m "docs(gallery): Curator's Walk design + implementation plan"
```

---

### Task 1: Pure walk-turn math (`walkTurn.ts`)

**Files:**
- Create: `components/gallery/walkTurn.ts`
- Test: `components/gallery/__tests__/walkTurn.test.ts`

The mechanic validated in the prototype: for camera depth `camZ`, find the dominant
station (nearest walk stop), weight it 0→1, drift camera x toward the wall *opposite*
the station's case, and blend the look target from corridor-ahead to the case center.

**Step 1: Write the failing tests**

```ts
// components/gallery/__tests__/walkTurn.test.ts
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
    const z = layout.walkStops[1];
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
    expect(pose.x).toBeGreaterThan(0.5);        // driven toward right wall
    expect(pose.look.x).toBeCloseTo(slot.x, 1); // looking at the case
    expect(pose.look.z).toBeCloseTo(slot.z, 1);
  });

  it('is symmetric for a right-wall case', () => {
    const pose = cameraPose(layout.walkStops[1], layout);
    expect(pose.x).toBeLessThan(-0.5);
  });
});
```

**Step 2: Run to verify failure**

Run: `npx vitest run components/gallery/__tests__/walkTurn.test.ts`
Expected: FAIL — `Cannot find module '../walkTurn'`.

**Step 3: Implement**

```ts
// components/gallery/walkTurn.ts
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
  // drift slightly (smoothstep re-shaping) so the head turns before the
  // feet plant — reads as intentional, not mechanical.
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
```

Note: `look.y` blends 0 → slot.y; the engine adds `EYE_Y` to the ahead-look
itself (see Task 3) so the module stays frame-of-reference-free.

**Step 4: Run to verify pass**

Run: `npx vitest run components/gallery/__tests__/walkTurn.test.ts`
Expected: PASS (6 tests).

**Step 5: Commit**

```bash
git add components/gallery/walkTurn.ts components/gallery/__tests__/walkTurn.test.ts
git commit -m "feat(gallery): pure walk-turn math for the Curator's Walk"
```

---

### Task 2: Diagnose the near-black inspected poster (fix before restyling)

**Files:**
- Read: `components/gallery/GalleryEngine.ts` — `beginInspect`, `applyFlight`, the
  `dimQuad` block in the animate loop (search `dimQuad`), `prepareTexture`.
- Possibly modify: the inspect dim path and/or poster material `toneMapped` flag.

**Step 1: Reproduce headlessly.** Run the existing smoke flow (see PR #81 body; if no
script exists, create `scripts/gallerySmoke.mjs` from Task 5's harness) and capture a
screenshot ~800ms after `beginInspect`. Sample the center pixel of the inspected
poster region.

**Step 2: Root-cause.** Known suspects, in order:
1. `dimQuad` renders in front of the inspected case (renderOrder/z fight) — check
   `dimQuad.position.z` vs the case's final flight z and both `renderOrder`s.
2. The flight target sits behind the backdrop plane's dim material.
3. `renderer.toneMappingExposure` or a material `color.multiplyScalar` applied to ALL
   cases including the inspected one during inspect (grep `exposure`, `multiplyScalar`).

**Step 3: Fix minimally.** The invariant: the inspected case must render *in front of*
the dim layer at full material brightness (`color 0xffffff`, `toneMapped` true,
no opacity dim). World dimming happens ONLY via `dimQuad` + backdrop material.

**Step 4: Guard.** Add to the smoke script an assertion: sampled center-pixel
luminance of the inspected poster > 0.35 (0–1 scale) for a known-bright fixture
poster. Expected: FAIL before fix, PASS after.

**Step 5: Commit**

```bash
git add components/gallery/GalleryEngine.ts scripts/gallerySmoke.mjs
git commit -m "fix(gallery): inspected poster renders bright — dim only the world layer"
```

---

### Task 3: Engine integration — the turn (`GalleryEngine.ts`)

**Files:**
- Modify: `components/gallery/GalleryEngine.ts`
- Reference: `components/gallery/walkTurn.ts` (Task 1)

**Step 1:** Locate the animate-loop camera update (method `animate`, near the
`walkZ()` / camera positioning code) and the constants block.

**Step 2:** Replace the current camera x/lookAt handling in hall mode with:

```ts
import { cameraPose } from './walkTurn';
// … in animate(), hall mode, after computing this.walkZ (camera depth):
const pose = cameraPose(this.walkZ, this.layout);
this.camera.position.x = THREE.MathUtils.damp(this.camera.position.x, pose.x, 6, delta);
this.camera.position.y = EYE_Y;
this.camera.position.z = this.walkZ;
this.lookTarget.set(
  pose.look.x,
  pose.look.y === 0 ? EYE_Y : pose.look.y,   // ahead-look stays at eye height
  pose.look.z,
);
this.lookSmoothed.lerp(this.lookTarget, 1 - Math.exp(-6 * delta));
this.camera.lookAt(this.lookSmoothed);
```

Add `private lookTarget = new THREE.Vector3()` and
`private lookSmoothed = new THREE.Vector3(0, EYE_Y, -LOOK_AHEAD)` fields.
Remove/park any existing per-room yaw logic that fights the lookAt (search
`lookAt`, `rotation.y` on camera).

**Step 3:** Soft-snap: the engine already has walk-stop snapping (`SNAP_IDLE_MS`).
Verify it snaps to `layout.walkStops[station.index]` so an idle camera settles
fully-turned (weight → 1). Adjust the snap target to the dominant station's stop.

**Step 4:** Hang the cases flatter now that the camera turns: in
`galleryLayout.ts`, change `CASE_FACE_BIAS` from `0.42` to `0.22` (cases still
readable mid-walk, near-frontal when turned-to). Run
`npx vitest run components/gallery/__tests__/galleryLayout.test.ts` — update any
yaw expectation accordingly.

**Step 5:** Verify: `npx tsc --noEmit` clean; `npx vitest run` clean; smoke script
screenshot at a walk stop shows the case centered and near-frontal.

**Step 6: Commit**

```bash
git add components/gallery/GalleryEngine.ts components/gallery/galleryLayout.ts components/gallery/__tests__/galleryLayout.test.ts
git commit -m "feat(gallery): camera turns to face each case at its walk stop"
```

---

### Task 4: Fullscreen `GalleryOverlay` portal

**Files:**
- Create: `components/gallery/GalleryOverlay.tsx`
- Modify: `pages/RankingAppPage.tsx:1845-1860` (the `viewMode === 'gallery'` branch)

**Step 1: Create the portal wrapper**

```tsx
// components/gallery/GalleryOverlay.tsx
// Fullscreen portal for the Curator's Walk. The gallery is a place you enter,
// not a panel in the page: body scroll locks while mounted, Esc exits when the
// engine is not mid-inspect (GalleryView already consumes Esc for inspect).
import React, { useEffect } from 'react';
import { createPortal } from 'react-dom';
import { X } from 'lucide-react';

interface GalleryOverlayProps {
  onExit: () => void;
  children: React.ReactNode;
}

export const GalleryOverlay: React.FC<GalleryOverlayProps> = ({ onExit, children }) => {
  useEffect(() => {
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => { document.body.style.overflow = prev; };
  }, []);

  return createPortal(
    <div className="fixed inset-0 z-[70] bg-background animate-fade-in">
      {children}
      <button
        onClick={onExit}
        aria-label="Exit gallery"
        className="absolute top-5 right-5 z-10 p-2 text-muted-foreground hover:text-foreground transition-colors"
      >
        <X size={20} />
      </button>
    </div>,
    document.body,
  );
};
```

**Step 2: Wire it in `RankingAppPage.tsx`.** In the `viewMode === 'gallery'` branch,
wrap the existing `<GalleryView …>` (with its Suspense) in
`<GalleryOverlay onExit={() => setViewMode('grid')}>`. The grid keeps rendering
underneath (no data unmount surprises), the overlay covers it.

**Step 3: GalleryView fills the overlay.** Confirm `GalleryView`'s container uses
`h-full w-full` when it no longer sizes to the embedded box; pass a `fullscreen`
prop if its root has fixed heights (check `containerRef` styles at
`components/gallery/GalleryView.tsx:40-75`).

**Step 4:** Verify: `npx tsc --noEmit`; `npm run dev` → toggle gallery → overlay
covers viewport, header/search gone, Esc exits from hall mode, ✕ always exits,
grid state intact on return. Wheel never scrolls the page.

**Step 5: Commit**

```bash
git add components/gallery/GalleryOverlay.tsx pages/RankingAppPage.tsx components/gallery/GalleryView.tsx
git commit -m "feat(gallery): fullscreen overlay portal — the Walk is a place, not a panel"
```

---

### Task 5: Headless smoke run + attribution + docs

**Files:**
- Modify/Create: `scripts/gallerySmoke.mjs` (if PR #81's harness isn't checked in)
- Modify: `components/gallery/GalleryEngine.ts:1-20` (header comment)
- Modify: `CLAUDE.md` (component org note), design doc status line

**Step 1:** Smoke run: full cycle hall → walk to stop 3 (camera fully turned) →
inspect → Esc → tier fast-travel. Screenshot each phase; assert the Task 2
brightness guard and zero console errors.

**Step 2:** Add attribution to the engine header:

```ts
 * Interaction patterns (continuous walk pacing, pull-forward inspect,
 * click-vs-drag threshold) studied from "The Complete Shelf" by Mint
 * (github.com/mintdotgg/mint-playground, MIT). Implementation is original.
```

**Step 3:** `npm run build` — confirm the three.js chunk is still lazy and the
overlay adds no meaningful weight to the main bundle.

**Step 4:** Full suite: `npx vitest run` and `npx tsc --noEmit` — zero new failures.

**Step 5: Commit**

```bash
git add scripts/gallerySmoke.mjs components/gallery/GalleryEngine.ts CLAUDE.md docs/plans/2026-07-28-curators-walk-design.md
git commit -m "test(gallery): smoke harness with brightness guard; attribute Complete Shelf patterns"
```

---

### Task 6: Live verification & PR

**Step 1:** `npm run dev`, manual pass per the design doc checklist: enter, walk S
wing, confirm the turn rhythm at ≥3 stations on both walls, inspect bright, placard
correct (`№ N of M · tier · score`), tier letters fast-travel, reduced-motion
crossfade path, WebGL-blocked fallback to grid.

**Step 2:** Push and open PR against `main` titled
`feat(gallery): The Curator's Walk — fullscreen museum walk with turn-to-face`,
body links the design doc, notes the brightness root cause + guard, and the MIT
attribution. Verify CI passes.
