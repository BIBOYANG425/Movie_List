import React, { useEffect, useState, useCallback, useRef } from 'react';
import { Search, BookOpen, Flame, Film } from 'lucide-react';
import { JournalEntryCard as JournalEntryCardType, JournalFilters, JournalStats, JournalEntry, RankedItem, Tier } from '../types';
import { listJournalEntries, searchJournalEntries, getJournalStats } from '../services/journalService';
import { MOOD_TAGS } from '../constants';
import { JournalEntryCard } from './JournalEntryCard';
import { JournalFilterBar } from './journal/JournalFilterBar';
import { SkeletonList } from './SkeletonCard';

interface JournalHomeViewProps {
  userId: string;
  currentUserId: string;
  isOwnProfile: boolean;
  onEditEntry?: (entry: JournalEntryCardType) => void;
}

export const JournalHomeView: React.FC<JournalHomeViewProps> = ({
  userId,
  currentUserId,
  isOwnProfile,
  onEditEntry,
}) => {
  const [entries, setEntries] = useState<JournalEntryCardType[]>([]);
  const [stats, setStats] = useState<JournalStats | null>(null);
  const [filters, setFilters] = useState<JournalFilters>({});
  const [searchQuery, setSearchQuery] = useState('');
  const [loading, setLoading] = useState(true);
  const [hasMore, setHasMore] = useState(true);
  const offsetRef = useRef(0);
  const PAGE_SIZE = 20;

  const loadEntries = useCallback(async (reset = false) => {
    const offset = reset ? 0 : offsetRef.current;
    setLoading(true);
    try {
      if (searchQuery.trim()) {
        const results = await searchJournalEntries(userId, searchQuery);
        // Enrich with profile data (search RPC returns raw rows)
        const cards: JournalEntryCardType[] = results.map((e) => ({
          ...e,
          username: '',
          displayName: undefined,
          avatarUrl: undefined,
        }));
        setEntries(cards);
        setHasMore(false);
      } else {
        const data = await listJournalEntries(userId, filters, offset, PAGE_SIZE);
        if (reset) {
          setEntries(data);
        } else {
          setEntries((prev) => [...prev, ...data]);
        }
        setHasMore(data.length === PAGE_SIZE);
        offsetRef.current = offset + data.length;
      }
    } catch (err) {
      console.error('Failed to load journal entries:', err);
    } finally {
      setLoading(false);
    }
  }, [userId, filters, searchQuery]);

  useEffect(() => {
    offsetRef.current = 0;
    loadEntries(true);
  }, [userId, filters, searchQuery]);

  useEffect(() => {
    getJournalStats(userId).then(setStats);
  }, [userId]);

  const loadMore = () => {
    if (!loading && hasMore) loadEntries();
  };

  // Infinite scroll
  const observerRef = useRef<IntersectionObserver | null>(null);
  const sentinelRef = useCallback((node: HTMLDivElement | null) => {
    if (observerRef.current) observerRef.current.disconnect();
    if (!node) return;
    observerRef.current = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) loadMore();
    });
    observerRef.current.observe(node);
  }, [loading, hasMore]);

  const mostCommonMoodTag = stats?.mostCommonMood
    ? MOOD_TAGS.find((t) => t.id === stats.mostCommonMood)
    : undefined;

  return (
    <div className="space-y-4">
      {/* Stats bar */}
      {stats && stats.totalEntries > 0 && (
        <div className="flex items-center gap-4 px-1">
          <div className="flex items-center gap-1.5 text-xs text-zinc-400">
            <BookOpen size={13} />
            <span><strong className="text-zinc-200">{stats.totalEntries}</strong> entries</span>
          </div>
          {mostCommonMoodTag && (
            <div className="flex items-center gap-1 text-xs text-zinc-400">
              <span>{mostCommonMoodTag.emoji}</span>
              <span>Most felt</span>
            </div>
          )}
          {stats.currentStreak > 0 && (
            <div className="flex items-center gap-1.5 text-xs text-zinc-400">
              <Flame size={13} className="text-orange-400" />
              <span><strong className="text-zinc-200">{stats.currentStreak}</strong> day streak</span>
            </div>
          )}
        </div>
      )}

      {/* Search */}
      <div className="relative">
        <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-zinc-500" />
        <input
          type="text"
          placeholder="Search journal..."
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          className="w-full bg-zinc-900 border border-zinc-800 rounded-xl pl-9 pr-3 py-2.5 text-sm text-zinc-200 placeholder-zinc-600 focus:outline-none focus:border-zinc-600"
        />
      </div>

      {/* Filters */}
      {!searchQuery && (
        <JournalFilterBar
          filters={filters}
          onFilterChange={setFilters}
          isOwnProfile={isOwnProfile}
        />
      )}

      {/* Entry list */}
      <div className="space-y-2.5">
        {entries.map((entry) => (
          <JournalEntryCard
            key={entry.id}
            entry={entry}
            currentUserId={currentUserId}
            isOwnProfile={isOwnProfile}
            onEdit={onEditEntry}
          />
        ))}

        {/* Sentinel for infinite scroll */}
        {hasMore && <div ref={sentinelRef} className="h-4" />}

        {/* Loading */}
        {loading && entries.length === 0 && (
          <SkeletonList count={4} variant="journal" />
        )}

        {/* Empty state */}
        {!loading && entries.length === 0 && (
          <div className="py-12 text-center">
            <Film size={32} className="mx-auto text-zinc-700 mb-3" />
            <p className="text-sm text-zinc-500">
              {isOwnProfile
                ? 'Start your film diary by ranking a movie'
                : 'No journal entries yet'}
            </p>
          </div>
        )}
      </div>
    </div>
  );
};
