import React from 'react';
import { LayoutGrid, Landmark } from 'lucide-react';
import { RankingViewMode } from '../../hooks/useGalleryViewMode';

interface GalleryModeToggleProps {
  mode: RankingViewMode;
  onChange: (mode: RankingViewMode) => void;
  /** false → gallery option disabled (no WebGL / suppressed this session). */
  supported: boolean;
}

export const GalleryModeToggle: React.FC<GalleryModeToggleProps> = ({
  mode,
  onChange,
  supported,
}) => (
  <div className="flex bg-card/50 rounded-lg p-1 border border-border/30">
    <button
      onClick={() => onChange('grid')}
      title="Grid view"
      aria-pressed={mode === 'grid'}
      className={`px-2.5 py-1.5 rounded-md text-xs font-semibold transition-all flex items-center gap-1.5 ${
        mode === 'grid'
          ? 'bg-secondary text-foreground shadow'
          : 'text-muted-foreground hover:text-foreground'
      }`}
    >
      <LayoutGrid size={13} />
    </button>
    <button
      onClick={() => supported && onChange('gallery')}
      disabled={!supported}
      title={
        supported
          ? 'Gallery view'
          : 'Gallery view needs WebGL, which is unavailable here'
      }
      aria-pressed={mode === 'gallery'}
      className={`px-2.5 py-1.5 rounded-md text-xs font-semibold transition-all flex items-center gap-1.5 ${
        mode === 'gallery'
          ? 'bg-secondary text-foreground shadow'
          : supported
            ? 'text-muted-foreground hover:text-foreground'
            : 'text-muted-foreground/30 cursor-not-allowed'
      }`}
    >
      <Landmark size={13} />
    </button>
  </div>
);
