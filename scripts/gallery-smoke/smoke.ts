/**
 * Headless smoke harness for GalleryEngine — no React, no Supabase, no auth.
 *
 * Instantiates the engine directly with fixture RankedItems whose posterUrl
 * is empty, so every case renders the engine's procedural fallback poster
 * (bright serif title text — a stable luminance target). Exposes a
 * `window.__smoke` API that run.mjs drives with puppeteer-core:
 *
 *   __smoke.ready          — engine constructed and corridor built
 *   __smoke.fatal          — engine reported onFatal (headless WebGL missing)
 *   __smoke.mode           — current GalleryMode (mirrors onModeChange)
 *   __smoke.inspectFirst() — fly the first case to the inspect anchor
 *   __smoke.walkTo(i)      — teleport BOTH walk and target to stop i and let
 *                            the animate loop settle the camera there (fully
 *                            turned). Use to place the camera before a sample.
 *   __smoke.travelTo(i)    — set ONLY the walk target to stop i (walk keeps
 *                            its current value) and back-date lastInputTime,
 *                            mirroring travelToTier — so walk damps across the
 *                            corridor through the real idle-snap path. This is
 *                            the regression drive for "snap fights the target".
 *   __smoke.walkState()    — { walk, targetWalk } read of the walk animator.
 *   __smoke.travelToSecondTier() — call the real GalleryEngine.travelToTier for
 *                            the fixture's second non-empty tier and return the
 *                            walk stop it targeted. Exercises the actual room
 *                            lookup / hall-mode guard / reducedMotion branch,
 *                            not a re-simulation of it.
 *   __smoke.sample(n, i?)  — render synchronously, then read an n×n pixel
 *                            block centered on a poster and return its
 *                            mean/max luminance (0-1), the camera x, and the
 *                            sampled case's slot x. With i given, samples case
 *                            i (hall walk-turn check); without it, the
 *                            inspected case.
 */
import * as THREE from 'three';
import { GalleryEngine } from '../../components/gallery/GalleryEngine';
import { GalleryMode } from '../../components/gallery/galleryTypes';
import { CorridorLayout } from '../../components/gallery/galleryLayout';
import { cameraPose } from '../../components/gallery/walkTurn';
import { Tier, RankedItem } from '../../types';

const TIER_LABELS: Record<Tier, string> = {
  [Tier.S]: 'Masterpiece',
  [Tier.A]: 'Great',
  [Tier.B]: 'Good',
  [Tier.C]: 'Fine',
  [Tier.D]: 'Bad',
};

const TIERS_CYCLE = [Tier.S, Tier.S, Tier.S, Tier.A, Tier.A, Tier.A, Tier.B, Tier.B, Tier.C, Tier.D];

function fixtureItems(): RankedItem[] {
  const perTierRank = new Map<Tier, number>();
  return TIERS_CYCLE.map((tier, i) => {
    const rank = perTierRank.get(tier) ?? 0;
    perTierRank.set(tier, rank + 1);
    return {
      id: `fx${i + 1}`,
      // Long titles wrap into several bright text lines across the fallback
      // poster's center — the luminance sample region.
      title: `Fixture Feature Number ${i + 1} Of The Smoke Harness`,
      year: `${1990 + i}`,
      posterUrl: '', // empty → engine renders makeFallbackPosterTexture
      type: 'movie',
      genres: ['Drama'],
      tier,
      rank,
    } as RankedItem;
  });
}

type SmokeApi = {
  ready: boolean;
  fatal: string | null;
  mode: GalleryMode;
  inspectFirst: () => void;
  walkTo: (stopIndex: number) => void;
  travelTo: (stopIndex: number) => void;
  walkState: () => { walk: number; targetWalk: number };
  pump: (frames?: number) => void;
  snapshot: () => string;
  travelToSecondTier: () => number;
  sample: (
    blockSize?: number,
    caseIndex?: number,
  ) => {
    mode: GalleryMode;
    mean: number;
    max: number;
    centerX: number;
    centerY: number;
    blockSize: number;
    cameraX: number;
    slotX: number;
    corners: {
      tl: { x: number; y: number };
      tr: { x: number; y: number };
      bl: { x: number; y: number };
      br: { x: number; y: number };
    };
  };
};

const canvas = document.getElementById('stage') as HTMLCanvasElement;
const items = fixtureItems();

const api: SmokeApi = {
  ready: false,
  fatal: null,
  mode: 'hall',
  inspectFirst: () => engine.inspect(items[0].id),
  walkTo: (stopIndex) => {
    // TS `private` is compile-time only — jump the hall walk target to the
    // requested stop and back-date lastInputTime so the idle-snap engages and
    // the animate loop settles the camera fully turned at that station.
    const eng = engine as unknown as {
      walk: number;
      targetWalk: number;
      lastInputTime: number;
      driftX: number;
      lookSmoothed: THREE.Vector3;
      layout: CorridorLayout;
    };
    eng.walk = stopIndex;
    eng.targetWalk = stopIndex;
    eng.lastInputTime = performance.now() - 10000;
    // Seed the smoothed eye-drift and gaze at their CONVERGED values for this
    // stop. Headless rAF is heavily throttled, so the per-frame damp toward the
    // turned pose can lag for seconds — a screenshot then catches a half-turned
    // (oblique) frame that misrepresents the real 60 fps app. Seeding makes the
    // very first rendered frame the settled, square-on pose the user sees.
    const camZ = eng.layout.walkStops[stopIndex] ?? 0;
    const pose = cameraPose(camZ, eng.layout);
    eng.driftX = pose.x;
    eng.lookSmoothed.set(pose.look.x, pose.look.y, pose.look.z);
  },
  travelTo: (stopIndex) => {
    // Mirrors GalleryEngine.travelToTier: move ONLY the target and back-date
    // lastInputTime; walk keeps its current value and must damp across the
    // corridor through the idle-snap path. Does NOT teleport walk, so the
    // snap-anchors-to-target fix is actually exercised.
    const eng = engine as unknown as {
      targetWalk: number;
      lastInputTime: number;
    };
    eng.targetWalk = stopIndex;
    eng.lastInputTime = performance.now() - 10000;
  },
  walkState: () => {
    const eng = engine as unknown as { walk: number; targetWalk: number };
    return { walk: eng.walk, targetWalk: eng.targetWalk };
  },
  pump: (frames = 90) => {
    // Deterministically advance the engine and present a frame. Headless rAF is
    // throttled, so between an input and a page.screenshot no animate frame may
    // run — the composited canvas then shows a stale, half-converged camera.
    // Stepping updateState directly (fixed 60 fps delta) settles the damped
    // drift/gaze and renders, so the screenshot matches what the sample() probe
    // measures (and what the real 60 fps app shows).
    const eng = engine as unknown as {
      updateState: (d: number, ts: number, el: number) => void;
      renderer: THREE.WebGLRenderer;
      scene: THREE.Scene;
      camera: THREE.PerspectiveCamera;
    };
    const base = performance.now();
    for (let i = 0; i < frames; i++) {
      const ts = base + i * (1000 / 60);
      eng.updateState(1 / 60, ts, ts / 1000);
    }
    eng.renderer.render(eng.scene, eng.camera);
  },
  snapshot: () => {
    // Ground-truth frame: read the WebGL drawing buffer straight after a render
    // and re-encode it as a PNG data URL. page.screenshot() captures the
    // browser compositor's frame, which (preserveDrawingBuffer: false) does not
    // reflect the harness's out-of-rAF render — so the composited hall shot can
    // lag the settled camera. This returns exactly what the engine drew.
    const eng = engine as unknown as {
      renderer: THREE.WebGLRenderer;
      scene: THREE.Scene;
      camera: THREE.PerspectiveCamera;
    };
    eng.renderer.render(eng.scene, eng.camera);
    const gl = eng.renderer.getContext();
    const w = gl.drawingBufferWidth;
    const h = gl.drawingBufferHeight;
    const pixels = new Uint8Array(w * h * 4);
    gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
    const out = document.createElement('canvas');
    out.width = w;
    out.height = h;
    const ctx = out.getContext('2d')!;
    const img = ctx.createImageData(w, h);
    // readPixels is bottom-up; flip into the top-down 2D canvas.
    for (let y = 0; y < h; y++) {
      const src = (h - 1 - y) * w * 4;
      const dst = y * w * 4;
      img.data.set(pixels.subarray(src, src + w * 4), dst);
    }
    ctx.putImageData(img, 0, 0);
    return out.toDataURL('image/png');
  },
  travelToSecondTier: () => {
    // Drive the REAL public control: travelToTier does the room lookup, the
    // hall-mode guard, and the reducedMotion branch itself. We just hand it the
    // fixture's second non-empty tier (canonical S→D order; the fixture's first
    // tier is S with 3 items, so this resolves to A — derived, not hardcoded)
    // and read back the stop it targeted as the expected arrival.
    const canonical = [Tier.S, Tier.A, Tier.B, Tier.C, Tier.D];
    const present = canonical.filter((t) => items.some((it) => it.tier === t));
    engine.travelToTier(present[1]);
    const eng = engine as unknown as { targetWalk: number };
    return eng.targetWalk;
  },
  sample: (blockSize = 60, caseIndex) => {
    // TS `private` is compile-time only — the harness reaches into the
    // engine to render synchronously (readPixels is only valid in the same
    // task as the draw; the drawing buffer is cleared after compositing).
    const eng = engine as unknown as {
      renderer: THREE.WebGLRenderer;
      scene: THREE.Scene;
      camera: THREE.PerspectiveCamera;
      cases: Array<{ poster: THREE.Mesh; slot: { x: number } }>;
      selectedIndex: number | null;
      mode: GalleryMode;
    };
    // Explicit caseIndex samples any case (hall walk-turn check); otherwise
    // fall back to the inspected case.
    const posterIndex = caseIndex ?? eng.selectedIndex;
    if (posterIndex === null || posterIndex === undefined) {
      throw new Error('sample() called with no case index and none inspected');
    }
    eng.renderer.render(eng.scene, eng.camera);

    const poster = eng.cases[posterIndex].poster;
    const center = new THREE.Vector3();
    poster.getWorldPosition(center);
    center.project(eng.camera);

    const gl = eng.renderer.getContext();
    const w = gl.drawingBufferWidth;
    const h = gl.drawingBufferHeight;
    // NDC → device pixels. readPixels origin is bottom-left, same as NDC +y
    // up, so no vertical flip is needed.
    const cx = Math.round((center.x * 0.5 + 0.5) * w);
    const cy = Math.round((center.y * 0.5 + 0.5) * h);
    const half = Math.floor(blockSize / 2);
    const x0 = Math.max(0, cx - half);
    const y0 = Math.max(0, cy - half);
    const bw = Math.min(blockSize, w - x0);
    const bh = Math.min(blockSize, h - y0);
    const pixels = new Uint8Array(bw * bh * 4);
    gl.readPixels(x0, y0, bw, bh, gl.RGBA, gl.UNSIGNED_BYTE, pixels);

    let sum = 0;
    let max = 0;
    for (let i = 0; i < bw * bh; i++) {
      const r = pixels[i * 4] / 255;
      const g = pixels[i * 4 + 1] / 255;
      const b = pixels[i * 4 + 2] / 255;
      const luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      sum += luminance;
      if (luminance > max) max = luminance;
    }
    // Project the poster's four local corners to screen px so phase 3 can
    // assert square-on (left/right edge heights equal) vs. an oblique view.
    const geo = poster.geometry as THREE.PlaneGeometry;
    const pw = geo.parameters.width / 2;
    const ph = geo.parameters.height / 2;
    const proj = (lx: number, ly: number) => {
      const v = new THREE.Vector3(lx, ly, 0);
      poster.localToWorld(v);
      v.project(eng.camera);
      return { x: Math.round((v.x * 0.5 + 0.5) * w), y: Math.round((v.y * 0.5 + 0.5) * h) };
    };
    const corners = {
      tl: proj(-pw, ph),
      tr: proj(pw, ph),
      bl: proj(-pw, -ph),
      br: proj(pw, -ph),
    };
    return {
      mode: eng.mode,
      mean: sum / (bw * bh),
      max,
      centerX: cx,
      centerY: cy,
      blockSize,
      cameraX: eng.camera.position.x,
      slotX: eng.cases[posterIndex].slot.x,
      corners,
    };
  },
};

declare global {
  interface Window {
    __smoke: SmokeApi;
  }
}
window.__smoke = api;

const engine = new GalleryEngine(canvas, {
  items,
  tierLabels: TIER_LABELS,
  reducedMotion: false,
  callbacks: {
    onModeChange: (mode) => {
      api.mode = mode;
    },
    onFocusChange: () => undefined,
    onStatus: () => undefined,
    onFatal: (reason) => {
      api.fatal = reason;
    },
  },
});

// Mirror the GalleryView mount contract: the corridor is built by the first
// setItems, not the constructor.
engine.setItems(items);
api.ready = api.fatal === null;
