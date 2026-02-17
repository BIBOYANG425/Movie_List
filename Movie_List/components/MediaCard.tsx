import React, { useState } from 'react';
import { RankedItem } from '../types';
import { GripVertical, Film, Star, StickyNote, Trash2, X } from 'lucide-react';
import { TIER_COLORS, TIER_LABELS } from '../constants';

interface MediaCardProps {
  item: RankedItem;
  rank: number;
  score: number;
  onDragStart: (e: React.DragEvent, id: string) => void;
  onDelete: (id: string) => void;
}

export const MediaCard: React.FC<MediaCardProps> = ({ item, rank, score, onDragStart, onDelete }) => {
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
        onClick={handleClick}
        className="group relative flex-shrink-0 w-32 md:w-40 bg-zinc-900 rounded-lg overflow-hidden border border-zinc-800 hover:border-zinc-600 transition-all cursor-pointer active:cursor-grabbing shadow-lg select-none"
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
        <div
          className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm"
          onClick={() => setIsOpen(false)}
        >
          <div
            className="bg-zinc-950 border border-zinc-800 w-full max-w-sm rounded-2xl shadow-2xl overflow-hidden animate-fade-in"
            onClick={(e) => e.stopPropagation()}
          >
            {/* Poster header */}
            <div className="relative aspect-[3/2] w-full bg-zinc-900 overflow-hidden">
              <img
                src={item.posterUrl}
                alt={item.title}
                className="w-full h-full object-cover"
              />
              <div className="absolute inset-0 bg-gradient-to-t from-zinc-950 via-zinc-950/40 to-transparent" />

              {/* Close button */}
              <button
                onClick={() => setIsOpen(false)}
                className="absolute top-3 right-3 p-1.5 rounded-full bg-black/50 backdrop-blur-sm text-zinc-400 hover:text-white border border-white/10 transition-colors"
              >
                <X size={16} />
              </button>

              {/* Title over poster */}
              <div className="absolute bottom-0 left-0 right-0 p-5">
                <h2 className="text-xl font-bold text-white leading-tight">{item.title}</h2>
                <div className="flex items-center gap-2 mt-1.5 text-sm text-zinc-400">
                  <Film size={14} />
                  <span>{item.year}</span>
                  {item.genres?.length > 0 && (
                    <>
                      <span className="text-zinc-700">·</span>
                      <span>{item.genres.join(', ')}</span>
                    </>
                  )}
                </div>
              </div>
            </div>

            {/* Details body */}
            <div className="p-5 space-y-4">
              {/* Score + Tier row */}
              <div className="flex items-center gap-3">
                <div className="flex items-center gap-1.5 bg-indigo-500/15 border border-indigo-500/30 px-3 py-1.5 rounded-lg">
                  <Star size={14} className="fill-indigo-400 text-indigo-400" />
                  <span className="text-lg font-bold text-white">{score.toFixed(1)}</span>
                </div>
                <div className={`px-3 py-1.5 rounded-lg border font-bold text-sm ${TIER_COLORS[item.tier]}`}>
                  {item.tier} — {TIER_LABELS[item.tier]}
                </div>
                <div className="ml-auto text-sm text-zinc-500 font-mono">
                  #{rank + 1}
                </div>
              </div>

              {/* Review/Notes */}
              {item.notes ? (
                <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4">
                  <div className="flex items-center gap-1.5 mb-2">
                    <StickyNote size={13} className="text-amber-400" />
                    <span className="text-xs font-semibold text-amber-400 uppercase tracking-wider">Your Review</span>
                  </div>
                  <p className="text-sm text-zinc-300 leading-relaxed whitespace-pre-wrap">{item.notes}</p>
                </div>
              ) : (
                <div className="bg-zinc-900/50 border border-zinc-800/50 border-dashed rounded-xl p-4 text-center">
                  <StickyNote size={18} className="text-zinc-700 mx-auto mb-1.5" />
                  <p className="text-xs text-zinc-600">No review added</p>
                </div>
              )}
            </div>
          </div>
        </div>
      )}
    </>
  );
};
