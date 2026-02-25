import React from 'react';
import { VIBE_TAGS } from '../../constants';

interface VibeTagSelectorProps {
  selected: string[];
  onChange: (tags: string[]) => void;
}

const chipBase = 'rounded-full px-3 py-1.5 text-xs font-medium border transition-colors whitespace-nowrap';
const chipActive = 'bg-purple-500/20 text-purple-300 border-purple-500/30';
const chipInactive = 'bg-transparent text-zinc-500 border-zinc-800 hover:border-zinc-600';

export const VibeTagSelector: React.FC<VibeTagSelectorProps> = ({ selected, onChange }) => {
  const toggle = (id: string) => {
    if (selected.includes(id)) {
      onChange(selected.filter((t) => t !== id));
    } else {
      onChange([...selected, id]);
    }
  };

  return (
    <div className="flex gap-1.5 flex-wrap">
      {VIBE_TAGS.map((tag) => (
        <button
          key={tag.id}
          type="button"
          className={`${chipBase} ${selected.includes(tag.id) ? chipActive : chipInactive}`}
          onClick={() => toggle(tag.id)}
        >
          {tag.emoji} {tag.label}
        </button>
      ))}
    </div>
  );
};
