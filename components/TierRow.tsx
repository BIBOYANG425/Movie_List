import React from 'react';
import { Tier, RankedItem } from '../types';
import { MediaCard } from './MediaCard';
import { TIER_COLORS, TIER_LABELS } from '../constants';
import { useTranslation } from '../contexts/LanguageContext';

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
      className={`relative flex flex-col gap-2 p-4 md:p-6 rounded-xl border-2 transition-colors duration-300 ${TIER_COLORS[tier]} min-h-[220px]`}
    >
      {/* Header */}
      <div className="flex items-center justify-between mb-2">
        <div className="flex items-center gap-3">
          <span className="text-4xl font-black opacity-40 select-none">{tier}</span>
          <span className="text-sm font-semibold tracking-wider uppercase opacity-80">
            {TIER_LABELS[tier]}
          </span>
        </div>
        <div className="flex gap-2">
          {showScores && items.length > 0 && (
            <div className="text-xs font-mono opacity-50 px-2 py-1 bg-black/20 rounded">
              {Math.min(...items.map(i => scoreMap.get(i.id) ?? 0)).toFixed(1)}–
              {Math.max(...items.map(i => scoreMap.get(i.id) ?? 0)).toFixed(1)} {t('tier.pts')}
            </div>
          )}
          <div className="text-xs font-mono opacity-50 px-2 py-1 bg-black/20 rounded">
            {items.length} {t('tier.items')}
          </div>
        </div>
      </div>

      {/* Horizontal Scroll Area */}
      <div className="flex overflow-x-auto gap-4 pb-4 items-start hide-scrollbar">
        {items.length === 0 ? (
          <div className="flex items-center justify-center w-full h-40 border-2 border-dashed border-current opacity-20 rounded-lg">
            <span className="text-sm font-medium">{t('tier.nothingYet')}</span>
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
