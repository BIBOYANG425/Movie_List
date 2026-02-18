import React, { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { ArrowLeft, BarChart2, Bookmark, LayoutGrid, Plus, RotateCcw } from 'lucide-react';
import { Tier, RankedItem, WatchlistItem } from '../types';
import { INITIAL_RANKINGS, TIERS } from '../constants';
import { TierRow } from '../components/TierRow';
import { AddMediaModal } from '../components/AddMediaModal';
import { StatsView } from '../components/StatsView';
import { Watchlist } from '../components/Watchlist';

const SCORE_MAX = 10.0;
const SCORE_MIN = 1.0;

function computeScores(items: RankedItem[]): Map<string, number> {
  const scoreMap = new Map<string, number>();
  const globalOrder: RankedItem[] = [];

  for (const tier of TIERS) {
    const tierItems = items
      .filter((i) => i.tier === tier)
      .sort((a, b) => a.rank - b.rank);
    globalOrder.push(...tierItems);
  }

  const total = globalOrder.length;
  if (total === 0) return scoreMap;

  if (total === 1) {
    scoreMap.set(globalOrder[0].id, SCORE_MAX);
    return scoreMap;
  }

  for (let i = 0; i < total; i++) {
    const score = SCORE_MAX - (i / (total - 1)) * (SCORE_MAX - SCORE_MIN);
    scoreMap.set(globalOrder[i].id, Math.round(score * 10) / 10);
  }

  return scoreMap;
}

const STORAGE_KEY = 'marquee_rankings_v1';
const WATCHLIST_KEY = 'marquee_watchlist_v1';

function loadRankings(): RankedItem[] {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved) return JSON.parse(saved) as RankedItem[];
  } catch {
    // Fall back to seed data.
  }
  return INITIAL_RANKINGS;
}

function loadWatchlist(): WatchlistItem[] {
  try {
    const saved = localStorage.getItem(WATCHLIST_KEY);
    if (saved) return JSON.parse(saved) as WatchlistItem[];
  } catch {
    // Fall back to empty watchlist.
  }
  return [];
}

const RankingAppPage = () => {
  const [items, setItems] = useState<RankedItem[]>(loadRankings);
  const [watchlist, setWatchlist] = useState<WatchlistItem[]>(loadWatchlist);
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [activeTab, setActiveTab] = useState<'ranking' | 'stats' | 'watchlist'>('ranking');
  const [filterType, setFilterType] = useState<'all' | 'movie'>('all');
  const [preselectedForRank, setPreselectedForRank] = useState<WatchlistItem | null>(null);
  const [draggedItemId, setDraggedItemId] = useState<string | null>(null);

  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(items));
    } catch {
      // Ignore storage quota errors.
    }
  }, [items]);

  useEffect(() => {
    try {
      localStorage.setItem(WATCHLIST_KEY, JSON.stringify(watchlist));
    } catch {
      // Ignore storage quota errors.
    }
  }, [watchlist]);

  const handleReset = () => {
    if (window.confirm('Reset your list to the default seed data? This cannot be undone.')) {
      localStorage.removeItem(STORAGE_KEY);
      setItems(INITIAL_RANKINGS);
    }
  };

  const handleDragStart = (e: React.DragEvent, id: string) => {
    setDraggedItemId(id);
    e.dataTransfer.effectAllowed = 'move';
  };

  const handleDrop = (e: React.DragEvent, targetTier: Tier) => {
    e.preventDefault();
    if (!draggedItemId) return;

    setItems((prev) => {
      const movedItem = prev.find((i) => i.id === draggedItemId);
      if (!movedItem) return prev;

      const others = prev.filter((i) => i.id !== draggedItemId);
      const targetTierItems = others.filter((i) => i.tier === targetTier);
      const newRank = targetTierItems.length;
      const newItem = { ...movedItem, tier: targetTier, rank: newRank };

      return [...others, newItem].sort((a, b) => {
        if (a.tier === b.tier) return a.rank - b.rank;
        return 0;
      });
    });

    setDraggedItemId(null);
  };

  const addItem = (newItem: RankedItem) => {
    setItems((prev) => {
      const tierItems = prev
        .filter((i) => i.tier === newItem.tier)
        .sort((a, b) => a.rank - b.rank);
      const otherItems = prev.filter((i) => i.tier !== newItem.tier);

      const newTierList = [...tierItems];
      newTierList.splice(newItem.rank, 0, newItem);

      const updatedTierList = newTierList.map((item, index) => ({ ...item, rank: index }));
      return [...otherItems, ...updatedTierList];
    });
  };

  const removeItem = (id: string) => {
    setItems((prev) => {
      const without = prev.filter((i) => i.id !== id);
      const tiers = new Set(without.map((i) => i.tier));
      let result: RankedItem[] = [];

      tiers.forEach((tier) => {
        const tierItems = without
          .filter((i) => i.tier === tier)
          .sort((a, b) => a.rank - b.rank)
          .map((item, idx) => ({ ...item, rank: idx }));
        result = [...result, ...tierItems];
      });

      return result;
    });
  };

  const addToWatchlist = (item: WatchlistItem) => {
    setWatchlist((prev) => {
      if (prev.some((w) => w.id === item.id)) return prev;
      return [item, ...prev];
    });
  };

  const removeFromWatchlist = (id: string) => {
    setWatchlist((prev) => prev.filter((w) => w.id !== id));
  };

  const rankFromWatchlist = (item: WatchlistItem) => {
    setPreselectedForRank(item);
    setIsModalOpen(true);
  };

  const handleAddItem = (newItem: RankedItem) => {
    addItem(newItem);
    if (preselectedForRank) {
      removeFromWatchlist(preselectedForRank.id);
      setPreselectedForRank(null);
    }
  };

  const watchlistIds = useMemo(() => new Set(watchlist.map((w) => w.id)), [watchlist]);
  const scoreMap = useMemo(() => computeScores(items), [items]);
  const filteredItems = filterType === 'all' ? items : items.filter((i) => i.type === filterType);

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100 font-sans pb-20">
      <nav className="sticky top-0 z-40 bg-zinc-950/80 backdrop-blur-md border-b border-zinc-800">
        <div className="max-w-5xl mx-auto px-4 h-16 flex items-center justify-between gap-4">
          <div className="flex items-center gap-3">
            <Link
              to="/"
              className="inline-flex items-center gap-1 rounded-lg border border-zinc-700 px-3 py-1.5 text-xs font-semibold text-zinc-200 hover:border-zinc-500 hover:text-white transition-colors"
            >
              <ArrowLeft size={14} />
              Back to Home
            </Link>
            <div className="flex items-center gap-2">
              <div className="w-8 h-8 bg-indigo-500 rounded-lg flex items-center justify-center font-bold text-white shadow-lg shadow-indigo-500/20">
                M
              </div>
              <span className="font-bold text-xl tracking-tight">Marquee</span>
            </div>
          </div>

          <div className="flex items-center gap-4">
            <div className="hidden md:flex bg-zinc-900 rounded-lg p-1 border border-zinc-800">
              {(['all', 'movie'] as const).map((type) => (
                <button
                  key={type}
                  onClick={() => setFilterType(type)}
                  className={`px-3 py-1.5 rounded-md text-xs font-semibold capitalize transition-all ${
                    filterType === type ? 'bg-zinc-700 text-white shadow' : 'text-zinc-500 hover:text-zinc-300'
                  }`}
                >
                  {type === 'all' ? 'All' : 'Movies'}
                </button>
              ))}
            </div>

            <button
              onClick={() => setIsModalOpen(true)}
              className="bg-white text-black hover:bg-zinc-200 px-4 py-2 rounded-lg font-semibold text-sm flex items-center gap-2 transition-colors"
            >
              <Plus size={16} />
              <span className="hidden sm:inline">Add Item</span>
            </button>
          </div>
        </div>
      </nav>

      <main className="max-w-5xl mx-auto px-4 py-8 space-y-8">
        <header className="flex flex-col md:flex-row md:items-end justify-between gap-4">
          <div>
            <h1 className="text-3xl font-bold mb-2">My Canon</h1>
            <p className="text-zinc-400 text-sm max-w-md">
              Add a movie and rank it head-to-head against your list. Order implies superiority.
            </p>
          </div>

          <div className="flex gap-2">
            <button
              onClick={() => setActiveTab('ranking')}
              className={`p-2 rounded-lg transition-colors ${
                activeTab === 'ranking' ? 'bg-zinc-800 text-white' : 'text-zinc-500 hover:bg-zinc-900'
              }`}
              title="Rankings"
            >
              <LayoutGrid size={20} />
            </button>
            <button
              onClick={() => setActiveTab('watchlist')}
              className={`p-2 rounded-lg transition-colors relative ${
                activeTab === 'watchlist' ? 'bg-zinc-800 text-white' : 'text-zinc-500 hover:bg-zinc-900'
              }`}
              title="Watch Later"
            >
              <Bookmark size={20} />
              {watchlist.length > 0 && (
                <span className="absolute -top-1 -right-1 w-4 h-4 text-[9px] font-bold rounded-full bg-emerald-500 text-black flex items-center justify-center">
                  {watchlist.length > 9 ? '9+' : watchlist.length}
                </span>
              )}
            </button>
            <button
              onClick={() => setActiveTab('stats')}
              className={`p-2 rounded-lg transition-colors ${
                activeTab === 'stats' ? 'bg-zinc-800 text-white' : 'text-zinc-500 hover:bg-zinc-900'
              }`}
              title="Stats"
            >
              <BarChart2 size={20} />
            </button>
            <button
              onClick={handleReset}
              title="Reset to defaults"
              className="p-2 rounded-lg text-zinc-600 hover:text-zinc-400 hover:bg-zinc-900 transition-colors"
            >
              <RotateCcw size={18} />
            </button>
          </div>
        </header>

        {activeTab === 'ranking' && (
          <div className="space-y-4">
            {TIERS.map((tier) => (
              <TierRow
                key={tier}
                tier={tier}
                items={filteredItems.filter((i) => i.tier === tier).sort((a, b) => a.rank - b.rank)}
                scoreMap={scoreMap}
                onDrop={handleDrop}
                onDragStart={handleDragStart}
                onDelete={removeItem}
              />
            ))}
          </div>
        )}

        {activeTab === 'watchlist' && (
          <Watchlist items={watchlist} onRemove={removeFromWatchlist} onRank={rankFromWatchlist} />
        )}

        {activeTab === 'stats' && <StatsView items={items} />}
      </main>

      <AddMediaModal
        isOpen={isModalOpen}
        onClose={() => {
          setIsModalOpen(false);
          setPreselectedForRank(null);
        }}
        onAdd={handleAddItem}
        onSaveForLater={addToWatchlist}
        currentItems={items}
        watchlistIds={watchlistIds}
        preselectedItem={preselectedForRank}
      />
    </div>
  );
};

export default RankingAppPage;
