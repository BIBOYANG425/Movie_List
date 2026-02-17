import React from 'react';
import { Tier, RankedItem } from '../types';
import { MediaCard } from './MediaCard';
import { TIER_COLORS, TIER_LABELS, TIER_SCORE_RANGES } from '../constants';

interface TierRowProps {
  tier: Tier;
  items: RankedItem[];
  onDrop: (e: React.DragEvent, tier: Tier) => void;
  onDragStart: (e: React.DragEvent, id: string) => void;
  onDelete: (id: string) => void;
}

export const TierRow: React.FC<TierRowProps> = ({ tier, items, onDrop, onDragStart, onDelete }) => {
  const handleDragOver = (e: React.DragEvent) => {
    e.preventDefault();
  };

  const calculateScore = (index: number, total: number) => {
    const range = TIER_SCORE_RANGES[tier];
    if (total <= 1) return range.max;
    
    // Linearly interpolate between max and min based on rank
    const step = (range.max - range.min) / (total - 1);
    const score = range.max - (index * step);
    return score;
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
           <div className="text-xs font-mono opacity-50 px-2 py-1 bg-black/20 rounded">
             {TIER_SCORE_RANGES[tier].min}-{TIER_SCORE_RANGES[tier].max} pts
           </div>
           <div className="text-xs font-mono opacity-50 px-2 py-1 bg-black/20 rounded">
            {items.length} items
          </div>
        </div>
      </div>

      {/* Horizontal Scroll Area */}
      <div className="flex overflow-x-auto gap-4 pb-4 items-start hide-scrollbar">
        {items.length === 0 ? (
          <div className="flex items-center justify-center w-full h-40 border-2 border-dashed border-current opacity-20 rounded-lg">
            <span className="text-sm font-medium">Nothing here yet</span>
          </div>
        ) : (
          items.map((item, index) => (
            <MediaCard
              key={item.id}
              item={item}
              rank={index}
              score={calculateScore(index, items.length)}
              onDragStart={onDragStart}
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
