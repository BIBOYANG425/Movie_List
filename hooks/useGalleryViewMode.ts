import { useCallback, useEffect, useState } from 'react';
import { isWebGLAvailable } from '../components/gallery/webglSupport';

export type RankingViewMode = 'grid' | 'gallery';

const STORAGE_KEY = 'spool.rankingViewMode';
const SUPPRESS_KEY = 'spool.gallerySuppressed';

/**
 * Device-local view-mode preference (v1; a Supabase profile column is a
 * follow-up if cross-device sync matters). Defaults to 'grid' — the gallery
 * becomes someone's default only after they opt in once. A session-scoped
 * suppression flag (set after a fatal engine failure) forces 'grid' without
 * touching the saved preference, so the next session tries again.
 */
export function useGalleryViewMode(): {
  viewMode: RankingViewMode;
  setViewMode: (mode: RankingViewMode) => void;
  gallerySupported: boolean;
  suppressGalleryForSession: () => void;
} {
  const [gallerySupported] = useState(() => isWebGLAvailable());
  const [suppressed, setSuppressed] = useState(() => {
    try {
      return sessionStorage.getItem(SUPPRESS_KEY) === '1';
    } catch {
      return false;
    }
  });
  const [preference, setPreference] = useState<RankingViewMode>(() => {
    try {
      return localStorage.getItem(STORAGE_KEY) === 'gallery'
        ? 'gallery'
        : 'grid';
    } catch {
      return 'grid';
    }
  });

  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, preference);
    } catch {
      // Private-mode storage failures fall back to in-memory state.
    }
  }, [preference]);

  const suppressGalleryForSession = useCallback(() => {
    setSuppressed(true);
    try {
      sessionStorage.setItem(SUPPRESS_KEY, '1');
    } catch {
      // ignore
    }
  }, []);

  const viewMode: RankingViewMode =
    gallerySupported && !suppressed ? preference : 'grid';

  return {
    viewMode,
    setViewMode: setPreference,
    gallerySupported: gallerySupported && !suppressed,
    suppressGalleryForSession,
  };
}
