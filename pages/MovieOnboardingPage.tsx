import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { ArrowLeft, Check, ChevronRight, Film, Loader2, RefreshCw, Search, X } from 'lucide-react';
import { RankedItem, Tier, MediaType, Bracket } from '../types';
import { TIER_COLORS, TIER_LABELS, TIERS, MIN_MOVIES_FOR_SCORES, TIER_SCORE_RANGES } from '../constants';
import { getSmartSuggestions, getSmartBackfill, buildTasteProfile, hasTmdbKey, searchMovies, searchPeople, getPersonFilmography, getMovieGlobalScore, TMDBMovie, PersonProfile, PersonDetail } from '../services/tmdbService';
import { classifyBracket, computeSeedIndex, adaptiveNarrow, computeTierScore } from '../services/rankingAlgorithm';
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
    const isProcessingRef = useRef(false);
    const smallTierRef = useRef<{
        mode: 'compare_all' | 'seed' | 'quartile';
        tierItems: RankedItem[];
        low: number; high: number; mid: number;
        round: number; seedIdx: number;
    } | null>(null);
    const [currentComparison, setCurrentComparison] = useState<ComparisonRequest | null>(null);
    const [sessionId, setSessionId] = useState(() => crypto.randomUUID());
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
        setSessionId(crypto.randomUUID());

        // Always check localStorage first — anonymous picks may exist from before sign-up
        let localPicks: RankedItem[] = [];
        try {
            localPicks = JSON.parse(localStorage.getItem(ONBOARDING_STORAGE_KEY) || '[]');
        } catch { /* ignore */ }

        if (user) {
            // Authenticated: load from Supabase, merging any localStorage picks
            (async () => {
                const { data } = await supabase
                    .from('user_rankings')
                    .select('*')
                    .eq('user_id', user.id)
                    .order('tier')
                    .order('rank_position');

                const dbItems: RankedItem[] = (data ?? []).map((row: any): RankedItem => ({
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
                }));

                if (dbItems.length > 0) {
                    setRankedItems(dbItems);
                } else if (localPicks.length > 0) {
                    // New account with pre-signup picks: migrate to Supabase
                    setRankedItems(localPicks);
                    const rows = localPicks.map(item => ({
                        user_id: user.id,
                        tmdb_id: item.id,
                        title: item.title,
                        year: item.year,
                        poster_url: item.posterUrl,
                        type: item.type,
                        genres: item.genres,
                        director: item.director ?? null,
                        tier: item.tier,
                        rank_position: item.rank,
                        bracket: item.bracket,
                        primary_genre: item.genres[0] ?? null,
                        notes: item.notes ?? null,
                        updated_at: new Date().toISOString(),
                    }));
                    await supabase.from('user_rankings').upsert(rows, { onConflict: 'user_id,tmdb_id' });
                    localStorage.removeItem(ONBOARDING_STORAGE_KEY);
                }
                setLoading(false);
            })();
        } else {
            // Anonymous: load from localStorage
            if (localPicks.length > 0) setRankedItems(localPicks);
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
        const newItem: RankedItem = {
            id: pendingMovie.id, title: pendingMovie.title, year: pendingMovie.year,
            posterUrl: pendingMovie.posterUrl ?? '', type: 'movie',
            genres: pendingMovie.genres, tier, rank: 0,
            bracket: classifyBracket(pendingMovie.genres), globalScore: pendingGlobalScore,
        };

        if (tierItems.length === 0) {
            // Empty tier — insert at 0
            finishInsert(tier, 0);
        } else if (tierItems.length <= 5) {
            // 1-5 items — compare against every item (top to bottom)
            smallTierRef.current = { mode: 'compare_all', tierItems, low: 0, high: tierItems.length, mid: 0, round: 1, seedIdx: 0 };
            engineRef.current = null;
            setCurrentComparison({ movieA: newItem, movieB: tierItems[0], question: 'Which do you prefer?', round: 1, phase: 'binary_search' });
            setModalStep('compare');
        } else if (tierItems.length <= 20) {
            // 6-20 items — seed pivot then quartile narrowing
            const range = TIER_SCORE_RANGES[tier];
            const tierScores = tierItems.map((_, idx) => computeTierScore(idx, tierItems.length, range.min, range.max));
            const seedIdx = computeSeedIndex(tierScores, range.min, range.max, pendingGlobalScore);
            smallTierRef.current = { mode: 'seed', tierItems, low: 0, high: tierItems.length, mid: seedIdx, round: 1, seedIdx };
            engineRef.current = null;
            setCurrentComparison({ movieA: newItem, movieB: tierItems[seedIdx], question: 'Which do you prefer?', round: 1, phase: 'binary_search' });
            setModalStep('compare');
        } else {
            // Large tier — use genre-anchored SpoolRankingEngine
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
        if (!selectedTier || !pendingMovie || !currentComparison) return;
        if (!engineRef.current && !smallTierRef.current) return;
        if (isProcessingRef.current) return;
        isProcessingRef.current = true;

        try {
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

            // Small tier path (≤ 20 items)
            if (smallTierRef.current) {
                const st = smallTierRef.current;
                const movieA = currentComparison.movieA;

                if (choice === 'skip') {
                    smallTierRef.current = null;
                    finishInsert(selectedTier, st.mid);
                    return;
                }

                const nextRound = st.round + 1;
                const setNext = (mid: number, mode?: typeof st.mode, low?: number, high?: number) => {
                    smallTierRef.current = { ...st, mode: mode ?? st.mode, low: low ?? st.low, high: high ?? st.high, mid, round: nextRound };
                    setCurrentComparison({ movieA, movieB: st.tierItems[mid], question: 'Which do you prefer?', round: nextRound, phase: 'binary_search' });
                };
                const done = (rank: number) => { smallTierRef.current = null; finishInsert(selectedTier, rank); };

                if (st.mode === 'compare_all') {
                    if (choice === 'new') { done(st.mid); }
                    else if (st.mid + 1 >= st.tierItems.length) { done(st.tierItems.length); }
                    else { setNext(st.mid + 1); }
                } else if (st.mode === 'seed') {
                    if (choice === 'new') {
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
                    const newLow = choice === 'new' ? st.low : st.mid + 1;
                    const newHigh = choice === 'new' ? st.mid : st.high;
                    if (newLow >= newHigh) { done(newLow); }
                    else {
                        const ratio = choice === 'new' ? 0.25 : 0.75;
                        const nextMid = Math.max(newLow, Math.min(newLow + Math.floor((newHigh - newLow) * ratio), newHigh - 1));
                        setNext(nextMid, 'quartile', newLow, newHigh);
                    }
                }
                return;
            }

            // SpoolRankingEngine path (large tiers > 20)
            if (!engineRef.current) return;

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
        } finally {
            isProcessingRef.current = false;
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
            <div className="min-h-screen bg-background flex items-center justify-center">
                <div className="w-8 h-8 border-2 border-gold border-t-transparent rounded-full animate-spin" />
            </div>
        );
    }

    // ── Render ──────────────────────────────────────────────────────────────────

    return (
        <div className="min-h-screen bg-background text-foreground">
            {/* Tier picker modal */}
            {pendingMovie && (
                <div
                    className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/80 backdrop-blur-sm"
                    onClick={() => setPendingMovie(null)}
                >
                    <div
                        className="bg-background border border-border w-full max-w-sm rounded-2xl shadow-2xl overflow-hidden animate-fade-in"
                        onClick={e => e.stopPropagation()}
                    >
                        {/* Header */}
                        <div className="flex items-center justify-between p-4 border-b border-border bg-card/30">
                            <div className="flex items-center gap-2">
                                {modalStep === 'compare' && (
                                    <button onClick={() => { setModalStep('tier'); setSelectedTier(null); }} className="text-muted-foreground hover:text-foreground transition-colors">
                                        <ArrowLeft size={18} />
                                    </button>
                                )}
                                <h3 className="text-lg font-bold">{modalStep === 'tier' ? 'Assign Tier' : 'Head-to-Head'}</h3>
                            </div>
                            <button onClick={() => setPendingMovie(null)} className="text-muted-foreground hover:text-foreground transition-colors">
                                <X size={20} />
                            </button>
                        </div>

                        {modalStep === 'tier' && (
                            <>
                                {/* Movie preview */}
                                <div className="flex items-center gap-3 p-4 bg-secondary/30">
                                    {pendingMovie.posterUrl ? (
                                        <img src={pendingMovie.posterUrl} alt="" className="w-12 h-[72px] object-cover rounded-lg shadow-md flex-shrink-0" />
                                    ) : (
                                        <div className="w-12 h-[72px] bg-secondary rounded-lg flex items-center justify-center flex-shrink-0">
                                            <Film size={18} className="text-muted-foreground/60" />
                                        </div>
                                    )}
                                    <div>
                                        <p className="font-bold text-foreground leading-tight">{pendingMovie.title}</p>
                                        <p className="text-muted-foreground text-xs mt-0.5">{pendingMovie.year}</p>
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
                                        <span className="text-[10px] font-mono uppercase tracking-widest text-muted-foreground bg-secondary/30 px-2 py-0.5 rounded">
                                            {currentComparison.phase.replace('_', '-')}
                                        </span>
                                    </div>

                                    <h4 className="text-center text-sm font-bold text-foreground">{currentComparison.question}</h4>

                                    {/* Head-to-head */}
                                    <div className="flex items-stretch gap-2">
                                        {/* New item (movieA) */}
                                        <button
                                            onClick={() => handleCompareChoice('new')}
                                            className="flex-1 flex flex-col items-center gap-2 p-2 rounded-xl border-2 border-border hover:border-gold hover:bg-gold/5 transition-all active:scale-[0.97]"
                                        >
                                            <img
                                                src={currentComparison.movieA.posterUrl ?? ''}
                                                alt={currentComparison.movieA.title}
                                                className="w-full aspect-[2/3] object-cover rounded-lg shadow-lg"
                                            />
                                            <p className="font-bold text-foreground text-xs leading-tight text-center">{currentComparison.movieA.title}</p>
                                            <span className="text-[10px] text-accent font-semibold border border-accent/30 bg-accent/10 px-2 py-0.5 rounded-full">NEW</span>
                                        </button>

                                        {/* OR divider */}
                                        <div className="flex items-center justify-center flex-shrink-0">
                                            <div className="w-7 h-7 rounded-full bg-secondary border border-border flex items-center justify-center text-[10px] font-black text-muted-foreground">
                                                OR
                                            </div>
                                        </div>

                                        {/* Existing item (movieB) */}
                                        <button
                                            onClick={() => handleCompareChoice('existing')}
                                            className="flex-1 flex flex-col items-center gap-2 p-2 rounded-xl border-2 border-border hover:border-border hover:bg-secondary/10 transition-all active:scale-[0.97]"
                                        >
                                            <img
                                                src={currentComparison.movieB.posterUrl ?? ''}
                                                alt={currentComparison.movieB.title}
                                                className="w-full aspect-[2/3] object-cover rounded-lg shadow-lg"
                                            />
                                            <p className="font-bold text-foreground text-xs leading-tight text-center">{currentComparison.movieB.title}</p>
                                            <span className={`text-[10px] font-semibold px-2 py-0.5 rounded-full border ${TIER_COLORS[selectedTier]}`}>
                                                {selectedTier}
                                            </span>
                                        </button>
                                    </div>

                                    {/* Actions */}
                                    <div className="flex items-center justify-between">
                                        <button
                                            onClick={handleCompareUndo}
                                            className="flex items-center gap-1 text-xs font-medium text-muted-foreground hover:text-foreground disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
                                        >
                                            <ArrowLeft size={13} />
                                            Undo
                                        </button>
                                        <button
                                            onClick={() => handleCompareChoice('skip')}
                                            className="px-3 py-1.5 rounded-full border border-border text-xs font-semibold text-muted-foreground hover:bg-secondary hover:border-border transition-all"
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
                    <p className="text-xs uppercase tracking-[0.2em] text-accent">{user ? 'Step 2 of 2' : 'Get Started'}</p>
                    <h1 className="text-3xl font-bold">Build your Spool</h1>
                    <p className="text-muted-foreground text-sm">
                        Pick at least <span className="text-foreground font-semibold">{REQUIRED_MOVIES} movies</span> you've seen
                        to seed your rankings. You can adjust and fine-tune everything later.
                    </p>
                </div>

                {/* Progress bar */}
                <div className="space-y-2">
                    <div className="flex items-center justify-between text-sm">
                        <span className="text-muted-foreground">
                            <span className="text-foreground font-bold">{rankedItems.length}</span> / {REQUIRED_MOVIES} movies
                        </span>
                        {remaining > 0 ? (
                            <span className="text-muted-foreground">{remaining} more to go</span>
                        ) : (
                            <span className="text-emerald-400 font-semibold flex items-center gap-1">
                                <Check size={14} /> Ready!
                            </span>
                        )}
                    </div>
                    <div className="h-2 bg-secondary rounded-full overflow-hidden">
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
                        {user ? 'Continue to Spool' : 'Create your account'}
                        <ChevronRight size={16} />
                    </button>
                )}

                {/* Search */}
                <div className="relative">
                    <Search className="absolute left-3 top-3.5 text-muted-foreground" size={18} />
                    <input
                        type="text"
                        placeholder="Search by title, director, or actor..."
                        className="w-full bg-card border border-border rounded-xl py-3 pl-10 pr-4 text-foreground placeholder-muted-foreground focus:outline-none focus:border-gold transition-colors"
                        value={searchTerm}
                        onChange={e => setSearchTerm(e.target.value)}
                    />
                    {isSearching && <Loader2 className="absolute right-3 top-3.5 text-muted-foreground animate-spin" size={18} />}
                </div>

                {/* Search results */}
                {searchTerm.trim() && !selectedPerson && (
                    <div className="space-y-3">
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
                        {!isSearching && personProfiles.length > 0 && (
                            <div className="space-y-1">
                                <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider px-1">People</p>
                                {personProfiles.map(person => (
                                    <button
                                        key={person.id}
                                        onClick={() => handleOpenPerson(person)}
                                        className="flex items-center gap-3 p-2.5 rounded-xl hover:bg-secondary/50 transition-colors w-full text-left"
                                    >
                                        {person.photoUrl ? (
                                            <img src={person.photoUrl} alt={person.name} className="w-11 h-11 object-cover rounded-full bg-secondary flex-shrink-0 shadow-md" />
                                        ) : (
                                            <div className="w-11 h-11 bg-secondary rounded-full flex items-center justify-center flex-shrink-0 text-muted-foreground/60 text-lg font-bold">
                                                {person.name.charAt(0)}
                                            </div>
                                        )}
                                        <div className="flex-1 min-w-0">
                                            <div className="flex items-center gap-2">
                                                <p className="font-semibold text-foreground truncate">{person.name}</p>
                                                <span className={`text-[10px] px-1.5 py-0.5 rounded-full font-medium flex-shrink-0 ${person.role === 'Director' ? 'bg-amber-500/15 text-gold' : 'bg-gold/15 text-accent'}`}>
                                                    {person.role}
                                                </span>
                                            </div>
                                            {person.knownFor.length > 0 && (
                                                <p className="text-xs text-muted-foreground mt-0.5 truncate">Known for: {person.knownFor.join(', ')}</p>
                                            )}
                                        </div>
                                        <ChevronRight size={16} className="text-muted-foreground/60 flex-shrink-0" />
                                    </button>
                                ))}
                            </div>
                        )}

                        {/* Movie title results */}
                        {!isSearching && filteredSearch.length > 0 && (
                            <div className="space-y-1">
                                {personProfiles.length > 0 && (
                                    <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider px-1 pt-1">Movies</p>
                                )}
                                {filteredSearch.map(movie => (
                                    <button
                                        key={movie.id}
                                        onClick={() => handleSelectMovie(movie, false)}
                                        className="flex items-center gap-3 p-2 rounded-xl hover:bg-secondary/50 transition-colors w-full text-left"
                                    >
                                        {movie.posterUrl ? (
                                            <img src={movie.posterUrl} alt={movie.title} className="w-12 h-[72px] object-cover rounded-lg bg-secondary flex-shrink-0 shadow-md" />
                                        ) : (
                                            <div className="w-12 h-[72px] bg-secondary rounded-lg flex items-center justify-center flex-shrink-0">
                                                <Film size={20} className="text-muted-foreground/60" />
                                            </div>
                                        )}
                                        <div className="flex-1 min-w-0">
                                            <p className="font-semibold text-foreground truncate">{movie.title}</p>
                                            <p className="text-xs text-muted-foreground mt-0.5">{movie.year}</p>
                                            {movie.genres.length > 0 && (
                                                <div className="flex gap-1 mt-1 flex-wrap">
                                                    {movie.genres.map(g => (
                                                        <span key={g} className="text-[10px] px-1.5 py-0.5 bg-secondary text-muted-foreground rounded-full border border-border">{g}</span>
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
                            <div className="text-center py-8 text-muted-foreground text-sm">
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
                            className="flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground transition-colors"
                        >
                            <ArrowLeft size={16} />
                            Back to search
                        </button>

                        {/* Person header */}
                        <div className="flex items-start gap-4 p-4 bg-card/50 rounded-2xl border border-border">
                            {selectedPerson.photoUrl ? (
                                <img
                                    src={selectedPerson.photoUrl}
                                    alt={selectedPerson.name}
                                    className="w-20 h-20 object-cover rounded-xl shadow-lg flex-shrink-0"
                                />
                            ) : (
                                <div className="w-20 h-20 bg-secondary rounded-xl flex items-center justify-center flex-shrink-0 text-3xl font-bold text-muted-foreground/60">
                                    {selectedPerson.name.charAt(0)}
                                </div>
                            )}
                            <div className="flex-1 min-w-0">
                                <div className="flex items-center gap-2">
                                    <h2 className="text-xl font-bold text-foreground">{selectedPerson.name}</h2>
                                    <span className={`text-[10px] px-1.5 py-0.5 rounded-full font-medium ${selectedPerson.role === 'Director' ? 'bg-amber-500/15 text-gold' : 'bg-gold/15 text-accent'}`}>
                                        {selectedPerson.role}
                                    </span>
                                </div>
                                <p className="text-xs text-muted-foreground mt-0.5">
                                    {selectedPerson.placeOfBirth && <span>{selectedPerson.placeOfBirth}</span>}
                                    {selectedPerson.birthday && <span> · Born {selectedPerson.birthday}</span>}
                                </p>
                                <p className="text-sm text-accent font-semibold mt-1">
                                    {selectedPerson.movies.length} {selectedPerson.movies.length === 1 ? 'film' : 'films'} {selectedPerson.role === 'Director' ? 'directed' : 'starred in'}
                                </p>
                            </div>
                        </div>

                        {/* Bio */}
                        {selectedPerson.biography && (
                            <p className="text-xs text-muted-foreground leading-relaxed line-clamp-4">
                                {selectedPerson.biography}
                            </p>
                        )}

                        {/* Filmography grid */}
                        <div>
                            <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider mb-3">Filmography</p>
                            <div className="grid grid-cols-3 sm:grid-cols-4 gap-3">
                                {selectedPerson.movies.filter(m => !isOwned(m)).map(movie => (
                                    <button
                                        key={movie.id}
                                        onClick={() => handleSelectMovie(movie, false)}
                                        className="group flex flex-col items-center text-center rounded-xl hover:bg-secondary/60 p-1.5 transition-colors"
                                    >
                                        <img
                                            src={movie.posterUrl!}
                                            alt={movie.title}
                                            className="w-full aspect-[2/3] object-cover rounded-lg bg-secondary shadow-md group-hover:shadow-lg group-hover:scale-[1.03] transition-all"
                                        />
                                        <p className="text-xs font-medium text-muted-foreground mt-1.5 leading-tight line-clamp-2 group-hover:text-foreground transition-colors">
                                            {movie.title}
                                        </p>
                                        <p className="text-[10px] text-muted-foreground/60">{movie.year}</p>
                                    </button>
                                ))}
                            </div>
                            {selectedPerson.movies.filter(m => !isOwned(m)).length === 0 && (
                                <p className="text-center py-6 text-muted-foreground text-sm">All movies already ranked!</p>
                            )}
                        </div>
                    </div>
                )}

                {/* Person loading */}
                {personLoading && (
                    <div className="flex items-center justify-center py-12">
                        <Loader2 className="w-6 h-6 text-gold animate-spin" />
                    </div>
                )}

                {/* Suggestions grid (when not searching) */}
                {!searchTerm.trim() && (
                    <section className="space-y-3">
                        <div className="flex items-center justify-between px-1">
                            <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wider">Suggested movies</p>
                            <button
                                onClick={handleRefresh}
                                className="flex items-center gap-1 text-[10px] font-semibold text-muted-foreground/60 hover:text-muted-foreground transition-colors px-2 py-1 rounded-lg hover:bg-secondary"
                            >
                                <RefreshCw size={11} />
                                Refresh
                            </button>
                        </div>

                        {suggestionsLoading ? (
                            <div className="grid grid-cols-3 sm:grid-cols-4 gap-3">
                                {[1, 2, 3, 4, 5, 6, 7, 8].map(i => (
                                    <div key={i} className="animate-pulse">
                                        <div className="w-full aspect-[2/3] bg-secondary rounded-lg" />
                                        <div className="h-3 bg-secondary rounded mt-2 w-3/4 mx-auto" />
                                    </div>
                                ))}
                            </div>
                        ) : (
                            <div className="grid grid-cols-3 sm:grid-cols-4 gap-3">
                                {filteredSuggestions.map(movie => (
                                    <button
                                        key={movie.id}
                                        onClick={() => handleSelectMovie(movie, true)}
                                        className="group flex flex-col items-center text-center rounded-xl hover:bg-secondary/60 p-2 transition-colors"
                                    >
                                        <img
                                            src={movie.posterUrl!}
                                            alt={movie.title}
                                            className="w-full aspect-[2/3] object-cover rounded-lg bg-secondary shadow-md group-hover:shadow-lg transition-shadow"
                                        />
                                        <p className="text-xs font-medium text-muted-foreground mt-2 leading-tight line-clamp-2 group-hover:text-foreground transition-colors">
                                            {movie.title}
                                        </p>
                                        <p className="text-[10px] text-muted-foreground/60 mt-0.5">{movie.year}</p>
                                    </button>
                                ))}
                            </div>
                        )}
                    </section>
                )}

                {/* Selected movies summary */}
                {rankedItems.length > 0 && (
                    <section className="space-y-3 pt-4 border-t border-border">
                        <h3 className="text-sm font-semibold text-muted-foreground">Your picks so far</h3>
                        <div className="flex flex-wrap gap-2">
                            {rankedItems.map(item => (
                                <div
                                    key={item.id}
                                    className={`flex items-center gap-2 px-2.5 py-1.5 rounded-lg border text-xs font-semibold ${TIER_COLORS[item.tier]}`}
                                >
                                    <span>{item.tier}</span>
                                    <span className="text-foreground opacity-80 truncate max-w-[120px]">{item.title}</span>
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
