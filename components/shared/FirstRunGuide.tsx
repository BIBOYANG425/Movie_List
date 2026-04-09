import React from 'react';
import { Search, ArrowRight } from 'lucide-react';
import { INITIAL_RANKINGS, TIER_LABELS } from '../../constants';
import { Tier } from '../../types';
import { useTranslation } from '../../contexts/LanguageContext';

interface FirstRunGuideProps {
  onStartSearch: () => void;
}

const SAMPLE_TIERS: Tier[] = [Tier.S, Tier.A, Tier.B];

export const FirstRunGuide: React.FC<FirstRunGuideProps> = ({ onStartSearch }) => {
  const { t } = useTranslation();

  return (
    <div className="animate-fade-in-up max-w-lg mx-auto px-4 py-12 text-center">
      <h2 className="font-serif text-3xl text-foreground mb-2">
        {t('firstRun.title')}
      </h2>
      <p className="text-muted-foreground text-sm mb-8 max-w-sm mx-auto">
        {t('firstRun.subtitle')}
      </p>

      <button
        onClick={onStartSearch}
        className="inline-flex items-center gap-2 px-6 py-3 rounded-xl bg-gold text-background font-semibold text-sm hover:opacity-90 transition-opacity mb-10 shadow-lg shadow-gold/10"
      >
        <Search size={16} />
        {t('firstRun.searchCta')}
        <ArrowRight size={14} />
      </button>

      {/* Sample tiers preview */}
      <div className="space-y-3">
        <p className="text-xs text-muted-foreground/60 uppercase tracking-widest mb-4">
          {t('firstRun.previewLabel')}
        </p>
        {SAMPLE_TIERS.map((tier) => {
          const tierItems = INITIAL_RANKINGS.filter(i => i.tier === tier).slice(0, 3);
          if (tierItems.length === 0) return null;
          return (
            <div
              key={tier}
              className="flex items-center gap-3 rounded-xl bg-card/40 border border-border/20 p-3 opacity-50"
            >
              <span className={`font-serif text-2xl font-black text-tier-${tier.toLowerCase()} w-8`}>
                {tier}
              </span>
              <span className="text-xs text-muted-foreground mr-2">
                {TIER_LABELS[tier]}
              </span>
              <div className="flex gap-2 overflow-hidden">
                {tierItems.map((item) => (
                  <img
                    key={item.id}
                    src={item.posterUrl}
                    alt={item.title}
                    className="w-8 h-12 rounded object-cover flex-shrink-0"
                  />
                ))}
              </div>
            </div>
          );
        })}
      </div>

      <p className="text-xs text-muted-foreground/40 mt-6 italic">
        {t('firstRun.reassurance')}
      </p>
    </div>
  );
};
