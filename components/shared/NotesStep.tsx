import React from 'react';
import { RankedItem, Tier } from '../../types';
import { TIER_COLORS, TIER_LABELS } from '../../constants';
import { Film, StickyNote, ChevronRight } from 'lucide-react';

const MAX_NOTES = 280;

interface NotesStepProps {
  selectedItem: RankedItem | null;
  selectedTier: Tier | null;
  notes: string;
  onNotesChange: (notes: string) => void;
  onContinue: () => void;
  onSkip: () => void;
}

export const NotesStep: React.FC<NotesStepProps> = ({
  selectedItem,
  selectedTier,
  notes,
  onNotesChange,
  onContinue,
  onSkip,
}) => (
  <div className="flex flex-col gap-5 animate-fade-in">
    {/* Item preview */}
    <div className="flex items-center gap-4 bg-elevated p-4 rounded-xl border border-border">
      {selectedItem?.posterUrl ? (
        <img
          src={selectedItem.posterUrl}
          alt=""
          className="w-12 h-[72px] object-cover rounded-lg shadow-md flex-shrink-0"
        />
      ) : (
        <div className="w-12 h-[72px] bg-card rounded-lg flex items-center justify-center flex-shrink-0">
          <Film size={18} className="text-muted" />
        </div>
      )}
      <div>
        <p className="font-serif text-white leading-tight">{selectedItem?.title}</p>
        <p className="text-dim text-xs mt-0.5">{selectedItem?.year}</p>
        {selectedItem?.seasonTitle && (
          <p className="text-muted text-[11px] mt-0.5">{selectedItem.seasonTitle}</p>
        )}
        {selectedTier && (
          <span className={`inline-block mt-2 text-xs font-bold px-2 py-0.5 rounded-full border ${TIER_COLORS[selectedTier]}`}>
            {selectedTier} — {TIER_LABELS[selectedTier]}
          </span>
        )}
      </div>
    </div>

    {/* Notes textarea */}
    <div className="space-y-2">
      <label className="flex items-center gap-2 text-sm font-semibold text-zinc-300">
        <StickyNote size={15} className="text-amber-400" />
        Your thoughts
        <span className="text-dim font-normal text-xs">(optional)</span>
      </label>
      <div className="relative">
        <textarea
          autoFocus
          rows={4}
          maxLength={MAX_NOTES}
          placeholder="What stood out? A scene, a feeling, why it deserves this tier..."
          className="w-full bg-card border border-border rounded-xl py-3 px-4 text-white placeholder:text-muted focus:outline-none focus:border-amber-500/60 transition-colors resize-none text-sm leading-relaxed"
          value={notes}
          onChange={(e) => onNotesChange(e.target.value)}
        />
        <span className={`absolute bottom-3 right-3 text-xs tabular-nums transition-colors ${notes.length > MAX_NOTES * 0.9 ? 'text-amber-400' : 'text-dim'}`}>
          {notes.length}/{MAX_NOTES}
        </span>
      </div>
    </div>

    {/* Action buttons */}
    <div className="flex flex-col gap-2 pt-1">
      <button
        onClick={onContinue}
        className="w-full flex items-center justify-center gap-2 py-3 rounded-xl bg-white text-black font-semibold text-sm hover:bg-zinc-200 transition-colors"
      >
        Continue
        <ChevronRight size={16} />
      </button>
      <button
        onClick={onSkip}
        className="w-full py-2.5 rounded-xl text-zinc-500 hover:text-zinc-300 text-sm transition-colors"
      >
        Skip — add without notes
      </button>
    </div>
  </div>
);
