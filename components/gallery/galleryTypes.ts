import { Tier, RankedItem } from '../../types';

export type GalleryMode = 'hall' | 'focusing' | 'inspect' | 'returning';

export interface GalleryFocus {
  itemId: string;
  tier: Tier;
  indexInTier: number;
  roomIndex: number;
}

export interface GalleryEngineCallbacks {
  onModeChange(mode: GalleryMode, itemId: string | null): void;
  onFocusChange(focus: GalleryFocus): void;
  /** Announced via the visually-hidden live region in GalleryView. */
  onStatus(message: string): void;
  /** Unrecoverable engine failure — GalleryView falls back to the grid. */
  onFatal(reason: 'webgl-lost' | 'init-failed'): void;
}

export interface GalleryEngineOptions {
  items: RankedItem[];
  tierLabels: Record<Tier, string>;
  reducedMotion: boolean;
  callbacks: GalleryEngineCallbacks;
}

export interface GalleryDiagnostics {
  mode: GalleryMode;
  textures: number;
  drawCalls: number;
  triangles: number;
  pixelRatio: number;
}
