let cached: boolean | null = null;

/** Cheap once-per-session probe; SSR-safe (false without a window). */
export function isWebGLAvailable(): boolean {
  if (cached !== null) return cached;
  try {
    if (typeof window === 'undefined' || typeof document === 'undefined') {
      cached = false;
      return cached;
    }
    const canvas = document.createElement('canvas');
    const gl =
      canvas.getContext('webgl2') ??
      canvas.getContext('webgl') ??
      canvas.getContext('experimental-webgl');
    cached = Boolean(gl);
  } catch {
    cached = false;
  }
  return cached;
}
