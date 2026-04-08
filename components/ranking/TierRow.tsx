import React, { useState } from 'react';
import { Tier, RankedItem } from '../../types';
import { MediaCard } from '../media/MediaCard';
import { TIER_COLORS, TIER_LABELS } from '../../constants';
import { useTranslation } from '../../contexts/LanguageContext';
import { Maximize2, X } from 'lucide-react';

/** Tier-letter text color */
const TIER_TEXT_COLOR: Record<Tier, string> = {
  [Tier.S]: 'text-tier-s',
  [Tier.A]: 'text-tier-a',
  [Tier.B]: 'text-tier-b',
  [Tier.C]: 'text-tier-c',
  [Tier.D]: 'text-tier-d',
};

/** Background tint per tier for the header strip */
const TIER_HEADER_BG: Record<Tier, string> = {
  [Tier.S]: 'bg-tier-s/10',
  [Tier.A]: 'bg-tier-a/10',
  [Tier.B]: 'bg-tier-b/10',
  [Tier.C]: 'bg-tier-c/10',
  [Tier.D]: 'bg-tier-d/10',
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
  onOpenJournal?: (tmdbId: string) => void;
  onRerank?: (item: RankedItem) => void;
  index?: number;
}

export const TierRow: React.FC<TierRowProps> = ({ tier, items, scoreMap, showScores, onDrop, onDragStart, onDropOnItem, onDelete, onOpenJournal, onRerank, index = 0 }) => {
  const { t } = useTranslation();
  const [expanded, setExpanded] = useState(false);
  const handleDragOver = (e: React.DragEvent) => {
    e.preventDefault();
  };

  const header = (
    <div className={`flex items-center justify-between px-4 py-3 md:px-6 md:py-4 ${TIER_HEADER_BG[tier]}`}>
      <div className="flex items-center gap-3">
        <span className={`font-serif text-4xl font-black select-none drop-shadow-[0_0_8px_currentColor] ${TIER_TEXT_COLOR[tier]}`}>{tier}</span>
        <span className="text-xs font-semibold tracking-widest uppercase text-muted-foreground">
          {TIER_LABELS[tier]}
        </span>
      </div>
      <div className="flex items-center gap-2">
        {showScores && items.length > 0 && (
          <div className="text-xs font-mono text-muted-foreground px-2 py-1 bg-secondary rounded">
            {Math.min(...items.map(i => scoreMap.get(i.id) ?? 0)).toFixed(1)}–
            {Math.max(...items.map(i => scoreMap.get(i.id) ?? 0)).toFixed(1)} {t('tier.pts')}
          </div>
        )}
        <div className="text-xs font-mono text-muted-foreground px-2 py-1 bg-secondary rounded">
          {items.length} {t('tier.items')}
        </div>
        {items.length > 0 && (
          <button
            onClick={() => setExpanded(!expanded)}
            className="p-1.5 rounded-lg text-muted-foreground hover:text-foreground hover:bg-secondary/50 transition-colors"
            title={expanded ? 'Collapse' : 'Expand'}
          >
            {expanded ? <X size={16} /> : <Maximize2 size={16} />}
          </button>
        )}
      </div>
    </div>
  );

  const cardList = items.map((item, index) => (
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
      onOpenJournal={onOpenJournal}
      onRerank={onRerank}
    />
  ));

  // Fullscreen expanded view
  if (expanded) {
    return (
      <>
        {/* Collapsed placeholder so layout doesn't jump */}
        <div
          onDragOver={handleDragOver}
          onDrop={(e) => onDrop(e, tier)}
          className="relative flex flex-col bg-card/40 backdrop-blur-sm rounded-2xl border border-border/30 overflow-hidden transition-colors duration-300"
        >
          {header}
        </div>

        {/* Fullscreen overlay */}
        <div className="fixed inset-0 z-50 bg-background/95 backdrop-blur-xl flex flex-col overflow-hidden">
          {/* Sticky header */}
          <div className="flex-shrink-0 border-b border-border/30">
            {header}
          </div>

          {/* Grid of cards */}
          <div className="flex-1 overflow-y-auto p-4">
            <div className="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-5 lg:grid-cols-6 xl:grid-cols-8 gap-4">
              {cardList}
            </div>
          </div>
        </div>
      </>
    );
  }

  // Normal inline view
  return (
    <div
      onDragOver={handleDragOver}
      onDrop={(e) => onDrop(e, tier)}
      className="relative flex flex-col bg-card/40 backdrop-blur-sm rounded-2xl border border-border/30 overflow-hidden min-h-[220px] transition-colors duration-300 animate-fade-in-up"
      style={{ animationDelay: `${index * 80}ms` }}
    >
      {header}

      {/* Horizontal Scroll Area */}
      <div className="flex overflow-x-auto gap-4 px-4 py-3 items-start hide-scrollbar">
        {items.length === 0 ? (
          <div className="flex items-center justify-center w-full h-40 border-2 border-dashed border-border rounded-lg">
            <span className="text-sm font-medium text-muted-foreground/40 italic">{t('tier.nothingYet')}</span>
          </div>
        ) : (
          cardList
        )}
        {/* Spacer for easier dropping at the end */}
        <div className="w-12 h-full flex-shrink-0" />
      </div>
    </div>
  );
};
