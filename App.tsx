import React, { useState, useEffect } from 'react';
import { LayoutGrid, Plus, Sparkles, Filter, BarChart2 } from 'lucide-react';
import { Tier, RankedItem, AiRecommendation } from './types';
import { INITIAL_RANKINGS, TIERS } from './constants';
import { TierRow } from './components/TierRow';
import { AddMediaModal } from './components/AddMediaModal';
import { StatsView } from './components/StatsView';
import { GeminiService } from './services/geminiService';

const App = () => {
  const [items, setItems] = useState<RankedItem[]>(INITIAL_RANKINGS);
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [activeTab, setActiveTab] = useState<'ranking' | 'stats'>('ranking');
  const [filterType, setFilterType] = useState<'all' | 'movie' | 'theater'>('all');
  
  // AI State
  const [apiKey, setApiKey] = useState('');
  const [aiLoading, setAiLoading] = useState(false);
  const [aiRoast, setAiRoast] = useState<string | null>(null);
  const [recommendations, setRecommendations] = useState<AiRecommendation[]>([]);
  const [showAiModal, setShowAiModal] = useState(false);

  // Drag State
  const [draggedItemId, setDraggedItemId] = useState<string | null>(null);

  useEffect(() => {
    // Load API Key from env if available for dev
    if (process.env.API_KEY) {
        setApiKey(process.env.API_KEY);
    }
  }, []);

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

  const generateAiInsights = async () => {
    if (!apiKey) {
      alert("Please enter a Google Gemini API Key to use this feature.");
      setShowAiModal(true);
      return;
    }
    
    setAiLoading(true);
    setShowAiModal(true);
    const service = new GeminiService(apiKey);
    const result = await service.getRoastAndRecommendations(items);
    setAiRoast(result.roast);
    setRecommendations(result.recommendations);
    setAiLoading(false);
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
              {(['all', 'movie', 'theater'] as const).map((type) => (
                <button
                  key={type}
                  onClick={() => setFilterType(type)}
                  className={`px-3 py-1.5 rounded-md text-xs font-semibold capitalize transition-all ${
                    filterType === type 
                      ? 'bg-zinc-700 text-white shadow' 
                      : 'text-zinc-500 hover:text-zinc-300'
                  }`}
                >
                  {type}
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
                    Drag items between tiers to rank them. Order implies superiority.
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
                    onClick={generateAiInsights}
                    className="flex items-center gap-2 px-3 py-2 bg-gradient-to-r from-purple-900 to-indigo-900 border border-indigo-700/50 rounded-lg text-indigo-100 text-sm font-medium hover:from-purple-800 hover:to-indigo-800 transition-all shadow-lg shadow-purple-900/20"
                >
                    <Sparkles size={16} />
                    <span>AI Insights</span>
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

      {/* AI Modal (Simple Overlay for Demo) */}
      {showAiModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm">
            <div className="bg-zinc-900 border border-zinc-800 w-full max-w-2xl rounded-2xl shadow-2xl p-6 relative">
                 <button onClick={() => setShowAiModal(false)} className="absolute top-4 right-4 text-zinc-400 hover:text-white"><Plus className="rotate-45" size={24}/></button>
                 
                 <div className="flex items-center gap-3 mb-6">
                    <div className="p-2 bg-purple-500/10 rounded-lg">
                        <Sparkles className="text-purple-400" size={24} />
                    </div>
                    <h2 className="text-xl font-bold">Curator Intelligence</h2>
                 </div>

                 {!apiKey && !process.env.API_KEY ? (
                     <div className="space-y-4">
                         <p className="text-zinc-400">To use AI features, please provide a Gemini API Key. The app does not store this permanently.</p>
                         <input 
                            type="password" 
                            placeholder="Enter API Key" 
                            className="w-full bg-black border border-zinc-700 rounded p-2"
                            onChange={(e) => setApiKey(e.target.value)}
                        />
                        <button 
                            onClick={generateAiInsights}
                            className="w-full bg-white text-black font-bold py-2 rounded"
                        >
                            Analyze My Taste
                        </button>
                     </div>
                 ) : aiLoading ? (
                     <div className="py-12 flex flex-col items-center justify-center text-zinc-500 gap-4">
                         <div className="animate-spin w-8 h-8 border-2 border-current border-t-transparent rounded-full"></div>
                         <p>Judging your taste...</p>
                     </div>
                 ) : (
                     <div className="space-y-6 animate-fade-in">
                         {aiRoast && (
                             <div className="bg-gradient-to-br from-purple-900/20 to-blue-900/20 p-4 rounded-xl border border-white/5">
                                 <h3 className="text-xs font-bold uppercase tracking-wider text-purple-400 mb-2">The Vibe Check</h3>
                                 <p className="text-lg italic font-medium leading-relaxed">"{aiRoast}"</p>
                             </div>
                         )}

                         {recommendations.length > 0 && (
                            <div>
                                <h3 className="text-xs font-bold uppercase tracking-wider text-green-400 mb-3">Recommended for You</h3>
                                <div className="space-y-3">
                                    {recommendations.map((rec, idx) => (
                                        <div key={idx} className="bg-zinc-800/50 p-3 rounded-lg flex flex-col gap-1">
                                            <span className="font-bold text-white">{rec.title}</span>
                                            <span className="text-sm text-zinc-400">{rec.reason}</span>
                                        </div>
                                    ))}
                                </div>
                            </div>
                         )}
                     </div>
                 )}
            </div>
        </div>
      )}
    </div>
  );
};

export default App;