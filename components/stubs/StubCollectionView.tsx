import React, { useCallback, useEffect, useState } from 'react';
import { Ticket } from 'lucide-react';
import { MovieStub } from '../../types';
import { getAllStubs, backfillStubs } from '../../services/stubService';
import { StubCard } from './StubCard';
import { StubDetailModal } from './StubDetailModal';

interface StubCollectionViewProps {
  userId: string;
}

export const StubCollectionView: React.FC<StubCollectionViewProps> = ({ userId }) => {
  const [stubs, setStubs] = useState<MovieStub[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedStub, setSelectedStub] = useState<MovieStub | null>(null);
  const [backfilling, setBackfilling] = useState(false);
  const [backfillDone, setBackfillDone] = useState(false);

  const loadStubs = useCallback(async () => {
    setLoading(true);
    const data = await getAllStubs(userId);
    setStubs(data);
    setLoading(false);
  }, [userId]);

  useEffect(() => {
    loadStubs();
  }, [loadStubs]);

  const handleBackfill = async () => {
    setBackfilling(true);
    const count = await backfillStubs(userId);
    setBackfilling(false);
    setBackfillDone(true);
    if (count > 0) loadStubs();
  };

  const handleDateChanged = () => {
    loadStubs();
  };

  // Group stubs by month
  const grouped = new Map<string, MovieStub[]>();
  for (const stub of stubs) {
    const d = new Date(stub.watchedDate + 'T00:00:00');
    const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
    const list = grouped.get(key) ?? [];
    list.push(stub);
    grouped.set(key, list);
  }

  const monthLabel = (key: string) => {
    const [y, m] = key.split('-');
    const months = ['January','February','March','April','May','June','July','August','September','October','November','December'];
    return `${months[Number(m) - 1]} ${y}`;
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Ticket size={18} className="text-gold" />
          <h2 className="font-serif text-xl text-foreground">Ticket Stubs</h2>
        </div>
        {!backfillDone && (
          <button
            onClick={handleBackfill}
            disabled={backfilling}
            className="text-xs text-muted-foreground hover:text-foreground transition-colors disabled:opacity-50"
          >
            {backfilling ? 'Generating...' : 'Generate past stubs'}
          </button>
        )}
      </div>

      {/* Loading skeleton */}
      {loading && (
        <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-4">
          {Array.from({ length: 8 }).map((_, i) => (
            <div key={i} className="aspect-[2/1] rounded-lg bg-card/50 animate-pulse" />
          ))}
        </div>
      )}

      {/* Empty state */}
      {!loading && stubs.length === 0 && (
        <div className="text-center py-16 text-muted-foreground">
          <Ticket size={32} className="mx-auto mb-3 text-muted-foreground/40" />
          <p className="font-serif text-lg text-foreground mb-1">No stubs yet</p>
          <p className="text-sm">Rank a movie or TV show to collect your first ticket stub.</p>
        </div>
      )}

      {/* Stubs grouped by month */}
      {!loading && [...grouped.entries()].map(([monthKey, monthStubs]) => (
        <div key={monthKey} className="space-y-3">
          <h3 className="text-sm font-semibold text-muted-foreground tracking-wide uppercase">
            {monthLabel(monthKey)}
          </h3>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
            {monthStubs.map((stub) => (
              <StubCard
                key={stub.id}
                stub={stub}
                size="full"
                onClick={() => setSelectedStub(stub)}
              />
            ))}
          </div>
        </div>
      ))}

      {/* Detail overlay */}
      {selectedStub && (
        <StubDetailModal
          stub={selectedStub}
          isOwnProfile={true}
          onClose={() => setSelectedStub(null)}
          onDateChanged={handleDateChanged}
        />
      )}
    </div>
  );
};
