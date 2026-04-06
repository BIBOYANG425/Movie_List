import React from 'react';
import { Flame } from 'lucide-react';
import { useTranslation } from '../../contexts/LanguageContext';

interface StreakBadgeProps {
  currentStreak: number;
  longestStreak: number;
  size?: 'sm' | 'md';
}

export const StreakBadge: React.FC<StreakBadgeProps> = ({
  currentStreak,
  longestStreak,
  size = 'md',
}) => {
  const { t } = useTranslation();

  if (currentStreak <= 0 && longestStreak <= 0) return null;

  const iconSize = size === 'sm' ? 12 : 14;
  const textClass = size === 'sm' ? 'text-[11px]' : 'text-xs';

  if (currentStreak > 0) {
    return (
      <div className={`flex items-center gap-1 ${textClass} text-muted-foreground`}>
        <Flame size={iconSize} className="text-orange-400" />
        <span>
          <strong className="text-foreground">{currentStreak}</strong>{' '}
          {t('streak.current')}
        </span>
      </div>
    );
  }

  return (
    <div className={`flex items-center gap-1 ${textClass} text-muted-foreground/60`}>
      <Flame size={iconSize} className="text-muted-foreground/40" />
      <span>{t('streak.longest').replace('{n}', String(longestStreak))}</span>
    </div>
  );
};
