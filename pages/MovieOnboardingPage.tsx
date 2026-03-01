import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { ArrowLeft, Check, ChevronRight, Film, Loader2, RefreshCw, Search, X } from 'lucide-react';
import { RankedItem, Tier, MediaType, Bracket } from '../types';
import { TIER_COLORS, TIER_LABELS, TIERS, MIN_MOVIES_FOR_SCORES } from '../constants';
import { getSmartSuggestions, getSmartBackfill, buildTasteProfile, hasTmdbKey, searchMovies, searchPeople, getPersonFilmography, getMovieGlobalScore, TMDBMovie, PersonProfile, PersonDetail } from '../services/tmdbService';
import { classifyBracket } from '../services/rankingAlgorithm';
import { SpoolRankingEngine } from '../services/spoolRankingEngine';
import { computePredictionSignals } from '../services/spoolPrediction';
import { ComparisonRequest } from '../types';
import { supabase } from '../lib/supabase';
import { useAuth } from '../contexts/AuthContext';
import { logRankingActivityEvent } from '../services/friendsService';

const REQUIRED_MOVIES = MIN_MOVIES_FOR_SCORES;
const ONBOARDING_STORAGE_KEY = 'spool_onboarding_picks';

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
    const engineRef = useRef<SpoolRankingEngine | null>(null);
    const [currentComparison, setCurrentComparison] = useState<ComparisonRequest | null>(null);
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
        setSessionId(globalThis.crypto?.randomUUID ? crypto.randomUUID() : Math.random().toString(36).substring(2));

        if (user) {
            // Authenticated: load from Supabase
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
                        bracket: (row.bracket as Bracket) ?? classifyBracket(row.genres ?? []),
                        notes: row.notes,
                    })));
                }
                setLoading(false);
            })();
        } else {
            // Anonymous: load from localStorage
            try {
                const stored = JSON.parse(localStorage.getItem(ONBOARDING_STORAGE_KEY) || '[]');
                if (stored.length > 0) setRankedItems(stored);
            } catch { /* ignore */ }
            setLoading(false);
        }
    }, [user]);

    // Redirect if already at threshold
    useEffect(() => {
        if (!loading && rankedItems.length >= REQUIRED_MOVIES) {
            navigate(user ? '/app' : '/auth', { replace: true });
        }
    }, [loading, rankedItems.length, navigate, user]);

    // ── Suggestions loading ─────────────────────────────────────────────────────

    const getExcludeIds = useCallback(() => rankedIds, [rankedIds]);
    const getExcludeTitles = useCallback(() => rankedTitles, [rankedTitles]);

    const prefetchBackfill = useCallback((page?: number) => {
        const p = page ?? backfillPageRef.current;
        const profile = buildTasteProfile(rankedItems);
        getSmartBackfill(profile, getExcludeIds(), p, getExcludeTitles()).then(results => {
            backfillPoolRef.current = results;
        });
    }, [getExcludeIds, getExcludeTitles, rankedItems]);

    const loadSuggestions = useCallback((page: number) => {
        if (!hasTmdbKey()) return;
        setSuggestionsLoading(true);
        const profile = buildTasteProfile(rankedItems);
        getSmartSuggestions(profile, getExcludeIds(), page, getExcludeTitles(), user?.id ?? undefined).then(results => {
            setSuggestions(results);
            setSuggestionsLoading(false);
        });
        backfillPageRef.current = 1;
        backfillPoolRef.current = [];
        prefetchBackfill(1);
    }, [getExcludeIds, getExcludeTitles, prefetchBackfill, rankedItems, user?.id]);

    useEffect(() => {
        if (!loading) {
            suggestionPageRef.current = 1;
            loadSuggestions(1);
        }
    }, [loading]); // eslint-disable-line react-hooks/exhaustive-deps

    const handleRefresh = () => {
        suggestionPageRef.current += 1;
        loadSuggestions(suggestionPageRef.current);
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
        engineRef.current = null;
        setCurrentComparison(null);
    };

    const getTierItems = (tier: Tier) =>
        rankedItems.filter(i => i.tier === tier).sort((a, b) => a.rank - b.rank);

    const handlePickTier = (tier: Tier) => {
        if (!pendingMovie) return;
        setSelectedTier(tier);

        const tierItems = getTierItems(tier);
        if (tierItems.length === 0 || rankedItems.length < 5) {
            // No existing items OR still in first 5 movies — insert immediately
            finishInsert(tier, Math.floor(tierItems.length / 2));
        } else {
            const engine = new SpoolRankingEngine();
            const signals = computePredictionSignals(
                rankedItems,
                pendingMovie.genres[0] ?? '',
                classifyBracket(pendingMovie.genres),
                pendingGlobalScore,
                tier,
            );
            const newItem: RankedItem = {
                id: pendingMovie.id, title: pendingMovie.title, year: pendingMovie.year,
                posterUrl: pendingMovie.posterUrl ?? '', type: 'movie',
                genres: pendingMovie.genres, tier, rank: 0,
                bracket: classifyBracket(pendingMovie.genres), globalScore: pendingGlobalScore,
            };
            const result = engine.start(newItem, tier, rankedItems, signals);
            engineRef.current = engine;

            if (result.type === 'done') {
                finishInsert(tier, result.finalRank!);
            } else {
                setCurrentComparison(result.comparison!);
                setModalStep('compare');
            }
        }
    };

    const handleCompareChoice = async (choice: 'new' | 'existing' | 'skip') => {
        if (!selectedTier || !pendingMovie || !engineRef.current || !currentComparison) return;

        // Log comparison
        if (user) {
            try {
                await supabase.from('comparison_logs').insert({
                    user_id: user.id,
                    session_id: sessionId,
                    movie_a_tmdb_id: currentComparison.movieA.id,
                    movie_b_tmdb_id: currentComparison.movieB.id,
                    winner: choice === 'new' ? 'a' : choice === 'existing' ? 'b' : 'skip',
                    round: currentComparison.round,
                    phase: currentComparison.phase,
                    question_text: currentComparison.question,
                });
            } catch (err) {
                console.error('Failed to log comparison:', err);
            }
        }

        if (choice === 'skip') {
            const result = engineRef.current.skip();
            finishInsert(selectedTier, result.finalRank!);
            return;
        }

        const winnerId = choice === 'new'
            ? currentComparison.movieA.id
            : currentComparison.movieB.id;
        const result = engineRef.current.submitChoice(winnerId);

        if (result.type === 'done') {
            finishInsert(selectedTier, result.finalRank!);
        } else {
            setCurrentComparison(result.comparison!);
        }
    };

    const handleCompareUndo = () => {
        if (!engineRef.current) return;
        const result = engineRef.current.undo();
        if (result && result.comparison) {
            setCurrentComparison(result.comparison);
        }
    };

    const finishInsert = async (tier: Tier, rankIndex: number) => {
        if (!pendingMovie) return;

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

        let updatedTierList: RankedItem[] = [];

        setRankedItems(prev => {
            const tierItems = prev.filter(i => i.tier === tier).sort((a, b) => a.rank - b.rank);
            const otherItems = prev.filter(i => i.tier !== tier);
            const newTierList = [...tierItems];
            newTierList.splice(rankIndex, 0, newItem);
            updatedTierList = newTierList.map((item, idx) => ({ ...item, rank: idx }));
            const result = [...otherItems, ...updatedTierList];

            // Always persist to localStorage during onboarding
            localStorage.setItem(ONBOARDING_STORAGE_KEY, JSON.stringify(result));

            return result;
        });
        setPendingMovie(null);

        // Only save to Supabase + log activity if authenticated
        if (user && updatedTierList.length > 0) {
            const rowsToUpdate = updatedTierList.map(item => ({
                user_id: user.id,
                tmdb_id: item.id,
                title: item.title,
                year: item.year,
                poster_url: item.posterUrl,
                type: item.type,
                genres: item.genres,
                director: null,
                tier: item.tier,
                rank_position: item.rank,
                bracket: item.bracket,
                primary_genre: item.genres[0] ?? null,
                notes: null,
                updated_at: new Date().toISOString(),
            }));

            const { error } = await supabase.from('user_rankings').upsert(rowsToUpdate, { onConflict: 'user_id,tmdb_id' });

            if (error) {
                console.error("Failed to save ranking to Supabase:", error);
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
        }
    };

    const handleContinue = () => {
        navigate(user ? '/app' : '/auth', { replace: true });
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

                        {modalStep === 'compare' && selectedTier && currentComparison && (
                                <div className="p-4 space-y-4 animate-fade-in">
                                    {/* Phase indicator */}
                                    <div className="flex items-center justify-center">
                                        <span className="text-[10px] font-mono uppercase tracking-widest text-zinc-500 bg-zinc-800/50 px-2 py-0.5 rounded">
                                            {currentComparison.phase.replace('_', '-')}
                                        </span>
                                    </div>

                                    <h4 className="text-center text-sm font-bold text-white">{currentComparison.question}</h4>

                                    {/* Head-to-head */}
                                    <div className="flex items-stretch gap-2">
                                        {/* New item (movieA) */}
                                        <button
                                            onClick={() => handleCompareChoice('new')}
                                            className="flex-1 flex flex-col items-center gap-2 p-2 rounded-xl border-2 border-zinc-700 hover:border-indigo-500 hover:bg-indigo-500/5 transition-all active:scale-[0.97]"
                                        >
                                            <img
                                                src={currentComparison.movieA.posterUrl ?? ''}
                                                alt={currentComparison.movieA.title}
                                                className="w-full aspect-[2/3] object-cover rounded-lg shadow-lg"
                                            />
                                            <p className="font-bold text-white text-xs leading-tight text-center">{currentComparison.movieA.title}</p>
                                            <span className="text-[10px] text-indigo-400 font-semibold border border-indigo-500/30 bg-indigo-500/10 px-2 py-0.5 rounded-full">NEW</span>
                                        </button>

                                        {/* OR divider */}
                                        <div className="flex items-center justify-center flex-shrink-0">
                                            <div className="w-7 h-7 rounded-full bg-zinc-800 border border-zinc-700 flex items-center justify-center text-[10px] font-black text-zinc-400">
                                                OR
                                            </div>
                                        </div>

                                        {/* Existing item (movieB) */}
                                        <button
                                            onClick={() => handleCompareChoice('existing')}
                                            className="flex-1 flex flex-col items-center gap-2 p-2 rounded-xl border-2 border-zinc-700 hover:border-zinc-400 hover:bg-zinc-400/5 transition-all active:scale-[0.97]"
                                        >
                                            <img
                                                src={currentComparison.movieB.posterUrl ?? ''}
                                                alt={currentComparison.movieB.title}
                                                className="w-full aspect-[2/3] object-cover rounded-lg shadow-lg"
                                            />
                                            <p className="font-bold text-white text-xs leading-tight text-center">{currentComparison.movieB.title}</p>
                                            <span className={`text-[10px] font-semibold px-2 py-0.5 rounded-full border ${TIER_COLORS[selectedTier]}`}>
                                                {selectedTier}
                                            </span>
                                        </button>
                                    </div>

                                    {/* Actions */}
                                    <div className="flex items-center justify-between">
                                        <button
                                            onClick={handleCompareUndo}
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
                        )}
                    </div>
                </div>
            )}

            <main className="max-w-2xl mx-auto px-4 py-10 space-y-6">
                {/* Header */}
                <div className="space-y-2">
                    <p className="text-xs uppercase tracking-[0.2em] text-indigo-300">{user ? 'Step 2 of 2' : 'Get Started'}</p>
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
                        {user ? 'Continue to Marquee' : 'Create your account'}
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
