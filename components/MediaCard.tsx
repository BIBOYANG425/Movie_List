import React from 'react';
import { RankedItem } from '../types';
import { GripVertical, Film, Theater, Star } from 'lucide-react';

interface MediaCardProps {
  item: RankedItem;
  rank: number;
  score: number;
  onDragStart: (e: React.DragEvent, id: string) => void;
}

export const MediaCard: React.FC<MediaCardProps> = ({ item, rank, score, onDragStart }) => {
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
          {item.type === 'movie' ? <Film size={12} /> : <Theater size={12} />}
          <span>{item.year}</span>
        </div>
      </div>

      {/* Hover Drag Handle Indicator (Now center to avoid conflict with score) */}
      <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 opacity-0 group-hover:opacity-100 transition-opacity text-white/80 bg-black/60 p-2 rounded-full backdrop-blur-sm pointer-events-none">
        <GripVertical size={24} />
      </div>
    </div>
  );
};
