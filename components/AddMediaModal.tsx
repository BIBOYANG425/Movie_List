import React, { useState, useEffect, useRef } from 'react';
import { X, Search, Plus, ArrowLeft, Loader2, Film, StickyNote, ChevronRight, Bookmark, RefreshCw } from 'lucide-react';
import { RankedItem, Tier, WatchlistItem, ComparisonLogEntry } from '../types';
import { TIER_COLORS, TIER_LABELS, TIER_SCORE_RANGES } from '../constants';
import { searchMovies, searchPeople, getPersonFilmography, getSmartSuggestions, getSmartBackfill, buildTasteProfile, hasTmdbKey, getMovieGlobalScore, TMDBMovie, PersonProfile, PersonDetail } from '../services/tmdbService';
import { classifyBracket, computeSeedIndex, adaptiveNarrow, computeTierScore } from '../services/rankingAlgorithm';
import { useAuth } from '../contexts/AuthContext';

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

interface CompareSnapshot {
  low: number;
  high: number;
}

const TMDB_SEARCH_TIMEOUT_MS = 4500;

function mergeAndDedupSearchResults(results: TMDBMovie[]): TMDBMovie[] {
  const byKey = new Map<string, TMDBMovie>();

  for (const movie of results) {
    const key = movie.tmdbId > 0
      ? `tmdb:${movie.tmdbId} `
      : `title:${movie.title.toLowerCase().trim()} `;
    if (!byKey.has(key)) byKey.set(key, movie);
  }

  return Array.from(byKey.values()).slice(0, 12);
}

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

  // Two-pool suggestion system
  const suggestionPageRef = useRef(1);
  const backfillPoolRef = useRef<TMDBMovie[]>([]);
  const backfillPageRef = useRef(1);
  const [hasBackfillMixed, setHasBackfillMixed] = useState(false);

  // Notes state
  const [notes, setNotes] = useState('');

  // Binary search comparison state
  const [compLow, setCompLow] = useState(0);
  const [compHigh, setCompHigh] = useState(0);
  const [compHistory, setCompHistory] = useState<CompareSnapshot[]>([]);
  const [compSeed, setCompSeed] = useState<number | null>(null);
  const [sessionId, setSessionId] = useState('');

  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

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
    });
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
    });

    backfillPageRef.current = 1;
    backfillPoolRef.current = [];
    getSmartBackfill(profile, excludeIds, 1, excludeTitles).then((results) => {
      backfillPoolRef.current = results;
    });
  };

  const handleRefreshSuggestions = () => {
    suggestionPageRef.current += 1;
    loadInitialSuggestions(suggestionPageRef.current);
  };

  // Reset on open/close
  useEffect(() => {
    if (isOpen) {
      setSearchTerm('');
      setSearchResults([]);
      setIsSearching(false);
      setSelectedTier(null);
      setNotes('');
      setCompLow(0);
      setCompHigh(0);
      setCompHistory([]);
      setCompSeed(null);
      setSessionId(globalThis.crypto?.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2));

      // If a watchlist item was pre-selected, skip to tier step
      if (preselectedItem && !preselectedTier) {
        const asRankedItem: RankedItem = {
          id: preselectedItem.id,
          title: preselectedItem.title,
          year: preselectedItem.year,
          posterUrl: preselectedItem.posterUrl,
          type: 'movie',
          genres: preselectedItem.genres,
          tier: Tier.B,
          rank: 0,
        };
        setSelectedItem(asRankedItem);
        setStep('tier');
      } else if (preselectedItem && preselectedTier) {
        // Tier migration
        const asRankedItem = preselectedItem as RankedItem;
        setSelectedItem(asRankedItem);
        setSelectedTier(preselectedTier);

        const tierItems = currentItems.filter(i => i.tier === preselectedTier).sort((a, b) => a.rank - b.rank);
        if (tierItems.length === 0) {
          onAdd({ ...asRankedItem, tier: preselectedTier, rank: 0 });
          onClose();
        } else {
          const range = TIER_SCORE_RANGES[preselectedTier];
          const tierItemScores = tierItems.map((_, idx) => computeTierScore(idx, tierItems.length, range.min, range.max));
          const seedIdx = computeSeedIndex(tierItemScores, range.min, range.max, asRankedItem.globalScore);

          setCompLow(0);
          setCompHigh(tierItems.length);
          setCompHistory([]);
          setCompSeed(seedIdx);
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
    if (!normalizedQuery) {
      setSearchResults([]);
      setDirectorProfiles([]);
      setSelectedDirector(null);
      setIsSearching(false);
      return;
    }

    setIsSearching(true);

    debounceRef.current = setTimeout(async () => {
      const [tmdbResults, people] = await Promise.all([
        searchMovies(normalizedQuery, TMDB_SEARCH_TIMEOUT_MS),
        searchPeople(normalizedQuery, TMDB_SEARCH_TIMEOUT_MS),
      ]);

      setSearchResults(mergeAndDedupSearchResults(tmdbResults));
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
    const detail = await getPersonFilmography(person.id, person.role);
    setSelectedDirector(detail);
    setDirectorLoading(false);
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

  const proceedFromNotes = () => {
    const tierItems = getTierItems(selectedTier!);
    if (tierItems.length === 0) {
      // No existing items in tier — insert immediately
      onAdd({
        ...selectedItem!,
        tier: selectedTier!,
        rank: 0,
        notes: notes.trim() || undefined,
      });
      onClose();
    } else {
      // Spool adaptive seeding: Use global average if it falls within the tier
      // Calculate derived scores for existing items in this tier
      const range = TIER_SCORE_RANGES[selectedTier!];
      const tierItemScores = tierItems.map((_, idx) =>
        computeTierScore(idx, tierItems.length, range.min, range.max)
      );

      const seedIdx = computeSeedIndex(
        tierItemScores,
        range.min,
        range.max,
        selectedItem?.globalScore
      );

      // Start head-to-head comparison around the seed index
      // The binary search needs a low and high bound. 
      // If we seed at index N, we can set bounds such that mid roughly equals N.
      // But standard binary search bounds are 0 to length.
      // Quartile narrowing from the algo still requires the true low/high bounds.
      // So we set low=0, high=length as the search space, but we could artificially
      // force the first comparison to be `seedIdx`.
      // Actually, since the UI expects `mid = Math.floor((low + high) / 2)` directly,
      // the simplest way to seed is to not change low/high in `proceedFromNotes`,
      // but to add a initial `seedMid` state, OR redefine how `compLow`/`compHigh` 
      // dictate the first comparison.
      // For V1 of the spec, the "start at this index" is easiest achieved by 
      // setting compLow=0, compHigh=length, but passing the seedIdx as the FIRST mid.
      // We need to store `seedIdx`.

      setCompLow(0);
      setCompHigh(tierItems.length);
      setCompHistory([]);
      // Store seed index to be used as first mid
      setCompSeed(seedIdx);

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
      };

      onAdd(finalItem);


      onClose();
    }
  };

  const handleCompareChoice = (choice: 'new' | 'existing' | 'too_tough' | 'skip') => {
    const mid = Math.floor((compLow + compHigh) / 2);

    // Log comparison
    if (onCompare && selectedItem && selectedTier) {
      const tierItems = getTierItems(selectedTier);
      const pivotItem = tierItems[mid];
      if (pivotItem) {
        onCompare({
          sessionId,
          movieAId: selectedItem.id,
          movieBId: pivotItem.id,
          winner: choice === 'new' ? 'a' : choice === 'existing' ? 'b' : 'skip',
          round: compHistory.length + 1,
        });
      }
    }

    if (choice === 'too_tough' || choice === 'skip') {
      handleInsertAt(mid);
      return;
    }

    setCompHistory(prev => [...prev, { low: compLow, high: compHigh }]);

    const result = adaptiveNarrow(compLow, compHigh, mid, choice);

    if (!result) {
      handleInsertAt(choice === 'new' ? mid : mid + 1);
    } else {
      setCompLow(result.newLow);
      setCompHigh(result.newHigh);
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
        <Search className="absolute left-3 top-3.5 text-muted" size={18} />
        <input
          type="text"
          autoFocus
          placeholder="Search any movie..."
          className="w-full bg-card border border-border rounded-xl py-3 pl-10 pr-4 text-white placeholder-zinc-600 focus:outline-none focus:border-indigo-500 transition-colors"
          value={searchTerm}
          onChange={(e) => setSearchTerm(e.target.value)}
        />
        {isSearching && (
          <Loader2 className="absolute right-3 top-3.5 text-muted animate-spin" size={18} />
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

        {/* People (directors & actors) */}
        {!isSearching && !selectedDirector && directorProfiles.length > 0 && (
          <div className="space-y-1 pb-2">
            <p className="text-xs font-semibold text-zinc-500 uppercase tracking-wider">People</p>
            {directorProfiles.map(person => (
              <button
                key={person.id}
                onClick={() => handleOpenDirector(person)}
                className="flex items-center gap-3 p-2.5 rounded-xl hover:bg-zinc-800/80 transition-colors w-full text-left"
              >
                {person.photoUrl ? (
                  <img src={person.photoUrl} alt={person.name} className="w-10 h-10 object-cover rounded-full bg-zinc-800 flex-shrink-0 shadow-md" />
                ) : (
                  <div className="w-10 h-10 bg-zinc-800 rounded-full flex items-center justify-center flex-shrink-0 text-zinc-600 text-sm font-bold">
                    {person.name.charAt(0)}
                  </div>
                )}
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <p className="font-semibold text-white truncate text-sm">{person.name}</p>
                    <span className={`text - [10px] px - 1.5 py - 0.5 rounded - full font - medium flex - shrink - 0 ${person.role === 'Director' ? 'bg-amber-500/15 text-amber-400' : 'bg-indigo-500/15 text-indigo-400'} `}>
                      {person.role}
                    </span>
                  </div>
                  {person.knownFor.length > 0 && (
                    <p className="text-[11px] text-zinc-500 truncate">Known for: {person.knownFor.join(', ')}</p>
                  )}
                </div>
                <ChevronRight size={14} className="text-zinc-600 flex-shrink-0" />
              </button>
            ))}
          </div>
        )}

        {/* Director loading */}
        {directorLoading && (
          <div className="flex items-center justify-center py-8">
            <Loader2 className="w-5 h-5 text-indigo-500 animate-spin" />
          </div>
        )}

        {/* Person profile card */}
        {selectedDirector && !directorLoading && (
          <div className="space-y-3 animate-fade-in">
            <button
              onClick={() => setSelectedDirector(null)}
              className="flex items-center gap-1 text-xs text-dim hover:text-white transition-colors"
            >
              <ArrowLeft size={14} />
              Back to results
            </button>

            <div className="flex items-start gap-3 p-3 bg-card rounded-xl border border-border">
              {selectedDirector.photoUrl ? (
                <img src={selectedDirector.photoUrl} alt={selectedDirector.name} className="w-16 h-16 object-cover rounded-xl shadow-lg flex-shrink-0" />
              ) : (
                <div className="w-16 h-16 bg-elevated rounded-xl flex items-center justify-center flex-shrink-0 text-2xl font-bold text-dim">
                  {selectedDirector.name.charAt(0)}
                </div>
              )}
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <h3 className="text-base font-serif text-white">{selectedDirector.name}</h3>
                  <span className={`text-[10px] px-1.5 py-0.5 rounded-full font-medium ${selectedDirector.role === 'Director' ? 'bg-amber-500/15 text-amber-400' : 'bg-indigo-500/15 text-indigo-400'}`}>
                    {selectedDirector.role}
                  </span>
                </div>
                <p className="text-[11px] text-dim">
                  {selectedDirector.placeOfBirth && <span>{selectedDirector.placeOfBirth}</span>}
                  {selectedDirector.birthday && <span> · Born {selectedDirector.birthday}</span>}
                </p>
              </div>
            </div>

            {selectedDirector.biography && (
              <p className="text-[11px] text-zinc-400 leading-relaxed line-clamp-3">{selectedDirector.biography}</p>
            )}

            <div className="grid grid-cols-3 gap-2">
              {selectedDirector.movies.filter(m => !isAlreadyOwned(m)).map(movie => (
                <div key={movie.id} className="relative group flex flex-col items-center text-center rounded-xl hover:bg-zinc-800/60 p-1.5 transition-colors">
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
                      className="w-full aspect-[2/3] object-cover rounded-lg bg-zinc-800 shadow-md group-hover:shadow-lg transition-all mb-1.5"
                    />
                  </button>
                  <button onClick={() => handleSelectMovie(movie)} className="text-[11px] font-medium text-zinc-300 leading-tight line-clamp-2 hover:text-indigo-400 transition-colors w-full text-left">
                    {movie.title}
                  </button>
                  <p className="text-[10px] text-zinc-600 w-full text-left">{movie.year}</p>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Search results (excludes already-ranked movies) */}
        {!isSearching && !selectedDirector && filteredSearchResults.length > 0 && (
          <div className="space-y-1">
            {directorProfiles.length > 0 && (
              <p className="text-xs font-semibold text-dim uppercase tracking-wider pt-1">Movies</p>
            )}
            {filteredSearchResults.map((movie) => (
              <div
                key={movie.id}
                className="flex items-center gap-3 p-2 rounded-xl hover:bg-elevated transition-colors group"
              >
                <div
                  className="cursor-pointer relative flex-shrink-0"
                  onClick={() => {
                    onClose();
                    onMovieInfoClick?.(`tmdb_${movie.tmdbId}`);
                  }}
                >
                  {movie.posterUrl ? (
                    <img src={movie.posterUrl} alt={movie.title} className="w-12 h-[72px] object-cover rounded-lg bg-zinc-800 shadow-md hover:scale-105 transition-transform" />
                  ) : (
                    <div className="w-12 h-[72px] bg-zinc-800 rounded-lg flex items-center justify-center flex-shrink-0">
                      <Film size={20} className="text-zinc-600" />
                    </div>
                  )}
                </div>
                <button onClick={() => handleSelectMovie(movie)} className="flex-1 min-w-0 text-left">
                  <p className="font-semibold text-white group-hover:text-indigo-400 transition-colors truncate leading-tight">{movie.title}</p>
                  <p className="text-xs text-zinc-500 mt-0.5">{movie.year}</p>
                  {movie.genres && movie.genres.length > 0 && (
                    <div className="flex gap-1 mt-1.5 flex-wrap">
                      {movie.genres.map(g => (
                        <span key={g} className="text-[10px] px-1.5 py-0.5 bg-zinc-800 text-zinc-400 rounded-full border border-zinc-700">{g}</span>
                      ))}
                    </div>
                  )}
                </button>
                <div className="flex items-center gap-1 flex-shrink-0">
                  {onSaveForLater && (
                    <button
                      onClick={() => handleBookmark(movie)}
                      title={isBookmarked(movie.id) ? 'Already saved' : 'Save for later'}
                      className={`p - 1.5 rounded - lg transition - colors ${isBookmarked(movie.id) ? 'text-emerald-400 bg-emerald-500/10' : 'text-zinc-700 hover:text-emerald-400 hover:bg-emerald-500/10'} `}
                    >
                      <Bookmark size={16} className={isBookmarked(movie.id) ? 'fill-current' : ''} />
                    </button>
                  )}
                  <button onClick={() => handleSelectMovie(movie)} className="p-1.5 rounded-lg text-zinc-700 group-hover:text-zinc-300 hover:bg-zinc-700/50 transition-colors" title="Rank this movie">
                    <Plus size={18} />
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}

        {/* Empty state */}
        {!isSearching && !selectedDirector && searchTerm.trim() && filteredSearchResults.length === 0 && directorProfiles.length === 0 && (
          <div className="text-center py-12 text-zinc-500 text-sm">
            <Film size={32} className="mx-auto mb-3 opacity-30" />
            <p>No results for "{searchTerm}"</p>
            <p className="text-xs mt-1 opacity-60">Try a different title, director name, or check spelling</p>
          </div>
        )}

        {/* Suggestions — shown when search is empty */}
        {!isSearching && !searchTerm.trim() && (
          <>
            {isRatingFetching && (
              <div className="absolute inset-0 bg-zinc-950/50 backdrop-blur-sm z-10 flex items-center justify-center rounded-xl">
                <div className="flex flex-col items-center gap-3 bg-zinc-900 border border-zinc-800 p-6 rounded-2xl shadow-2xl">
                  <Loader2 className="w-8 h-8 text-indigo-500 animate-spin" />
                  <p className="text-sm font-semibold text-zinc-300">Fetching global ranking...</p>
                </div>
              </div>
            )}
            {suggestionsLoading && (
              <div className="grid grid-cols-3 gap-2">
                {[1, 2, 3, 4, 5, 6].map(i => (
                  <div key={i} className="animate-pulse p-2">
                    <div className="w-full aspect-[2/3] bg-zinc-800 rounded-lg" />
                    <div className="h-3 bg-zinc-800 rounded mt-2 w-3/4 mx-auto" />
                    <div className="h-2 bg-zinc-800 rounded mt-1 w-1/2 mx-auto" />
                  </div>
                ))}
              </div>
            )}
            {!suggestionsLoading && filteredSuggestions.length > 0 ? (
              <div>
                <div className="flex items-center justify-between mb-3 px-1">
                  <p className="text-xs font-semibold text-zinc-500 uppercase tracking-wider">
                    {hasBackfillMixed ? 'Based on your taste' : 'Popular right now'}
                  </p>
                  <button
                    onClick={handleRefreshSuggestions}
                    className="flex items-center gap-1 text-[10px] font-semibold text-zinc-600 hover:text-zinc-300 transition-colors px-2 py-1 rounded-lg hover:bg-zinc-800"
                    title="Show different suggestions"
                  >
                    <RefreshCw size={11} />
                    Refresh
                  </button>
                </div>
                <div className="grid grid-cols-3 gap-2">
                  {filteredSuggestions.map((movie) => (
                    <div key={movie.id} className="relative group">
                      <div className="flex flex-col items-center text-center rounded-xl hover:bg-zinc-800/60 p-2 transition-colors w-full">
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
                            className="w-full aspect-[2/3] object-cover rounded-lg bg-zinc-800 shadow-md group-hover:shadow-lg hover:scale-105 transition-all mb-1.5"
                          />
                        </button>
                        <button onClick={() => handleSelectMovie(movie, true)} className="text-xs font-medium text-zinc-300 leading-tight line-clamp-2 hover:text-indigo-400 transition-colors w-full text-left">
                          {movie.title}
                        </button>
                        <p className="text-[10px] text-zinc-600 w-full text-left">{movie.year}</p>
                      </div>
                      {onSaveForLater && (
                        <button
                          onClick={(e) => { e.stopPropagation(); handleBookmark(movie, true); }}
                          title={isBookmarked(movie.id) ? 'Already saved' : 'Save for later'}
                          className={`absolute top - 3 right - 3 p - 1.5 rounded - full transition - all shadow - md ${isBookmarked(movie.id)
                            ? 'bg-emerald-500/30 text-emerald-400 border border-emerald-500/40'
                            : 'bg-black/60 text-zinc-500 border border-zinc-700 opacity-0 group-hover:opacity-100 hover:text-emerald-400 hover:bg-emerald-500/20'
                            } `}
                        >
                          <Bookmark size={12} className={isBookmarked(movie.id) ? 'fill-current' : ''} />
                        </button>
                      )}
                    </div>
                  ))}
                </div>
              </div>
            ) : !suggestionsLoading ? (
              <div className="text-center py-12 text-zinc-600 text-sm">
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
    <div className="space-y-5 animate-fade-in">
      {/* Selected movie preview */}
      <div className="flex items-center gap-4 bg-elevated p-4 rounded-xl border border-border">
        {selectedItem?.posterUrl ? (
          <img src={selectedItem.posterUrl} alt="" className="w-14 h-20 object-cover rounded-lg shadow-lg flex-shrink-0" />
        ) : (
          <div className="w-14 h-20 bg-card rounded-lg flex items-center justify-center flex-shrink-0">
            <Film size={20} className="text-muted" />
          </div>
        )}
        <div>
          <h3 className="font-serif text-lg leading-tight text-white">{selectedItem?.title}</h3>
          <p className="text-dim text-sm mt-0.5">{selectedItem?.year}</p>
          <p className="text-muted text-sm mt-1">How does this tier feel?</p>
        </div>
      </div>

      <div className="grid gap-2.5">
        {Object.values(Tier).map((tier) => (
          <button
            key={tier}
            onClick={() => handleSelectTier(tier)}
            className={`flex items - center justify - between p - 4 rounded - xl border - 2 transition - all hover: scale - [1.02] active: scale - [0.98] ${TIER_COLORS[tier]} `}
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
      <div className="flex items-center gap-4 bg-elevated p-4 rounded-xl border border-border">
        {selectedItem?.posterUrl ? (
          <img
            src={selectedItem.posterUrl}
            alt=""
            className="w-12 h-[72px] object-cover rounded-lg shadow-md flex-shrink-0"
          />
        ) : (
          <div className="w-12 h-[72px] bg-card rounded-lg flex items-center justify-center flex-shrink-0">
            <Film size={18} className="text-muted" />
          </div>
        )}
        <div>
          <p className="font-serif text-white leading-tight">{selectedItem?.title}</p>
          <p className="text-dim text-xs mt-0.5">{selectedItem?.year}</p>
          <span className={`inline - block mt - 2 text - xs font - bold px - 2 py - 0.5 rounded - full border ${TIER_COLORS[selectedTier!]} `}>
            {selectedTier} — {TIER_LABELS[selectedTier!]}
          </span>
        </div>
      </div>

      {/* Notes textarea */}
      <div className="space-y-2">
        <label className="flex items-center gap-2 text-sm font-semibold text-zinc-300">
          <StickyNote size={15} className="text-amber-400" />
          Your thoughts
          <span className="text-dim font-normal text-xs">(optional)</span>
        </label>
        <div className="relative">
          <textarea
            autoFocus
            rows={4}
            maxLength={MAX_NOTES}
            placeholder="What stood out? A scene, a feeling, why it deserves this tier..."
            className="w-full bg-card border border-border rounded-xl py-3 px-4 text-white placeholder:text-muted focus:outline-none focus:border-amber-500/60 transition-colors resize-none text-sm leading-relaxed"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
          />
          {/* Character count */}
          <span className={`absolute bottom - 3 right - 3 text - xs tabular - nums transition - colors ${notes.length > MAX_NOTES * 0.9 ? 'text-amber-400' : 'text-dim'
            } `}>
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
                className={`h - 1.5 w - 6 rounded - full transition - colors ${i < compHistory.length ? 'bg-indigo-500' : i === compHistory.length ? 'bg-zinc-500' : 'bg-zinc-800'
                  } `}
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
            className="flex-1 flex flex-col items-center gap-3 p-3 rounded-2xl border-2 border-border hover:border-indigo-500 hover:bg-indigo-500/5 transition-all group active:scale-[0.97]"
          >
            <img
              src={selectedItem?.posterUrl}
              alt={selectedItem?.title}
              className="w-full aspect-[2/3] object-cover rounded-xl shadow-lg"
            />
            <div className="text-center">
              <p className="font-serif text-white text-sm leading-tight">{selectedItem?.title}</p>
              <p className="text-xs text-dim mt-0.5">{selectedItem?.year}</p>
              <span className="inline-block mt-2 text-xs text-indigo-400 font-semibold border border-indigo-500/30 bg-indigo-500/10 px-2 py-0.5 rounded-full">
                NEW
              </span>
            </div>
          </button>

          {/* OR divider */}
          <div className="flex items-center justify-center flex-shrink-0">
            <div className="w-9 h-9 rounded-full bg-card border border-border flex items-center justify-center text-xs font-black text-muted">
              OR
            </div>
          </div>

          {/* Pivot item */}
          <button
            onClick={() => handleCompareChoice('existing')}
            className="flex-1 flex flex-col items-center gap-3 p-3 rounded-2xl border-2 border-border hover:border-zinc-400 hover:bg-zinc-400/5 transition-all group active:scale-[0.97]"
          >
            <img
              src={pivotItem?.posterUrl}
              alt={pivotItem?.title}
              className="w-full aspect-[2/3] object-cover rounded-xl shadow-lg"
            />
            <div className="text-center">
              <p className="font-bold text-white text-sm leading-tight">{pivotItem?.title}</p>
              <p className="text-xs text-dim mt-0.5">{pivotItem?.year}</p>
              <span className={`inline-block mt-2 text-xs font-semibold px-2 py-0.5 rounded-full border ${TIER_COLORS[selectedTier!]} `}>
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
            className="flex items-center gap-1.5 text-sm font-medium text-muted hover:text-white disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
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
      case 'search': return 'Add to Marquee';
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
          {step === 'search' && renderSearchStep()}
          {step === 'tier' && renderTierStep()}
          {step === 'notes' && renderNotesStep()}
          {step === 'compare' && renderCompareStep()}
        </div>
      </div>
    </div>
  );
};
