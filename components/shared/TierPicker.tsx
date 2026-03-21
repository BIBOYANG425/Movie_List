import React from 'react';
import { Tier, Bracket, RankedItem } from '../../types';
import { TIER_COLORS, TIER_LABELS, BRACKET_LABELS } from '../../constants';
import { Film, BookOpen } from 'lucide-react';

interface TierPickerProps {
  selectedItem: RankedItem | null;
  currentItems: RankedItem[];
  onSelectTier: (tier: Tier) => void;
  onBracketChange: (bracket: Bracket) => void;
}

export const TierPicker: React.FC<TierPickerProps> = ({
  selectedItem,
  currentItems,
  onSelectTier,
  onBracketChange,
}) => (
  <div className="space-y-5 animate-fade-in">
    {/* Selected item preview */}
    <div className="flex items-center gap-4 bg-secondary p-4 rounded-xl border border-border">
      {selectedItem?.posterUrl ? (
        <img src={selectedItem.posterUrl} alt="" className="w-14 h-20 object-cover rounded-lg shadow-lg flex-shrink-0" />
      ) : (
        <div className="w-14 h-20 bg-card rounded-lg flex items-center justify-center flex-shrink-0">
          {selectedItem?.type === 'book' ? <BookOpen size={20} className="text-muted" /> : <Film size={20} className="text-muted" />}
        </div>
      )}
      <div>
        <h3 className="font-serif text-lg leading-tight text-foreground">{selectedItem?.title}</h3>
        <p className="text-muted-foreground text-sm mt-0.5">{selectedItem?.year}</p>
        {selectedItem?.seasonTitle && (
          <p className="text-muted text-xs mt-0.5">{selectedItem.seasonTitle}</p>
        )}
        {selectedItem?.type === 'book' && selectedItem?.author && (
          <p className="text-muted text-xs mt-0.5">{selectedItem.author}</p>
        )}
        <p className="text-muted text-sm mt-1">How does this tier feel?</p>
      </div>
    </div>

    {/* Bracket selector */}
    <div className="space-y-1.5">
      <p className="text-xs text-muted-foreground font-medium">Category</p>
      <div className="flex gap-1.5">
        {Object.values(Bracket).map((b) => (
          <button
            key={b}
            type="button"
            onClick={() => onBracketChange(b)}
            className={`flex-1 px-2 py-1.5 rounded-lg text-xs font-medium border transition-all ${
              selectedItem?.bracket === b
                ? 'bg-accent/20 text-accent border-accent/30'
                : 'bg-transparent text-muted-foreground border-border hover:border-border'
            }`}
          >
            {BRACKET_LABELS[b]}
          </button>
        ))}
      </div>
    </div>

    <div className="grid gap-2.5">
      {Object.values(Tier).map((tier) => (
        <button
          key={tier}
          onClick={() => onSelectTier(tier)}
          className={`flex items-center justify-between p-4 rounded-xl border-2 transition-all hover:scale-[1.02] active:scale-[0.98] ${TIER_COLORS[tier]}`}
        >
          <div className="flex items-center gap-4">
            <span className="text-2xl font-black">{tier}</span>
            <span className="font-semibold opacity-90">{TIER_LABELS[tier]}</span>
          </div>
          <span className="text-xs font-mono opacity-50 bg-black/20 px-2 py-1 rounded">
            {currentItems.filter(i => i.tier === tier).length} items
          </span>
        </button>
      ))}
    </div>
  </div>
);
