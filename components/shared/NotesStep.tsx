import React from 'react';
import { RankedItem, Tier } from '../../types';
import { TIER_COLORS, TIER_LABELS } from '../../constants';
import { Film, StickyNote, ChevronRight, Users } from 'lucide-react';
import { FriendTagInput } from '../journal/FriendTagInput';

const MAX_NOTES = 280;

interface NotesStepProps {
  selectedItem: RankedItem | null;
  selectedTier: Tier | null;
  notes: string;
  onNotesChange: (notes: string) => void;
  onContinue: () => void;
  onSkip: () => void;
  // Watched-with tagging (optional)
  currentUserId?: string;
  watchedWithUserIds?: string[];
  onWatchedWithChange?: (userIds: string[]) => void;
}

export const NotesStep: React.FC<NotesStepProps> = ({
  selectedItem,
  selectedTier,
  notes,
  onNotesChange,
  onContinue,
  onSkip,
  currentUserId,
  watchedWithUserIds,
  onWatchedWithChange,
}) => (
  <div className="flex flex-col gap-5 animate-fade-in">
    {/* Item preview */}
    <div className="flex items-center gap-4 bg-secondary p-4 rounded-xl border border-border">
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
        <p className="font-serif text-foreground leading-tight">{selectedItem?.title}</p>
        <p className="text-muted-foreground text-xs mt-0.5">{selectedItem?.year}</p>
        {selectedItem?.seasonTitle && (
          <p className="text-muted text-xs mt-0.5">{selectedItem.seasonTitle}</p>
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
      <label className="flex items-center gap-2 text-sm font-semibold text-muted-foreground">
        <StickyNote size={15} className="text-gold" />
        Your thoughts
        <span className="text-muted-foreground font-normal text-xs">(optional)</span>
      </label>
      <div className="relative">
        <textarea
          autoFocus
          rows={4}
          maxLength={MAX_NOTES}
          placeholder="What stood out? A scene, a feeling, why it deserves this tier..."
          className="w-full bg-card border border-border rounded-xl py-3 px-4 text-foreground placeholder:text-muted focus:outline-none focus:border-amber-500/60 transition-colors resize-none text-sm leading-relaxed"
          value={notes}
          onChange={(e) => onNotesChange(e.target.value)}
        />
        <span className={`absolute bottom-3 right-3 text-xs tabular-nums transition-colors ${notes.length > MAX_NOTES * 0.9 ? 'text-gold' : 'text-muted-foreground'}`}>
          {notes.length}/{MAX_NOTES}
        </span>
      </div>
    </div>

    {/* Watched with */}
    {currentUserId && onWatchedWithChange && (
      <div className="space-y-2">
        <label className="flex items-center gap-2 text-sm font-semibold text-muted-foreground">
          <Users size={15} className="text-accent" />
          Watched with
          <span className="text-muted-foreground font-normal text-xs">(optional)</span>
        </label>
        <FriendTagInput
          currentUserId={currentUserId}
          friendsOnly
          selectedUserIds={watchedWithUserIds ?? []}
          onChange={onWatchedWithChange}
        />
      </div>
    )}

    {/* Action buttons */}
    <div className="flex flex-col gap-2 pt-1">
      <button
        onClick={onContinue}
        className="w-full flex items-center justify-center gap-2 py-3 rounded-xl bg-gold text-background font-semibold text-sm hover:bg-foreground/20 transition-colors"
      >
        Continue
        <ChevronRight size={16} />
      </button>
      <button
        onClick={onSkip}
        className="w-full py-2.5 rounded-xl text-muted-foreground hover:text-muted-foreground text-sm transition-colors"
      >
        Skip — add without notes
      </button>
    </div>
  </div>
);
