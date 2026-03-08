import React, { useState, useEffect, useRef } from 'react';
import { X, Search, ArrowLeft, Loader2, Tv, Check, ChevronRight, Bookmark } from 'lucide-react';
import { RankedItem, Tier, Bracket, WatchlistItem, ComparisonLogEntry, ComparisonRequest } from '../types';
import { TIER_SCORE_RANGES } from '../constants';
import {
  searchTVShows, getTVShowDetails, normalizeTVGenres, getTVShowGlobalScore,
  TMDBTVShow, TMDBTVSeasonSummary,
} from '../services/tmdbService';
import { classifyBracket, computeSeedIndex, computeTierScore } from '../services/rankingAlgorithm';
import { SpoolRankingEngine } from '../services/spoolRankingEngine';
import { computePredictionSignals } from '../services/spoolPrediction';
import { TierPicker } from './shared/TierPicker';
import { NotesStep } from './shared/NotesStep';
import { ComparisonStep } from './shared/ComparisonStep';

interface AddTVSeasonModalProps {
  isOpen: boolean;
  onClose: () => void;
  onAdd: (item: RankedItem) => void;
  onSaveForLater?: (item: WatchlistItem) => void;
  currentItems: RankedItem[];
  watchlistIds?: Set<string>;
  onCompare?: (log: ComparisonLogEntry) => void;
  preselectedItem?: RankedItem | null;
}

type Step = 'search' | 'show_detail' | 'tier' | 'notes' | 'compare';

export const AddTVSeasonModal: React.FC<AddTVSeasonModalProps> = ({
  isOpen,
  onClose,
  onAdd,
  onSaveForLater,
  currentItems,
  onCompare,
  preselectedItem,
}) => {
  const [step, setStep] = useState<Step>('search');
  const [searchTerm, setSearchTerm] = useState('');
  const [isSearching, setIsSearching] = useState(false);
  const [searchResults, setSearchResults] = useState<TMDBTVShow[]>([]);
  const [selectedShow, setSelectedShow] = useState<TMDBTVShow | null>(null);
  const [showLoading, setShowLoading] = useState(false);
  const [selectedItem, setSelectedItem] = useState<RankedItem | null>(null);
  const [selectedTier, setSelectedTier] = useState<Tier | null>(null);
  const [notes, setNotes] = useState('');
  const [currentComparison, setCurrentComparison] = useState<ComparisonRequest | null>(null);
  const [sessionId, setSessionId] = useState(() => crypto.randomUUID());

  const searchTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const engineRef = useRef<SpoolRankingEngine | null>(null);
  const smallTierRef = useRef<{
    mode: 'compare_all' | 'seed' | 'quartile';
    tierItems: RankedItem[];
    low: number;
    high: number;
    mid: number;
    round: number;
    seedIdx: number;
  } | null>(null);
  const isProcessingRef = useRef(false);

  // Already ranked TV season IDs
  const rankedIds = new Set(currentItems.filter(i => i.type === 'tv_season').map(i => i.id));

  // ─── Reset on open ────────────────────────────────────────────────────────
  useEffect(() => {
    if (!isOpen) return;

    let cancelled = false;

    setSearchTerm('');
    setSearchResults([]);
    setSelectedShow(null);
    setSelectedTier(null);
    setNotes('');
    setCurrentComparison(null);
    setSessionId(crypto.randomUUID());
    engineRef.current = null;
    smallTierRef.current = null;

    if (preselectedItem) {
      // Skip search/show_detail — go directly to tier selection.
      setSelectedItem(preselectedItem);
      setStep('tier');

      if (preselectedItem.showTmdbId) {
        void getTVShowGlobalScore(preselectedItem.showTmdbId).then((globalScore) => {
          if (cancelled || globalScore === undefined) return;
          setSelectedItem((prev) => (
            prev && prev.id === preselectedItem.id ? { ...prev, globalScore } : prev
          ));
        });
      }
    } else {
      setSelectedItem(null);
      setStep('search');
    }

    return () => {
      cancelled = true;
    };
  }, [isOpen, preselectedItem]);

  // ─── Search ───────────────────────────────────────────────────────────────
  useEffect(() => {
    if (searchTimeoutRef.current) clearTimeout(searchTimeoutRef.current);
    if (!searchTerm.trim()) {
      setSearchResults([]);
      return;
    }

    setIsSearching(true);
    searchTimeoutRef.current = setTimeout(async () => {
      const results = await searchTVShows(searchTerm);
      setSearchResults(results);
      setIsSearching(false);
    }, 350);

    return () => {
      if (searchTimeoutRef.current) clearTimeout(searchTimeoutRef.current);
    };
  }, [searchTerm]);

  // ─── Show selection ───────────────────────────────────────────────────────
  const handleSelectShow = async (show: TMDBTVShow) => {
    setShowLoading(true);
    const details = await getTVShowDetails(show.tmdbId);
    if (details) {
      setSelectedShow(details);
      setStep('show_detail');
    }
    setShowLoading(false);
  };

  // ─── Season selection → RankedItem conversion ─────────────────────────────
  const handleSelectSeason = async (season: TMDBTVSeasonSummary) => {
    if (!selectedShow) return;

    const normalizedGenres = normalizeTVGenres(selectedShow.genres);
    const globalScore = await getTVShowGlobalScore(selectedShow.tmdbId);

    const item: RankedItem = {
      id: `tv_${selectedShow.tmdbId}_s${season.seasonNumber}`,
      title: selectedShow.name,
      year: season.airDate ? season.airDate.slice(0, 4) : selectedShow.year,
      posterUrl: season.posterUrl ?? selectedShow.posterUrl ?? '',
      type: 'tv_season',
      genres: normalizedGenres,
      creator: selectedShow.creators[0],
      showTmdbId: selectedShow.tmdbId,
      seasonNumber: season.seasonNumber,
      seasonTitle: season.name,
      episodeCount: season.episodeCount,
      bracket: classifyBracket(normalizedGenres),
      globalScore,
      tier: Tier.B, // placeholder
      rank: 0,
    };

    setSelectedItem(item);
    setStep('tier');
  };

  // ─── Save season for later ───────────────────────────────────────────────
  const handleSaveSeasonForLater = (season: TMDBTVSeasonSummary) => {
    if (!selectedShow || !onSaveForLater) return;

    const watchItem: WatchlistItem = {
      id: `tv_${selectedShow.tmdbId}_s${season.seasonNumber}`,
      title: selectedShow.name,
      year: season.airDate ? season.airDate.slice(0, 4) : selectedShow.year,
      posterUrl: season.posterUrl ?? selectedShow.posterUrl ?? '',
      type: 'tv_season',
      genres: normalizeTVGenres(selectedShow.genres),
      creator: selectedShow.creators[0],
      showTmdbId: selectedShow.tmdbId,
      seasonNumber: season.seasonNumber,
      seasonTitle: season.name,
      episodeCount: season.episodeCount,
      addedAt: new Date().toISOString(),
    };

    onSaveForLater(watchItem);
    onClose();
  };

  // ─── Tier selection ───────────────────────────────────────────────────────
  const handleSelectTier = (tier: Tier) => {
    setSelectedTier(tier);
    setStep('notes');
  };

  // ─── Get tier items (TV only) ─────────────────────────────────────────────
  const getTierItems = (tier: Tier) =>
    currentItems.filter(i => i.tier === tier && i.type === 'tv_season').sort((a, b) => a.rank - b.rank);

  // ─── Proceed from notes → compare or done ─────────────────────────────────
  const proceedFromNotes = () => {
    const tierItems = getTierItems(selectedTier!);
    const item = selectedItem!;

    if (tierItems.length === 0) {
      onAdd({ ...item, tier: selectedTier!, rank: 0, notes: notes.trim() || undefined });
      onClose();
    } else if (tierItems.length <= 5) {
      smallTierRef.current = { mode: 'compare_all', tierItems, low: 0, high: tierItems.length, mid: 0, round: 1, seedIdx: 0 };
      engineRef.current = null;
      setCurrentComparison({ movieA: item, movieB: tierItems[0], question: 'Which do you prefer?', round: 1, phase: 'binary_search' });
      setStep('compare');
    } else if (tierItems.length <= 20) {
      const range = TIER_SCORE_RANGES[selectedTier!];
      const tierScores = tierItems.map((_, idx) => computeTierScore(idx, tierItems.length, range.min, range.max));
      const seedIdx = computeSeedIndex(tierScores, range.min, range.max, item.globalScore);
      smallTierRef.current = { mode: 'seed', tierItems, low: 0, high: tierItems.length, mid: seedIdx, round: 1, seedIdx };
      engineRef.current = null;
      setCurrentComparison({ movieA: item, movieB: tierItems[seedIdx], question: 'Which do you prefer?', round: 1, phase: 'binary_search' });
      setStep('compare');
    } else {
      const engine = new SpoolRankingEngine();
      const signals = computePredictionSignals(
        currentItems.filter(i => i.type === 'tv_season'),
        item.genres[0] ?? '',
        item.bracket ?? classifyBracket(item.genres),
        item.globalScore,
        selectedTier!,
      );
      const result = engine.start(item, selectedTier!, currentItems.filter(i => i.type === 'tv_season'), signals);
      engineRef.current = engine;

      if (result.type === 'done') {
        handleInsertAt(result.finalRank!);
      } else {
        setCurrentComparison(result.comparison!);
        setStep('compare');
      }
    }
  };

  const handleInsertAt = (rankIndex: number) => {
    if (selectedItem && selectedTier) {
      onAdd({
        ...selectedItem,
        tier: selectedTier,
        rank: rankIndex,
        notes: notes.trim() || undefined,
      });
      onClose();
    }
  };

  // ─── Compare logic (identical to movie flow) ──────────────────────────────
  const handleCompareChoice = (choice: 'new' | 'existing' | 'too_tough' | 'skip') => {
    if (!currentComparison) return;
    if (!engineRef.current && !smallTierRef.current) return;
    if (isProcessingRef.current) return;
    isProcessingRef.current = true;

    try {
      if (onCompare && selectedItem && selectedTier) {
        onCompare({
          sessionId,
          movieAId: currentComparison.movieA.id,
          movieBId: currentComparison.movieB.id,
          winner: choice === 'new' ? 'a' : choice === 'existing' ? 'b' : 'skip',
          round: currentComparison.round,
          phase: currentComparison.phase,
          questionText: currentComparison.question,
        });
      }

      if (smallTierRef.current) {
        const st = smallTierRef.current;
        const movieA = currentComparison.movieA;

        if (choice === 'too_tough' || choice === 'skip') {
          smallTierRef.current = null;
          handleInsertAt(st.mid);
          return;
        }

        const pick = choice === 'new' ? 'new' as const : 'existing' as const;
        const nextRound = st.round + 1;
        const setNext = (mid: number, mode?: typeof st.mode, low?: number, high?: number) => {
          smallTierRef.current = { ...st, mode: mode ?? st.mode, low: low ?? st.low, high: high ?? st.high, mid, round: nextRound };
          setCurrentComparison({ movieA, movieB: st.tierItems[mid], question: 'Which do you prefer?', round: nextRound, phase: 'binary_search' });
        };
        const done = (rank: number) => { smallTierRef.current = null; handleInsertAt(rank); };

        if (st.mode === 'compare_all') {
          if (pick === 'new') { done(st.mid); }
          else if (st.mid + 1 >= st.tierItems.length) { done(st.tierItems.length); }
          else { setNext(st.mid + 1); }
        } else if (st.mode === 'seed') {
          if (pick === 'new') {
            if (st.mid === 0) { done(0); }
            else { setNext(0, 'quartile', 0, st.mid); }
          } else {
            const newLow = st.mid + 1;
            if (newLow >= st.tierItems.length) { done(st.tierItems.length); }
            else {
              const newHigh = st.tierItems.length;
              const nextMid = Math.min(newLow + Math.floor((newHigh - newLow) * 0.75), newHigh - 1);
              setNext(nextMid, 'quartile', newLow, newHigh);
            }
          }
        } else {
          const newLow = pick === 'new' ? st.low : st.mid + 1;
          const newHigh = pick === 'new' ? st.mid : st.high;
          if (newLow >= newHigh) { done(newLow); }
          else {
            const ratio = pick === 'new' ? 0.25 : 0.75;
            const nextMid = Math.max(newLow, Math.min(newLow + Math.floor((newHigh - newLow) * ratio), newHigh - 1));
            setNext(nextMid, 'quartile', newLow, newHigh);
          }
        }
        return;
      }

      if (!engineRef.current) return;

      if (choice === 'too_tough' || choice === 'skip') {
        const result = engineRef.current.skip();
        handleInsertAt(result.finalRank!);
        return;
      }

      const winnerId = choice === 'new' ? selectedItem!.id : currentComparison.movieB.id;
      const result = engineRef.current.submitChoice(winnerId);

      if (result.type === 'done') {
        handleInsertAt(result.finalRank!);
      } else {
        setCurrentComparison(result.comparison!);
      }
    } finally {
      isProcessingRef.current = false;
    }
  };

  const handleUndo = () => {
    if (!engineRef.current) return;
    const result = engineRef.current.undo();
    if (result && result.comparison) {
      setCurrentComparison(result.comparison);
    }
  };

  // ─── Step titles ──────────────────────────────────────────────────────────
  const getStepTitle = () => {
    switch (step) {
      case 'search': return 'Add TV Season';
      case 'show_detail': return selectedShow?.name ?? 'Select Season';
      case 'tier': return 'Assign Tier';
      case 'notes': return 'Add a Note';
      case 'compare': return 'Head-to-Head';
    }
  };

  const handleBack = () => {
    if (step === 'compare') setStep('notes');
    else if (step === 'notes') setStep('tier');
    else if (step === 'tier') setStep(selectedShow ? 'show_detail' : 'search');
    else if (step === 'show_detail') { setSelectedShow(null); setStep('search'); }
  };

  if (!isOpen) return null;

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
            <h2 className="text-xl font-bold text-white truncate">{getStepTitle()}</h2>
          </div>
          <button onClick={onClose} className="text-zinc-400 hover:text-white transition-colors">
            <X size={24} />
          </button>
        </div>

        {/* Content */}
        <div className="p-5 overflow-y-auto flex-1">
          {/* ─── Search Step ────────────────────────────────────────────── */}
          {step === 'search' && (
            <div className="space-y-4 animate-fade-in">
              <div className="relative">
                <Search className="absolute left-3 top-3.5 text-muted" size={18} />
                <input
                  type="text"
                  autoFocus
                  placeholder="Search TV shows..."
                  className="w-full bg-card border border-border rounded-xl py-3 pl-10 pr-4 text-white placeholder-zinc-600 focus:outline-none focus:border-purple-500 transition-colors"
                  value={searchTerm}
                  onChange={(e) => setSearchTerm(e.target.value)}
                />
                {isSearching && (
                  <Loader2 className="absolute right-3 top-3.5 text-muted animate-spin" size={18} />
                )}
              </div>

              {showLoading && (
                <div className="flex items-center justify-center py-8">
                  <Loader2 className="w-5 h-5 text-purple-500 animate-spin" />
                </div>
              )}

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

              {!isSearching && !showLoading && searchResults.length > 0 && (
                <div className="space-y-1 max-h-[55vh] overflow-y-auto pr-1">
                  {searchResults.map((show) => (
                    <button
                      key={show.id}
                      onClick={() => handleSelectShow(show)}
                      className="flex items-center gap-3 p-2.5 rounded-xl hover:bg-elevated transition-colors w-full text-left group"
                    >
                      {show.posterUrl ? (
                        <img src={show.posterUrl} alt={show.name} className="w-12 h-[72px] object-cover rounded-lg bg-zinc-800 shadow-md flex-shrink-0" />
                      ) : (
                        <div className="w-12 h-[72px] bg-zinc-800 rounded-lg flex items-center justify-center flex-shrink-0">
                          <Tv size={20} className="text-zinc-600" />
                        </div>
                      )}
                      <div className="flex-1 min-w-0">
                        <p className="font-semibold text-white group-hover:text-purple-400 transition-colors truncate">{show.name}</p>
                        <p className="text-xs text-zinc-500 mt-0.5">{show.year}</p>
                        {show.genres.length > 0 && (
                          <div className="flex gap-1 mt-1.5 flex-wrap">
                            {show.genres.map(g => (
                              <span key={g} className="text-[10px] px-1.5 py-0.5 bg-zinc-800 text-zinc-400 rounded-full border border-zinc-700">{g}</span>
                            ))}
                          </div>
                        )}
                      </div>
                      <ChevronRight size={14} className="text-zinc-600 flex-shrink-0" />
                    </button>
                  ))}
                </div>
              )}

              {!isSearching && searchTerm.trim() && searchResults.length === 0 && (
                <div className="text-center py-12 text-zinc-500 text-sm">
                  <Tv size={32} className="mx-auto mb-3 opacity-30" />
                  <p>No results for "{searchTerm}"</p>
                  <p className="text-xs mt-1 opacity-60">Try a different show title</p>
                </div>
              )}

              {!isSearching && !searchTerm.trim() && (
                <div className="text-center py-12 text-zinc-600 text-sm">
                  <Search size={32} className="mx-auto mb-3 opacity-30" />
                  <p>Type a TV show title to search</p>
                </div>
              )}
            </div>
          )}

          {/* ─── Show Detail / Season Picker Step ───────────────────────── */}
          {step === 'show_detail' && selectedShow && (
            <div className="space-y-4 animate-fade-in">
              {/* Show info */}
              <div className="flex items-start gap-4 bg-elevated p-4 rounded-xl border border-border">
                {selectedShow.posterUrl ? (
                  <img src={selectedShow.posterUrl} alt="" className="w-20 h-[120px] object-cover rounded-lg shadow-lg flex-shrink-0" />
                ) : (
                  <div className="w-20 h-[120px] bg-card rounded-lg flex items-center justify-center flex-shrink-0">
                    <Tv size={24} className="text-muted" />
                  </div>
                )}
                <div className="flex-1 min-w-0">
                  <h3 className="font-serif text-lg leading-tight text-white">{selectedShow.name}</h3>
                  <p className="text-dim text-sm mt-0.5">{selectedShow.year} · {selectedShow.status}</p>
                  {selectedShow.creators.length > 0 && (
                    <p className="text-muted text-xs mt-1">Created by {selectedShow.creators.join(', ')}</p>
                  )}
                  {selectedShow.genres.length > 0 && (
                    <div className="flex gap-1 mt-2 flex-wrap">
                      {selectedShow.genres.map(g => (
                        <span key={g} className="text-[10px] px-1.5 py-0.5 bg-purple-500/10 text-purple-300 rounded-full border border-purple-500/20">{g}</span>
                      ))}
                    </div>
                  )}
                </div>
              </div>

              {selectedShow.overview && (
                <p className="text-[11px] text-zinc-400 leading-relaxed line-clamp-3">{selectedShow.overview}</p>
              )}

              {/* Season grid */}
              <div>
                <p className="text-xs font-semibold text-zinc-500 uppercase tracking-wider mb-3">
                  Select a Season ({selectedShow.seasons?.length ?? 0})
                </p>
                <div className="grid grid-cols-3 gap-2 max-h-[40vh] overflow-y-auto pr-1">
                  {(selectedShow.seasons ?? []).map((season) => {
                    const seasonId = `tv_${selectedShow.tmdbId}_s${season.seasonNumber}`;
                    const isRanked = rankedIds.has(seasonId);

                    return (
                      <button
                        key={season.seasonNumber}
                        onClick={() => !isRanked && handleSelectSeason(season)}
                        disabled={isRanked}
                        className={`relative flex flex-col items-center text-center rounded-xl p-2 transition-all ${
                          isRanked
                            ? 'opacity-50 cursor-not-allowed'
                            : 'hover:bg-purple-500/10 hover:border-purple-500/30 cursor-pointer'
                        } border border-border`}
                      >
                        {season.posterUrl ? (
                          <img
                            src={season.posterUrl}
                            alt={season.name}
                            className="w-full aspect-[2/3] object-cover rounded-lg bg-zinc-800 shadow-md mb-1.5"
                          />
                        ) : selectedShow.posterUrl ? (
                          <img
                            src={selectedShow.posterUrl}
                            alt={season.name}
                            className="w-full aspect-[2/3] object-cover rounded-lg bg-zinc-800 shadow-md mb-1.5 opacity-60"
                          />
                        ) : (
                          <div className="w-full aspect-[2/3] bg-zinc-800 rounded-lg flex items-center justify-center mb-1.5">
                            <Tv size={20} className="text-zinc-600" />
                          </div>
                        )}

                        {isRanked && (
                          <div className="absolute top-3 right-3 w-5 h-5 bg-green-500 rounded-full flex items-center justify-center">
                            <Check size={12} className="text-white" />
                          </div>
                        )}

                        {!isRanked && onSaveForLater && (
                          <div
                            className="absolute top-2 left-2 p-1 rounded-full bg-black/50 text-zinc-400 hover:text-amber-400 hover:bg-black/70 transition-colors z-10"
                            onClick={(e) => { e.stopPropagation(); handleSaveSeasonForLater(season); }}
                            title="Save for later"
                          >
                            <Bookmark size={12} />
                          </div>
                        )}

                        <p className="text-[11px] font-medium text-zinc-300 leading-tight line-clamp-1">{season.name}</p>
                        <p className="text-[10px] text-zinc-600 mt-0.5">
                          {season.episodeCount} ep{season.episodeCount !== 1 ? 's' : ''}
                          {season.airDate ? ` · ${season.airDate.slice(0, 4)}` : ''}
                        </p>
                      </button>
                    );
                  })}
                </div>
              </div>
            </div>
          )}

          {/* ─── Tier Step ──────────────────────────────────────────────── */}
          {step === 'tier' && (
            <TierPicker
              selectedItem={selectedItem}
              currentItems={currentItems.filter(i => i.type === 'tv_season')}
              onSelectTier={handleSelectTier}
              onBracketChange={(b) => setSelectedItem(prev => prev ? { ...prev, bracket: b } : prev)}
            />
          )}

          {/* ─── Notes Step ─────────────────────────────────────────────── */}
          {step === 'notes' && (
            <NotesStep
              selectedItem={selectedItem}
              selectedTier={selectedTier}
              notes={notes}
              onNotesChange={setNotes}
              onContinue={proceedFromNotes}
              onSkip={() => { setNotes(''); proceedFromNotes(); }}
            />
          )}

          {/* ─── Compare Step ───────────────────────────────────────────── */}
          {step === 'compare' && currentComparison && (
            <ComparisonStep
              comparison={currentComparison}
              selectedTier={selectedTier}
              onChoice={handleCompareChoice}
              onUndo={handleUndo}
            />
          )}
        </div>
      </div>
    </div>
  );
};
