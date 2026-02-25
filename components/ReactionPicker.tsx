import React from 'react';
import { ReactionType } from '../types';

interface ReactionPickerProps {
  reactionCounts: Record<ReactionType, number>;
  myReactions: ReactionType[];
  onToggle: (reaction: ReactionType) => void;
  disabled?: boolean;
}

const REACTIONS: { type: ReactionType; emoji: string }[] = [
  { type: 'fire', emoji: '\u{1F525}' },
  { type: 'agree', emoji: '\u{1F91D}' },
  { type: 'disagree', emoji: '\u{1F62C}' },
  { type: 'want_to_watch', emoji: '\u{1F440}' },
  { type: 'love', emoji: '\u{2764}\u{FE0F}' },
];

export const ReactionPicker: React.FC<ReactionPickerProps> = ({
  reactionCounts,
  myReactions,
  onToggle,
  disabled = false,
}) => {
  return (
    <div className="flex gap-1.5">
      {REACTIONS.map(({ type, emoji }) => {
        const count = reactionCounts[type] ?? 0;
        const isActive = myReactions.includes(type);

        return (
          <button
            key={type}
            type="button"
            disabled={disabled}
            onClick={() => onToggle(type)}
            className={`flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs transition-colors ${
              isActive
                ? 'bg-indigo-500/20 border-indigo-500/40 text-white'
                : 'bg-zinc-800/50 border-zinc-800 text-zinc-400 hover:border-zinc-600'
            } ${disabled ? 'opacity-50 cursor-not-allowed' : 'cursor-pointer'}`}
          >
            <span>{emoji}</span>
            {count > 0 && <span>{count}</span>}
          </button>
        );
      })}
    </div>
  );
};
