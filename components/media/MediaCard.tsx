import React, { useState } from 'react';
import { RankedItem } from '../../types';
import { GripVertical, Film, Tv, BookOpen, Star, StickyNote, Trash2 } from 'lucide-react';
import { TIER_COLORS, TIER_LABELS } from '../../constants';
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
  onOpenJournal?: (tmdbId: string) => void;
  onRerank?: (item: RankedItem) => void;
}

export const MediaCard: React.FC<MediaCardProps> = ({ item, rank, score, showScore = true, onDragStart, onDragOver, onDrop, onDelete, onOpenJournal, onRerank }) => {
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
        className="group relative flex-shrink-0 w-32 md:w-40 cursor-pointer active:cursor-grabbing active:scale-95 transition-transform duration-200 select-none"
      >
        {/* Rank Badge */}
        <div className="absolute top-2 left-2 z-10 bg-black/70 backdrop-blur-sm px-2 py-0.5 rounded text-xs font-bold text-foreground border border-border/30">
          #{rank + 1}
        </div>

        {/* Season Badge (TV) */}
        {item.type === 'tv_season' && item.seasonNumber && (
          <div className="absolute top-2 left-14 z-10 bg-accent backdrop-blur-sm px-1.5 py-0.5 rounded-md text-[10px] font-semibold text-background border border-border/30 shadow-lg">
            S{item.seasonNumber}
          </div>
        )}

        {/* Score Badge */}
        {showScore && (
          <div className="absolute top-2 right-2 z-10 bg-gold/90 backdrop-blur-sm px-1.5 py-0.5 rounded text-xs font-bold text-background border border-border/30 flex items-center gap-1 shadow-lg">
            <Star size={10} className="fill-current" />
            <span>{score.toFixed(1)}</span>
          </div>
        )}

        {/* Poster Image */}
        <div className="relative aspect-[2/3] w-full rounded-xl overflow-hidden bg-secondary/40 border border-border/30 shadow-md">
          <img
            src={item.posterUrl}
            alt={item.title}
            className="w-full h-full object-cover opacity-90 group-hover:opacity-100 transition-opacity"
            draggable={false}
          />
          <div className="absolute inset-0 bg-gradient-to-t from-black/30 via-transparent to-transparent" />

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
          <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 opacity-0 group-hover:opacity-100 transition-opacity text-foreground/80 bg-black/60 p-2 rounded-full backdrop-blur-sm pointer-events-none">
            <GripVertical size={24} />
          </div>
        </div>

        {/* Title & Year (below poster) */}
        <div className="mt-1.5 px-1">
          <h3 className="text-xs text-foreground line-clamp-2 font-semibold leading-tight">{item.title}</h3>
          {item.type === 'book' && item.author && (
            <p className="text-[10px] text-muted-foreground/70 truncate mt-0.5">{item.author}</p>
          )}
          <div className="flex items-center gap-1.5 mt-0.5 text-[11px] text-muted-foreground">
            {item.type === 'book' ? <BookOpen size={11} /> : item.type === 'tv_season' ? <Tv size={11} /> : <Film size={11} />}
            <span>{item.year}</span>
            {item.notes && (
              <StickyNote size={10} className="text-gold ml-auto" />
            )}
          </div>
        </div>
      </div>

      {/* ── Detail Modal ─────────────────────────────────────────────────── */}
      {isOpen && (
        <MediaDetailModal
          initialItem={item}
          tmdbId={item.id}
          onClose={() => setIsOpen(false)}
          onOpenJournal={onOpenJournal}
          onRerank={onRerank}
        />
      )}
    </>
  );
};
