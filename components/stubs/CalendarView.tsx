import React, { useCallback, useEffect, useState } from 'react';
import { ChevronLeft, ChevronRight, Ticket } from 'lucide-react';
import { MovieStub } from '../../types';
import { getStubsForMonth, backfillStubs } from '../../services/stubService';
import { StubCard } from './StubCard';
import { StubDetailModal } from './StubDetailModal';

interface CalendarViewProps {
  userId: string;
  isOwnProfile: boolean;
}

const DAY_LABELS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

const MONTH_NAMES = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

export const CalendarView: React.FC<CalendarViewProps> = ({ userId, isOwnProfile }) => {
  const now = new Date();
  const [year, setYear] = useState(now.getFullYear());
  const [month, setMonth] = useState(now.getMonth() + 1); // 1-indexed
  const [stubs, setStubs] = useState<MovieStub[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedStub, setSelectedStub] = useState<MovieStub | null>(null);
  const [backfilling, setBackfilling] = useState(false);
  const [backfillDone, setBackfillDone] = useState(false);

  const loadStubs = useCallback(async () => {
    setLoading(true);
    const data = await getStubsForMonth(userId, year, month);
    setStubs(data);
    setLoading(false);
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
    await backfillStubs(userId);
    setBackfilling(false);
    setBackfillDone(true);
    loadStubs();
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
        <div className="flex items-center gap-2">
          <Ticket size={16} className="text-gold" />
          <h3 className="font-serif text-lg text-foreground">Ticket Stubs</h3>
        </div>
        {isOwnProfile && !backfillDone && (
          <button
            onClick={handleBackfill}
            disabled={backfilling}
            className="text-xs text-muted-foreground hover:text-foreground transition-colors disabled:opacity-50"
          >
            {backfilling ? 'Generating...' : 'Generate past stubs'}
          </button>
        )}
      </div>

      {/* Month navigation */}
      <div className="flex items-center justify-between">
        <button
          onClick={prevMonth}
          className="w-8 h-8 rounded-lg flex items-center justify-center text-muted-foreground hover:text-foreground hover:bg-secondary/30 transition-colors"
        >
          <ChevronLeft size={18} />
        </button>
        <span className="font-serif text-base text-foreground">
          {MONTH_NAMES[month - 1]} {year}
        </span>
        <button
          onClick={nextMonth}
          className="w-8 h-8 rounded-lg flex items-center justify-center text-muted-foreground hover:text-foreground hover:bg-secondary/30 transition-colors"
        >
          <ChevronRight size={18} />
        </button>
      </div>

      {/* Day labels */}
      <div className="grid grid-cols-7 gap-px">
        {DAY_LABELS.map((d) => (
          <div key={d} className="text-center text-[10px] text-muted-foreground font-sans py-1">
            {d}
          </div>
        ))}
      </div>

      {/* Calendar grid */}
      <div className="grid grid-cols-7 gap-px bg-border/10 rounded-lg overflow-hidden">
        {loading ? (
          // Skeleton
          Array.from({ length: 35 }).map((_, i) => (
            <div key={i} className="bg-card/30 aspect-square animate-pulse" />
          ))
        ) : (
          cells.map((day, idx) => {
            if (day === null) {
              return <div key={idx} className="bg-card/20 aspect-square" />;
            }
            const dayStubs = stubsByDay.get(day) ?? [];
            return (
              <div
                key={idx}
                className={`relative bg-card/30 aspect-square p-0.5 flex flex-col ${
                  isToday(day) ? 'ring-1 ring-gold/50' : ''
                }`}
              >
                {/* Day number */}
                <span
                  className={`text-[9px] leading-none font-sans ${
                    isToday(day)
                      ? 'text-gold font-semibold'
                      : dayStubs.length > 0
                        ? 'text-foreground/70'
                        : 'text-muted-foreground/40'
                  }`}
                >
                  {day}
                </span>

                {/* Stub thumbnails */}
                {dayStubs.length > 0 && (
                  <div className="flex-1 flex items-center justify-center">
                    {dayStubs.length <= 2 ? (
                      <div className="flex gap-0.5">
                        {dayStubs.map((stub) => (
                          <div key={stub.id} className="w-5 sm:w-6">
                            <StubCard
                              stub={stub}
                              size="mini"
                              onClick={() => setSelectedStub(stub)}
                            />
                          </div>
                        ))}
                      </div>
                    ) : (
                      <button
                        onClick={() => setSelectedStub(dayStubs[0])}
                        className="relative w-6 sm:w-7"
                      >
                        <StubCard stub={dayStubs[0]} size="mini" />
                        <span className="absolute -top-0.5 -right-0.5 text-[7px] font-bold bg-gold text-background rounded-full w-3 h-3 flex items-center justify-center">
                          {dayStubs.length}
                        </span>
                      </button>
                    )}
                  </div>
                )}
              </div>
            );
          })
        )}
      </div>

      {/* Monthly summary */}
      {totalStubs > 0 && !loading && (
        <p className="text-[11px] text-muted-foreground text-center font-sans">
          {MONTH_NAMES[month - 1]} {year}: {totalStubs} moment{totalStubs !== 1 ? 's' : ''}
          {topMood ? ` · Most felt: ${topMood[0]} (${topMood[1]})` : ''}
          {sTierCount > 0 ? ` · S-tier: ${sTierCount}` : ''}
        </p>
      )}

      {/* Empty state */}
      {totalStubs === 0 && !loading && (
        <p className="text-xs text-muted-foreground text-center py-4">
          No stubs this month
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
    </div>
  );
};
