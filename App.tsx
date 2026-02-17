import React, { useState } from 'react';
import { LayoutGrid, Plus, BarChart2 } from 'lucide-react';
import { Tier, RankedItem } from './types';
import { INITIAL_RANKINGS, TIERS } from './constants';
import { TierRow } from './components/TierRow';
import { AddMediaModal } from './components/AddMediaModal';
import { StatsView } from './components/StatsView';

const App = () => {
  const [items, setItems] = useState<RankedItem[]>(INITIAL_RANKINGS);
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [activeTab, setActiveTab] = useState<'ranking' | 'stats'>('ranking');
  const [filterType, setFilterType] = useState<'all' | 'movie'>('all');
  
  // Drag State
  const [draggedItemId, setDraggedItemId] = useState<string | null>(null);

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
            </div>
        </header>

        {activeTab === 'ranking' ? (
             <div className="space-y-4">
                {TIERS.map((tier) => (
                    <TierRow
                    key={tier}
                    tier={tier}
                    items={filteredItems.filter((i) => i.tier === tier).sort((a, b) => a.rank - b.rank)}
                    onDrop={handleDrop}
                    onDragStart={handleDragStart}
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