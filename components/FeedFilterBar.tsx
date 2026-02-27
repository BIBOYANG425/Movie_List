import React from 'react';
import { FeedFilters, FeedCardType, Tier } from '../types';
import { useTranslation } from '../contexts/LanguageContext';

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
const chipActive = 'bg-indigo-500/20 text-indigo-300 border-indigo-500/30';
const chipInactive = 'bg-transparent text-zinc-500 border-zinc-800 hover:border-zinc-600';

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

  return (
    <div className="space-y-2">
      {/* Card Type */}
      <div className="flex gap-2 overflow-x-auto pb-1 scrollbar-hide">
        {cardTypeOptions.map((opt) => (
          <button
            key={opt.value}
            className={`${chipBase} ${currentCardType === opt.value ? chipActive : chipInactive}`}
            onClick={() =>
              onFilterChange({
                ...filters,
                cardType: opt.value === 'all' ? 'all' : opt.value,
              })
            }
          >
            {opt.label}
          </button>
        ))}
      </div>

      {/* Tier */}
      <div className="flex gap-2 overflow-x-auto pb-1 scrollbar-hide">
        {TIER_OPTIONS.map((opt) => (
          <button
            key={opt.value}
            className={`${chipBase} ${currentTier === opt.value ? chipActive : chipInactive}`}
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

      {/* Time Range */}
      <div className="flex gap-2 overflow-x-auto pb-1 scrollbar-hide">
        {timeRangeOptions.map((opt) => (
          <button
            key={opt.value}
            className={`${chipBase} ${currentTimeRange === opt.value ? chipActive : chipInactive}`}
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
    </div>
  );
};
