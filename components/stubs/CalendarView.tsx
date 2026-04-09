import React, { useCallback, useEffect, useState } from 'react';
import { ChevronLeft, ChevronRight, Share2, Ticket } from 'lucide-react';
import { MovieStub } from '../../types';
import { getStubsForMonth, backfillStubs } from '../../services/stubService';
import { TIER_HEX } from '../../constants';
import { useTranslation } from '../../contexts/LanguageContext';
import { StreakBadge } from '../shared/StreakBadge';
import { StubDetailModal } from './StubDetailModal';
import { MonthlyRecapModal } from './MonthlyRecapModal';

interface CalendarViewProps {
  userId: string;
  isOwnProfile: boolean;
  currentStreak?: number;
  longestStreak?: number;
  username?: string;
  displayName?: string;
}

export const CalendarView: React.FC<CalendarViewProps> = ({
  userId,
  isOwnProfile,
  currentStreak = 0,
  longestStreak = 0,
  username,
  displayName,
}) => {
  const { locale, t } = useTranslation();
  const now = new Date();
  const [year, setYear] = useState(now.getFullYear());
  const [month, setMonth] = useState(now.getMonth() + 1); // 1-indexed
  const [stubs, setStubs] = useState<MovieStub[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedStub, setSelectedStub] = useState<MovieStub | null>(null);
  const [backfilling, setBackfilling] = useState(false);
  const [backfillDone, setBackfillDone] = useState(false);
  const [recapOpen, setRecapOpen] = useState(false);

  const dayLabels = Array.from({ length: 7 }, (_, i) => {
    // Monday-start: Jan 5 2026 is a Monday
    const d = new Date(2026, 0, 5 + i);
    return d.toLocaleDateString(locale, { weekday: 'short' });
  });

  const monthName = new Date(year, month - 1).toLocaleDateString(locale, { month: 'long', year: 'numeric' });

  const loadStubs = useCallback(async () => {
    setLoading(true);
    try {
      const data = await getStubsForMonth(userId, year, month);
      setStubs(data);
    } catch (err) {
      console.error('Failed to load stubs:', err);
    } finally {
      setLoading(false);
    }
  }, [userId, year, month]);

  useEffect(() => {
    loadStubs();
  }, [loadStubs]);

  const prevMonth = () => {
    if (month === 1) { setMonth(12); setYear(year - 1); }
    else setMonth(month - 1);
  };

  const nextMonth = () => {
    if (month === 12) { setMonth(1); setYear(year + 1); }
    else setMonth(month + 1);
  };

  const handleBackfill = async () => {
    setBackfilling(true);
    try {
      await backfillStubs(userId);
      setBackfillDone(true);
    } catch (err) {
      console.error('Backfill failed:', err);
    } finally {
      setBackfilling(false);
      loadStubs();
    }
  };

  const handleDateChanged = (_stubId: string, _newDate: string) => {
    loadStubs();
  };

  // Group stubs by day of month
  const stubsByDay = new Map<number, MovieStub[]>();
  for (const stub of stubs) {
    const day = new Date(stub.watchedDate + 'T00:00:00').getDate();
    const list = stubsByDay.get(day) ?? [];
    list.push(stub);
    stubsByDay.set(day, list);
  }

  // Calendar grid math (Monday-start)
  const firstDayOfMonth = new Date(year, month - 1, 1);
  const daysInMonth = new Date(year, month, 0).getDate();
  // getDay(): 0=Sun, 1=Mon... We want Mon=0
  const startDow = (firstDayOfMonth.getDay() + 6) % 7;

  const cells: (number | null)[] = [];
  for (let i = 0; i < startDow; i++) cells.push(null);
  for (let d = 1; d <= daysInMonth; d++) cells.push(d);
  // Fill remaining cells to complete the last week
  while (cells.length % 7 !== 0) cells.push(null);

  const isToday = (day: number) =>
    year === now.getFullYear() && month === now.getMonth() + 1 && day === now.getDate();

  // Monthly summary
  const totalStubs = stubs.length;
  const sTierCount = stubs.filter((s) => s.tier === 'S').length;
  const moodCounts = new Map<string, number>();
  for (const s of stubs) {
    for (const tag of s.moodTags) {
      moodCounts.set(tag, (moodCounts.get(tag) ?? 0) + 1);
    }
  }
  const topMood = [...moodCounts.entries()].sort((a, b) => b[1] - a[1])[0];

  return (
    <div className="space-y-3">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2.5">
          <Ticket size={18} className="text-gold" />
          <h3 className="font-serif text-lg text-foreground">{t('stubs.title')}</h3>
        </div>
        {isOwnProfile && !backfillDone && (
          <button
            onClick={handleBackfill}
            disabled={backfilling}
            className="text-xs text-muted-foreground hover:text-foreground transition-colors disabled:opacity-50"
          >
            {backfilling ? t('stubs.backfilling') : t('stubs.backfill')}
          </button>
        )}
      </div>

      {/* Month navigation */}
      <div className="flex items-center justify-between">
        <button
          onClick={prevMonth}
          aria-label="Previous month"
          className="w-8 h-8 rounded-full flex items-center justify-center text-muted-foreground hover:text-foreground hover:bg-secondary/50 transition-colors"
        >
          <ChevronLeft size={18} aria-hidden="true" />
        </button>
        <span className="font-serif text-base font-semibold text-foreground">
          {monthName}
        </span>
        <button
          onClick={nextMonth}
          aria-label="Next month"
          className="w-8 h-8 rounded-full flex items-center justify-center text-muted-foreground hover:text-foreground hover:bg-secondary/50 transition-colors"
        >
          <ChevronRight size={18} aria-hidden="true" />
        </button>
      </div>

      {/* Day labels */}
      <div className="grid grid-cols-7">
        {dayLabels.map((d) => (
          <div key={d} className="text-center text-xs text-muted-foreground font-medium py-1.5">
            {d}
          </div>
        ))}
      </div>

      {/* Calendar grid */}
      <div className="grid grid-cols-7 border border-border/20 rounded-xl overflow-hidden">
        {loading ? (
          Array.from({ length: 35 }).map((_, i) => (
            <div key={i} className="bg-card/20 aspect-square animate-pulse border-b border-r border-border/10" />
          ))
        ) : (
          cells.map((day, idx) => {
            if (day === null) {
              return <div key={idx} className="bg-card/10 aspect-square border-b border-r border-border/10" />;
            }
            const dayStubs = stubsByDay.get(day) ?? [];
            const heroStub = dayStubs[0];
            const posterSrc = heroStub?.posterPath
              ? (heroStub.posterPath.startsWith('http') ? heroStub.posterPath : `https://image.tmdb.org/t/p/w185${heroStub.posterPath}`)
              : null;
            const tierColor = heroStub ? (TIER_HEX[heroStub.tier] ?? '#71717a') : undefined;

            return (
              <button
                key={idx}
                onClick={heroStub ? () => setSelectedStub(heroStub) : undefined}
                disabled={!heroStub}
                className={`relative aspect-square border-b border-r border-border/10 overflow-hidden transition-transform ${
                  heroStub ? 'cursor-pointer hover:z-10 hover:scale-[1.04] active:scale-95' : ''
                } ${isToday(day) ? 'ring-1 ring-inset ring-gold/40' : ''}`}
              >
                {/* Background: poster fills cell, or subtle bg */}
                {posterSrc ? (
                  <img
                    src={posterSrc}
                    alt={heroStub.title}
                    className="absolute inset-0 w-full h-full object-cover"
                  />
                ) : (
                  <div className={`absolute inset-0 ${isToday(day) ? 'bg-gold/5' : 'bg-card/10'}`} />
                )}

                {/* Gradient overlay for text readability on posters */}
                {posterSrc && (
                  <div className="absolute inset-0 bg-gradient-to-b from-black/50 via-transparent to-black/40" />
                )}

                {/* Day number — top-left */}
                <span
                  className={`relative z-10 block p-1 sm:p-1.5 text-[10px] sm:text-xs font-semibold leading-none ${
                    posterSrc
                      ? 'text-white drop-shadow-md'
                      : isToday(day)
                        ? 'text-gold font-bold'
                        : 'text-muted-foreground/50'
                  }`}
                >
                  {day}
                </span>

                {/* Tier badge — bottom-left */}
                {heroStub && tierColor && (
                  <span
                    className="absolute bottom-1 left-1 z-10 text-[9px] sm:text-[10px] font-bold px-1 sm:px-1.5 py-0.5 rounded-sm shadow"
                    style={{ backgroundColor: tierColor, color: '#fff' }}
                  >
                    {heroStub.tier}
                  </span>
                )}

                {/* Multi-stub count — top-right */}
                {dayStubs.length > 1 && (
                  <span className="absolute top-1 right-1 z-10 text-[8px] sm:text-[10px] font-bold bg-gold text-background rounded-full w-4 h-4 sm:w-5 sm:h-5 flex items-center justify-center shadow">
                    {dayStubs.length}
                  </span>
                )}

                {/* S-tier shimmer */}
                {heroStub?.tier === 'S' && (
                  <div className="absolute inset-0 bg-gradient-to-br from-yellow-400/15 via-transparent to-amber-500/10 pointer-events-none" />
                )}
              </button>
            );
          })
        )}
      </div>

      {/* Monthly summary */}
      {totalStubs > 0 && !loading && (
        <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-2 sm:gap-0 pt-1">
          <p className="text-xs text-muted-foreground">
            {totalStubs} {totalStubs !== 1 ? t('stubs.moments') : t('stubs.moment')}
            {topMood ? ` · ${t('stubs.mostFelt')} ${topMood[0]} (${topMood[1]})` : ''}
            {sTierCount > 0 ? ` · ${t('stubs.sTier')} ${sTierCount}` : ''}
          </p>
          <div className="flex items-center gap-3">
            <StreakBadge currentStreak={currentStreak} longestStreak={longestStreak} size="sm" />
            {username && (
              <button
                onClick={() => setRecapOpen(true)}
                className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground transition-colors"
              >
                <Share2 size={12} />
                {t('recap.shareMonth')}
              </button>
            )}
          </div>
        </div>
      )}

      {/* Empty state */}
      {totalStubs === 0 && !loading && (
        <p className="text-sm text-muted-foreground text-center py-6">
          {t('stubs.noStubsMonth')}
        </p>
      )}

      {/* Stub detail modal */}
      {selectedStub && (
        <StubDetailModal
          stub={selectedStub}
          isOwnProfile={isOwnProfile}
          onClose={() => setSelectedStub(null)}
          onDateChanged={handleDateChanged}
        />
      )}

      {/* Monthly recap share modal — only mount when open to avoid bundling html2canvas eagerly */}
      {recapOpen && username && (
        <MonthlyRecapModal
          open={recapOpen}
          onClose={() => setRecapOpen(false)}
          stubs={stubs}
          monthLabel={monthName}
          totalStubs={totalStubs}
          sTierCount={sTierCount}
          topMood={topMood}
          username={username}
          displayName={displayName}
          currentStreak={currentStreak}
        />
      )}
    </div>
  );
};
