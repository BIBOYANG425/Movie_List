import React from 'react';
import { FeedFilters, FeedCardType, Tier } from '../../types';
import { useTranslation } from '../../contexts/LanguageContext';

const TIER_OPTIONS: { value: Tier | 'all'; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: Tier.S, label: 'S' },
  { value: Tier.A, label: 'A' },
  { value: Tier.B, label: 'B' },
  { value: Tier.C, label: 'C' },
  { value: Tier.D, label: 'D' },
];

const TIME_RANGE_KEYS: { value: '24h' | '7d' | '30d' | 'all'; labelKey?: string; label?: string }[] = [
  { value: 'all', labelKey: 'filter.allTime' },
  { value: '24h', label: '24h' },
  { value: '7d', label: '7d' },
  { value: '30d', label: '30d' },
];

interface FeedFilterBarProps {
  filters: FeedFilters;
  onFilterChange: (filters: FeedFilters) => void;
}

const chipBase = 'rounded-full px-3 py-1 text-xs font-medium border transition-colors';
const chipActive = 'bg-accent/20 text-accent border-accent/30';
const chipInactive = 'bg-transparent text-muted-foreground border-border hover:border-border';

export const FeedFilterBar: React.FC<FeedFilterBarProps> = ({ filters, onFilterChange }) => {
  const { t } = useTranslation();

  const cardTypeOptions = [
    { value: 'all' as const, label: t('filter.all') },
    { value: 'ranking' as const, label: t('filter.rankings') },
    { value: 'review' as const, label: t('filter.reviews') },
    { value: 'milestone' as const, label: t('filter.milestones') },
    { value: 'list' as const, label: t('filter.lists') },
  ];

  const timeRangeOptions = TIME_RANGE_KEYS.map(opt => ({
    value: opt.value,
    label: opt.labelKey ? t(opt.labelKey as any) : opt.label!,
  }));

  const currentCardType = filters.cardType ?? 'all';
  const currentTier = filters.tier ?? 'all';
  const currentTimeRange = filters.timeRange ?? 'all';

  const hasActiveFilters = currentCardType !== 'all' || currentTier !== 'all' || currentTimeRange !== 'all';

  return (
    <>
      {/* Card Type — always visible */}
      <div className="flex items-center gap-1 flex-shrink-0">
        {cardTypeOptions.map((opt) => (
          <button
            key={opt.value}
            aria-pressed={currentCardType === opt.value}
            className={`px-2.5 py-1 rounded-md text-xs font-semibold transition-all whitespace-nowrap ${
              currentCardType === opt.value
                ? 'text-foreground bg-secondary/60'
                : 'text-muted-foreground hover:text-foreground'
            }`}
            onClick={() =>
              onFilterChange({
                ...filters,
                cardType: opt.value === 'all' ? 'all' : opt.value,
                tier: opt.value === 'all' ? 'all' : filters.tier,
                timeRange: opt.value === 'all' ? 'all' : filters.timeRange,
              })
            }
          >
            {opt.label}
          </button>
        ))}
      </div>

      {/* Tier + Time — shown when type filter is active */}
      {(currentCardType !== 'all' || currentTier !== 'all') && (
        <>
          <div className="w-px h-4 bg-border/40 flex-shrink-0" />
          <div className="flex items-center gap-1 flex-shrink-0">
            {TIER_OPTIONS.map((opt) => (
              <button
                key={opt.value}
                aria-pressed={currentTier === opt.value}
                className={`px-2 py-1 rounded-md text-xs font-semibold transition-all ${
                  currentTier === opt.value
                    ? 'text-foreground bg-secondary/60'
                    : 'text-muted-foreground hover:text-foreground'
                }`}
                onClick={() =>
                  onFilterChange({
                    ...filters,
                    tier: opt.value === 'all' ? 'all' : opt.value,
                  })
                }
              >
                {opt.label}
              </button>
            ))}
          </div>
        </>
      )}

      {(currentCardType !== 'all' || currentTimeRange !== 'all') && (
        <>
          <div className="w-px h-4 bg-border/40 flex-shrink-0" />
          <div className="flex items-center gap-1 flex-shrink-0">
            {timeRangeOptions.map((opt) => (
              <button
                key={opt.value}
                aria-pressed={currentTimeRange === opt.value}
                className={`px-2 py-1 rounded-md text-xs font-semibold transition-all whitespace-nowrap ${
                  currentTimeRange === opt.value
                    ? 'text-foreground bg-secondary/60'
                    : 'text-muted-foreground hover:text-foreground'
                }`}
                onClick={() =>
                  onFilterChange({
                    ...filters,
                    timeRange: opt.value === 'all' ? 'all' : opt.value,
                  })
                }
              >
                {opt.label}
              </button>
            ))}
          </div>
        </>
      )}
    </>
  );
};
