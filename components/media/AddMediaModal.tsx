import React, { useState, useEffect, useRef } from 'react';
import FocusTrap from 'focus-trap-react';
import { X, Search, Plus, ArrowLeft, Loader2, Film, ChevronRight, Bookmark, RefreshCw } from 'lucide-react';
import { RankedItem, Tier, Bracket, WatchlistItem, ComparisonLogEntry, ComparisonRequest } from '../../types';
import { TIER_SCORE_RANGES } from '../../constants';
import { searchMovies, searchPeople, getPersonFilmography, getSmartSuggestions, getSmartBackfill, buildTasteProfile, hasTmdbKey, getMovieGlobalScore, TMDBMovie, PersonProfile, PersonDetail } from '../../services/tmdbService';
import { fuzzyFilterLocal, getBestCorrectedQuery, mergeAndDedupSearchResults } from '../../services/fuzzySearch';
import { classifyBracket, computeSeedIndex, computeTierScore } from '../../services/rankingAlgorithm';
import { SpoolRankingEngine } from '../../services/spoolRankingEngine';
import { computePredictionSignals } from '../../services/spoolPrediction';
import { useAuth } from '../../contexts/AuthContext';
import { SkeletonList } from '../shared/SkeletonCard';
import { TierPicker } from '../shared/TierPicker';
import { NotesStep } from '../shared/NotesStep';
import { ComparisonStep } from '../shared/ComparisonStep';

interface AddMediaModalProps {
  isOpen: boolean;
  onClose: () => void;
  onAdd: (item: RankedItem) => void;
  onSaveForLater?: (item: TMDBMovie) => void;
  currentItems: RankedItem[];
  watchlistIds?: Set<string>;
  preselectedItem?: WatchlistItem | RankedItem | TMDBMovie | null;
  preselectedTier?: Tier | null;
  onCompare?: (log: ComparisonLogEntry) => void;
  onMovieInfoClick?: (tmdbId: string) => void;
}

type Step = 'search' | 'tier' | 'notes' | 'compare';

const TMDB_SEARCH_TIMEOUT_MS = 4500;

export const AddMediaModal: React.FC<AddMediaModalProps> = ({ isOpen, onClose, onAdd, onSaveForLater, currentItems, watchlistIds, preselectedItem, preselectedTier, onCompare, onMovieInfoClick }) => {
  const { user } = useAuth();
  const [step, setStep] = useState<Step>('search');
  const [searchTerm, setSearchTerm] = useState('');
  const [searchResults, setSearchResults] = useState<TMDBMovie[]>([]);
  const [directorProfiles, setDirectorProfiles] = useState<PersonProfile[]>([]);
  const [selectedDirector, setSelectedDirector] = useState<PersonDetail | null>(null);
  const [directorLoading, setDirectorLoading] = useState(false);
  const [suggestions, setSuggestions] = useState<TMDBMovie[]>([]);
  const [isSearching, setIsSearching] = useState(false);
  const [suggestionsLoading, setSuggestionsLoading] = useState(false);
  const [selectedItem, setSelectedItem] = useState<RankedItem | null>(null);
  const [selectedTier, setSelectedTier] = useState<Tier | null>(null);
  const [isRatingFetching, setIsRatingFetching] = useState(false);
  const [correctedQuery, setCorrectedQuery] = useState<string | null>(null);

  // Two-pool suggestion system
  const suggestionPageRef = useRef(1);
  const backfillPoolRef = useRef<TMDBMovie[]>([]);
  const backfillPageRef = useRef(1);
  const [hasBackfillMixed, setHasBackfillMixed] = useState(false);

  // Notes state
  const [notes, setNotes] = useState('');
  const [watchedWithUserIds, setWatchedWithUserIds] = useState<string[]>([]);

  // Spool ranking engine state
  const engineRef = useRef<SpoolRankingEngine | null>(null);
  const isProcessingRef = useRef(false);
  const smallTierRef = useRef<{
    mode: 'compare_all' | 'seed' | 'quartile';
    tierItems: RankedItem[];
    low: number; high: number; mid: number;
    round: number; seedIdx: number;
  } | null>(null);
  const [currentComparison, setCurrentComparison] = useState<ComparisonRequest | null>(null);
  const [sessionId, setSessionId] = useState(() => crypto.randomUUID());

  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const searchRequestIdRef = useRef(0);

  const getExcludeIds = () => new Set<string>([
    ...currentItems.map(i => i.id),
    ...(watchlistIds ?? []),
  ]);

  const getExcludeTitles = () => new Set<string>(
    currentItems.map(i => i.title.toLowerCase()),
  );

  const prefetchBackfillPool = (excludeIds: Set<string>, excludeTitles: Set<string>, page?: number) => {
    const profile = buildTasteProfile(currentItems);
    getSmartBackfill(profile, excludeIds, page ?? backfillPageRef.current, excludeTitles).then((results) => {
      backfillPoolRef.current = results;
    }).catch(() => {});
  };

  const consumeSuggestion = (movieId: string) => {
    setSuggestions(prev => {
      const without = prev.filter(m => m.id !== movieId);
      if (backfillPoolRef.current.length > 0) {
        const existingIds = new Set(without.map(m => m.id));
        let fill: TMDBMovie | undefined;
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

  const loadInitialSuggestions = (page: number) => {
    if (!hasTmdbKey()) return;
    setSuggestionsLoading(true);
    setHasBackfillMixed(false);

    const excludeIds = getExcludeIds();
    const excludeTitles = getExcludeTitles();
    const profile = buildTasteProfile(currentItems);

    getSmartSuggestions(profile, excludeIds, page, excludeTitles, user?.id ?? undefined).then((results) => {
      setSuggestions(results);
      setSuggestionsLoading(false);
    }).catch(() => { setSuggestionsLoading(false); });

    backfillPageRef.current = 1;
    backfillPoolRef.current = [];
    getSmartBackfill(profile, excludeIds, 1, excludeTitles).then((results) => {
      backfillPoolRef.current = results;
    }).catch(() => {});
  };

  const handleRefreshSuggestions = () => {
    suggestionPageRef.current += 1;
    loadInitialSuggestions(suggestionPageRef.current);
  };

  // Reset on open/close
  useEffect(() => {
    if (isOpen) {
      searchRequestIdRef.current += 1;
      setSearchTerm('');
      setSearchResults([]);
      setDirectorProfiles([]);
      setSelectedDirector(null);
      setIsSearching(false);
      setSelectedTier(null);
      setNotes('');
      setWatchedWithUserIds([]);
      setCorrectedQuery(null);
      engineRef.current = null;
      setCurrentComparison(null);
      setSessionId(crypto.randomUUID());

      // If a watchlist item was pre-selected, skip to tier step
      if (preselectedItem && !preselectedTier) {
        const existingNotes = 'notes' in preselectedItem ? (preselectedItem as RankedItem).notes : undefined;
        const existingWatchedWith = 'watchedWithUserIds' in preselectedItem ? (preselectedItem as RankedItem).watchedWithUserIds : undefined;
        const asRankedItem: RankedItem = {
          id: preselectedItem.id,
          title: preselectedItem.title,
          year: preselectedItem.year,
          posterUrl: preselectedItem.posterUrl,
          type: 'movie',
          genres: preselectedItem.genres,
          director: 'director' in preselectedItem ? preselectedItem.director : undefined,
          bracket: classifyBracket(preselectedItem.genres),
          tier: Tier.B,
          rank: 0,
          notes: existingNotes,
          watchedWithUserIds: existingWatchedWith,
        };
        setSelectedItem(asRankedItem);
        if (existingNotes) setNotes(existingNotes);
        if (existingWatchedWith?.length) setWatchedWithUserIds(existingWatchedWith);
        setStep('tier');
      } else if (preselectedItem && preselectedTier) {
        // Tier migration
        const asRankedItem = preselectedItem as RankedItem;
        setSelectedItem(asRankedItem);
        if (asRankedItem.notes) setNotes(asRankedItem.notes);
        if (asRankedItem.watchedWithUserIds?.length) setWatchedWithUserIds(asRankedItem.watchedWithUserIds);
        setSelectedTier(preselectedTier);

        const engine = new SpoolRankingEngine();
        const signals = computePredictionSignals(
          currentItems,
          asRankedItem.genres[0] ?? '',
          asRankedItem.bracket ?? classifyBracket(asRankedItem.genres),
          asRankedItem.globalScore,
          preselectedTier,
        );
        const result = engine.start(asRankedItem, preselectedTier, currentItems, signals);
        engineRef.current = engine;

        if (result.type === 'done') {
          onAdd({ ...asRankedItem, tier: preselectedTier, rank: result.finalRank! });
          onClose();
        } else {
          setCurrentComparison(result.comparison!);
          setStep('compare');
        }
      } else {
        setSelectedItem(null);
        setStep('search');
      }

      // Reset page counters and load fresh suggestions + prefetch backfill
      suggestionPageRef.current = 1;
      loadInitialSuggestions(1);
    }
  }, [isOpen, preselectedItem, preselectedTier]);

  // Debounced search — searches TMDB directly.
  useEffect(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);

    const normalizedQuery = searchTerm.trim();
    const requestId = ++searchRequestIdRef.current;

    if (!normalizedQuery) {
      setSearchResults([]);
      setDirectorProfiles([]);
      setSelectedDirector(null);
      setCorrectedQuery(null);
      setIsSearching(false);
      return;
    }

    setIsSearching(true);

    debounceRef.current = setTimeout(async () => {
      const [tmdbResults, people] = await Promise.all([
        searchMovies(normalizedQuery, TMDB_SEARCH_TIMEOUT_MS),
        searchPeople(normalizedQuery, TMDB_SEARCH_TIMEOUT_MS),
      ]);

      // Stale check — a newer search was fired while we were awaiting
      if (requestId !== searchRequestIdRef.current) return;

      // Fuzzy-match against local pools (suggestions + backfill)
      const localPool = [...suggestions, ...backfillPoolRef.current];
      const fuzzyMatches = fuzzyFilterLocal(normalizedQuery, localPool, m => m.title);
      const merged = mergeAndDedupSearchResults([...tmdbResults, ...fuzzyMatches]);

      let corrected: string | null = null;

      // If TMDB returned few results, try a corrected query
      if (tmdbResults.length < 3) {
        const titleDict = [
          ...currentItems.map(i => i.title),
          ...suggestions.map(m => m.title),
          ...backfillPoolRef.current.map(m => m.title),
        ];
        const bestMatch = getBestCorrectedQuery(normalizedQuery, titleDict);
        if (bestMatch && bestMatch.toLowerCase() !== normalizedQuery.toLowerCase()) {
          corrected = bestMatch;
          const correctedResults = await searchMovies(bestMatch, TMDB_SEARCH_TIMEOUT_MS);
          // Stale check again after second await
          if (requestId !== searchRequestIdRef.current) return;
          const finalMerged = mergeAndDedupSearchResults([...merged, ...correctedResults]);
          setSearchResults(finalMerged);
        } else {
          setSearchResults(merged);
        }
      } else {
        setSearchResults(merged);
      }

      setCorrectedQuery(corrected);
      setDirectorProfiles(people);
      setSelectedDirector(null);
      setIsSearching(false);
    }, 350);

    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, [searchTerm]);

  const handleOpenDirector = async (person: PersonProfile) => {
    setDirectorLoading(true);
    try {
      const detail = await getPersonFilmography(person.id, person.role);
      setSelectedDirector(detail);
    } catch (err) {
      console.error('Failed to load filmography:', err);
    } finally {
      setDirectorLoading(false);
    }
  };

  if (!isOpen) return null;

  // IDs and titles of movies the user already has ranked or saved
  const rankedIds = new Set(currentItems.map(i => i.id));
  const rankedTitles = new Set(currentItems.map(i => i.title.toLowerCase()));
  const allExcludedIds = new Set([...rankedIds, ...(watchlistIds ?? [])]);

  const isAlreadyOwned = (m: { id: string; title: string }) =>
    allExcludedIds.has(m.id) || rankedTitles.has(m.title.toLowerCase());

  const getTierItems = (tier: Tier) =>
    currentItems.filter(i => i.tier === tier).sort((a, b) => a.rank - b.rank);

  // Filter search results: remove already-ranked movies (by ID or title)
  const filteredSearchResults = searchResults.filter(m => !isAlreadyOwned(m));

  // Filter suggestions client-side as a safety net (covers old localStorage IDs,
  // bookmarks made during this session, and any API-level filtering misses)
  const filteredSuggestions = suggestions.filter(m => !isAlreadyOwned(m));

  const handleSelectMovie = async (movie: TMDBMovie, fromSuggestion = false) => {
    if (fromSuggestion) consumeSuggestion(movie.id);

    setIsRatingFetching(true);
    const globalScore = await getMovieGlobalScore(movie.tmdbId);
    setIsRatingFetching(false);

    const asRankedItem: RankedItem = {
      id: movie.id,
      title: movie.title,
      year: movie.year,
      posterUrl: movie.posterUrl ?? '',
      type: 'movie',
      genres: movie.genres,
      tier: Tier.B,
      rank: 0,
      bracket: classifyBracket(movie.genres),
      globalScore,
    };
    setSelectedItem(asRankedItem);
    setStep('tier');
  };

  const handleBookmark = async (movie: TMDBMovie, fromSuggestion = false) => {
    if (!onSaveForLater) return;
    if (fromSuggestion) consumeSuggestion(movie.id);
    onSaveForLater(movie);
  };

  const isBookmarked = (movieId: string) => watchlistIds?.has(movieId) ?? false;

  const handleSelectTier = (tier: Tier) => {
    setSelectedTier(tier);
    // Always go to notes step first, regardless of tier size
    setStep('notes');
  };

  const proceedFromNotes = (overrideSkip?: boolean) => {
    const tierItems = getTierItems(selectedTier!);
    const item = selectedItem!;
    const finalNotes = overrideSkip ? undefined : (notes.trim() || undefined);
    const finalWatchedWith = overrideSkip ? undefined : (watchedWithUserIds.length > 0 ? watchedWithUserIds : undefined);

    if (tierItems.length === 0) {
      // Empty tier — insert at 0
      onAdd({ ...item, tier: selectedTier!, rank: 0, notes: finalNotes, watchedWithUserIds: finalWatchedWith });
      onClose();
    } else if (tierItems.length <= 5) {
      // 1-5 items — compare against every item (top to bottom)
      smallTierRef.current = { mode: 'compare_all', tierItems, low: 0, high: tierItems.length, mid: 0, round: 1, seedIdx: 0 };
      engineRef.current = null;
      setCurrentComparison({ movieA: item, movieB: tierItems[0], question: 'Which do you prefer?', round: 1, phase: 'binary_search' });
      setStep('compare');
    } else if (tierItems.length <= 20) {
      // 6-20 items — seed pivot then quartile narrowing
      const range = TIER_SCORE_RANGES[selectedTier!];
      const tierScores = tierItems.map((_, idx) => computeTierScore(idx, tierItems.length, range.min, range.max));
      const seedIdx = computeSeedIndex(tierScores, range.min, range.max, item.globalScore);
      smallTierRef.current = { mode: 'seed', tierItems, low: 0, high: tierItems.length, mid: seedIdx, round: 1, seedIdx };
      engineRef.current = null;
      setCurrentComparison({ movieA: item, movieB: tierItems[seedIdx], question: 'Which do you prefer?', round: 1, phase: 'binary_search' });
      setStep('compare');
    } else {
      // Large tier — use genre-anchored SpoolRankingEngine
      const engine = new SpoolRankingEngine();
      const signals = computePredictionSignals(
        currentItems,
        item.genres[0] ?? '',
        item.bracket ?? classifyBracket(item.genres),
        item.globalScore,
        selectedTier!,
      );
      const result = engine.start(item, selectedTier!, currentItems, signals);
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
      const finalItem: RankedItem = {
        ...selectedItem,
        tier: selectedTier,
        rank: rankIndex,
        notes: notes.trim() || undefined,
        watchedWithUserIds: watchedWithUserIds.length > 0 ? watchedWithUserIds : undefined,
      };

      onAdd(finalItem);


      onClose();
    }
  };

  const handleCompareChoice = (choice: 'new' | 'existing' | 'too_tough' | 'skip') => {
    if (!currentComparison) return;
    if (!engineRef.current && !smallTierRef.current) return;
    if (isProcessingRef.current) return;
    isProcessingRef.current = true;

    try {
      // Log comparison
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

      // Small tier path (≤ 20 items)
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
          // quartile narrowing
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

      // SpoolRankingEngine path (large tiers > 20)
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

  // ─── Render: Search ───────────────────────────────────────────────────────
  const renderSearchStep = () => (
    <div className="space-y-4 animate-fade-in">
      {/* Search input */}
      <div className="relative">
        <Search className="absolute left-3 top-3.5 text-muted" size={18} />
        <input
          type="text"
          autoFocus
          placeholder="Search any movie..."
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

      {/* No API key warning */}
      {!hasTmdbKey() && (
        <div className="bg-gold/10 border border-yellow-500/20 rounded-xl p-4 text-sm text-yellow-300">
          <p className="font-semibold mb-1">TMDB API key not configured</p>
          <p className="text-gold/70 text-xs">
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
                <div className="w-12 h-16 bg-secondary rounded flex-shrink-0" />
                <div className="flex-1 space-y-2">
                  <div className="h-3 bg-secondary rounded w-3/4" />
                  <div className="h-2 bg-secondary rounded w-1/2" />
                </div>
              </div>
            ))}
          </div>
        )}

        {/* People (directors & actors) */}
        {!isSearching && !selectedDirector && directorProfiles.length > 0 && (
          <div className="space-y-1 pb-2">
            <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">People</p>
            {directorProfiles.map(person => (
              <button
                key={person.id}
                onClick={() => handleOpenDirector(person)}
                className="flex items-center gap-3 p-2.5 rounded-xl hover:bg-secondary/50 transition-colors w-full text-left"
              >
                {person.photoUrl ? (
                  <img src={person.photoUrl} alt={person.name} className="w-10 h-10 object-cover rounded-full bg-secondary flex-shrink-0 shadow-md" />
                ) : (
                  <div className="w-10 h-10 bg-secondary rounded-full flex items-center justify-center flex-shrink-0 text-muted-foreground/60 text-sm font-bold">
                    {person.name.charAt(0)}
                  </div>
                )}
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <p className="font-semibold text-foreground truncate text-sm">{person.name}</p>
                    <span className={`text-[10px] px-1.5 py-0.5 rounded-full font-medium flex-shrink-0 ${person.role === 'Director' ? 'bg-amber-500/15 text-gold' : 'bg-gold/15 text-accent'}`}>
                      {person.role}
                    </span>
                  </div>
                  {person.knownFor.length > 0 && (
                    <p className="text-xs text-muted-foreground truncate">Known for: {person.knownFor.join(', ')}</p>
                  )}
                </div>
                <ChevronRight size={14} className="text-muted-foreground/60 flex-shrink-0" />
              </button>
            ))}
          </div>
        )}

        {/* Director loading */}
        {directorLoading && (
          <div className="flex items-center justify-center py-8">
            <Loader2 className="w-5 h-5 text-gold animate-spin" />
          </div>
        )}

        {/* Person profile card */}
        {selectedDirector && !directorLoading && (
          <div className="space-y-3 animate-fade-in">
            <button
              onClick={() => setSelectedDirector(null)}
              className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground transition-colors"
            >
              <ArrowLeft size={14} />
              Back to results
            </button>

            <div className="flex items-start gap-3 p-3 bg-card rounded-xl border border-border">
              {selectedDirector.photoUrl ? (
                <img src={selectedDirector.photoUrl} alt={selectedDirector.name} className="w-16 h-16 object-cover rounded-xl shadow-lg flex-shrink-0" />
              ) : (
                <div className="w-16 h-16 bg-secondary rounded-xl flex items-center justify-center flex-shrink-0 text-2xl font-bold text-muted-foreground">
                  {selectedDirector.name.charAt(0)}
                </div>
              )}
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <h3 className="text-base font-serif text-foreground">{selectedDirector.name}</h3>
                  <span className={`text-[10px] px-1.5 py-0.5 rounded-full font-medium ${selectedDirector.role === 'Director' ? 'bg-amber-500/15 text-gold' : 'bg-gold/15 text-accent'}`}>
                    {selectedDirector.role}
                  </span>
                </div>
                <p className="text-xs text-muted-foreground">
                  {selectedDirector.placeOfBirth && <span>{selectedDirector.placeOfBirth}</span>}
                  {selectedDirector.birthday && <span> · Born {selectedDirector.birthday}</span>}
                </p>
              </div>
            </div>

            {selectedDirector.biography && (
              <p className="text-xs text-muted-foreground leading-relaxed line-clamp-3">{selectedDirector.biography}</p>
            )}

            <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
              {selectedDirector.movies.filter(m => !isAlreadyOwned(m)).map(movie => (
                <div key={movie.id} className="relative group flex flex-col items-center text-center rounded-xl hover:bg-secondary/60 p-1.5 transition-colors">
                  <button
                    onClick={() => {
                      onClose();
                      onMovieInfoClick?.(`tmdb_${movie.tmdbId}`);
                    }}
                    className="w-full relative cursor-pointer"
                  >
                    <img
                      src={movie.posterUrl!}
                      alt={movie.title}
                      className="w-full aspect-[2/3] object-cover rounded-lg bg-secondary shadow-md group-hover:shadow-lg transition-all mb-1.5"
                    />
                  </button>
                  <button onClick={() => handleSelectMovie(movie)} className="text-xs font-medium text-muted-foreground leading-tight line-clamp-2 hover:text-accent transition-colors w-full text-left">
                    {movie.title}
                  </button>
                  <p className="text-[10px] text-muted-foreground/60 w-full text-left">{movie.year}</p>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Search results (excludes already-ranked movies) */}
        {!isSearching && !selectedDirector && filteredSearchResults.length > 0 && (
          <div className="space-y-1">
            {directorProfiles.length > 0 && (
              <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider pt-1">Movies</p>
            )}
            {filteredSearchResults.map((movie) => (
              <div
                key={movie.id}
                className="flex items-center gap-3 p-2 rounded-xl hover:bg-secondary transition-colors group"
              >
                <div
                  className="cursor-pointer relative flex-shrink-0"
                  onClick={() => {
                    onClose();
                    onMovieInfoClick?.(`tmdb_${movie.tmdbId}`);
                  }}
                >
                  {movie.posterUrl ? (
                    <img src={movie.posterUrl} alt={movie.title} className="w-12 h-[72px] object-cover rounded-lg bg-secondary shadow-md hover:scale-105 transition-transform" />
                  ) : (
                    <div className="w-12 h-[72px] bg-secondary rounded-lg flex items-center justify-center flex-shrink-0">
                      <Film size={20} className="text-muted-foreground/60" />
                    </div>
                  )}
                </div>
                <button onClick={() => handleSelectMovie(movie)} className="flex-1 min-w-0 text-left">
                  <p className="font-semibold text-foreground group-hover:text-accent transition-colors truncate leading-tight">{movie.title}</p>
                  <p className="text-xs text-muted-foreground mt-0.5">{movie.year}</p>
                  {movie.genres && movie.genres.length > 0 && (
                    <div className="flex gap-1 mt-1.5 flex-wrap">
                      {movie.genres.map(g => (
                        <span key={g} className="text-[10px] px-1.5 py-0.5 bg-secondary text-muted-foreground rounded-full border border-border">{g}</span>
                      ))}
                    </div>
                  )}
                </button>
                <div className="flex items-center gap-1 flex-shrink-0">
                  {onSaveForLater && (
                    <button
                      onClick={() => handleBookmark(movie)}
                      title={isBookmarked(movie.id) ? 'Already saved' : 'Save for later'}
                      className={`p-1.5 rounded-lg transition-colors ${isBookmarked(movie.id) ? 'text-emerald-400 bg-emerald-500/10' : 'text-muted-foreground/40 hover:text-emerald-400 hover:bg-emerald-500/10'}`}
                    >
                      <Bookmark size={16} className={isBookmarked(movie.id) ? 'fill-current' : ''} />
                    </button>
                  )}
                  <button onClick={() => handleSelectMovie(movie)} className="p-1.5 rounded-lg text-muted-foreground/40 group-hover:text-muted-foreground hover:bg-secondary/50 transition-colors" title="Rank this movie">
                    <Plus size={18} />
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}

        {/* Empty state */}
        {!isSearching && !selectedDirector && searchTerm.trim() && filteredSearchResults.length === 0 && directorProfiles.length === 0 && (
          <div className="text-center py-12 text-muted-foreground text-sm">
            <Film size={32} className="mx-auto mb-3 opacity-30" />
            <p>No results for "{searchTerm}"</p>
            <p className="text-xs mt-1 opacity-60">Try a different title, director name, or check spelling</p>
          </div>
        )}

        {/* Suggestions — shown when search is empty */}
        {!isSearching && !searchTerm.trim() && (
          <>
            {isRatingFetching && (
              <div className="absolute inset-0 bg-background/50 backdrop-blur-sm z-10 flex items-center justify-center rounded-xl">
                <div className="flex flex-col items-center gap-3 bg-card border border-border p-6 rounded-2xl shadow-2xl">
                  <Loader2 className="w-8 h-8 text-gold animate-spin" />
                  <p className="text-sm font-semibold text-muted-foreground">Fetching global ranking...</p>
                </div>
              </div>
            )}
            {suggestionsLoading && (
              <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
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
                <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
                  {filteredSuggestions.map((movie) => (
                    <div key={movie.id} className="relative group">
                      <div className="flex flex-col items-center text-center rounded-xl hover:bg-secondary/60 p-2 transition-colors w-full">
                        <button
                          onClick={() => {
                            onClose();
                            onMovieInfoClick?.(`tmdb_${movie.tmdbId}`);
                          }}
                          className="w-full relative cursor-pointer"
                        >
                          <img
                            src={movie.posterUrl!}
                            alt={movie.title}
                            className="w-full aspect-[2/3] object-cover rounded-lg bg-secondary shadow-md group-hover:shadow-lg hover:scale-105 transition-all mb-1.5"
                          />
                        </button>
                        <button onClick={() => handleSelectMovie(movie, true)} className="text-xs font-medium text-muted-foreground leading-tight line-clamp-2 hover:text-accent transition-colors w-full text-left">
                          {movie.title}
                        </button>
                        <p className="text-[10px] text-muted-foreground/60 w-full text-left">{movie.year}</p>
                      </div>
                      {onSaveForLater && (
                        <button
                          onClick={(e) => { e.stopPropagation(); handleBookmark(movie, true); }}
                          title={isBookmarked(movie.id) ? 'Already saved' : 'Save for later'}
                          className={`absolute top-3 right-3 p-1.5 rounded-full transition-all shadow-md ${isBookmarked(movie.id)
                            ? 'bg-emerald-500/30 text-emerald-400 border border-emerald-500/40'
                            : 'bg-black/60 text-muted-foreground border border-border opacity-0 group-hover:opacity-100 hover:text-emerald-400 hover:bg-emerald-500/20'
                            }`}
                        >
                          <Bookmark size={12} className={isBookmarked(movie.id) ? 'fill-current' : ''} />
                        </button>
                      )}
                    </div>
                  ))}
                </div>
              </div>
            ) : !suggestionsLoading ? (
              <div className="text-center py-12 text-muted-foreground/60 text-sm">
                <Search size={32} className="mx-auto mb-3 opacity-30" />
                <p>Type a movie title to search</p>
              </div>
            ) : null}
          </>
        )}
      </div>
    </div>
  );

  // ─── Render: Tier ─────────────────────────────────────────────────────────
  const renderTierStep = () => (
    <TierPicker
      selectedItem={selectedItem}
      currentItems={currentItems}
      onSelectTier={handleSelectTier}
      onBracketChange={(b) => setSelectedItem(prev => prev ? { ...prev, bracket: b } : prev)}
    />
  );

  // ─── Render: Notes ────────────────────────────────────────────────────────
  const renderNotesStep = () => (
    <NotesStep
      selectedItem={selectedItem}
      selectedTier={selectedTier}
      notes={notes}
      onNotesChange={setNotes}
      onContinue={proceedFromNotes}
      onSkip={() => { setNotes(''); setWatchedWithUserIds([]); proceedFromNotes(true); }}
      currentUserId={user?.id}
      watchedWithUserIds={watchedWithUserIds}
      onWatchedWithChange={setWatchedWithUserIds}
    />
  );

  // ─── Render: Compare ──────────────────────────────────────────────────────
  const renderCompareStep = () => {
    if (!currentComparison) return null;
    return (
      <ComparisonStep
        comparison={currentComparison}
        selectedTier={selectedTier}
        onChoice={handleCompareChoice}
        onUndo={handleUndo}
      />
    );
  };

  const getStepTitle = () => {
    switch (step) {
      case 'search': return 'Add to Spool';
      case 'tier': return 'Assign Tier';
      case 'notes': return 'Add a Note';
      case 'compare': return 'Head-to-Head';
    }
  };

  const handleBack = () => {
    if (step === 'compare') setStep('notes');
    else if (step === 'notes') setStep('tier');
    else if (step === 'tier') setStep('search');
  };

  return (
    <FocusTrap focusTrapOptions={{ allowOutsideClick: true }}>
    <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center p-0 sm:p-4 bg-black/50 backdrop-blur-sm">
      <div role="dialog" aria-modal="true" aria-label="Add media" className="bg-background border border-border w-full sm:max-w-lg rounded-t-2xl sm:rounded-2xl shadow-2xl overflow-hidden flex flex-col max-h-[95vh] sm:max-h-[90vh]">
        {/* Header */}
        <div className="flex items-center justify-between p-3 sm:p-5 border-b border-border bg-card/30 flex-shrink-0">
          <div className="flex items-center gap-2 sm:gap-3">
            {step !== 'search' && (
              <button onClick={handleBack} className="text-muted-foreground hover:text-foreground transition-colors">
                <ArrowLeft size={20} />
              </button>
            )}
            <h2 className="text-lg sm:text-xl font-bold text-foreground">{getStepTitle()}</h2>
          </div>
          <button onClick={onClose} className="text-muted-foreground hover:text-foreground transition-colors">
            <X size={24} />
          </button>
        </div>

        {/* Content */}
        <div className="p-3 sm:p-5 overflow-y-auto flex-1">
          {step === 'search' && renderSearchStep()}
          {step === 'tier' && renderTierStep()}
          {step === 'notes' && renderNotesStep()}
          {step === 'compare' && renderCompareStep()}
        </div>
      </div>
    </div>
    </FocusTrap>
  );
};
