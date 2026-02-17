import React, { useState, useEffect, useRef } from 'react';
import { X, Search, Plus, ArrowLeft, Loader2, Film, StickyNote, ChevronRight } from 'lucide-react';
import { RankedItem, Tier } from '../types';
import { TIER_COLORS, TIER_LABELS } from '../constants';
import { searchMovies, hasTmdbKey, TMDBMovie } from '../services/tmdbService';

interface AddMediaModalProps {
  isOpen: boolean;
  onClose: () => void;
  onAdd: (item: RankedItem) => void;
  currentItems: RankedItem[];
}

type Step = 'search' | 'tier' | 'notes' | 'compare';

interface CompareSnapshot {
  low: number;
  high: number;
}

export const AddMediaModal: React.FC<AddMediaModalProps> = ({ isOpen, onClose, onAdd, currentItems }) => {
  const [step, setStep] = useState<Step>('search');
  const [searchTerm, setSearchTerm] = useState('');
  const [searchResults, setSearchResults] = useState<TMDBMovie[]>([]);
  const [isSearching, setIsSearching] = useState(false);
  const [selectedItem, setSelectedItem] = useState<RankedItem | null>(null);
  const [selectedTier, setSelectedTier] = useState<Tier | null>(null);

  // Notes state
  const [notes, setNotes] = useState('');

  // Binary search comparison state
  const [compLow, setCompLow] = useState(0);
  const [compHigh, setCompHigh] = useState(0);
  const [compHistory, setCompHistory] = useState<CompareSnapshot[]>([]);

  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Reset on open/close
  useEffect(() => {
    if (isOpen) {
      setStep('search');
      setSearchTerm('');
      setSearchResults([]);
      setIsSearching(false);
      setSelectedItem(null);
      setSelectedTier(null);
      setNotes('');
      setCompLow(0);
      setCompHigh(0);
      setCompHistory([]);
    }
  }, [isOpen]);

  // Debounced TMDB search
  useEffect(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);

    if (!searchTerm.trim()) {
      setSearchResults([]);
      setIsSearching(false);
      return;
    }

    setIsSearching(true);

    debounceRef.current = setTimeout(async () => {
      const results = await searchMovies(searchTerm);
      setSearchResults(results);
      setIsSearching(false);
    }, 350);

    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, [searchTerm]);

  if (!isOpen) return null;

  const getTierItems = (tier: Tier) =>
    currentItems.filter(i => i.tier === tier).sort((a, b) => a.rank - b.rank);

  const handleSelectMovie = (movie: TMDBMovie) => {
    // Convert TMDBMovie → RankedItem (tier/rank are placeholders, set in next steps)
    const asRankedItem: RankedItem = {
      id: movie.id,
      title: movie.title,
      year: movie.year,
      posterUrl: movie.posterUrl ?? '',
      type: 'movie',
      genres: movie.genres,
      tier: Tier.B,  // placeholder — overwritten in handleSelectTier
      rank: 0,
    };
    setSelectedItem(asRankedItem);
    setStep('tier');
  };

  const handleSelectTier = (tier: Tier) => {
    setSelectedTier(tier);
    // Always go to notes step first, regardless of tier size
    setStep('notes');
  };

  const proceedFromNotes = () => {
    const tierItems = getTierItems(selectedTier!);
    if (tierItems.length === 0) {
      // No existing items in tier — insert immediately
      onAdd({
        ...selectedItem!,
        tier: selectedTier!,
        rank: 0,
        notes: notes.trim() || undefined,
        id: Math.random().toString(36).substr(2, 9),
      });
      onClose();
    } else {
      // Start head-to-head comparison
      setCompLow(0);
      setCompHigh(tierItems.length);
      setCompHistory([]);
      setStep('compare');
    }
  };

  const handleInsertAt = (rankIndex: number) => {
    if (selectedItem && selectedTier) {
      const finalItem: RankedItem = {
        ...selectedItem,
        tier: selectedTier,
        rank: rankIndex,
        notes: notes.trim() || undefined,
        id: Math.random().toString(36).substr(2, 9),
      };

      onAdd(finalItem);

      // TODO (Day 4): POST finalItem to backend /rankings endpoint
      // fetch('/api/rankings', { method: 'POST', body: JSON.stringify(finalItem) })

      onClose();
    }
  };

  const handleCompareChoice = (choice: 'new' | 'existing' | 'too_tough' | 'skip') => {
    const mid = Math.floor((compLow + compHigh) / 2);

    if (choice === 'too_tough' || choice === 'skip') {
      handleInsertAt(mid);
      return;
    }

    setCompHistory(prev => [...prev, { low: compLow, high: compHigh }]);

    let newLow = compLow;
    let newHigh = compHigh;

    if (choice === 'new') {
      newHigh = mid;
    } else {
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
    <div className="space-y-4 animate-fade-in">
      {/* Search input */}
      <div className="relative">
        <Search className="absolute left-3 top-3.5 text-zinc-500" size={18} />
        <input
          type="text"
          autoFocus
          placeholder="Search any movie..."
          className="w-full bg-zinc-950 border border-zinc-800 rounded-xl py-3 pl-10 pr-4 text-white placeholder-zinc-600 focus:outline-none focus:border-indigo-500 transition-colors"
          value={searchTerm}
          onChange={(e) => setSearchTerm(e.target.value)}
        />
        {isSearching && (
          <Loader2 className="absolute right-3 top-3.5 text-zinc-500 animate-spin" size={18} />
        )}
      </div>

      {/* No API key warning */}
      {!hasTmdbKey() && (
        <div className="bg-yellow-500/10 border border-yellow-500/20 rounded-xl p-4 text-sm text-yellow-300">
          <p className="font-semibold mb-1">TMDB API key not configured</p>
          <p className="text-yellow-400/70 text-xs">
            Add <code className="bg-black/30 px-1 rounded">VITE_TMDB_API_KEY</code> to your Vercel environment variables to enable live search.
          </p>
        </div>
      )}

      {/* Results */}
      <div className="space-y-1 max-h-[55vh] overflow-y-auto pr-1">
        {/* Loading skeleton */}
        {isSearching && (
          <div className="space-y-2">
            {[1, 2, 3].map(i => (
              <div key={i} className="flex items-center gap-3 p-2 rounded-lg animate-pulse">
                <div className="w-12 h-16 bg-zinc-800 rounded flex-shrink-0" />
                <div className="flex-1 space-y-2">
                  <div className="h-3 bg-zinc-800 rounded w-3/4" />
                  <div className="h-2 bg-zinc-800 rounded w-1/2" />
                </div>
              </div>
            ))}
          </div>
        )}

        {/* Search results */}
        {!isSearching && searchResults.map((movie) => (
          <button
            key={movie.id}
            onClick={() => handleSelectMovie(movie)}
            className="w-full flex items-center gap-3 p-2 rounded-xl hover:bg-zinc-800/80 transition-colors group text-left"
          >
            {/* Poster */}
            {movie.posterUrl ? (
              <img
                src={movie.posterUrl}
                alt={movie.title}
                className="w-12 h-[72px] object-cover rounded-lg bg-zinc-800 flex-shrink-0 shadow-md"
              />
            ) : (
              <div className="w-12 h-[72px] bg-zinc-800 rounded-lg flex items-center justify-center flex-shrink-0">
                <Film size={20} className="text-zinc-600" />
              </div>
            )}

            {/* Info */}
            <div className="flex-1 min-w-0">
              <p className="font-semibold text-white group-hover:text-indigo-400 transition-colors truncate leading-tight">
                {movie.title}
              </p>
              <p className="text-xs text-zinc-500 mt-0.5">{movie.year}</p>
              {movie.genres.length > 0 && (
                <div className="flex gap-1 mt-1.5 flex-wrap">
                  {movie.genres.map(g => (
                    <span key={g} className="text-[10px] px-1.5 py-0.5 bg-zinc-800 text-zinc-400 rounded-full border border-zinc-700">
                      {g}
                    </span>
                  ))}
                </div>
              )}
            </div>

            <div className="text-zinc-700 group-hover:text-zinc-300 flex-shrink-0 transition-colors">
              <Plus size={18} />
            </div>
          </button>
        ))}

        {/* Empty state */}
        {!isSearching && searchTerm.trim() && searchResults.length === 0 && (
          <div className="text-center py-12 text-zinc-500 text-sm">
            <Film size={32} className="mx-auto mb-3 opacity-30" />
            <p>No results for "{searchTerm}"</p>
            <p className="text-xs mt-1 opacity-60">Try a different title or check spelling</p>
          </div>
        )}

        {/* Initial prompt */}
        {!isSearching && !searchTerm.trim() && (
          <div className="text-center py-12 text-zinc-600 text-sm">
            <Search size={32} className="mx-auto mb-3 opacity-30" />
            <p>Type a movie title to search</p>
          </div>
        )}
      </div>
    </div>
  );

  // ─── Render: Tier ─────────────────────────────────────────────────────────
  const renderTierStep = () => (
    <div className="space-y-5 animate-fade-in">
      {/* Selected movie preview */}
      <div className="flex items-center gap-4 bg-zinc-800/50 p-4 rounded-xl border border-zinc-700/50">
        {selectedItem?.posterUrl ? (
          <img src={selectedItem.posterUrl} alt="" className="w-14 h-20 object-cover rounded-lg shadow-lg flex-shrink-0" />
        ) : (
          <div className="w-14 h-20 bg-zinc-800 rounded-lg flex items-center justify-center flex-shrink-0">
            <Film size={20} className="text-zinc-600" />
          </div>
        )}
        <div>
          <h3 className="font-bold text-lg leading-tight">{selectedItem?.title}</h3>
          <p className="text-zinc-500 text-sm mt-0.5">{selectedItem?.year}</p>
          <p className="text-zinc-400 text-sm mt-1">How does this tier feel?</p>
        </div>
      </div>

      <div className="grid gap-2.5">
        {Object.values(Tier).map((tier) => (
          <button
            key={tier}
            onClick={() => handleSelectTier(tier)}
            className={`flex items-center justify-between p-4 rounded-xl border-2 transition-all hover:scale-[1.02] active:scale-[0.98] ${TIER_COLORS[tier]}`}
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

  // ─── Render: Notes ────────────────────────────────────────────────────────
  const MAX_NOTES = 280;

  const renderNotesStep = () => (
    <div className="flex flex-col gap-5 animate-fade-in">
      {/* Movie preview */}
      <div className="flex items-center gap-4 bg-zinc-800/50 p-4 rounded-xl border border-zinc-700/50">
        {selectedItem?.posterUrl ? (
          <img
            src={selectedItem.posterUrl}
            alt=""
            className="w-12 h-[72px] object-cover rounded-lg shadow-md flex-shrink-0"
          />
        ) : (
          <div className="w-12 h-[72px] bg-zinc-800 rounded-lg flex items-center justify-center flex-shrink-0">
            <Film size={18} className="text-zinc-600" />
          </div>
        )}
        <div>
          <p className="font-bold text-white leading-tight">{selectedItem?.title}</p>
          <p className="text-zinc-500 text-xs mt-0.5">{selectedItem?.year}</p>
          <span className={`inline-block mt-2 text-xs font-bold px-2 py-0.5 rounded-full border ${TIER_COLORS[selectedTier!]}`}>
            {selectedTier} — {TIER_LABELS[selectedTier!]}
          </span>
        </div>
      </div>

      {/* Notes textarea */}
      <div className="space-y-2">
        <label className="flex items-center gap-2 text-sm font-semibold text-zinc-300">
          <StickyNote size={15} className="text-amber-400" />
          Your thoughts
          <span className="text-zinc-600 font-normal text-xs">(optional)</span>
        </label>
        <div className="relative">
          <textarea
            autoFocus
            rows={4}
            maxLength={MAX_NOTES}
            placeholder="What stood out? A scene, a feeling, why it deserves this tier..."
            className="w-full bg-zinc-900 border border-zinc-700 rounded-xl py-3 px-4 text-white placeholder-zinc-600 focus:outline-none focus:border-amber-500/60 transition-colors resize-none text-sm leading-relaxed"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
          />
          {/* Character count */}
          <span className={`absolute bottom-3 right-3 text-xs tabular-nums transition-colors ${
            notes.length > MAX_NOTES * 0.9 ? 'text-amber-400' : 'text-zinc-600'
          }`}>
            {notes.length}/{MAX_NOTES}
          </span>
        </div>
      </div>

      {/* Action buttons */}
      <div className="flex flex-col gap-2 pt-1">
        <button
          onClick={proceedFromNotes}
          className="w-full flex items-center justify-center gap-2 py-3 rounded-xl bg-white text-black font-semibold text-sm hover:bg-zinc-200 transition-colors"
        >
          Continue
          <ChevronRight size={16} />
        </button>
        <button
          onClick={() => { setNotes(''); proceedFromNotes(); }}
          className="w-full py-2.5 rounded-xl text-zinc-500 hover:text-zinc-300 text-sm transition-colors"
        >
          Skip — add without notes
        </button>
      </div>
    </div>
  );

  // ─── Render: Compare ──────────────────────────────────────────────────────
  const renderCompareStep = () => {
    const tierItems = getTierItems(selectedTier!);
    const mid = Math.floor((compLow + compHigh) / 2);
    const pivotItem = tierItems[mid];
    const totalRounds = Math.ceil(Math.log2(tierItems.length + 1));
    const currentRound = compHistory.length + 1;

    return (
      <div className="flex flex-col gap-5 animate-fade-in">
        {/* Progress */}
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
                  i < compHistory.length ? 'bg-indigo-500' : i === compHistory.length ? 'bg-zinc-500' : 'bg-zinc-800'
                }`}
              />
            ))}
          </div>
        </div>

        <h3 className="text-center text-lg font-bold text-white">Which do you prefer?</h3>

        {/* Head-to-head */}
        <div className="flex items-stretch gap-3">
          {/* New item */}
          <button
            onClick={() => handleCompareChoice('new')}
            className="flex-1 flex flex-col items-center gap-3 p-3 rounded-2xl border-2 border-zinc-700 hover:border-indigo-500 hover:bg-indigo-500/5 transition-all group active:scale-[0.97]"
          >
            <img
              src={selectedItem?.posterUrl}
              alt={selectedItem?.title}
              className="w-full aspect-[2/3] object-cover rounded-xl shadow-lg"
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

          {/* Pivot item */}
          <button
            onClick={() => handleCompareChoice('existing')}
            className="flex-1 flex flex-col items-center gap-3 p-3 rounded-2xl border-2 border-zinc-700 hover:border-zinc-400 hover:bg-zinc-400/5 transition-all group active:scale-[0.97]"
          >
            <img
              src={pivotItem?.posterUrl}
              alt={pivotItem?.title}
              className="w-full aspect-[2/3] object-cover rounded-xl shadow-lg"
            />
            <div className="text-center">
              <p className="font-bold text-white text-sm leading-tight">{pivotItem?.title}</p>
              <p className="text-xs text-zinc-500 mt-0.5">{pivotItem?.year}</p>
              <span className={`inline-block mt-2 text-xs font-semibold px-2 py-0.5 rounded-full border ${TIER_COLORS[selectedTier!]}`}>
                {selectedTier} · #{mid + 1}
              </span>
            </div>
          </button>
        </div>

        {/* Actions */}
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

  const getStepTitle = () => {
    switch (step) {
      case 'search':  return 'Add to Marquee';
      case 'tier':    return 'Assign Tier';
      case 'notes':   return 'Add a Note';
      case 'compare': return 'Head-to-Head';
    }
  };

  const handleBack = () => {
    if (step === 'compare') setStep('notes');
    else if (step === 'notes') setStep('tier');
    else if (step === 'tier') setStep('search');
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm">
      <div className="bg-zinc-950 border border-zinc-800 w-full max-w-lg rounded-2xl shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">
        {/* Header */}
        <div className="flex items-center justify-between p-5 border-b border-zinc-800 bg-zinc-900/50 flex-shrink-0">
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
        <div className="p-5 overflow-y-auto flex-1">
          {step === 'search'  && renderSearchStep()}
          {step === 'tier'    && renderTierStep()}
          {step === 'notes'   && renderNotesStep()}
          {step === 'compare' && renderCompareStep()}
        </div>
      </div>
    </div>
  );
};
