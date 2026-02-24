import React, { useEffect, useState } from 'react';
import { RankedItem, Tier, MovieSocialStats, StreamingAvailability } from '../types';
import { X, Film, Star, MessageCircle, Link, StickyNote, ThumbsUp, ChevronRight } from 'lucide-react';
import { getExtendedMovieDetails, TMDBMovie } from '../services/tmdbService';
import { getMovieSocialStats } from '../services/friendsService';
import { TIER_COLORS, TIER_LABELS } from '../constants';
import { supabase } from '../lib/supabase';

interface MediaDetailModalProps {
    initialItem?: RankedItem;
    tmdbId: string;
    onClose: () => void;
}

export const MediaDetailModal: React.FC<MediaDetailModalProps> = ({ initialItem, tmdbId, onClose }) => {
    const defaultMovie: TMDBMovie | null = initialItem ? {
        ...initialItem,
        tmdbId: parseInt(initialItem.id, 10),
        overview: ''
    } : null;

    const [movie, setMovie] = useState<TMDBMovie | null>(defaultMovie);
    const [extendedDetailsLoaded, setExtendedDetailsLoaded] = useState(false);
    const [streaming, setStreaming] = useState<StreamingAvailability | null>(null);
    const [director, setDirector] = useState<string | null>(initialItem?.director ?? null);

    const [rankedItem, setRankedItem] = useState<RankedItem | null>(initialItem ?? null);
    const [rankContext, setRankContext] = useState<{ above: string, below: string, date: string } | null>(null);

    const [socialStats, setSocialStats] = useState<MovieSocialStats | null>(null);
    const [socialLoading, setSocialLoading] = useState(true);

    const [currentUserId, setCurrentUserId] = useState<string | null>(null);

    useEffect(() => {
        // Esc to close
        const handleKeyDown = (e: KeyboardEvent) => {
            if (e.key === 'Escape') onClose();
        };
        window.addEventListener('keydown', handleKeyDown);
        return () => window.removeEventListener('keydown', handleKeyDown);
    }, [onClose]);

    useEffect(() => {
        const fetchData = async () => {
            const { data: userData } = await supabase.auth.getUser();
            const userId = userData.user?.id;
            if (userId) setCurrentUserId(userId);

            // Fetch Extended TMDB (Backdrop, Watch Providers, Runtime)
            if (!movie?.backdropUrl || !streaming) {
                // tmdbId might be "tmdb_123" or "123"
                const numericId = parseInt(tmdbId.replace('tmdb_', ''), 10);
                if (!isNaN(numericId)) {
                    const extended = await getExtendedMovieDetails(numericId);
                    if (extended) {
                        setMovie(prev => ({ ...prev, ...extended.movie } as TMDBMovie));
                        setStreaming(extended.streaming);
                        if (extended.director) setDirector(extended.director);
                        setExtendedDetailsLoaded(true);
                    }
                }
            }

            if (userId) {
                // Fetch User's specific ranking context (what did they rank above/below?)
                const { data: ranks } = await supabase
                    .from('user_rankings')
                    .select('*')
                    .eq('user_id', userId)
                    .order('tier')
                    .order('rank_position');

                if (ranks) {
                    const myItemIndex = ranks.findIndex(r => r.tmdb_id === tmdbId);
                    if (myItemIndex !== -1) {
                        const item = ranks[myItemIndex];
                        if (!rankedItem) {
                            setRankedItem({
                                id: item.tmdb_id,
                                title: item.title,
                                year: item.year,
                                posterUrl: item.poster_url,
                                type: 'movie',
                                genres: item.genres,
                                director: item.director,
                                tier: item.tier as Tier,
                                rank: item.rank_position,
                                notes: item.notes,
                            });
                        }

                        // Compute "Ranked above X, below Y" within same tier
                        const sameTier = ranks.filter(r => r.tier === item.tier).sort((a, b) => a.rank_position - b.rank_position);
                        const subIndex = sameTier.findIndex(r => r.tmdb_id === tmdbId);

                        let aboveStr = '';
                        let belowStr = '';
                        if (subIndex > 0) belowStr = sameTier[subIndex - 1].title;
                        if (subIndex < sameTier.length - 1) aboveStr = sameTier[subIndex + 1].title;

                        setRankContext({
                            above: aboveStr,
                            below: belowStr,
                            date: new Date(item.updated_at).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
                        });
                    }
                }

                // Fetch Social Stats
                setSocialLoading(true);
                const stats = await getMovieSocialStats(userId, tmdbId);
                setSocialStats(stats);
                setSocialLoading(false);
            }
        };

        fetchData();
    }, [tmdbId, initialItem]);

    if (!movie) return null;

    return (
        <div className="fixed inset-0 z-50 flex items-end sm:items-center justify-center bg-black/80 backdrop-blur-md transition-opacity">
            {/* Click outside to close */}
            <div className="absolute inset-0" onClick={onClose} />

            {/* Modal Container */}
            <div
                className="relative w-full max-w-xl bg-[#0a0a0c] sm:rounded-3xl shadow-2xl overflow-hidden h-[95vh] sm:h-[85vh] flex flex-col origin-bottom animate-slide-up-modal pb-24"
            >
                {/* Close Button */}
                <button
                    onClick={onClose}
                    className="absolute top-4 right-4 z-20 p-2 bg-black/50 backdrop-blur-md rounded-full text-white/70 hover:text-white hover:bg-black/80 transition"
                >
                    <X size={20} />
                </button>

                {/* Scrollable Content */}
                <div className="flex-1 overflow-y-auto overflow-x-hidden hide-scrollbar">

                    {/* 🎬 Hero Section */}
                    <div className="relative w-full pb-6 border-b border-white/10">
                        {/* Backdrop */}
                        <div className="absolute inset-0 h-80 bg-zinc-900 overflow-hidden">
                            {movie.backdropUrl ? (
                                <img src={movie.backdropUrl} className="w-full h-full object-cover opacity-60 mix-blend-screen animate-fade-in" />
                            ) : (
                                <div className="w-full h-full animate-pulse bg-zinc-800" />
                            )}
                            <div className="absolute inset-0 bg-gradient-to-t from-[#0a0a0c] via-[#0a0a0c]/80 to-transparent" />
                        </div>

                        <div className="relative pt-32 px-6 flex flex-col items-center">
                            <div className="w-32 sm:w-40 aspect-[2/3] rounded-xl shadow-[0_10px_40px_rgba(0,0,0,0.8)] overflow-hidden border border-white/10 shrink-0">
                                <img src={movie.posterUrl!} className="w-full h-full object-cover" />
                            </div>

                            <h1 className="mt-5 text-3xl font-black text-center text-white text-balance leading-tight tracking-tight">
                                {movie.title}
                            </h1>

                            <div className="mt-2 flex items-center justify-center gap-2 text-sm text-zinc-400">
                                <span className="font-semibold text-zinc-300">{movie.year}</span>
                                {director && (
                                    <>
                                        <span>·</span>
                                        <span>{director}</span>
                                    </>
                                )}
                                {movie.runtime && (
                                    <>
                                        <span>·</span>
                                        <span>{Math.floor(movie.runtime / 60)}h {movie.runtime % 60}m</span>
                                    </>
                                )}
                            </div>

                            {movie.genres && movie.genres.length > 0 && (
                                <div className="mt-3 flex flex-wrap justify-center gap-1.5">
                                    {movie.genres.map(g => (
                                        <span key={g} className="px-2.5 py-1 text-[11px] font-bold tracking-wider uppercase bg-white/5 border border-white/10 rounded-full text-zinc-300">
                                            {g}
                                        </span>
                                    ))}
                                </div>
                            )}

                            {/* Streaming Badges */}
                            {streaming?.flatrate && streaming.flatrate.length > 0 && (
                                <div className="mt-6 flex flex-col items-center">
                                    <span className="text-xs font-semibold text-zinc-500 uppercase tracking-widest mb-2">Stream Now</span>
                                    <div className="flex gap-2">
                                        {streaming.flatrate.map(p => (
                                            <div key={p.providerId} className="w-8 h-8 rounded-lg overflow-hidden border border-white/10 opacity-80 hover:opacity-100 transition shadow-sm" title={p.providerName}>
                                                <img src={p.logoUrl} alt={p.providerName} className="w-full h-full object-cover" />
                                            </div>
                                        ))}
                                    </div>
                                </div>
                            )}
                        </div>
                    </div>

                    {/* 📊 Your Ranking Context */}
                    <div className="px-6 py-8 border-b border-white/10">
                        {rankedItem ? (
                            <div className="bg-white/5 border border-white/10 rounded-2xl p-5">
                                <div className="flex items-start justify-between">
                                    <div>
                                        <div className="flex items-center gap-2">
                                            <div className={`px-2 py-0.5 rounded text-xs font-bold border ${TIER_COLORS[rankedItem.tier]}`}>
                                                {rankedItem.tier}
                                            </div>
                                            <h3 className="text-lg font-bold text-white">Your Rank: #{rankedItem.rank + 1}</h3>
                                        </div>

                                        {(rankContext?.above || rankContext?.below) && (
                                            <div className="mt-2 text-sm text-zinc-400 leading-relaxed">
                                                {rankContext.above && <span>Ranked above <span className="text-zinc-200 italic">{rankContext.above}</span></span>}
                                                {rankContext.above && rankContext.below && <span> · </span>}
                                                {rankContext.below && <span>Ranked below <span className="text-zinc-200 italic">{rankContext.below}</span></span>}
                                            </div>
                                        )}

                                        {rankContext?.date && (
                                            <div className="mt-3 flex items-center gap-1.5 text-xs text-zinc-500 font-mono uppercase tracking-wide">
                                                <Star size={12} /> Watched {rankContext.date}
                                            </div>
                                        )}
                                    </div>

                                    <button className="px-4 py-2 bg-white/5 hover:bg-white/10 border border-white/10 rounded-xl text-xs font-bold transition flex items-center gap-2">
                                        Re-rank
                                    </button>
                                </div>
                            </div>
                        ) : (
                            <div className="bg-white/5 border border-white/10 rounded-2xl p-6 text-center">
                                <h3 className="text-lg font-bold text-white mb-1">Not yet ranked</h3>
                                <p className="text-sm text-zinc-400 mb-4">Add this movie to your lists to compare it to your favorites.</p>
                                <div className="flex justify-center gap-3">
                                    <button className="px-5 py-2.5 bg-indigo-500 hover:bg-indigo-400 text-white font-bold rounded-xl text-sm transition">
                                        📌 Want-to-Watch
                                    </button>
                                    <button className="px-5 py-2.5 bg-white/10 hover:bg-white/15 text-white font-bold rounded-xl text-sm transition border border-white/10">
                                        ✅ I've Watched This
                                    </button>
                                </div>
                            </div>
                        )}
                    </div>

                    {/* 👥 Friends' Corner */}
                    <div className="px-6 py-8">
                        <h3 className="text-xs font-bold text-zinc-500 uppercase tracking-widest mb-4">What Your Friends Think</h3>

                        {socialLoading ? (
                            <div className="animate-pulse flex gap-3 h-16 bg-white/5 rounded-xl border border-white/10" />
                        ) : socialStats && socialStats.friendsWatched > 0 ? (
                            <div className="space-y-4">

                                <div className="flex items-center gap-4">
                                    <div className="flex -space-x-2">
                                        {socialStats.friendAvatars.map((url, i) => (
                                            <div key={i} className="w-8 h-8 rounded-full border-2 border-[#0a0a0c] bg-zinc-800 overflow-hidden">
                                                <img src={url} className="w-full h-full object-cover" />
                                            </div>
                                        ))}
                                    </div>
                                    <div className="text-sm font-medium text-zinc-300">
                                        <span className="text-white font-bold">{socialStats.friendsWatched} friends</span> watched
                                    </div>
                                </div>

                                {socialStats.avgFriendRankPosition !== undefined && (
                                    <div className="inline-flex items-center gap-2 bg-indigo-500/10 border border-indigo-500/20 px-3 py-1.5 rounded-lg text-indigo-400 text-sm font-semibold">
                                        <div className="w-1.5 h-1.5 rounded-full bg-indigo-400" />
                                        Avg rank: #{socialStats.avgFriendRankPosition + 1}
                                    </div>
                                )}

                                {socialStats.topFriendReview && (
                                    <div className="bg-white/5 border border-white/10 rounded-xl p-4 mt-2">
                                        <p className="text-base text-zinc-200 font-medium italic">"{socialStats.topFriendReview.body}"</p>
                                        <div className="flex items-center gap-2 mt-3 text-xs text-zinc-400">
                                            <img src={socialStats.topFriendReview.avatarUrl} className="w-5 h-5 rounded-full" />
                                            <span className="font-semibold text-zinc-300">{socialStats.topFriendReview.username}</span>
                                            <span>ranked it <span className="font-bold text-white">#{socialStats.topFriendReview.rankPosition + 1}</span></span>
                                        </div>
                                    </div>
                                )}

                                <button className="flex items-center gap-2 text-sm text-indigo-400 font-bold hover:text-indigo-300 transition group mt-2">
                                    See all {socialStats.friendsWatched} friend rankings
                                    <ChevronRight size={14} className="group-hover:translate-x-1 transition-transform" />
                                </button>
                            </div>
                        ) : (
                            <div className="text-sm text-zinc-500 italic bg-white/5 p-4 rounded-xl border-dashed border border-white/10">
                                None of your friends have ranked this yet. Be exploring and invite them!
                            </div>
                        )}
                    </div>
                </div>

                {/* 🎯 Action Footer (Sticky Bottom) */}
                <div className="absolute bottom-0 left-0 right-0 bg-[#0a0a0c] border-t border-white/10 p-4 pb-safe shadow-[0_-10px_40px_rgba(0,0,0,0.5)] flex items-center gap-3">
                    {rankedItem ? (
                        <>
                            <button className="flex-1 bg-indigo-500 hover:bg-indigo-400 text-white font-bold py-3.5 rounded-xl transition flex items-center justify-center gap-2 shadow-lg shadow-indigo-500/20 active:scale-[0.98]">
                                <MessageCircle size={18} />
                                Leave a Review
                            </button>
                            <button className="w-12 h-12 flex items-center justify-center bg-white/5 border border-white/10 rounded-xl hover:bg-white/10 transition text-zinc-400 hover:text-white" title="Share with a Friend">
                                <Link size={18} />
                            </button>
                        </>
                    ) : (
                        <>
                            <button className="flex-1 bg-indigo-500 hover:bg-indigo-400 text-white font-bold py-3.5 rounded-xl transition flex items-center justify-center gap-2 shadow-lg shadow-indigo-500/20 active:scale-[0.98]">
                                📌 Want-to-Watch
                            </button>
                            <button className="px-6 bg-white/5 border border-white/10 text-white font-bold py-3.5 rounded-xl transition flex items-center justify-center gap-2 hover:bg-white/10 active:scale-[0.98]" title="Share with a Friend">
                                ✅ Watched
                            </button>
                        </>
                    )}
                </div>

            </div>
        </div>
    );
};
