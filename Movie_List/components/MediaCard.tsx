import React, { useState } from 'react';
import { RankedItem } from '../types';
import { GripVertical, Film, Star, StickyNote } from 'lucide-react';

interface MediaCardProps {
  item: RankedItem;
  rank: number;
  score: number;
  onDragStart: (e: React.DragEvent, id: string) => void;
}

export const MediaCard: React.FC<MediaCardProps> = ({ item, rank, score, onDragStart }) => {
  const [showNote, setShowNote] = useState(false);

  return (
    <div
      draggable
      onDragStart={(e) => onDragStart(e, item.id)}
      className="group relative flex-shrink-0 w-32 md:w-40 bg-zinc-900 rounded-lg overflow-hidden border border-zinc-800 hover:border-zinc-600 transition-all cursor-grab active:cursor-grabbing shadow-lg select-none"
    >
      {/* Rank Badge */}
      <div className="absolute top-2 left-2 z-10 bg-black/70 backdrop-blur-sm px-2 py-0.5 rounded text-xs font-bold text-white border border-white/10">
        #{rank + 1}
      </div>

      {/* Score Badge */}
      <div className="absolute top-2 right-2 z-10 bg-indigo-500/90 backdrop-blur-sm px-1.5 py-0.5 rounded text-xs font-bold text-white border border-white/10 flex items-center gap-1 shadow-lg">
        <Star size={10} className="fill-current" />
        <span>{score.toFixed(1)}</span>
      </div>

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
        </div>
      </div>

      {/* Notes indicator — bottom-left, only when notes exist */}
      {item.notes && (
        <button
          draggable={false}
          onClick={(e) => { e.stopPropagation(); setShowNote(v => !v); }}
          className="absolute bottom-10 right-2 z-20 p-1 rounded-full bg-amber-400/20 border border-amber-400/40 text-amber-400 hover:bg-amber-400/30 transition-colors pointer-events-auto"
          title="View note"
        >
          <StickyNote size={11} />
        </button>
      )}

      {/* Notes popover */}
      {item.notes && showNote && (
        <div
          className="absolute inset-0 z-30 bg-black/90 backdrop-blur-sm p-3 flex flex-col gap-2 pointer-events-auto"
          onClick={(e) => { e.stopPropagation(); setShowNote(false); }}
        >
          <div className="flex items-center gap-1.5 text-amber-400">
            <StickyNote size={12} />
            <span className="text-xs font-semibold">Your note</span>
          </div>
          <p className="text-xs text-zinc-300 leading-relaxed overflow-y-auto">{item.notes}</p>
          <p className="text-[10px] text-zinc-600 mt-auto">tap to close</p>
        </div>
      )}

      {/* Hover Drag Handle */}
      <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 opacity-0 group-hover:opacity-100 transition-opacity text-white/80 bg-black/60 p-2 rounded-full backdrop-blur-sm pointer-events-none">
        <GripVertical size={24} />
      </div>
    </div>
  );
};
