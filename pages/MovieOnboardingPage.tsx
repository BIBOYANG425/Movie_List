import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { ArrowLeft, Check, ChevronRight, Film, Loader2, RefreshCw, Search, X } from 'lucide-react';
import { RankedItem, Tier, MediaType, Bracket } from '../types';
import { TIER_COLORS, TIER_LABELS, TIERS, MIN_MOVIES_FOR_SCORES, TIER_SCORE_RANGES } from '../constants';
import { getDynamicSuggestions, getEditorsChoiceFills, hasTmdbKey, searchMovies, searchPeople, getPersonFilmography, getMovieGlobalScore, TMDBMovie, PersonProfile, PersonDetail } from '../services/tmdbService';
import { classifyBracket, computeSeedIndex, adaptiveNarrow, computeTierScore } from '../services/rankingAlgorithm';
import { supabase } from '../lib/supabase';
import { useAuth } from '../contexts/AuthContext';
import { logRankingActivityEvent } from '../services/friendsService';

const REQUIRED_MOVIES = MIN_MOVIES_FOR_SCORES;

function mergeAndDedup(results: TMDBMovie[]): TMDBMovie[] {
    const map = new Map<string, TMDBMovie>();
    for (const m of results) {
        const key = m.tmdbId > 0 ? `tmdb:${m.tmdbId}` : `title:${m.title.toLowerCase().trim()}`;
        if (!map.has(key)) map.set(key, m);
    }
    return Array.from(map.values()).slice(0, 12);
}

const MovieOnboardingPage: React.FC = () => {
    const { user } = useAuth();
    const navigate = useNavigate();

    // Ranked movies collected during onboarding
    const [rankedItems, setRankedItems] = useState<RankedItem[]>([]);
    const [loading, setLoading] = useState(true);

    // Suggestions
    const [suggestions, setSuggestions] = useState<TMDBMovie[]>([]);
    const [suggestionsLoading, setSuggestionsLoading] = useState(false);
    // Suggestion system pagination and backfill
    const suggestionPageRef = useRef(1);
    const backfillPoolRef = useRef<TMDBMovie[]>([]);
    const backfillPageRef = useRef(1);

    // Session tracking for suggestions algorithm
    const [sessionStartTime, setSessionStartTime] = useState(Date.now());
    const [sessionClickCount, setSessionClickCount] = useState(0);

    // Search
    const [searchTerm, setSearchTerm] = useState('');
    const [searchResults, setSearchResults] = useState<TMDBMovie[]>([]);
    const [personProfiles, setPersonProfiles] = useState<PersonProfile[]>([]);
    const [selectedPerson, setSelectedPerson] = useState<PersonDetail | null>(null);
    const [personLoading, setPersonLoading] = useState(false);
    const [isSearching, setIsSearching] = useState(false);
    const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

    // Tier picker modal
    const [pendingMovie, setPendingMovie] = useState<TMDBMovie | null>(null);
    const [pendingGlobalScore, setPendingGlobalScore] = useState<number | undefined>();
    const [fromSuggestion, setFromSuggestion] = useState(false);
    const [modalStep, setModalStep] = useState<'tier' | 'compare'>('tier');
    const [selectedTier, setSelectedTier] = useState<Tier | null>(null);
    const [compLow, setCompLow] = useState(0);
    const [compHigh, setCompHigh] = useState(0);
    const [compHistory, setCompHistory] = useState<{ low: number; high: number }[]>([]);
    const [compSeed, setCompSeed] = useState<number | null>(null);
    const [sessionId, setSessionId] = useState('');
    const [isRatingFetching, setIsRatingFetching] = useState(false);

    // ── Helpers ──────────────────────────────────────────────────────────────────

    const rankedIds = useMemo(() => new Set(rankedItems.map(i => i.id)), [rankedItems]);
    const rankedTitles = useMemo(() => new Set(rankedItems.map(i => i.title.toLowerCase())), [rankedItems]);

    const isOwned = useCallback(
        (m: { id: string; title: string }) => rankedIds.has(m.id) || rankedTitles.has(m.title.toLowerCase()),
        [rankedIds, rankedTitles],
    );

    // ── Load existing rankings on mount ─────────────────────────────────────────

    useEffect(() => {
        if (!user) return;
        setSessionId(globalThis.crypto?.randomUUID ? crypto.randomUUID() : Math.random().toString(36).substring(2));
        (async () => {
            const { data } = await supabase
                .from('user_rankings')
                .select('*')
                .eq('user_id', user.id)
                .order('tier')
                .order('rank_position');
            if (data) {
                setRankedItems(data.map((row: any): RankedItem => ({
                    id: row.tmdb_id,
                    title: row.title,
                    year: row.year ?? '',
                    posterUrl: row.poster_url ?? '',
                    type: row.type as MediaType,
                    genres: row.genres ?? [],
                    director: row.director,
                    tier: row.tier as Tier,
                    rank: row.rank_position,
                    bracket: row.bracket as Bracket,
                    notes: row.notes,
                })));
            }
            setLoading(false);
        })();
    }, [user]);

    // Redirect if already at threshold
    useEffect(() => {
        if (!loading && rankedItems.length >= REQUIRED_MOVIES) {
            navigate('/app', { replace: true });
        }
    }, [loading, rankedItems.length, navigate]);

    // ── Suggestions loading ─────────────────────────────────────────────────────

    const getExcludeIds = useCallback(() => rankedIds, [rankedIds]);
    const getExcludeTitles = useCallback(() => rankedTitles, [rankedTitles]);

    const getTopGenres = useCallback(() => {
        const counts = new Map<string, number>();
        for (const item of rankedItems) {
            for (const g of item.genres) {
                counts.set(g, (counts.get(g) ?? 0) + 1);
            }
        }
        return [...counts.entries()]
            .sort((a, b) => b[1] - a[1])
            .slice(0, 3)
            .map(([name]) => name);
    }, [rankedItems]);

    const prefetchBackfill = useCallback((page?: number) => {
        const p = page ?? backfillPageRef.current;
        getEditorsChoiceFills(getExcludeIds(), p, getExcludeTitles()).then(results => {
            backfillPoolRef.current = results;
        });
    }, [getExcludeIds, getExcludeTitles]);

    const loadSuggestions = useCallback((page: number, clicks: number) => {
        if (!hasTmdbKey()) return;
        setSuggestionsLoading(true);
        const topGenres = getTopGenres();
        getDynamicSuggestions(topGenres, getExcludeIds(), page, getExcludeTitles(), clicks).then(results => {
            setSuggestions(results);
            setSuggestionsLoading(false);
        });
        backfillPageRef.current = 1;
        backfillPoolRef.current = [];
        prefetchBackfill(1);
    }, [getExcludeIds, getExcludeTitles, prefetchBackfill, getTopGenres]);

    useEffect(() => {
        if (!loading) {
            const now = Date.now();
            let clickCount = sessionClickCount;
            if (now - sessionStartTime > 30 * 60 * 1000) {
                setSessionStartTime(now);
                setSessionClickCount(1);
                clickCount = 1;
            } else {
                setSessionClickCount(c => c + 1);
                clickCount += 1;
            }
            suggestionPageRef.current = 1;
            loadSuggestions(1, clickCount);
        }
    }, [loading]); // eslint-disable-line react-hooks/exhaustive-deps

    const handleRefresh = () => {
        suggestionPageRef.current += 1;
        loadSuggestions(suggestionPageRef.current, sessionClickCount);
    };

    const consumeSuggestion = (movieId: string) => {
        setSuggestions(prev => {
            const without = prev.filter(m => m.id !== movieId);
            if (backfillPoolRef.current.length > 0) {
                const existingIds = new Set(without.map(m => m.id));
                let fill: TMDBMovie | undefined;
                while (backfillPoolRef.current.length > 0) {
                    const candidate = backfillPoolRef.current.shift()!;
                    if (!existingIds.has(candidate.id)) { fill = candidate; break; }
                }
                if (fill) without.push(fill);
                if (backfillPoolRef.current.length < 3) {
                    backfillPageRef.current += 1;
                    prefetchBackfill(backfillPageRef.current);
                }
            }
            return without;
        });
    };

    // ── Search ──────────────────────────────────────────────────────────────────

    useEffect(() => {
        if (debounceRef.current) clearTimeout(debounceRef.current);
        const q = searchTerm.trim();
        if (!q) { setSearchResults([]); setPersonProfiles([]); setIsSearching(false); return; }
        setIsSearching(true);
        debounceRef.current = setTimeout(async () => {
            const [tmdb, people] = await Promise.all([
                searchMovies(q, 4500),
                searchPeople(q, 4500),
            ]);
            setSearchResults(mergeAndDedup(tmdb));
            setPersonProfiles(people);
            setIsSearching(false);
        }, 350);
        return () => { if (debounceRef.current) clearTimeout(debounceRef.current); };
    }, [searchTerm]);

    const handleOpenPerson = async (person: PersonProfile) => {
        setPersonLoading(true);
        const detail = await getPersonFilmography(person.id, person.role);
        setSelectedPerson(detail);
        setPersonLoading(false);
    };

    // ── Add item ────────────────────────────────────────────────────────────────

    const handleSelectMovie = async (movie: TMDBMovie, isSuggestion: boolean) => {
        if (isSuggestion) consumeSuggestion(movie.id);

        setIsRatingFetching(true);
        const globalScore = await getMovieGlobalScore(movie.tmdbId);
        setIsRatingFetching(false);
        setPendingGlobalScore(globalScore);

        setPendingMovie(movie);
        setFromSuggestion(isSuggestion);
        setModalStep('tier');
        setSelectedTier(null);
        setCompHistory([]);
        setCompSeed(null);
    };

    const getTierItems = (tier: Tier) =>
        rankedItems.filter(i => i.tier === tier).sort((a, b) => a.rank - b.rank);

    const handlePickTier = (tier: Tier) => {
        if (!pendingMovie || !user) return;
        setSelectedTier(tier);

        const tierItems = getTierItems(tier);
        if (tierItems.length === 0 || rankedItems.length < 5) {
            // No existing items OR still in first 5 movies — insert immediately
            finishInsert(tier, Math.floor(tierItems.length / 2));
        } else {
            // Spool adaptive seeding
            const range = TIER_SCORE_RANGES[tier];
            const tierItemScores = tierItems.map((_, idx) => computeTierScore(idx, tierItems.length, range.min, range.max));
            const seedIdx = computeSeedIndex(tierItemScores, range.min, range.max, pendingGlobalScore);

            setCompLow(0);
            setCompHigh(tierItems.length);
            setCompHistory([]);
            setCompSeed(seedIdx);
            setModalStep('compare');
        }
    };

    const handleCompareChoice = async (choice: 'new' | 'existing' | 'skip') => {
        if (!selectedTier || !pendingMovie) return;
        const tierItems = getTierItems(selectedTier);
        const mid = Math.floor((compLow + compHigh) / 2);

        // Log comparison
        const pivotItem = tierItems[mid];
        if (pivotItem && user) {
            try {
                await supabase.from('comparison_logs').insert({
                    user_id: user.id,
                    session_id: sessionId,
                    movie_a_tmdb_id: pendingMovie.id,
                    movie_b_tmdb_id: pivotItem.id,
                    winner: choice === 'new' ? 'a' : choice === 'existing' ? 'b' : 'skip',
                    round: compHistory.length + 1,
                });
            } catch (err) {
                console.error('Failed to log comparison:', err);
            }
        }

        if (choice === 'skip') {
            finishInsert(selectedTier, mid);
            return;
        }

        setCompHistory(prev => [...prev, { low: compLow, high: compHigh }]);

        const result = adaptiveNarrow(compLow, compHigh, mid, choice);

        if (!result) {
            finishInsert(selectedTier, choice === 'new' ? mid : mid + 1);
        } else {
            setCompLow(result.newLow);
            setCompHigh(result.newHigh);
        }
    };

    const handleCompareUndo = () => {
        if (compHistory.length === 0) return;
        const prev = compHistory[compHistory.length - 1];
        setCompLow(prev.low);
        setCompHigh(prev.high);
        setCompHistory(h => h.slice(0, -1));
    };

    const finishInsert = async (tier: Tier, rankIndex: number) => {
        if (!pendingMovie || !user) return;

        if (fromSuggestion) consumeSuggestion(pendingMovie.id);

        const newItem: RankedItem = {
            id: pendingMovie.id,
            title: pendingMovie.title,
            year: pendingMovie.year,
            posterUrl: pendingMovie.posterUrl ?? '',
            type: 'movie',
            genres: pendingMovie.genres,
            tier,
            rank: rankIndex,
            bracket: classifyBracket(pendingMovie.genres),
            globalScore: pendingGlobalScore,
        };

        setRankedItems(prev => {
            const tierItems = prev.filter(i => i.tier === tier).sort((a, b) => a.rank - b.rank);
            const otherItems = prev.filter(i => i.tier !== tier);
            const newTierList = [...tierItems];
            newTierList.splice(rankIndex, 0, newItem);
            const updated = newTierList.map((item, idx) => ({ ...item, rank: idx }));
            return [...otherItems, ...updated];
        });
        setPendingMovie(null);

        const { error } = await supabase.from('user_rankings').upsert({
            user_id: user.id,
            tmdb_id: newItem.id,
            title: newItem.title,
            year: newItem.year,
            poster_url: newItem.posterUrl,
            type: newItem.type,
            genres: newItem.genres,
            director: null,
            tier: newItem.tier,
            rank_position: newItem.rank,
            bracket: newItem.bracket,
            notes: null,
            updated_at: new Date().toISOString(),
        }, { onConflict: 'user_id,tmdb_id' });

        if (error) {
            console.error("Failed to save ranking to Supabase:", error);
            alert(`Failed to save movie. Please ensure you have run the supabase_spool_ranking.sql migration in your Supabase dashboard.\n\nError: ${error.message}`);

            // Revert immediately if requested (optional)
            // But showing the alert is the critical fix to break the confusing loop.
        }

        await logRankingActivityEvent(
            user.id,
            {
                id: newItem.id,
                title: newItem.title,
                tier: newItem.tier,
                posterUrl: newItem.posterUrl,
                year: newItem.year,
            },
            'ranking_add',
        );
    };

    const handleContinue = () => {
        navigate('/app', { replace: true });
    };

    // ── Derived state ───────────────────────────────────────────────────────────

    const remaining = REQUIRED_MOVIES - rankedItems.length;
    const progress = Math.min(rankedItems.length / REQUIRED_MOVIES, 1);
    const filteredSearch = searchResults.filter(m => !isOwned(m));
    const filteredSuggestions = suggestions.filter(m => !isOwned(m));

    if (loading) {
        return (
            <div className="min-h-screen bg-zinc-950 flex items-center justify-center">
                <div className="w-8 h-8 border-2 border-indigo-500 border-t-transparent rounded-full animate-spin" />
            </div>
        );
    }

    // ── Render ──────────────────────────────────────────────────────────────────

    return (
        <div className="min-h-screen bg-zinc-950 text-zinc-100">
            {/* Tier picker modal */}
            {pendingMovie && (
                <div
                    className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm"
                    onClick={() => setPendingMovie(null)}
                >
                    <div
                        className="bg-zinc-950 border border-zinc-800 w-full max-w-sm rounded-2xl shadow-2xl overflow-hidden animate-fade-in"
                        onClick={e => e.stopPropagation()}
                    >
                        {/* Header */}
                        <div className="flex items-center justify-between p-4 border-b border-zinc-800 bg-zinc-900/50">
                            <div className="flex items-center gap-2">
                                {modalStep === 'compare' && (
                                    <button onClick={() => { setModalStep('tier'); setSelectedTier(null); }} className="text-zinc-400 hover:text-white transition-colors">
                                        <ArrowLeft size={18} />
                                    </button>
                                )}
                                <h3 className="text-lg font-bold">{modalStep === 'tier' ? 'Assign Tier' : 'Head-to-Head'}</h3>
                            </div>
                            <button onClick={() => setPendingMovie(null)} className="text-zinc-400 hover:text-white transition-colors">
                                <X size={20} />
                            </button>
                        </div>

                        {modalStep === 'tier' && (
                            <>
                                {/* Movie preview */}
                                <div className="flex items-center gap-3 p-4 bg-zinc-800/30">
                                    {pendingMovie.posterUrl ? (
                                        <img src={pendingMovie.posterUrl} alt="" className="w-12 h-[72px] object-cover rounded-lg shadow-md flex-shrink-0" />
                                    ) : (
                                        <div className="w-12 h-[72px] bg-zinc-800 rounded-lg flex items-center justify-center flex-shrink-0">
                                            <Film size={18} className="text-zinc-600" />
                                        </div>
                                    )}
                                    <div>
                                        <p className="font-bold text-white leading-tight">{pendingMovie.title}</p>
                                        <p className="text-zinc-500 text-xs mt-0.5">{pendingMovie.year}</p>
                                    </div>
                                </div>

                                {/* Tier buttons */}
                                <div className="p-4 space-y-2">
                                    {TIERS.map(tier => (
                                        <button
                                            key={tier}
                                            onClick={() => handlePickTier(tier)}
                                            className={`flex items-center justify-between w-full p-3 rounded-xl border-2 transition-all hover:scale-[1.02] active:scale-[0.98] ${TIER_COLORS[tier]}`}
                                        >
                                            <div className="flex items-center gap-3">
                                                <span className="text-xl font-black">{tier}</span>
                                                <span className="font-semibold opacity-90 text-sm">{TIER_LABELS[tier]}</span>
                                            </div>
                                            <span className="text-xs font-mono opacity-50 bg-black/20 px-2 py-0.5 rounded">
                                                {rankedItems.filter(i => i.tier === tier).length}
                                            </span>
                                        </button>
                                    ))}
                                </div>
                            </>
                        )}

                        {modalStep === 'compare' && selectedTier && (() => {
                            const tierItems = getTierItems(selectedTier);
                            const mid = Math.floor((compLow + compHigh) / 2);
                            const pivotItem = tierItems[mid];
                            const totalRounds = Math.ceil(Math.log2(tierItems.length + 1));
                            const currentRound = compHistory.length + 1;

                            return (
                                <div className="p-4 space-y-4 animate-fade-in">
                                    {/* Progress */}
                                    <div className="flex items-center justify-between">
                                        <p className="text-zinc-400 text-xs">
                                            Round <span className="text-white font-semibold">{currentRound}</span>
                                            {' '}of ~<span className="text-white font-semibold">{totalRounds}</span>
                                        </p>
                                        <div className="flex gap-1">
                                            {Array.from({ length: totalRounds }).map((_, i) => (
                                                <div
                                                    key={i}
                                                    className={`h-1.5 w-4 rounded-full transition-colors ${i < compHistory.length ? 'bg-indigo-500' : i === compHistory.length ? 'bg-zinc-500' : 'bg-zinc-800'
                                                        }`}
                                                />
                                            ))}
                                        </div>
                                    </div>

                                    <h4 className="text-center text-sm font-bold text-white">Which do you prefer?</h4>

                                    {/* Head-to-head */}
                                    <div className="flex items-stretch gap-2">
                                        {/* New item */}
                                        <button
                                            onClick={() => handleCompareChoice('new')}
                                            className="flex-1 flex flex-col items-center gap-2 p-2 rounded-xl border-2 border-zinc-700 hover:border-indigo-500 hover:bg-indigo-500/5 transition-all active:scale-[0.97]"
                                        >
                                            <img
                                                src={pendingMovie.posterUrl ?? ''}
                                                alt={pendingMovie.title}
                                                className="w-full aspect-[2/3] object-cover rounded-lg shadow-lg"
                                            />
                                            <p className="font-bold text-white text-xs leading-tight text-center">{pendingMovie.title}</p>
                                            <span className="text-[10px] text-indigo-400 font-semibold border border-indigo-500/30 bg-indigo-500/10 px-2 py-0.5 rounded-full">NEW</span>
                                        </button>

                                        {/* OR divider */}
                                        <div className="flex items-center justify-center flex-shrink-0">
                                            <div className="w-7 h-7 rounded-full bg-zinc-800 border border-zinc-700 flex items-center justify-center text-[10px] font-black text-zinc-400">
                                                OR
                                            </div>
                                        </div>

                                        {/* Pivot item */}
                                        <button
                                            onClick={() => handleCompareChoice('existing')}
                                            className="flex-1 flex flex-col items-center gap-2 p-2 rounded-xl border-2 border-zinc-700 hover:border-zinc-400 hover:bg-zinc-400/5 transition-all active:scale-[0.97]"
                                        >
                                            <img
                                                src={pivotItem?.posterUrl ?? ''}
                                                alt={pivotItem?.title}
                                                className="w-full aspect-[2/3] object-cover rounded-lg shadow-lg"
                                            />
                                            <p className="font-bold text-white text-xs leading-tight text-center">{pivotItem?.title}</p>
                                            <span className={`text-[10px] font-semibold px-2 py-0.5 rounded-full border ${TIER_COLORS[selectedTier]}`}>
                                                {selectedTier} · #{mid + 1}
                                            </span>
                                        </button>
                                    </div>

                                    {/* Actions */}
                                    <div className="flex items-center justify-between">
                                        <button
                                            onClick={handleCompareUndo}
                                            disabled={compHistory.length === 0}
                                            className="flex items-center gap-1 text-xs font-medium text-zinc-400 hover:text-white disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
                                        >
                                            <ArrowLeft size={13} />
                                            Undo
                                        </button>
                                        <button
                                            onClick={() => handleCompareChoice('skip')}
                                            className="px-3 py-1.5 rounded-full border border-zinc-700 text-xs font-semibold text-zinc-300 hover:bg-zinc-800 hover:border-zinc-500 transition-all"
                                        >
                                            Too tough — place here
                                        </button>
                                    </div>
                                </div>
                            );
                        })()}
                    </div>
                </div>
            )}

            <main className="max-w-2xl mx-auto px-4 py-10 space-y-6">
                {/* Header */}
                <div className="space-y-2">
                    <p className="text-xs uppercase tracking-[0.2em] text-indigo-300">Step 2 of 2</p>
                    <h1 className="text-3xl font-bold">Build your Marquee</h1>
                    <p className="text-zinc-400 text-sm">
                        Pick at least <span className="text-white font-semibold">{REQUIRED_MOVIES} movies</span> you've seen
                        to seed your rankings. You can adjust and fine-tune everything later.
                    </p>
                </div>

                {/* Progress bar */}
                <div className="space-y-2">
                    <div className="flex items-center justify-between text-sm">
                        <span className="text-zinc-400">
                            <span className="text-white font-bold">{rankedItems.length}</span> / {REQUIRED_MOVIES} movies
                        </span>
                        {remaining > 0 ? (
                            <span className="text-zinc-500">{remaining} more to go</span>
                        ) : (
                            <span className="text-emerald-400 font-semibold flex items-center gap-1">
                                <Check size={14} /> Ready!
                            </span>
                        )}
                    </div>
                    <div className="h-2 bg-zinc-800 rounded-full overflow-hidden">
                        <div
                            className="h-full rounded-full transition-all duration-500 ease-out"
                            style={{
                                width: `${progress * 100}%`,
                                background: progress >= 1
                                    ? 'linear-gradient(90deg, #34d399, #10b981)'
                                    : 'linear-gradient(90deg, #818cf8, #6366f1)',
                            }}
                        />
                    </div>
                </div>

                {/* Continue button (only when threshold met) */}
                {rankedItems.length >= REQUIRED_MOVIES && (
                    <button
                        onClick={handleContinue}
                        className="w-full flex items-center justify-center gap-2 py-3 rounded-xl bg-emerald-500 text-black font-bold text-sm hover:bg-emerald-400 transition-colors shadow-lg shadow-emerald-500/20 animate-fade-in"
                    >
                        Continue to Marquee
                        <ChevronRight size={16} />
                    </button>
                )}

                {/* Search */}
                <div className="relative">
                    <Search className="absolute left-3 top-3.5 text-zinc-500" size={18} />
                    <input
                        type="text"
                        placeholder="Search by title, director, or actor..."
                        className="w-full bg-zinc-900 border border-zinc-800 rounded-xl py-3 pl-10 pr-4 text-white placeholder-zinc-500 focus:outline-none focus:border-indigo-500 transition-colors"
                        value={searchTerm}
                        onChange={e => setSearchTerm(e.target.value)}
                    />
                    {isSearching && <Loader2 className="absolute right-3 top-3.5 text-zinc-500 animate-spin" size={18} />}
                </div>

                {/* Search results */}
                {searchTerm.trim() && !selectedPerson && (
                    <div className="space-y-3">
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
                        {!isSearching && personProfiles.length > 0 && (
                            <div className="space-y-1">
                                <p className="text-xs font-semibold text-zinc-500 uppercase tracking-wider px-1">People</p>
                                {personProfiles.map(person => (
                                    <button
                                        key={person.id}
                                        onClick={() => handleOpenPerson(person)}
                                        className="flex items-center gap-3 p-2.5 rounded-xl hover:bg-zinc-800/80 transition-colors w-full text-left"
                                    >
                                        {person.photoUrl ? (
                                            <img src={person.photoUrl} alt={person.name} className="w-11 h-11 object-cover rounded-full bg-zinc-800 flex-shrink-0 shadow-md" />
                                        ) : (
                                            <div className="w-11 h-11 bg-zinc-800 rounded-full flex items-center justify-center flex-shrink-0 text-zinc-600 text-lg font-bold">
                                                {person.name.charAt(0)}
                                            </div>
                                        )}
                                        <div className="flex-1 min-w-0">
                                            <div className="flex items-center gap-2">
                                                <p className="font-semibold text-white truncate">{person.name}</p>
                                                <span className={`text-[10px] px-1.5 py-0.5 rounded-full font-medium flex-shrink-0 ${person.role === 'Director' ? 'bg-amber-500/15 text-amber-400' : 'bg-indigo-500/15 text-indigo-400'}`}>
                                                    {person.role}
                                                </span>
                                            </div>
                                            {person.knownFor.length > 0 && (
                                                <p className="text-xs text-zinc-500 mt-0.5 truncate">Known for: {person.knownFor.join(', ')}</p>
                                            )}
                                        </div>
                                        <ChevronRight size={16} className="text-zinc-600 flex-shrink-0" />
                                    </button>
                                ))}
                            </div>
                        )}

                        {/* Movie title results */}
                        {!isSearching && filteredSearch.length > 0 && (
                            <div className="space-y-1">
                                {personProfiles.length > 0 && (
                                    <p className="text-xs font-semibold text-zinc-500 uppercase tracking-wider px-1 pt-1">Movies</p>
                                )}
                                {filteredSearch.map(movie => (
                                    <button
                                        key={movie.id}
                                        onClick={() => handleSelectMovie(movie, false)}
                                        className="flex items-center gap-3 p-2 rounded-xl hover:bg-zinc-800/80 transition-colors w-full text-left"
                                    >
                                        {movie.posterUrl ? (
                                            <img src={movie.posterUrl} alt={movie.title} className="w-12 h-[72px] object-cover rounded-lg bg-zinc-800 flex-shrink-0 shadow-md" />
                                        ) : (
                                            <div className="w-12 h-[72px] bg-zinc-800 rounded-lg flex items-center justify-center flex-shrink-0">
                                                <Film size={20} className="text-zinc-600" />
                                            </div>
                                        )}
                                        <div className="flex-1 min-w-0">
                                            <p className="font-semibold text-white truncate">{movie.title}</p>
                                            <p className="text-xs text-zinc-500 mt-0.5">{movie.year}</p>
                                            {movie.genres.length > 0 && (
                                                <div className="flex gap-1 mt-1 flex-wrap">
                                                    {movie.genres.map(g => (
                                                        <span key={g} className="text-[10px] px-1.5 py-0.5 bg-zinc-800 text-zinc-400 rounded-full border border-zinc-700">{g}</span>
                                                    ))}
                                                </div>
                                            )}
                                        </div>
                                    </button>
                                ))}
                            </div>
                        )}

                        {/* Empty state */}
                        {!isSearching && searchTerm.trim() && filteredSearch.length === 0 && personProfiles.length === 0 && (
                            <div className="text-center py-8 text-zinc-500 text-sm">
                                <Film size={28} className="mx-auto mb-2 opacity-30" />
                                <p>No results for "{searchTerm}"</p>
                            </div>
                        )}
                    </div>
                )}

                {/* Person profile card */}
                {selectedPerson && (
                    <div className="space-y-4 animate-fade-in">
                        <button
                            onClick={() => setSelectedPerson(null)}
                            className="flex items-center gap-1 text-sm text-zinc-400 hover:text-white transition-colors"
                        >
                            <ArrowLeft size={16} />
                            Back to search
                        </button>

                        {/* Person header */}
                        <div className="flex items-start gap-4 p-4 bg-zinc-900/80 rounded-2xl border border-zinc-800">
                            {selectedPerson.photoUrl ? (
                                <img
                                    src={selectedPerson.photoUrl}
                                    alt={selectedPerson.name}
                                    className="w-20 h-20 object-cover rounded-xl shadow-lg flex-shrink-0"
                                />
                            ) : (
                                <div className="w-20 h-20 bg-zinc-800 rounded-xl flex items-center justify-center flex-shrink-0 text-3xl font-bold text-zinc-600">
                                    {selectedPerson.name.charAt(0)}
                                </div>
                            )}
                            <div className="flex-1 min-w-0">
                                <div className="flex items-center gap-2">
                                    <h2 className="text-xl font-bold text-white">{selectedPerson.name}</h2>
                                    <span className={`text-[10px] px-1.5 py-0.5 rounded-full font-medium ${selectedPerson.role === 'Director' ? 'bg-amber-500/15 text-amber-400' : 'bg-indigo-500/15 text-indigo-400'}`}>
                                        {selectedPerson.role}
                                    </span>
                                </div>
                                <p className="text-xs text-zinc-500 mt-0.5">
                                    {selectedPerson.placeOfBirth && <span>{selectedPerson.placeOfBirth}</span>}
                                    {selectedPerson.birthday && <span> · Born {selectedPerson.birthday}</span>}
                                </p>
                                <p className="text-sm text-indigo-400 font-semibold mt-1">
                                    {selectedPerson.movies.length} {selectedPerson.movies.length === 1 ? 'film' : 'films'} {selectedPerson.role === 'Director' ? 'directed' : 'starred in'}
                                </p>
                            </div>
                        </div>

                        {/* Bio */}
                        {selectedPerson.biography && (
                            <p className="text-xs text-zinc-400 leading-relaxed line-clamp-4">
                                {selectedPerson.biography}
                            </p>
                        )}

                        {/* Filmography grid */}
                        <div>
                            <p className="text-xs font-semibold text-zinc-500 uppercase tracking-wider mb-3">Filmography</p>
                            <div className="grid grid-cols-3 sm:grid-cols-4 gap-3">
                                {selectedPerson.movies.filter(m => !isOwned(m)).map(movie => (
                                    <button
                                        key={movie.id}
                                        onClick={() => handleSelectMovie(movie, false)}
                                        className="group flex flex-col items-center text-center rounded-xl hover:bg-zinc-800/60 p-1.5 transition-colors"
                                    >
                                        <img
                                            src={movie.posterUrl!}
                                            alt={movie.title}
                                            className="w-full aspect-[2/3] object-cover rounded-lg bg-zinc-800 shadow-md group-hover:shadow-lg group-hover:scale-[1.03] transition-all"
                                        />
                                        <p className="text-[11px] font-medium text-zinc-300 mt-1.5 leading-tight line-clamp-2 group-hover:text-white transition-colors">
                                            {movie.title}
                                        </p>
                                        <p className="text-[10px] text-zinc-600">{movie.year}</p>
                                    </button>
                                ))}
                            </div>
                            {selectedPerson.movies.filter(m => !isOwned(m)).length === 0 && (
                                <p className="text-center py-6 text-zinc-500 text-sm">All movies already ranked!</p>
                            )}
                        </div>
                    </div>
                )}

                {/* Person loading */}
                {personLoading && (
                    <div className="flex items-center justify-center py-12">
                        <Loader2 className="w-6 h-6 text-indigo-500 animate-spin" />
                    </div>
                )}

                {/* Suggestions grid (when not searching) */}
                {!searchTerm.trim() && (
                    <section className="space-y-3">
                        <div className="flex items-center justify-between px-1">
                            <p className="text-xs font-semibold text-zinc-500 uppercase tracking-wider">Suggested movies</p>
                            <button
                                onClick={handleRefresh}
                                className="flex items-center gap-1 text-[10px] font-semibold text-zinc-600 hover:text-zinc-300 transition-colors px-2 py-1 rounded-lg hover:bg-zinc-800"
                            >
                                <RefreshCw size={11} />
                                Refresh
                            </button>
                        </div>

                        {suggestionsLoading ? (
                            <div className="grid grid-cols-3 sm:grid-cols-4 gap-3">
                                {[1, 2, 3, 4, 5, 6, 7, 8].map(i => (
                                    <div key={i} className="animate-pulse">
                                        <div className="w-full aspect-[2/3] bg-zinc-800 rounded-lg" />
                                        <div className="h-3 bg-zinc-800 rounded mt-2 w-3/4 mx-auto" />
                                    </div>
                                ))}
                            </div>
                        ) : (
                            <div className="grid grid-cols-3 sm:grid-cols-4 gap-3">
                                {filteredSuggestions.map(movie => (
                                    <button
                                        key={movie.id}
                                        onClick={() => handleSelectMovie(movie, true)}
                                        className="group flex flex-col items-center text-center rounded-xl hover:bg-zinc-800/60 p-2 transition-colors"
                                    >
                                        <img
                                            src={movie.posterUrl!}
                                            alt={movie.title}
                                            className="w-full aspect-[2/3] object-cover rounded-lg bg-zinc-800 shadow-md group-hover:shadow-lg transition-shadow"
                                        />
                                        <p className="text-xs font-medium text-zinc-300 mt-2 leading-tight line-clamp-2 group-hover:text-white transition-colors">
                                            {movie.title}
                                        </p>
                                        <p className="text-[10px] text-zinc-600 mt-0.5">{movie.year}</p>
                                    </button>
                                ))}
                            </div>
                        )}
                    </section>
                )}

                {/* Selected movies summary */}
                {rankedItems.length > 0 && (
                    <section className="space-y-3 pt-4 border-t border-zinc-800">
                        <h3 className="text-sm font-semibold text-zinc-400">Your picks so far</h3>
                        <div className="flex flex-wrap gap-2">
                            {rankedItems.map(item => (
                                <div
                                    key={item.id}
                                    className={`flex items-center gap-2 px-2.5 py-1.5 rounded-lg border text-xs font-semibold ${TIER_COLORS[item.tier]}`}
                                >
                                    <span>{item.tier}</span>
                                    <span className="text-white opacity-80 truncate max-w-[120px]">{item.title}</span>
                                </div>
                            ))}
                        </div>
                    </section>
                )}
            </main>
        </div>
    );
};

export default MovieOnboardingPage;
