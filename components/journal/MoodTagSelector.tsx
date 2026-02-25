import React from 'react';
import { MOOD_TAGS, MOOD_CATEGORIES } from '../../constants';

interface MoodTagSelectorProps {
  selected: string[];
  onChange: (tags: string[]) => void;
  max?: number;
}

const chipBase = 'rounded-full px-3 py-1.5 text-xs font-medium border transition-colors whitespace-nowrap';
const chipActive = 'bg-indigo-500/20 text-indigo-300 border-indigo-500/30';
const chipInactive = 'bg-transparent text-zinc-500 border-zinc-800 hover:border-zinc-600';

export const MoodTagSelector: React.FC<MoodTagSelectorProps> = ({ selected, onChange, max = 10 }) => {
  const toggle = (id: string) => {
    if (selected.includes(id)) {
      onChange(selected.filter((t) => t !== id));
    } else if (selected.length < max) {
      onChange([...selected, id]);
    }
  };

  return (
    <div className="space-y-3">
      {MOOD_CATEGORIES.map((cat) => {
        const tags = MOOD_TAGS.filter((t) => t.category === cat.id);
        return (
          <div key={cat.id}>
            <p className="text-[10px] uppercase tracking-wider text-zinc-600 mb-1.5">{cat.label}</p>
            <div className="flex gap-1.5 flex-wrap">
              {tags.map((tag) => (
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
          </div>
        );
      })}
    </div>
  );
};
