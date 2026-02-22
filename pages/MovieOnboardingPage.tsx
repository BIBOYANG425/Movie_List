import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Check, ChevronRight, Film, Loader2, RefreshCw, Search, X } from 'lucide-react';
import { RankedItem, Tier, MediaType } from '../types';
import { TIER_COLORS, TIER_LABELS, TIERS, MIN_MOVIES_FOR_SCORES } from '../constants';
import { getGenericSuggestions, getPersonalizedFills, hasTmdbKey, searchMovies, TMDBMovie } from '../services/tmdbService';
import { searchMediaFromBackend, hasBackendUrl } from '../services/backendService';
import { supabase } from '../lib/supabase';
import { useAuth } from '../contexts/AuthContext';

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
    const suggestionPageRef = useRef(1);
    const backfillPoolRef = useRef<TMDBMovie[]>([]);
    const backfillPageRef = useRef(1);

    // Search
    const [searchTerm, setSearchTerm] = useState('');
    const [searchResults, setSearchResults] = useState<TMDBMovie[]>([]);
    const [isSearching, setIsSearching] = useState(false);
    const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);

    // Tier picker modal
    const [pendingMovie, setPendingMovie] = useState<TMDBMovie | null>(null);
    const [fromSuggestion, setFromSuggestion] = useState(false);

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
        const topGenres = getTopGenres();
        if (topGenres.length === 0) return;
        const p = page ?? backfillPageRef.current;
        getPersonalizedFills(topGenres, getExcludeIds(), p, getExcludeTitles()).then(results => {
            backfillPoolRef.current = results;
        });
    }, [getTopGenres, getExcludeIds, getExcludeTitles]);

    const loadSuggestions = useCallback((page: number) => {
        if (!hasTmdbKey()) return;
        setSuggestionsLoading(true);
        getGenericSuggestions(getExcludeIds(), page, getExcludeTitles()).then(results => {
            setSuggestions(results);
            setSuggestionsLoading(false);
        });
        backfillPageRef.current = 1;
        backfillPoolRef.current = [];
        prefetchBackfill(1);
    }, [getExcludeIds, getExcludeTitles, prefetchBackfill]);

    useEffect(() => {
        if (!loading) loadSuggestions(1);
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
        if (!q) { setSearchResults([]); setIsSearching(false); return; }
        setIsSearching(true);
        debounceRef.current = setTimeout(async () => {
            const [backend, tmdb] = await Promise.all([
                hasBackendUrl() ? searchMediaFromBackend(q, 2500) : Promise.resolve([]),
                searchMovies(q, 4500),
            ]);
            setSearchResults(mergeAndDedup([...backend, ...tmdb]));
            setIsSearching(false);
        }, 350);
        return () => { if (debounceRef.current) clearTimeout(debounceRef.current); };
    }, [searchTerm]);

    // ── Add item ────────────────────────────────────────────────────────────────

    const handleSelectMovie = (movie: TMDBMovie, isSuggestion: boolean) => {
        setPendingMovie(movie);
        setFromSuggestion(isSuggestion);
    };

    const handlePickTier = async (tier: Tier) => {
        if (!pendingMovie || !user) return;

        if (fromSuggestion) consumeSuggestion(pendingMovie.id);

        const newRank = rankedItems.filter(i => i.tier === tier).length;
        const newItem: RankedItem = {
            id: pendingMovie.id,
            title: pendingMovie.title,
            year: pendingMovie.year,
            posterUrl: pendingMovie.posterUrl ?? '',
            type: 'movie',
            genres: pendingMovie.genres,
            tier,
            rank: newRank,
        };

        setRankedItems(prev => [...prev, newItem]);
        setPendingMovie(null);

        await supabase.from('user_rankings').upsert({
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
            notes: null,
            updated_at: new Date().toISOString(),
        }, { onConflict: 'user_id,tmdb_id' });
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
                            <h3 className="text-lg font-bold">Assign Tier</h3>
                            <button onClick={() => setPendingMovie(null)} className="text-zinc-400 hover:text-white transition-colors">
                                <X size={20} />
                            </button>
                        </div>

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
                        placeholder="Search for a movie..."
                        className="w-full bg-zinc-900 border border-zinc-800 rounded-xl py-3 pl-10 pr-4 text-white placeholder-zinc-500 focus:outline-none focus:border-indigo-500 transition-colors"
                        value={searchTerm}
                        onChange={e => setSearchTerm(e.target.value)}
                    />
                    {isSearching && <Loader2 className="absolute right-3 top-3.5 text-zinc-500 animate-spin" size={18} />}
                </div>

                {/* Search results */}
                {searchTerm.trim() && (
                    <div className="space-y-1">
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
                        {!isSearching && filteredSearch.map(movie => (
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
                        {!isSearching && searchTerm.trim() && filteredSearch.length === 0 && (
                            <div className="text-center py-8 text-zinc-500 text-sm">
                                <Film size={28} className="mx-auto mb-2 opacity-30" />
                                <p>No results for "{searchTerm}"</p>
                            </div>
                        )}
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
