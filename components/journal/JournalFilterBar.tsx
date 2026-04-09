import React, { useState } from 'react';
import { JournalFilters, Tier } from '../../types';
import { MOOD_TAGS, VIBE_TAGS, PLATFORM_OPTIONS } from '../../constants';
import { TIERS } from '../../constants';
import { SlidersHorizontal } from 'lucide-react';

interface JournalFilterBarProps {
  filters: JournalFilters;
  onFilterChange: (filters: JournalFilters) => void;
  isOwnProfile: boolean;
}

export const JournalFilterBar: React.FC<JournalFilterBarProps> = ({ filters, onFilterChange, isOwnProfile }) => {
  const [showMore, setShowMore] = useState(false);

  const setFilter = (update: Partial<JournalFilters>) => {
    onFilterChange({ ...filters, ...update });
  };

  const hasSecondaryFilters = !!filters.vibe || !!filters.platform || !!filters.dateFrom;
  const activeFilterCount = [filters.mood, filters.tier, filters.vibe, filters.platform, filters.dateFrom].filter(Boolean).length;

  const DATE_OPTIONS = [
    { label: 'All Time', from: undefined, to: undefined },
    { label: 'This Week', from: getDateDaysAgo(7), to: undefined },
    { label: 'This Month', from: getDateDaysAgo(30), to: undefined },
    { label: 'This Year', from: `${new Date().getFullYear()}-01-01`, to: undefined },
  ];

  return (
    <div className="space-y-2">
      {/* Row 1: Mood (emoji-only) + Tier + More toggle */}
      <div className="flex items-center gap-3 overflow-x-auto pb-1 scrollbar-hide">
        {/* Mood pills — emoji-only for compactness */}
        <div className="flex items-center gap-0.5 flex-shrink-0">
          <button
            className={`px-2.5 py-1 rounded-md text-xs font-semibold transition-all ${
              !filters.mood ? 'text-foreground bg-secondary/60' : 'text-muted-foreground hover:text-foreground'
            }`}
            onClick={() => setFilter({ mood: undefined })}
          >
            All
          </button>
          {MOOD_TAGS.slice(0, 12).map((tag) => (
            <button
              key={tag.id}
              title={tag.label}
              className={`px-1.5 py-1 rounded-md text-sm transition-all ${
                filters.mood === tag.id ? 'bg-secondary/60 scale-110' : 'opacity-60 hover:opacity-100'
              }`}
              onClick={() => setFilter({ mood: filters.mood === tag.id ? undefined : tag.id })}
            >
              {tag.emoji}
            </button>
          ))}
        </div>

        <div className="w-px h-4 bg-border/40 flex-shrink-0" />

        {/* Tier pills */}
        <div className="flex items-center gap-0.5 flex-shrink-0">
          {TIERS.map((tier) => (
            <button
              key={tier}
              className={`px-2 py-1 rounded-md text-xs font-semibold transition-all ${
                filters.tier === tier ? 'text-foreground bg-secondary/60' : 'text-muted-foreground hover:text-foreground'
              }`}
              onClick={() => setFilter({ tier: filters.tier === tier ? undefined : tier })}
            >
              {tier}
            </button>
          ))}
        </div>

        {/* More filters toggle */}
        {isOwnProfile && (
          <>
            <div className="w-px h-4 bg-border/40 flex-shrink-0" />
            <button
              onClick={() => setShowMore(!showMore)}
              className={`flex items-center gap-1 px-2 py-1 rounded-md text-xs font-semibold transition-all flex-shrink-0 ${
                showMore || hasSecondaryFilters ? 'text-foreground bg-secondary/60' : 'text-muted-foreground hover:text-foreground'
              }`}
            >
              <SlidersHorizontal size={12} />
              More
              {activeFilterCount > 0 && (
                <span className="w-4 h-4 rounded-full bg-gold/20 text-gold text-[10px] flex items-center justify-center">
                  {activeFilterCount}
                </span>
              )}
            </button>
          </>
        )}
      </div>

      {/* Row 2: Secondary filters — vibe, platform, date (progressive disclosure) */}
      {(showMore || hasSecondaryFilters) && isOwnProfile && (
        <div className="flex items-center gap-3 overflow-x-auto pb-1 scrollbar-hide">
          {/* Vibe pills */}
          <div className="flex items-center gap-0.5 flex-shrink-0">
            {VIBE_TAGS.map((tag) => (
              <button
                key={tag.id}
                title={tag.label}
                className={`px-1.5 py-1 rounded-md text-sm transition-all ${
                  filters.vibe === tag.id ? 'bg-secondary/60 scale-110' : 'opacity-60 hover:opacity-100'
                }`}
                onClick={() => setFilter({ vibe: filters.vibe === tag.id ? undefined : tag.id })}
              >
                {tag.emoji}
              </button>
            ))}
          </div>

          <div className="w-px h-4 bg-border/40 flex-shrink-0" />

          {/* Platform pills */}
          <div className="flex items-center gap-1 flex-shrink-0">
            {PLATFORM_OPTIONS.map((opt) => (
              <button
                key={opt.id}
                className={`px-2 py-1 rounded-md text-xs font-semibold transition-all whitespace-nowrap ${
                  filters.platform === opt.id ? 'text-foreground bg-secondary/60' : 'text-muted-foreground hover:text-foreground'
                }`}
                onClick={() => setFilter({ platform: filters.platform === opt.id ? undefined : opt.id })}
              >
                {opt.label}
              </button>
            ))}
          </div>

          <div className="w-px h-4 bg-border/40 flex-shrink-0" />

          {/* Date range */}
          <div className="flex items-center gap-1 flex-shrink-0">
            {DATE_OPTIONS.map((opt) => (
              <button
                key={opt.label}
                className={`px-2 py-1 rounded-md text-xs font-semibold transition-all whitespace-nowrap ${
                  filters.dateFrom === opt.from ? 'text-foreground bg-secondary/60' : 'text-muted-foreground hover:text-foreground'
                }`}
                onClick={() => setFilter({ dateFrom: opt.from, dateTo: opt.to })}
              >
                {opt.label}
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
};

function getDateDaysAgo(days: number): string {
  const d = new Date();
  d.setDate(d.getDate() - days);
  return d.toISOString().split('T')[0];
}
