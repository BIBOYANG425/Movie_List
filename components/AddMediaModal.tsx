import React, { useState, useEffect } from 'react';
import { X, Search, Plus, ArrowLeft, ArrowDown, ChevronDown } from 'lucide-react';
import { RankedItem, Tier } from '../types';
import { MOCK_SEARCH_RESULTS, TIER_COLORS, TIER_LABELS } from '../constants';

interface AddMediaModalProps {
  isOpen: boolean;
  onClose: () => void;
  onAdd: (item: RankedItem) => void;
  currentItems: RankedItem[];
}

type Step = 'search' | 'tier' | 'rank';

export const AddMediaModal: React.FC<AddMediaModalProps> = ({ isOpen, onClose, onAdd, currentItems }) => {
  const [step, setStep] = useState<Step>('search');
  const [searchTerm, setSearchTerm] = useState('');
  const [selectedItem, setSelectedItem] = useState<RankedItem | null>(null);
  const [selectedTier, setSelectedTier] = useState<Tier | null>(null);

  // Reset state when modal opens/closes
  useEffect(() => {
    if (isOpen) {
      setStep('search');
      setSearchTerm('');
      setSelectedItem(null);
      setSelectedTier(null);
    }
  }, [isOpen]);

  if (!isOpen) return null;

  const handleSelectMovie = (item: RankedItem) => {
    setSelectedItem(item);
    setStep('tier');
  };

  const handleSelectTier = (tier: Tier) => {
    setSelectedTier(tier);
    // If the tier is empty, we can skip the ranking step
    const hasItemsInTier = currentItems.some(i => i.tier === tier);
    if (!hasItemsInTier) {
      // Add immediately at rank 0
      onAdd({ ...selectedItem!, tier, rank: 0, id: Math.random().toString(36).substr(2, 9) });
      onClose();
    } else {
      setStep('rank');
    }
  };

  const handleInsertAt = (rankIndex: number) => {
    if (selectedItem && selectedTier) {
      onAdd({
        ...selectedItem,
        tier: selectedTier,
        rank: rankIndex,
        id: Math.random().toString(36).substr(2, 9)
      });
      onClose();
    }
  };

  const renderSearchStep = () => (
    <div className="space-y-6 animate-fade-in">
       <div className="relative">
        <Search className="absolute left-3 top-3 text-zinc-500" size={20} />
        <input
          type="text"
          autoFocus
          placeholder="Search movies or plays..."
          className="w-full bg-zinc-950 border border-zinc-800 rounded-xl py-3 pl-10 pr-4 text-white placeholder-zinc-600 focus:outline-none focus:border-indigo-500 transition-colors"
          value={searchTerm}
          onChange={(e) => setSearchTerm(e.target.value)}
        />
      </div>

      <div className="space-y-2 max-h-[60vh] overflow-y-auto pr-2">
        {MOCK_SEARCH_RESULTS.filter(i => i.title.toLowerCase().includes(searchTerm.toLowerCase())).map((item) => (
          <button
            key={item.id}
            onClick={() => handleSelectMovie(item)}
            className="w-full flex items-center gap-3 p-2 rounded-lg hover:bg-zinc-800 transition-colors group text-left"
          >
            <img src={item.posterUrl} alt="" className="w-12 h-16 object-cover rounded bg-zinc-800 shadow-sm" />
            <div className="flex-1">
              <div className="font-semibold text-white group-hover:text-indigo-400 transition-colors">{item.title}</div>
              <div className="text-xs text-zinc-500">{item.year} • {item.genres.join(', ')}</div>
            </div>
            <div className="text-zinc-600 group-hover:text-white">
              <Plus size={20} />
            </div>
          </button>
        ))}
        {searchTerm && MOCK_SEARCH_RESULTS.filter(i => i.title.toLowerCase().includes(searchTerm.toLowerCase())).length === 0 && (
              <div className="text-center py-12 text-zinc-500 text-sm">
                No results found. <br/> <span className="text-xs opacity-50">(This is a mock search)</span>
              </div>
        )}
      </div>
    </div>
  );

  const renderTierStep = () => (
    <div className="space-y-6 animate-fade-in">
       <div className="flex items-center gap-4 bg-zinc-800/50 p-4 rounded-xl border border-zinc-700/50">
          <img src={selectedItem?.posterUrl} alt="" className="w-16 h-24 object-cover rounded shadow-lg" />
          <div>
            <h3 className="font-bold text-lg leading-tight">{selectedItem?.title}</h3>
            <p className="text-zinc-400 text-sm mt-1">Select a Tier to place this item.</p>
          </div>
       </div>

       <div className="grid gap-3">
          {Object.values(Tier).map((tier) => (
            <button
              key={tier}
              onClick={() => handleSelectTier(tier)}
              className={`flex items-center justify-between p-4 rounded-xl border-2 transition-all hover:scale-[1.02] active:scale-[0.98] ${TIER_COLORS[tier]} bg-opacity-10 hover:bg-opacity-20`}
            >
               <div className="flex items-center gap-4">
                  <span className="text-2xl font-black">{tier}</span>
                  <span className="font-semibold opacity-90">{TIER_LABELS[tier]}</span>
               </div>
               <span className="text-xs font-mono opacity-50 bg-black/20 px-2 py-1 rounded">
                 {currentItems.filter(i => i.tier === tier).length} items
               </span>
            </button>
          ))}
       </div>
    </div>
  );

  const renderRankStep = () => {
    const existingItems = currentItems
      .filter(i => i.tier === selectedTier)
      .sort((a, b) => a.rank - b.rank);

    return (
      <div className="flex flex-col h-[60vh] animate-fade-in">
        <div className="flex items-center justify-between mb-4">
            <div>
               <h3 className="font-bold text-lg">Compare & Rank</h3>
               <p className="text-zinc-400 text-xs">Where does <span className="text-white font-semibold">{selectedItem?.title}</span> fit in Tier {selectedTier}?</p>
            </div>
            <div className={`px-3 py-1 rounded font-black text-xl ${TIER_COLORS[selectedTier!]?.split(' ')[0]}`}>
              {selectedTier}
            </div>
        </div>
        
        <div className="flex-1 overflow-y-auto pr-2 space-y-2 relative pb-20">
             {/* Insert Button at Top */}
             <InsertButton onClick={() => handleInsertAt(0)} label="Insert at Top" />

             {existingItems.map((item, index) => (
               <React.Fragment key={item.id}>
                 <div className="flex items-center gap-3 p-3 bg-zinc-900 border border-zinc-800 rounded-lg opacity-70">
                    <span className="font-mono text-zinc-500 w-6 text-center">#{index + 1}</span>
                    <img src={item.posterUrl} className="w-8 h-12 object-cover rounded bg-zinc-800" alt="" />
                    <span className="font-medium text-zinc-300 text-sm truncate flex-1">{item.title}</span>
                 </div>
                 
                 {/* Insert Button between items */}
                 <InsertButton onClick={() => handleInsertAt(index + 1)} />
               </React.Fragment>
             ))}
        </div>
      </div>
    );
  };

  const getStepTitle = () => {
    switch(step) {
      case 'search': return 'Add to Marquee';
      case 'tier': return 'Assign Tier';
      case 'rank': return 'Relative Ranking';
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm">
      <div className="bg-zinc-950 border border-zinc-800 w-full max-w-lg rounded-2xl shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">
        
        {/* Header */}
        <div className="flex items-center justify-between p-6 border-b border-zinc-800 bg-zinc-900/50">
          <div className="flex items-center gap-3">
             {step !== 'search' && (
               <button onClick={() => setStep(step === 'rank' ? 'tier' : 'search')} className="text-zinc-400 hover:text-white">
                 <ArrowLeft size={20} />
               </button>
             )}
             <h2 className="text-xl font-bold text-white">{getStepTitle()}</h2>
          </div>
          <button onClick={onClose} className="text-zinc-400 hover:text-white transition-colors">
            <X size={24} />
          </button>
        </div>

        {/* Content */}
        <div className="p-6 overflow-y-auto">
           {step === 'search' && renderSearchStep()}
           {step === 'tier' && renderTierStep()}
           {step === 'rank' && renderRankStep()}
        </div>
      </div>
    </div>
  );
};

// Helper Component for the "Insert Here" button
const InsertButton = ({ onClick, label }: { onClick: () => void, label?: string }) => (
  <button 
    onClick={onClick}
    className="w-full group flex items-center justify-center py-2 my-1"
  >
     <div className="h-[1px] flex-1 bg-zinc-800 group-hover:bg-indigo-500/50 transition-colors"></div>
     <div className="mx-2 px-3 py-1 rounded-full bg-zinc-900 border border-zinc-700 text-xs text-zinc-500 group-hover:border-indigo-500 group-hover:text-indigo-400 group-hover:bg-indigo-500/10 transition-all flex items-center gap-1">
        <ChevronDown size={12} />
        {label || "Insert Here"}
     </div>
     <div className="h-[1px] flex-1 bg-zinc-800 group-hover:bg-indigo-500/50 transition-colors"></div>
  </button>
);
