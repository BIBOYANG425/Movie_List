import React, { useEffect, useMemo, useRef, useState } from 'react';
import { Tier, RankedItem } from '../../types';
import { TIERS, TIER_LABELS } from '../../constants';
import { useTranslation } from '../../contexts/LanguageContext';
import { useInspectDetails } from '../../hooks/useInspectDetails';
import { GalleryEngine } from './GalleryEngine';
import { GalleryFocus, GalleryMode } from './galleryTypes';
import { tmdbImageAtSize } from './textureWindow';

interface GalleryViewProps {
  /** RankingAppPage's localizedItems — same input as the grid. */
  items: RankedItem[];
  scoreMap: Map<string, number>;
  showScores: boolean;
  /** RankingAppPage.handleRerankItem — raw-item + locale contract lives there. */
  onRerank: (item: RankedItem) => void;
  /** Fatal engine failure → parent flips this session back to the grid. */
  onFallbackToGrid: () => void;
}

function mediumLine(item: RankedItem, runtimeMinutes: number | null, episodeCount: number | null, genres: string[]): string {
  const genrePart = genres.slice(0, 3).join(' · ');
  if (item.type === 'tv_season') {
    const episodes = episodeCount ? `${episodeCount} episodes` : 'TV season';
    return genrePart ? `${episodes} · ${genrePart}` : episodes;
  }
  if (item.type === 'book') {
    const pages = item.pageCount ? `${item.pageCount} pages` : 'Book';
    return genrePart ? `${pages} · ${genrePart}` : pages;
  }
  if (runtimeMinutes) {
    const hours = Math.floor(runtimeMinutes / 60);
    const minutes = runtimeMinutes % 60;
    const runtime = hours > 0 ? `${hours}h ${minutes}m` : `${minutes}m`;
    return genrePart ? `Feature film, ${runtime} · ${genrePart}` : `Feature film, ${runtime}`;
  }
  return genrePart ? `Feature film · ${genrePart}` : 'Feature film';
}

const GalleryView: React.FC<GalleryViewProps> = ({
  items,
  scoreMap,
  showScores,
  onRerank,
  onFallbackToGrid,
}) => {
  const { t } = useTranslation();
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const engineRef = useRef<GalleryEngine | null>(null);

  const [mode, setMode] = useState<GalleryMode>('hall');
  const [focus, setFocus] = useState<GalleryFocus | null>(null);
  const [inspectItemId, setInspectItemId] = useState<string | null>(null);
  const [status, setStatus] = useState('');
  const [crossfading, setCrossfading] = useState(false);

  const inspectItem = useMemo(
    () => items.find((i) => i.id === inspectItemId) ?? null,
    [items, inspectItemId],
  );
  const details = useInspectDetails(inspectItem);

  const tiersWithItems = useMemo(() => {
    const set = new Set(items.map((i) => i.tier));
    return set;
  }, [items]);

  // Engine lifecycle. Items flow in via setItems below; the engine is
  // created once per mount.
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return undefined;

    const reducedMotionQuery = window.matchMedia(
      '(prefers-reduced-motion: reduce)',
    );

    const engine = new GalleryEngine(canvas, {
      items,
      tierLabels: TIER_LABELS,
      reducedMotion: reducedMotionQuery.matches,
      callbacks: {
        onModeChange: (nextMode, itemId) => {
          setMode(nextMode);
          if (nextMode === 'focusing') setInspectItemId(itemId);
          if (nextMode === 'hall') setInspectItemId(null);
        },
        onFocusChange: setFocus,
        onStatus: setStatus,
        onFatal: () => onFallbackToGrid(),
      },
    });
    engineRef.current = engine;
    engine.onCrossfade(() => {
      setCrossfading(true);
      window.setTimeout(() => setCrossfading(false), 220);
    });

    const handleMotionChange = (event: MediaQueryListEvent) => {
      engine.setReducedMotion(event.matches);
    };
    reducedMotionQuery.addEventListener('change', handleMotionChange);

    return () => {
      reducedMotionQuery.removeEventListener('change', handleMotionChange);
      engine.onCrossfade(null);
      engine.dispose();
      engineRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Rank/tier changes re-lay the corridor (returning from Re-rank included).
  useEffect(() => {
    engineRef.current?.setItems(items);
  }, [items]);

  // Stage-2 async backdrop: detail fetch resolves → engine environment.
  useEffect(() => {
    if (!inspectItem) return;
    if (details.loading) return;
    engineRef.current?.setBackdrop(
      inspectItem.id,
      details.backdropUrl
        ? tmdbImageAtSize(details.backdropUrl, 'w780')
        : null,
    );
  }, [inspectItem, details.backdropUrl, details.loading]);

  const closeInspect = () => engineRef.current?.closeInspect();

  const tierCount = inspectItem
    ? items.filter((i) => i.tier === inspectItem.tier).length
    : 0;
  const score = inspectItem ? scoreMap.get(inspectItem.id) : undefined;
  const note = inspectItem?.notes?.trim() ?? '';
  const truncatedNote =
    note.length > 280 ? `${note.slice(0, 280).trimEnd()}…` : note;
  const placardVisible =
    (mode === 'focusing' || mode === 'inspect') && inspectItem !== null;

  return (
    <div
      ref={containerRef}
      className="relative w-full h-[calc(100dvh-230px)] min-h-[480px] rounded-2xl overflow-hidden bg-[#050505] select-none"
    >
      <canvas
        ref={canvasRef}
        tabIndex={0}
        role="application"
        aria-label="Gallery view of your ranked collection"
        className={`absolute inset-0 w-full h-full outline-none transition-opacity duration-200 ${
          crossfading ? 'opacity-0' : 'opacity-100'
        }`}
        style={{ touchAction: 'none' }}
      />

      {/* Visually-hidden live region — narrated status (technique 12). */}
      <div aria-live="polite" className="sr-only">
        {status}
      </div>

      {/* Focused title — only on hover/press, per the minimalist spec. */}
      {mode === 'hall' && focus && (
        <div className="pointer-events-none absolute bottom-14 inset-x-0 text-center">
          <span className="text-[13px] text-[#87837b] font-serif italic">
            {items.find((i) => i.id === focus.itemId)?.title}
          </span>
        </div>
      )}

      {/* Understated text tier-nav; doubles as fast travel. */}
      {mode === 'hall' && (
        <nav
          aria-label="Tiers"
          className="absolute bottom-4 inset-x-0 flex items-center justify-center gap-6"
        >
          {TIERS.map((tier: Tier) => {
            const hasItems = tiersWithItems.has(tier);
            const active = focus?.tier === tier;
            return (
              <button
                key={tier}
                disabled={!hasItems}
                onClick={() => {
                  engineRef.current?.travelToTier(tier);
                  canvasRef.current?.focus({ preventScroll: true });
                }}
                className={`font-serif text-sm tracking-[0.3em] pl-[0.3em] transition-colors ${
                  active
                    ? 'text-[#e7e2d6] border-b border-[#d2a85f]'
                    : hasItems
                      ? 'text-[#87837b] hover:text-[#cfcbc2]'
                      : 'text-[#3a3a40] cursor-default'
                }`}
              >
                {tier}
              </button>
            );
          })}
        </nav>
      )}

      {/* Museum placard — HTML overlay, never WebGL text. */}
      {placardVisible && inspectItem && (
        <div
          className="absolute inset-0 flex md:items-end md:justify-end items-end justify-center pointer-events-none"
          aria-modal="true"
          role="dialog"
          aria-label={`${inspectItem.title} details`}
        >
          <div
            className="pointer-events-auto m-4 md:m-8 w-full md:w-[min(41%,380px)] max-w-[420px] bg-[#f2ede1] text-[#23211c] p-5 shadow-2xl"
            onPointerDown={(e) => e.stopPropagation()}
          >
            <h2 className="font-serif italic text-xl leading-snug">
              {inspectItem.title}
            </h2>
            <p className="text-xs text-[#57534a] mt-0.5">
              {details.director ??
                inspectItem.director ??
                inspectItem.creator ??
                inspectItem.author ??
                '—'}
              , {inspectItem.year}
            </p>
            <p className="text-[11px] italic text-[#6b675d] border-b border-[#d8d2c2] pb-2 mb-2 mt-1.5">
              {mediumLine(
                inspectItem,
                details.runtimeMinutes,
                details.episodeCount,
                details.genres.length > 0 ? details.genres : inspectItem.genres,
              )}
            </p>
            {truncatedNote && (
              <p className="text-[13px] leading-relaxed">
                <span className="font-semibold">Curator’s note:</span>{' '}
                {truncatedNote}
              </p>
            )}
            <p className="text-[10px] text-[#8a8474] mt-2.5 tracking-wide uppercase">
              {inspectItem.tier} Tier · No. {inspectItem.rank + 1} of{' '}
              {tierCount}
              {showScores && score !== undefined && ` · ★ ${score.toFixed(1)}`}
            </p>
            <div className="flex items-center gap-4 mt-3 text-xs">
              <button
                onClick={() => {
                  closeInspect();
                  onRerank(inspectItem);
                }}
                className="border-b border-[#8a8474] hover:text-[#57534a] transition-colors"
              >
                {t('detail.reRank')}
              </button>
              <button
                onClick={closeInspect}
                className="border-b border-transparent text-[#8a8474] hover:text-[#57534a] transition-colors"
              >
                Esc — return to wall
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default GalleryView;
