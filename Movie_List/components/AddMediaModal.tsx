import React, { useState, useEffect } from 'react';
import { X, Search, Plus, ArrowLeft } from 'lucide-react';
import { RankedItem, Tier } from '../types';
import { MOCK_SEARCH_RESULTS, TIER_COLORS, TIER_LABELS } from '../constants';

interface AddMediaModalProps {
  isOpen: boolean;
  onClose: () => void;
  onAdd: (item: RankedItem) => void;
  currentItems: RankedItem[];
}

type Step = 'search' | 'tier' | 'compare';

interface CompareSnapshot {
  low: number;
  high: number;
}

export const AddMediaModal: React.FC<AddMediaModalProps> = ({ isOpen, onClose, onAdd, currentItems }) => {
  const [step, setStep] = useState<Step>('search');
  const [searchTerm, setSearchTerm] = useState('');
  const [selectedItem, setSelectedItem] = useState<RankedItem | null>(null);
  const [selectedTier, setSelectedTier] = useState<Tier | null>(null);

  // Binary search comparison state
  const [compLow, setCompLow] = useState(0);
  const [compHigh, setCompHigh] = useState(0);
  const [compHistory, setCompHistory] = useState<CompareSnapshot[]>([]);

  // Reset state when modal opens/closes
  useEffect(() => {
    if (isOpen) {
      setStep('search');
      setSearchTerm('');
      setSelectedItem(null);
      setSelectedTier(null);
      setCompLow(0);
      setCompHigh(0);
      setCompHistory([]);
    }
  }, [isOpen]);

  if (!isOpen) return null;

  const getTierItems = (tier: Tier) =>
    currentItems.filter(i => i.tier === tier).sort((a, b) => a.rank - b.rank);

  const handleSelectMovie = (item: RankedItem) => {
    setSelectedItem(item);
    setStep('tier');
  };

  const handleSelectTier = (tier: Tier) => {
    setSelectedTier(tier);
    const tierItems = getTierItems(tier);
    if (tierItems.length === 0) {
      // No items in tier — insert immediately at rank 0
      onAdd({ ...selectedItem!, tier, rank: 0, id: Math.random().toString(36).substr(2, 9) });
      onClose();
    } else {
      // Start binary search
      setCompLow(0);
      setCompHigh(tierItems.length);
      setCompHistory([]);
      setStep('compare');
    }
  };

  const handleInsertAt = (rankIndex: number) => {
    if (selectedItem && selectedTier) {
      onAdd({
        ...selectedItem,
        tier: selectedTier,
        rank: rankIndex,
        id: Math.random().toString(36).substr(2, 9),
      });
      onClose();
    }
  };

  const handleCompareChoice = (choice: 'new' | 'existing' | 'too_tough' | 'skip') => {
    const mid = Math.floor((compLow + compHigh) / 2);

    if (choice === 'too_tough' || choice === 'skip') {
      handleInsertAt(mid);
      return;
    }

    // Save snapshot for Undo
    setCompHistory(prev => [...prev, { low: compLow, high: compHigh }]);

    let newLow = compLow;
    let newHigh = compHigh;

    if (choice === 'new') {
      // New item is better → it belongs above the pivot (lower index)
      newHigh = mid;
    } else {
      // Existing is better → new item belongs below the pivot
      newLow = mid + 1;
    }

    if (newLow >= newHigh) {
      handleInsertAt(newLow);
    } else {
      setCompLow(newLow);
      setCompHigh(newHigh);
    }
  };

  const handleUndo = () => {
    if (compHistory.length === 0) return;
    const prev = compHistory[compHistory.length - 1];
    setCompLow(prev.low);
    setCompHigh(prev.high);
    setCompHistory(h => h.slice(0, -1));
  };

  // ─── Render: Search ───────────────────────────────────────────────────────
  const renderSearchStep = () => (
    <div className="space-y-6 animate-fade-in">
      <div className="relative">
        <Search className="absolute left-3 top-3 text-zinc-500" size={20} />
        <input
          type="text"
          autoFocus
          placeholder="Search movies..."
          className="w-full bg-zinc-950 border border-zinc-800 rounded-xl py-3 pl-10 pr-4 text-white placeholder-zinc-600 focus:outline-none focus:border-indigo-500 transition-colors"
          value={searchTerm}
          onChange={(e) => setSearchTerm(e.target.value)}
        />
      </div>

      <div className="space-y-2 max-h-[60vh] overflow-y-auto pr-2">
        {MOCK_SEARCH_RESULTS.filter(i =>
          i.title.toLowerCase().includes(searchTerm.toLowerCase())
        ).map((item) => (
          <button
            key={item.id}
            onClick={() => handleSelectMovie(item)}
            className="w-full flex items-center gap-3 p-2 rounded-lg hover:bg-zinc-800 transition-colors group text-left"
          >
            <img src={item.posterUrl} alt="" className="w-12 h-16 object-cover rounded bg-zinc-800 shadow-sm" />
            <div className="flex-1">
              <div className="font-semibold text-white group-hover:text-indigo-400 transition-colors">{item.title}</div>
              <div className="text-xs text-zinc-500">{item.year} · {item.genres.join(', ')}</div>
            </div>
            <div className="text-zinc-600 group-hover:text-white">
              <Plus size={20} />
            </div>
          </button>
        ))}
        {searchTerm &&
          MOCK_SEARCH_RESULTS.filter(i =>
            i.title.toLowerCase().includes(searchTerm.toLowerCase())
          ).length === 0 && (
            <div className="text-center py-12 text-zinc-500 text-sm">
              No results found.<br />
              <span className="text-xs opacity-50">(This is a mock search)</span>
            </div>
          )}
      </div>
    </div>
  );

  // ─── Render: Tier ────────────────────────────────────────────────────────
  const renderTierStep = () => (
    <div className="space-y-6 animate-fade-in">
      <div className="flex items-center gap-4 bg-zinc-800/50 p-4 rounded-xl border border-zinc-700/50">
        <img src={selectedItem?.posterUrl} alt="" className="w-16 h-24 object-cover rounded shadow-lg" />
        <div>
          <h3 className="font-bold text-lg leading-tight">{selectedItem?.title}</h3>
          <p className="text-zinc-400 text-sm mt-1">How does this tier feel to you?</p>
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

  // ─── Render: Compare ─────────────────────────────────────────────────────
  const renderCompareStep = () => {
    const tierItems = getTierItems(selectedTier!);
    const mid = Math.floor((compLow + compHigh) / 2);
    const pivotItem = tierItems[mid];
    const totalRounds = Math.ceil(Math.log2(tierItems.length + 1));
    const currentRound = compHistory.length + 1;

    return (
      <div className="flex flex-col gap-6 animate-fade-in">
        {/* Round indicator */}
        <div className="flex items-center justify-between">
          <p className="text-zinc-400 text-sm">
            Round <span className="text-white font-semibold">{currentRound}</span>
            {' '}of ~<span className="text-white font-semibold">{totalRounds}</span>
          </p>
          <div className="flex gap-1">
            {Array.from({ length: totalRounds }).map((_, i) => (
              <div
                key={i}
                className={`h-1.5 w-6 rounded-full transition-colors ${
                  i < compHistory.length
                    ? 'bg-indigo-500'
                    : i === compHistory.length
                    ? 'bg-zinc-500'
                    : 'bg-zinc-800'
                }`}
              />
            ))}
          </div>
        </div>

        {/* Question */}
        <h3 className="text-center text-lg font-bold text-white">Which do you prefer?</h3>

        {/* Head-to-head cards */}
        <div className="flex items-stretch gap-3">
          {/* New item (left) */}
          <button
            onClick={() => handleCompareChoice('new')}
            className="flex-1 flex flex-col items-center gap-3 p-4 rounded-2xl border-2 border-zinc-700 hover:border-indigo-500 hover:bg-indigo-500/5 transition-all group active:scale-[0.97]"
          >
            <img
              src={selectedItem?.posterUrl}
              alt={selectedItem?.title}
              className="w-full aspect-[2/3] object-cover rounded-lg shadow-lg group-hover:shadow-indigo-500/20"
            />
            <div className="text-center">
              <p className="font-bold text-white text-sm leading-tight">{selectedItem?.title}</p>
              <p className="text-xs text-zinc-500 mt-0.5">{selectedItem?.year}</p>
              <span className="inline-block mt-2 text-xs text-indigo-400 font-semibold border border-indigo-500/30 bg-indigo-500/10 px-2 py-0.5 rounded-full">
                NEW
              </span>
            </div>
          </button>

          {/* OR divider */}
          <div className="flex items-center justify-center flex-shrink-0">
            <div className="w-9 h-9 rounded-full bg-zinc-800 border border-zinc-700 flex items-center justify-center text-xs font-black text-zinc-400">
              OR
            </div>
          </div>

          {/* Pivot item (right) */}
          <button
            onClick={() => handleCompareChoice('existing')}
            className="flex-1 flex flex-col items-center gap-3 p-4 rounded-2xl border-2 border-zinc-700 hover:border-zinc-400 hover:bg-zinc-400/5 transition-all group active:scale-[0.97]"
          >
            <img
              src={pivotItem?.posterUrl}
              alt={pivotItem?.title}
              className="w-full aspect-[2/3] object-cover rounded-lg shadow-lg"
            />
            <div className="text-center">
              <p className="font-bold text-white text-sm leading-tight">{pivotItem?.title}</p>
              <p className="text-xs text-zinc-500 mt-0.5">{pivotItem?.year}</p>
              <span className={`inline-block mt-2 text-xs font-semibold px-2 py-0.5 rounded-full border ${TIER_COLORS[selectedTier!]}`}>
                {selectedTier} Tier · #{mid + 1}
              </span>
            </div>
          </button>
        </div>

        {/* Action buttons */}
        <div className="flex items-center justify-between mt-1">
          <button
            onClick={handleUndo}
            disabled={compHistory.length === 0}
            className="flex items-center gap-1.5 text-sm font-medium text-zinc-400 hover:text-white disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
          >
            <ArrowLeft size={15} />
            Undo
          </button>

          <button
            onClick={() => handleCompareChoice('too_tough')}
            className="px-4 py-2 rounded-full border border-zinc-700 text-sm font-semibold text-zinc-300 hover:bg-zinc-800 hover:border-zinc-500 transition-all"
          >
            Too tough
          </button>

          <button
            onClick={() => handleCompareChoice('skip')}
            className="flex items-center gap-1.5 text-sm font-medium text-zinc-400 hover:text-white transition-colors"
          >
            Skip
            <ArrowLeft size={15} className="rotate-180" />
          </button>
        </div>
      </div>
    );
  };

  // ─── Step title ───────────────────────────────────────────────────────────
  const getStepTitle = () => {
    switch (step) {
      case 'search': return 'Add to Marquee';
      case 'tier':   return 'Assign Tier';
      case 'compare': return 'Head-to-Head';
    }
  };

  const handleBack = () => {
    if (step === 'compare') setStep('tier');
    else if (step === 'tier') setStep('search');
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm">
      <div className="bg-zinc-950 border border-zinc-800 w-full max-w-lg rounded-2xl shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">

        {/* Header */}
        <div className="flex items-center justify-between p-6 border-b border-zinc-800 bg-zinc-900/50">
          <div className="flex items-center gap-3">
            {step !== 'search' && (
              <button onClick={handleBack} className="text-zinc-400 hover:text-white transition-colors">
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
          {step === 'search'  && renderSearchStep()}
          {step === 'tier'    && renderTierStep()}
          {step === 'compare' && renderCompareStep()}
        </div>
      </div>
    </div>
  );
};
