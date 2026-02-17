import React, { useState, useEffect, useMemo } from 'react';
import { LayoutGrid, Plus, BarChart2, RotateCcw } from 'lucide-react';
import { Tier, RankedItem } from './types';
import { INITIAL_RANKINGS, TIERS } from './constants';

// ── Dynamic scoring ──────────────────────────────────────────────────────────
// Each item gets a score from 10.0 (best) to 1.0 (worst) based on its
// global rank position across all tiers, with tier boundaries enforced.
const TIER_BOUNDS: Record<Tier, { min: number; max: number }> = {
  [Tier.S]: { min: 9.0, max: 10.0 },
  [Tier.A]: { min: 7.5, max: 8.9 },
  [Tier.B]: { min: 5.5, max: 7.4 },
  [Tier.C]: { min: 3.5, max: 5.4 },
  [Tier.D]: { min: 1.0, max: 3.4 },
};

/**
 * Compute a score map for all items. Each item's score is calculated by:
 * 1. Sorting all items globally: S first, then A, B, C, D — within each tier by rank.
 * 2. Within each tier, distributing scores evenly between that tier's max and min.
 *    - The #1 item in the tier gets the max score.
 *    - The last item gets the min score.
 *    - Single items get the midpoint of the range.
 * This means scores shift dynamically as items are added/removed/moved.
 */
function computeScores(items: RankedItem[]): Map<string, number> {
  const scoreMap = new Map<string, number>();

  for (const tier of TIERS) {
    const tierItems = items
      .filter(i => i.tier === tier)
      .sort((a, b) => a.rank - b.rank);

    if (tierItems.length === 0) continue;

    const { min, max } = TIER_BOUNDS[tier];

    if (tierItems.length === 1) {
      scoreMap.set(tierItems[0].id, Math.round(((min + max) / 2) * 10) / 10);
      continue;
    }

    for (let i = 0; i < tierItems.length; i++) {
      // Linear interpolation: #1 gets max, last gets min
      const score = max - (i / (tierItems.length - 1)) * (max - min);
      scoreMap.set(tierItems[i].id, Math.round(score * 10) / 10);
    }
  }

  return scoreMap;
}
import { TierRow } from './components/TierRow';
import { AddMediaModal } from './components/AddMediaModal';
import { StatsView } from './components/StatsView';

const STORAGE_KEY = 'marquee_rankings_v1';

// Load saved rankings from localStorage, fall back to seed data
function loadRankings(): RankedItem[] {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved) return JSON.parse(saved) as RankedItem[];
  } catch {
    // Corrupted data — fall back to defaults
  }
  return INITIAL_RANKINGS;
}

const App = () => {
  // Lazy initialiser — only runs once on mount
  const [items, setItems] = useState<RankedItem[]>(loadRankings);
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [activeTab, setActiveTab] = useState<'ranking' | 'stats'>('ranking');
  const [filterType, setFilterType] = useState<'all' | 'movie'>('all');
  
  // Persist to localStorage whenever rankings change
  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(items));
    } catch {
      // Storage full or unavailable — fail silently
    }
  }, [items]);

  // Drag State
  const [draggedItemId, setDraggedItemId] = useState<string | null>(null);

  const handleReset = () => {
    if (window.confirm('Reset your list to the default seed data? This cannot be undone.')) {
      localStorage.removeItem(STORAGE_KEY);
      setItems(INITIAL_RANKINGS);
    }
  };

  const handleDragStart = (e: React.DragEvent, id: string) => {
    setDraggedItemId(id);
    e.dataTransfer.effectAllowed = "move";
  };

  const handleDrop = (e: React.DragEvent, targetTier: Tier) => {
    e.preventDefault();
    if (!draggedItemId) return;

    setItems((prev) => {
      const movedItem = prev.find((i) => i.id === draggedItemId);
      if (!movedItem) return prev;

      // Remove item from old position
      const others = prev.filter((i) => i.id !== draggedItemId);
      
      // Calculate new rank (append to end of tier)
      const targetTierItems = others.filter(i => i.tier === targetTier);
      const newRank = targetTierItems.length;

      const newItem = { ...movedItem, tier: targetTier, rank: newRank };
      
      // Re-sort items in the target tier just in case (optional)
      return [...others, newItem].sort((a, b) => {
        if (a.tier === b.tier) return a.rank - b.rank;
        return 0; // Tiers are separate
      });
    });

    setDraggedItemId(null);
  };

  const addItem = (newItem: RankedItem) => {
    setItems((prev) => {
      // items in the target tier
      const tierItems = prev.filter((i) => i.tier === newItem.tier).sort((a, b) => a.rank - b.rank);
      // items in other tiers
      const otherItems = prev.filter((i) => i.tier !== newItem.tier);
      
      // Insert item at the specific rank provided by the modal
      // If rank is greater than length, it just appends
      const newTierList = [...tierItems];
      newTierList.splice(newItem.rank, 0, newItem);

      // Re-normalize ranks for the tier
      const updatedTierList = newTierList.map((item, index) => ({ ...item, rank: index }));

      return [...otherItems, ...updatedTierList];
    });
  };

  const removeItem = (id: string) => {
    setItems((prev) => {
      const without = prev.filter((i) => i.id !== id);
      // Re-normalize ranks within the affected tier
      const tiers = new Set(without.map(i => i.tier));
      let result: RankedItem[] = [];
      tiers.forEach((tier) => {
        const tierItems = without
          .filter(i => i.tier === tier)
          .sort((a, b) => a.rank - b.rank)
          .map((item, idx) => ({ ...item, rank: idx }));
        result = [...result, ...tierItems];
      });
      return result;
    });
  };

  // Recompute scores whenever rankings change
  const scoreMap = useMemo(() => computeScores(items), [items]);

  const filteredItems = filterType === 'all'
    ? items
    : items.filter(i => i.type === filterType);

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100 font-sans pb-20">
      
      {/* Top Navbar */}
      <nav className="sticky top-0 z-40 bg-zinc-950/80 backdrop-blur-md border-b border-zinc-800">
        <div className="max-w-5xl mx-auto px-4 h-16 flex items-center justify-between">
          <div className="flex items-center gap-2">
            <div className="w-8 h-8 bg-indigo-500 rounded-lg flex items-center justify-center font-bold text-white shadow-lg shadow-indigo-500/20">
              M
            </div>
            <span className="font-bold text-xl tracking-tight">Marquee</span>
          </div>

          <div className="flex items-center gap-4">
             {/* Filter Chips (Desktop) */}
            <div className="hidden md:flex bg-zinc-900 rounded-lg p-1 border border-zinc-800">
              {(['all', 'movie'] as const).map((type) => (
                <button
                  key={type}
                  onClick={() => setFilterType(type)}
                  className={`px-3 py-1.5 rounded-md text-xs font-semibold capitalize transition-all ${
                    filterType === type 
                      ? 'bg-zinc-700 text-white shadow' 
                      : 'text-zinc-500 hover:text-zinc-300'
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
        
        {/* Header Section */}
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
                    className={`p-2 rounded-lg transition-colors ${activeTab === 'ranking' ? 'bg-zinc-800 text-white' : 'text-zinc-500 hover:bg-zinc-900'}`}
                 >
                    <LayoutGrid size={20} />
                </button>
                <button 
                    onClick={() => setActiveTab('stats')}
                    className={`p-2 rounded-lg transition-colors ${activeTab === 'stats' ? 'bg-zinc-800 text-white' : 'text-zinc-500 hover:bg-zinc-900'}`}
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

        {activeTab === 'ranking' ? (
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
        ) : (
            <StatsView items={items} />
        )}
      </main>

      {/* Add Media Modal */}
      <AddMediaModal 
        isOpen={isModalOpen} 
        onClose={() => setIsModalOpen(false)} 
        onAdd={addItem} 
        currentItems={items}
      />

    </div>
  );
};

export default App;