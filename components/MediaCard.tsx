import React, { useState } from 'react';
import { RankedItem } from '../types';
import { GripVertical, Film, Star, StickyNote, Trash2 } from 'lucide-react';
import { TIER_COLORS, TIER_LABELS } from '../constants';
import { MediaDetailModal } from './MediaDetailModal';

interface MediaCardProps {
  item: RankedItem;
  rank: number;
  score: number;
  showScore?: boolean;
  onDragStart: (e: React.DragEvent, id: string) => void;
  onDragOver?: (e: React.DragEvent, id: string) => void;
  onDrop?: (e: React.DragEvent, id: string) => void;
  onDelete: (id: string) => void;
}

export const MediaCard: React.FC<MediaCardProps> = ({ item, rank, score, showScore = true, onDragStart, onDragOver, onDrop, onDelete }) => {
  const [isOpen, setIsOpen] = useState(false);

  const handleClick = (e: React.MouseEvent) => {
    // Don't open detail if the user is trying to drag
    if ((e.target as HTMLElement).closest('[data-no-detail]')) return;
    setIsOpen(true);
  };

  return (
    <>
      {/* ── Card ─────────────────────────────────────────────────────────── */}
      <div
        draggable
        onDragStart={(e) => onDragStart(e, item.id)}
        onDragOver={(e) => onDragOver?.(e, item.id)}
        onDrop={(e) => onDrop?.(e, item.id)}
        onClick={handleClick}
        className="group relative flex-shrink-0 w-32 md:w-40 bg-zinc-900 rounded-lg overflow-hidden border border-zinc-800 hover:border-zinc-600 transition-all cursor-pointer active:cursor-grabbing shadow-lg select-none"
      >
        {/* Rank Badge */}
        <div className="absolute top-2 left-2 z-10 bg-black/70 backdrop-blur-sm px-2 py-0.5 rounded text-xs font-bold text-white border border-white/10">
          #{rank + 1}
        </div>

        {/* Score Badge */}
        {showScore && (
          <div className="absolute top-2 right-2 z-10 bg-indigo-500/90 backdrop-blur-sm px-1.5 py-0.5 rounded text-xs font-bold text-white border border-white/10 flex items-center gap-1 shadow-lg">
            <Star size={10} className="fill-current" />
            <span>{score.toFixed(1)}</span>
          </div>
        )}

        {/* Poster Image */}
        <div className="relative aspect-[2/3] w-full bg-zinc-800">
          <img
            src={item.posterUrl}
            alt={item.title}
            className="w-full h-full object-cover opacity-90 group-hover:opacity-100 transition-opacity"
            draggable={false}
          />
          <div className="absolute inset-0 bg-gradient-to-t from-black/90 via-transparent to-transparent opacity-80" />
        </div>

        {/* Content Overlay (Bottom) */}
        <div className="absolute bottom-0 left-0 right-0 p-3 pt-6">
          <h3 className="text-sm font-semibold text-white leading-tight truncate">{item.title}</h3>
          <div className="flex items-center gap-1.5 mt-1 text-xs text-zinc-400">
            <Film size={12} />
            <span>{item.year}</span>
            {item.notes && (
              <StickyNote size={10} className="text-amber-400 ml-auto" />
            )}
          </div>
        </div>

        {/* Delete button — hover only */}
        <button
          data-no-detail
          draggable={false}
          onClick={(e) => {
            e.stopPropagation();
            e.preventDefault();
            onDelete(item.id);
          }}
          className="absolute bottom-2 left-2 z-20 p-1.5 rounded-full bg-red-500/0 text-transparent group-hover:bg-red-500/20 group-hover:text-red-400 border border-transparent group-hover:border-red-500/30 hover:!bg-red-500/40 transition-all pointer-events-auto"
          title="Remove from list"
        >
          <Trash2 size={12} />
        </button>

        {/* Hover Drag Handle */}
        <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 opacity-0 group-hover:opacity-100 transition-opacity text-white/80 bg-black/60 p-2 rounded-full backdrop-blur-sm pointer-events-none">
          <GripVertical size={24} />
        </div>
      </div>

      {/* ── Detail Modal ─────────────────────────────────────────────────── */}
      {isOpen && (
        <MediaDetailModal
          initialItem={item}
          tmdbId={item.id}
          onClose={() => setIsOpen(false)}
        />
      )}
    </>
  );
};
