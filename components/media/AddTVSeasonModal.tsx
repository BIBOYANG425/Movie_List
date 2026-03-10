import React, { useState, useEffect, useRef } from 'react';
import { X, Search, ArrowLeft, Loader2, Tv, Check, ChevronRight, Bookmark, RefreshCw } from 'lucide-react';
import { RankedItem, Tier, Bracket, WatchlistItem, ComparisonLogEntry, ComparisonRequest } from '../../types';
import { TIER_SCORE_RANGES } from '../../constants';
import {
  searchTVShows, getTVShowDetails, normalizeTVGenres, getTVShowGlobalScore,
  buildTVTasteProfile, getSmartTVSuggestions, getSmartTVBackfill, hasTmdbKey,
  TMDBTVShow, TMDBTVSeasonSummary,
} from '../../services/tmdbService';
import { fuzzyFilterLocal, getBestCorrectedQuery } from '../../services/fuzzySearch';
import { classifyBracket, computeSeedIndex, computeTierScore } from '../../services/rankingAlgorithm';
import { SpoolRankingEngine } from '../../services/spoolRankingEngine';
import { computePredictionSignals } from '../../services/spoolPrediction';
import { useAuth } from '../../contexts/AuthContext';
import { useTranslation } from '../../contexts/LanguageContext';
import { TierPicker } from '../shared/TierPicker';
import { NotesStep } from '../shared/NotesStep';
import { ComparisonStep } from '../shared/ComparisonStep';
import { SkeletonList } from '../shared/SkeletonCard';

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
  watchlistIds,
  onCompare,
  preselectedItem,
}) => {
  const { user } = useAuth();
  const { t } = useTranslation();
  const [step, setStep] = useState<Step>('search');
  const [searchTerm, setSearchTerm] = useState('');
  const [isSearching, setIsSearching] = useState(false);
  const [searchResults, setSearchResults] = useState<TMDBTVShow[]>([]);
  const [selectedShow, setSelectedShow] = useState<TMDBTVShow | null>(null);
  const [showLoading, setShowLoading] = useState(false);
  const [selectedItem, setSelectedItem] = useState<RankedItem | null>(null);
  const [selectedTier, setSelectedTier] = useState<Tier | null>(null);
  const [notes, setNotes] = useState('');
  const [correctedQuery, setCorrectedQuery] = useState<string | null>(null);
  const [currentComparison, setCurrentComparison] = useState<ComparisonRequest | null>(null);
  const [sessionId, setSessionId] = useState(() => crypto.randomUUID());

  // Suggestion state
  const [suggestions, setSuggestions] = useState<TMDBTVShow[]>([]);
  const [suggestionsLoading, setSuggestionsLoading] = useState(false);
  const [hasBackfillMixed, setHasBackfillMixed] = useState(false);
  const suggestionPageRef = useRef(1);
  const backfillPoolRef = useRef<TMDBTVShow[]>([]);
  const backfillPageRef = useRef(1);

  const searchTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const searchRequestIdRef = useRef(0);
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

  // Show-level IDs extracted from ranked seasons for suggestion filtering
  const rankedShowIds = new Set(
    currentItems
      .filter(i => i.type === 'tv_season')
      .map(i => { const m = i.id.match(/^tv_(\d+)_s\d+$/); return m ? `tv_${m[1]}` : null; })
      .filter(Boolean) as string[]
  );

  // Extract show-level IDs from season-level watchlist entries
  // e.g. tv_1399_s1 → tv_1399, so suggestions for that show are filtered out
  const watchlistShowIds = new Set<string>(
    [...(watchlistIds ?? [])].flatMap(id => {
      const m = id.match(/^tv_(\d+)_s\d+$/);
      return m ? [`tv_${m[1]}`, id] : [id];
    })
  );

  const getExcludeIds = () => new Set<string>([
    ...rankedIds,
    ...rankedShowIds,
    ...watchlistShowIds,
  ]);

  const getExcludeTitles = () => new Set<string>(
    currentItems.filter(i => i.type === 'tv_season').map(i => i.title.toLowerCase()),
  );

  const isAlreadyOwned = (s: TMDBTVShow) =>
    rankedShowIds.has(s.id) || watchlistShowIds.has(s.id);

  const prefetchBackfillPool = (excludeIds: Set<string>, excludeTitles: Set<string>, page?: number) => {
    const profile = buildTVTasteProfile(currentItems.filter(i => i.type === 'tv_season'));
    getSmartTVBackfill(profile, excludeIds, page ?? backfillPageRef.current, excludeTitles).then((results) => {
      backfillPoolRef.current = results;
    });
  };

  const consumeSuggestion = (showId: string) => {
    setSuggestions(prev => {
      const without = prev.filter(s => s.id !== showId);
      if (backfillPoolRef.current.length > 0) {
        const existingIds = new Set(without.map(s => s.id));
        let fill: TMDBTVShow | undefined;
        while (backfillPoolRef.current.length > 0) {
          const candidate = backfillPoolRef.current.shift()!;
          if (!existingIds.has(candidate.id)) {
            fill = candidate;
            break;
          }
        }
        if (fill) {
          setHasBackfillMixed(true);
          without.push(fill);
        }
        if (backfillPoolRef.current.length < 3) {
          backfillPageRef.current += 1;
          prefetchBackfillPool(getExcludeIds(), getExcludeTitles(), backfillPageRef.current);
        }
      }
      return without;
    });
  };

  const loadInitialTVSuggestions = (page: number) => {
    if (!hasTmdbKey()) return;
    setSuggestionsLoading(true);
    setHasBackfillMixed(false);

    const excludeIds = getExcludeIds();
    const excludeTitles = getExcludeTitles();
    const profile = buildTVTasteProfile(currentItems.filter(i => i.type === 'tv_season'));

    getSmartTVSuggestions(profile, excludeIds, page, excludeTitles, user?.id ?? undefined).then((results) => {
      setSuggestions(results);
      setSuggestionsLoading(false);
    });

    backfillPageRef.current = 1;
    backfillPoolRef.current = [];
    getSmartTVBackfill(profile, excludeIds, 1, excludeTitles).then((results) => {
      backfillPoolRef.current = results;
    });
  };

  const handleRefreshSuggestions = () => {
    suggestionPageRef.current += 1;
    loadInitialTVSuggestions(suggestionPageRef.current);
  };

  const handleSelectSuggestion = (show: TMDBTVShow) => {
    consumeSuggestion(show.id);
    handleSelectShow(show);
  };

  const handleBookmarkSuggestion = (show: TMDBTVShow) => {
    if (!onSaveForLater) return;
    consumeSuggestion(show.id);
    const watchItem: WatchlistItem = {
      id: show.id,
      title: show.name,
      year: show.year,
      posterUrl: show.posterUrl ?? '',
      type: 'tv_season',
      genres: normalizeTVGenres(show.genres),
      showTmdbId: show.tmdbId,
      addedAt: new Date().toISOString(),
    };
    onSaveForLater(watchItem);
  };

  const filteredSuggestions = suggestions.filter(s => !isAlreadyOwned(s));

  // ─── Reset on open ────────────────────────────────────────────────────────
  useEffect(() => {
    if (!isOpen) return;

    let cancelled = false;

    searchRequestIdRef.current += 1;
    setSearchTerm('');
    setSearchResults([]);
    setSelectedShow(null);
    setSelectedTier(null);
    setNotes('');
    setCorrectedQuery(null);
    setIsSearching(false);
    setCurrentComparison(null);
    setSessionId(crypto.randomUUID());
    engineRef.current = null;
    smallTierRef.current = null;

    if (preselectedItem && preselectedItem.showTmdbId && !preselectedItem.seasonNumber) {
      // Show-level bookmark — send user through season selection first.
      setSelectedItem(null);
      setShowLoading(true);
      setStep('search');
      void getTVShowDetails(preselectedItem.showTmdbId).then((details) => {
        if (cancelled || !details) { setShowLoading(false); return; }
        setSelectedShow(details);
        setShowLoading(false);
        setStep('show_detail');
      });
    } else if (preselectedItem) {
      // Full season bookmark — go directly to tier selection.
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

    // Load suggestions
    suggestionPageRef.current = 1;
    loadInitialTVSuggestions(1);

    return () => {
      cancelled = true;
    };
  }, [isOpen, preselectedItem]);

  // ─── Search ───────────────────────────────────────────────────────────────
  useEffect(() => {
    if (searchTimeoutRef.current) clearTimeout(searchTimeoutRef.current);
    const requestId = ++searchRequestIdRef.current;

    if (!searchTerm.trim()) {
      setSearchResults([]);
      setCorrectedQuery(null);
      setIsSearching(false);
      return;
    }

    setIsSearching(true);

    searchTimeoutRef.current = setTimeout(async () => {
      const query = searchTerm.trim();
      const tmdbResults = await searchTVShows(query);

      // Stale check
      if (requestId !== searchRequestIdRef.current) return;

      // Fuzzy-match against local pools
      const localPool = [...suggestions, ...backfillPoolRef.current];
      const fuzzyMatches = fuzzyFilterLocal(query, localPool, s => s.name);

      // Dedup by tmdbId
      const byKey = new Map<string, TMDBTVShow>();
      for (const show of [...tmdbResults, ...fuzzyMatches]) {
        const key = `tmdb:${show.tmdbId}`;
        if (!byKey.has(key)) byKey.set(key, show);
      }
      let merged = Array.from(byKey.values()).slice(0, 12);

      let corrected: string | null = null;

      // If TMDB returned few results, try a corrected query
      if (tmdbResults.length < 3) {
        const titleDict = [
          ...currentItems.filter(i => i.type === 'tv_season').map(i => i.title),
          ...suggestions.map(s => s.name),
          ...backfillPoolRef.current.map(s => s.name),
        ];
        const bestMatch = getBestCorrectedQuery(query, titleDict);
        if (bestMatch && bestMatch.toLowerCase() !== query.toLowerCase()) {
          corrected = bestMatch;
          const correctedResults = await searchTVShows(bestMatch);
          // Stale check again after second await
          if (requestId !== searchRequestIdRef.current) return;
          for (const show of correctedResults) {
            const key = `tmdb:${show.tmdbId}`;
            if (!byKey.has(key)) byKey.set(key, show);
          }
          merged = Array.from(byKey.values()).slice(0, 12);
        }
      }

      setCorrectedQuery(corrected);
      setSearchResults(merged);
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
      case 'search': return t('tv.addSeason');
      case 'show_detail': return selectedShow?.name ?? t('tv.selectSeason');
      case 'tier': return t('tv.assignTier');
      case 'notes': return t('tv.addNote');
      case 'compare': return t('tv.headToHead');
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
      <div className="bg-background border border-border w-full max-w-lg rounded-2xl shadow-2xl overflow-hidden flex flex-col max-h-[90vh]">
        {/* Header */}
        <div className="flex items-center justify-between p-5 border-b border-border bg-card/30 flex-shrink-0">
          <div className="flex items-center gap-3">
            {step !== 'search' && (
              <button onClick={handleBack} className="text-muted-foreground hover:text-foreground transition-colors">
                <ArrowLeft size={20} />
              </button>
            )}
            <h2 className="text-xl font-bold text-foreground truncate">{getStepTitle()}</h2>
          </div>
          <button onClick={onClose} className="text-muted-foreground hover:text-foreground transition-colors">
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
                  placeholder={t('tv.searchShows')}
                  className="w-full bg-card border border-border rounded-xl py-3 pl-10 pr-4 text-foreground placeholder-muted-foreground focus:outline-none focus:border-gold transition-colors"
                  value={searchTerm}
                  onChange={(e) => setSearchTerm(e.target.value)}
                />
                {isSearching && (
                  <Loader2 className="absolute right-3 top-3.5 text-muted animate-spin" size={18} />
                )}
              </div>

              {/* Corrected query hint */}
              {correctedQuery && !isSearching && (
                <p className="text-xs text-muted-foreground italic px-1">
                  Showing results for <span className="font-semibold text-accent">"{correctedQuery}"</span>
                </p>
              )}

              {showLoading && (
                <div className="flex items-center justify-center py-8">
                  <Loader2 className="w-5 h-5 text-purple-500 animate-spin" />
                </div>
              )}

              {isSearching && (
                <div className="space-y-2">
                  {[1, 2, 3].map(i => (
                    <div key={i} className="flex items-center gap-3 p-2 rounded-lg animate-pulse">
                      <div className="w-12 h-16 bg-secondary rounded flex-shrink-0" />
                      <div className="flex-1 space-y-2">
                        <div className="h-3 bg-secondary rounded w-3/4" />
                        <div className="h-2 bg-secondary rounded w-1/2" />
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
                      className="flex items-center gap-3 p-2.5 rounded-xl hover:bg-secondary transition-colors w-full text-left group"
                    >
                      {show.posterUrl ? (
                        <img src={show.posterUrl} alt={show.name} className="w-12 h-[72px] object-cover rounded-lg bg-secondary shadow-md flex-shrink-0" />
                      ) : (
                        <div className="w-12 h-[72px] bg-secondary rounded-lg flex items-center justify-center flex-shrink-0">
                          <Tv size={20} className="text-muted-foreground/60" />
                        </div>
                      )}
                      <div className="flex-1 min-w-0">
                        <p className="font-semibold text-foreground group-hover:text-purple-400 transition-colors truncate">{show.name}</p>
                        <p className="text-xs text-muted-foreground mt-0.5">{show.year}</p>
                        {show.genres.length > 0 && (
                          <div className="flex gap-1 mt-1.5 flex-wrap">
                            {show.genres.map(g => (
                              <span key={g} className="text-[10px] px-1.5 py-0.5 bg-secondary text-muted-foreground rounded-full border border-border">{g}</span>
                            ))}
                          </div>
                        )}
                      </div>
                      <ChevronRight size={14} className="text-muted-foreground/60 flex-shrink-0" />
                    </button>
                  ))}
                </div>
              )}

              {!isSearching && searchTerm.trim() && searchResults.length === 0 && (
                <div className="text-center py-12 text-muted-foreground text-sm">
                  <Tv size={32} className="mx-auto mb-3 opacity-30" />
                  <p>No results for "{searchTerm}"</p>
                  <p className="text-xs mt-1 opacity-60">Try a different show title</p>
                </div>
              )}

              {!isSearching && !searchTerm.trim() && (
                <>
                  {suggestionsLoading && (
                    <div className="grid grid-cols-3 gap-3">
                      <SkeletonList count={6} variant="suggestion" />
                    </div>
                  )}
                  {!suggestionsLoading && filteredSuggestions.length > 0 ? (
                    <div>
                      <div className="flex items-center justify-between mb-3 px-1">
                        <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">
                          {hasBackfillMixed ? 'Based on your taste' : 'Popular right now'}
                        </p>
                        <button
                          onClick={handleRefreshSuggestions}
                          className="flex items-center gap-1 text-[10px] font-semibold text-muted-foreground/60 hover:text-muted-foreground transition-colors px-2 py-1 rounded-lg hover:bg-secondary"
                          title="Show different suggestions"
                        >
                          <RefreshCw size={11} />
                          Refresh
                        </button>
                      </div>
                      <div className="grid grid-cols-3 gap-2">
                        {filteredSuggestions.map((show) => (
                          <div key={show.id} className="relative group">
                            <button
                              onClick={() => handleSelectSuggestion(show)}
                              className="flex flex-col items-center text-center rounded-xl hover:bg-secondary/60 p-2 transition-colors w-full"
                            >
                              <img
                                src={show.posterUrl!}
                                alt={show.name}
                                className="w-full aspect-[2/3] object-cover rounded-lg bg-secondary shadow-md group-hover:shadow-lg hover:scale-105 transition-all mb-1.5"
                              />
                              <p className="text-xs font-medium text-muted-foreground leading-tight line-clamp-2 hover:text-purple-400 transition-colors w-full text-left">
                                {show.name}
                              </p>
                              <p className="text-[10px] text-muted-foreground/60 w-full text-left">{show.year}</p>
                            </button>
                            {onSaveForLater && (
                              <button
                                onClick={(e) => { e.stopPropagation(); handleBookmarkSuggestion(show); }}
                                title="Save for later"
                                className="absolute top-3 right-3 p-1.5 rounded-full transition-all shadow-md bg-black/60 text-muted-foreground border border-border opacity-0 group-hover:opacity-100 hover:text-purple-400 hover:bg-purple-500/20"
                              >
                                <Bookmark size={12} />
                              </button>
                            )}
                          </div>
                        ))}
                      </div>
                    </div>
                  ) : !suggestionsLoading ? (
                    <div className="text-center py-12 text-muted-foreground/60 text-sm">
                      <Search size={32} className="mx-auto mb-3 opacity-30" />
                      <p>Type a TV show title to search</p>
                    </div>
                  ) : null}
                </>
              )}
            </div>
          )}

          {/* ─── Show Detail / Season Picker Step ───────────────────────── */}
          {step === 'show_detail' && selectedShow && (
            <div className="space-y-4 animate-fade-in">
              {/* Show info */}
              <div className="flex items-start gap-4 bg-secondary p-4 rounded-xl border border-border">
                {selectedShow.posterUrl ? (
                  <img src={selectedShow.posterUrl} alt="" className="w-20 h-[120px] object-cover rounded-lg shadow-lg flex-shrink-0" />
                ) : (
                  <div className="w-20 h-[120px] bg-card rounded-lg flex items-center justify-center flex-shrink-0">
                    <Tv size={24} className="text-muted" />
                  </div>
                )}
                <div className="flex-1 min-w-0">
                  <h3 className="font-serif text-lg leading-tight text-foreground">{selectedShow.name}</h3>
                  <p className="text-muted-foreground text-sm mt-0.5">{selectedShow.year} · {selectedShow.status}</p>
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
                <p className="text-[11px] text-muted-foreground leading-relaxed line-clamp-3">{selectedShow.overview}</p>
              )}

              {/* Season grid */}
              <div>
                <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider mb-3">
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
                            className="w-full aspect-[2/3] object-cover rounded-lg bg-secondary shadow-md mb-1.5"
                          />
                        ) : selectedShow.posterUrl ? (
                          <img
                            src={selectedShow.posterUrl}
                            alt={season.name}
                            className="w-full aspect-[2/3] object-cover rounded-lg bg-secondary shadow-md mb-1.5 opacity-60"
                          />
                        ) : (
                          <div className="w-full aspect-[2/3] bg-secondary rounded-lg flex items-center justify-center mb-1.5">
                            <Tv size={20} className="text-muted-foreground/60" />
                          </div>
                        )}

                        {isRanked && (
                          <div className="absolute top-3 right-3 w-5 h-5 bg-green-500 rounded-full flex items-center justify-center">
                            <Check size={12} className="text-foreground" />
                          </div>
                        )}

                        {!isRanked && onSaveForLater && (
                          <div
                            className="absolute top-2 left-2 p-1 rounded-full bg-black/50 text-muted-foreground hover:text-gold hover:bg-black/70 transition-colors z-10"
                            onClick={(e) => { e.stopPropagation(); handleSaveSeasonForLater(season); }}
                            title="Save for later"
                          >
                            <Bookmark size={12} />
                          </div>
                        )}

                        <p className="text-[11px] font-medium text-muted-foreground leading-tight line-clamp-1">{season.name}</p>
                        <p className="text-[10px] text-muted-foreground/60 mt-0.5">
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
