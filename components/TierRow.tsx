import React from 'react';
import { Tier, RankedItem } from '../types';
import { MediaCard } from './MediaCard';
import { TIER_COLORS, TIER_LABELS } from '../constants';
import { useTranslation } from '../contexts/LanguageContext';

/** Tier-letter text color */
const TIER_TEXT_COLOR: Record<Tier, string> = {
  [Tier.S]: 'text-tier-s',
  [Tier.A]: 'text-tier-a',
  [Tier.B]: 'text-tier-b',
  [Tier.C]: 'text-tier-c',
  [Tier.D]: 'text-tier-d',
};

/** Subtle background tint per tier for the header strip */
const TIER_HEADER_BG: Record<Tier, string> = {
  [Tier.S]: 'bg-tier-s/8',
  [Tier.A]: 'bg-tier-a/8',
  [Tier.B]: 'bg-tier-b/8',
  [Tier.C]: 'bg-tier-c/8',
  [Tier.D]: 'bg-tier-d/8',
};

interface TierRowProps {
  tier: Tier;
  items: RankedItem[];
  scoreMap: Map<string, number>;
  showScores: boolean;
  onDrop: (e: React.DragEvent, tier: Tier) => void;
  onDragStart: (e: React.DragEvent, id: string) => void;
  onDropOnItem?: (e: React.DragEvent, id: string) => void;
  onDelete: (id: string) => void;
}

export const TierRow: React.FC<TierRowProps> = ({ tier, items, scoreMap, showScores, onDrop, onDragStart, onDropOnItem, onDelete }) => {
  const { t } = useTranslation();
  const handleDragOver = (e: React.DragEvent) => {
    e.preventDefault();
  };

  return (
    <div
      onDragOver={handleDragOver}
      onDrop={(e) => onDrop(e, tier)}
      className="relative flex flex-col bg-card/40 backdrop-blur-sm rounded-2xl border border-border/30 overflow-hidden min-h-[220px] transition-colors duration-300"
    >
      {/* Header */}
      <div className={`flex items-center justify-between px-4 py-3 md:px-6 md:py-4 ${TIER_HEADER_BG[tier]}`}>
        <div className="flex items-center gap-3">
          <span className={`font-serif text-3xl font-black select-none ${TIER_TEXT_COLOR[tier]}`}>{tier}</span>
          <span className="text-xs font-semibold tracking-widest uppercase text-muted-foreground">
            {TIER_LABELS[tier]}
          </span>
        </div>
        <div className="flex gap-2">
          {showScores && items.length > 0 && (
            <div className="text-xs font-mono text-muted-foreground px-2 py-1 bg-secondary rounded">
              {Math.min(...items.map(i => scoreMap.get(i.id) ?? 0)).toFixed(1)}–
              {Math.max(...items.map(i => scoreMap.get(i.id) ?? 0)).toFixed(1)} {t('tier.pts')}
            </div>
          )}
          <div className="text-xs font-mono text-muted-foreground px-2 py-1 bg-secondary rounded">
            {items.length} {t('tier.items')}
          </div>
        </div>
      </div>

      {/* Horizontal Scroll Area */}
      <div className="flex overflow-x-auto gap-4 px-4 py-3 items-start hide-scrollbar">
        {items.length === 0 ? (
          <div className="flex items-center justify-center w-full h-40 border-2 border-dashed border-border rounded-lg">
            <span className="text-sm font-medium text-muted-foreground/40 italic">{t('tier.nothingYet')}</span>
          </div>
        ) : (
          items.map((item, index) => (
            <MediaCard
              key={item.id}
              item={item}
              rank={index}
              score={scoreMap.get(item.id) ?? 0}
              showScore={showScores}
              onDragStart={onDragStart}
              onDragOver={(e) => {
                e.preventDefault();
                e.stopPropagation();
              }}
              onDrop={onDropOnItem}
              onDelete={onDelete}
            />
          ))
        )}
        {/* Spacer for easier dropping at the end */}
        <div className="w-12 h-full flex-shrink-0" />
      </div>
    </div>
  );
};
