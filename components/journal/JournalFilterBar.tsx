import React from 'react';
import { JournalFilters, Tier } from '../../types';
import { MOOD_TAGS, VIBE_TAGS, PLATFORM_OPTIONS } from '../../constants';
import { TIERS } from '../../constants';

interface JournalFilterBarProps {
  filters: JournalFilters;
  onFilterChange: (filters: JournalFilters) => void;
  isOwnProfile: boolean;
}

const chipBase = 'rounded-full px-3 py-1 text-xs font-medium border transition-colors whitespace-nowrap';
const chipActive = 'bg-indigo-500/20 text-indigo-300 border-indigo-500/30';
const chipInactive = 'bg-transparent text-zinc-500 border-zinc-800 hover:border-zinc-600';

export const JournalFilterBar: React.FC<JournalFilterBarProps> = ({ filters, onFilterChange, isOwnProfile }) => {
  const setFilter = (update: Partial<JournalFilters>) => {
    onFilterChange({ ...filters, ...update });
  };

  return (
    <div className="space-y-2">
      {/* Mood */}
      <div className="flex gap-1.5 overflow-x-auto pb-1 scrollbar-hide">
        <button
          className={`${chipBase} ${!filters.mood ? chipActive : chipInactive}`}
          onClick={() => setFilter({ mood: undefined })}
        >
          All Moods
        </button>
        {MOOD_TAGS.slice(0, 12).map((tag) => (
          <button
            key={tag.id}
            className={`${chipBase} ${filters.mood === tag.id ? chipActive : chipInactive}`}
            onClick={() => setFilter({ mood: filters.mood === tag.id ? undefined : tag.id })}
          >
            {tag.emoji} {tag.label}
          </button>
        ))}
      </div>

      {/* Tier */}
      <div className="flex gap-1.5 overflow-x-auto pb-1 scrollbar-hide">
        <button
          className={`${chipBase} ${!filters.tier ? chipActive : chipInactive}`}
          onClick={() => setFilter({ tier: undefined })}
        >
          All Tiers
        </button>
        {TIERS.map((tier) => (
          <button
            key={tier}
            className={`${chipBase} ${filters.tier === tier ? chipActive : chipInactive}`}
            onClick={() => setFilter({ tier: filters.tier === tier ? undefined : tier })}
          >
            {tier}
          </button>
        ))}
      </div>

      {/* Vibe (own profile only) */}
      {isOwnProfile && (
        <div className="flex gap-1.5 overflow-x-auto pb-1 scrollbar-hide">
          <button
            className={`${chipBase} ${!filters.vibe ? chipActive : chipInactive}`}
            onClick={() => setFilter({ vibe: undefined })}
          >
            All Vibes
          </button>
          {VIBE_TAGS.map((tag) => (
            <button
              key={tag.id}
              className={`${chipBase} ${filters.vibe === tag.id ? chipActive : chipInactive}`}
              onClick={() => setFilter({ vibe: filters.vibe === tag.id ? undefined : tag.id })}
            >
              {tag.emoji} {tag.label}
            </button>
          ))}
        </div>
      )}

      {/* Platform (own profile only) */}
      {isOwnProfile && (
        <div className="flex gap-1.5 overflow-x-auto pb-1 scrollbar-hide">
          <button
            className={`${chipBase} ${!filters.platform ? chipActive : chipInactive}`}
            onClick={() => setFilter({ platform: undefined })}
          >
            All Platforms
          </button>
          {PLATFORM_OPTIONS.map((opt) => (
            <button
              key={opt.id}
              className={`${chipBase} ${filters.platform === opt.id ? chipActive : chipInactive}`}
              onClick={() => setFilter({ platform: filters.platform === opt.id ? undefined : opt.id })}
            >
              {opt.label}
            </button>
          ))}
        </div>
      )}

      {/* Date range */}
      <div className="flex gap-1.5 overflow-x-auto pb-1 scrollbar-hide">
        {[
          { label: 'All Time', from: undefined, to: undefined },
          { label: 'This Week', from: getDateDaysAgo(7), to: undefined },
          { label: 'This Month', from: getDateDaysAgo(30), to: undefined },
          { label: 'This Year', from: `${new Date().getFullYear()}-01-01`, to: undefined },
        ].map((opt) => (
          <button
            key={opt.label}
            className={`${chipBase} ${filters.dateFrom === opt.from ? chipActive : chipInactive}`}
            onClick={() => setFilter({ dateFrom: opt.from, dateTo: opt.to })}
          >
            {opt.label}
          </button>
        ))}
      </div>
    </div>
  );
};

function getDateDaysAgo(days: number): string {
  const d = new Date();
  d.setDate(d.getDate() - days);
  return d.toISOString().split('T')[0];
}
