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
 *   __smoke.walkTo(i)      — set the hall walk target to walk stop i and let
 *                            the animate loop settle the camera at that stop
 *                            (fully turned to face the case).
 *   __smoke.sample(n, i?)  — render synchronously, then read an n×n pixel
 *                            block centered on a poster and return its
 *                            mean/max luminance (0-1) plus the camera x. With
 *                            i given, samples case i (hall walk-turn check);
 *                            without it, samples the inspected case.
 */
import * as THREE from 'three';
import { GalleryEngine } from '../../components/gallery/GalleryEngine';
import { GalleryMode } from '../../components/gallery/galleryTypes';
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
    };
    eng.walk = stopIndex;
    eng.targetWalk = stopIndex;
    eng.lastInputTime = performance.now() - 10000;
  },
  sample: (blockSize = 60, caseIndex) => {
    // TS `private` is compile-time only — the harness reaches into the
    // engine to render synchronously (readPixels is only valid in the same
    // task as the draw; the drawing buffer is cleared after compositing).
    const eng = engine as unknown as {
      renderer: THREE.WebGLRenderer;
      scene: THREE.Scene;
      camera: THREE.PerspectiveCamera;
      cases: Array<{ poster: THREE.Mesh }>;
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
    return {
      mode: eng.mode,
      mean: sum / (bw * bh),
      max,
      centerX: cx,
      centerY: cy,
      blockSize,
      cameraX: eng.camera.position.x,
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
