import React, { useEffect, useState } from 'react';
import { Compass, Flame, Sparkles, TrendingUp, BookmarkPlus, Star } from 'lucide-react';
import { FriendRecommendation, TrendingMovie, GenreProfileItem } from '../types';
import { GenreRadarChart } from './GenreRadarChart';
import {
    getFriendRecommendations,
    getTrendingAmongFriends,
    getGenreProfile,
} from '../services/friendsService';

const TIER_COLORS: Record<string, string> = {
    S: '#f59e0b',
    A: '#22c55e',
    B: '#3b82f6',
    C: '#8b5cf6',
    D: '#ef4444',
};

const TIER_LABELS: Record<string, string> = {
    S: 'S-Tier',
    A: 'A-Tier',
    B: 'B-Tier',
    C: 'C-Tier',
    D: 'D-Tier',
};

interface DiscoverViewProps {
    userId: string;
}

export const DiscoverView: React.FC<DiscoverViewProps> = ({ userId }) => {
    const [recommendations, setRecommendations] = useState<FriendRecommendation[]>([]);
    const [trending, setTrending] = useState<TrendingMovie[]>([]);
    const [genreProfile, setGenreProfile] = useState<GenreProfileItem[]>([]);
    const [loading, setLoading] = useState(true);
    const [activeSection, setActiveSection] = useState<'recs' | 'trending' | 'genres'>('recs');

    useEffect(() => {
        if (!userId) return;

        const load = async () => {
            setLoading(true);
            try {
                const [recs, trend, genres] = await Promise.all([
                    getFriendRecommendations(userId),
                    getTrendingAmongFriends(userId),
                    getGenreProfile(userId),
                ]);
                setRecommendations(recs);
                setTrending(trend);
                setGenreProfile(genres);
            } catch (err) {
                console.error('Discovery load failed:', err);
            } finally {
                setLoading(false);
            }
        };

        load();
    }, [userId]);

    if (loading) {
        return (
            <div className="flex items-center justify-center py-20">
                <div className="w-8 h-8 border-2 border-amber-500 border-t-transparent rounded-full animate-spin" />
            </div>
        );
    }

    return (
        <div className="space-y-6">
            {/* Section tabs */}
            <div className="flex gap-2 bg-zinc-900/60 rounded-xl p-1 border border-zinc-800/50">
                {[
                    { key: 'recs' as const, label: 'For You', icon: Sparkles, count: recommendations.length },
                    { key: 'trending' as const, label: 'Trending', icon: TrendingUp, count: trending.length },
                    { key: 'genres' as const, label: 'Your Taste', icon: Star, count: genreProfile.length },
                ].map(({ key, label, icon: Icon, count }) => (
                    <button
                        key={key}
                        onClick={() => setActiveSection(key)}
                        className={`flex-1 flex items-center justify-center gap-2 px-4 py-2.5 rounded-lg text-sm font-semibold transition-all ${activeSection === key
                                ? 'bg-zinc-800 text-white shadow-lg'
                                : 'text-zinc-500 hover:text-zinc-300'
                            }`}
                    >
                        <Icon size={16} />
                        {label}
                        {count > 0 && (
                            <span className="text-[10px] px-1.5 py-0.5 rounded-full bg-zinc-700 text-zinc-300">
                                {count}
                            </span>
                        )}
                    </button>
                ))}
            </div>

            {/* For You — Friend Recommendations */}
            {activeSection === 'recs' && (
                <div className="space-y-4">
                    <div className="flex items-center gap-2 mb-1">
                        <Sparkles size={18} className="text-amber-500" />
                        <h2 className="text-lg font-bold">From Your Circle</h2>
                        <span className="text-xs text-zinc-500">
                            Movies your friends love that you haven't seen yet
                        </span>
                    </div>

                    {recommendations.length === 0 ? (
                        <div className="text-center py-16 text-zinc-500">
                            <Compass size={40} className="mx-auto mb-3 opacity-40" />
                            <p className="text-sm">Follow more friends to get personalized recommendations!</p>
                        </div>
                    ) : (
                        <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-4">
                            {recommendations.map((rec) => (
                                <div
                                    key={rec.tmdbId}
                                    className="group relative rounded-xl overflow-hidden bg-zinc-900 border border-zinc-800/50 hover:border-zinc-700 transition-all hover:scale-[1.02]"
                                >
                                    {/* Poster */}
                                    <div className="aspect-[2/3] bg-zinc-800 relative">
                                        {rec.posterUrl ? (
                                            <img
                                                src={rec.posterUrl}
                                                alt={rec.title}
                                                className="w-full h-full object-cover"
                                                loading="lazy"
                                            />
                                        ) : (
                                            <div className="w-full h-full flex items-center justify-center text-zinc-600">
                                                <Compass size={32} />
                                            </div>
                                        )}

                                        {/* Tier badge overlay */}
                                        <div className="absolute top-2 left-2">
                                            <span
                                                className="px-2 py-0.5 rounded-md text-[10px] font-bold text-black"
                                                style={{ backgroundColor: TIER_COLORS[rec.topTier] || '#71717a' }}
                                            >
                                                {TIER_LABELS[rec.topTier] || rec.topTier}
                                            </span>
                                        </div>

                                        {/* Friend count badge */}
                                        <div className="absolute top-2 right-2 bg-black/70 backdrop-blur-sm rounded-full px-2 py-0.5 flex items-center gap-1">
                                            <Flame size={10} className="text-amber-500" />
                                            <span className="text-[10px] font-bold text-white">
                                                {rec.friendCount} {rec.friendCount === 1 ? 'friend' : 'friends'}
                                            </span>
                                        </div>

                                        {/* Hover overlay with action */}
                                        <div className="absolute inset-0 bg-black/60 opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center">
                                            <button className="flex items-center gap-1.5 bg-white text-black px-3 py-1.5 rounded-lg text-xs font-semibold hover:bg-zinc-200 transition-colors">
                                                <BookmarkPlus size={14} />
                                                Save to Watchlist
                                            </button>
                                        </div>
                                    </div>

                                    {/* Info */}
                                    <div className="p-3">
                                        <h3 className="text-sm font-semibold text-zinc-100 truncate">{rec.title}</h3>
                                        <p className="text-[11px] text-zinc-500 mt-0.5">
                                            {rec.year} · {rec.genres.slice(0, 2).join(', ')}
                                        </p>

                                        {/* Friend avatars */}
                                        {rec.friendUsernames.length > 0 && (
                                            <div className="flex items-center gap-1 mt-2">
                                                <div className="flex -space-x-1.5">
                                                    {rec.friendAvatars.slice(0, 3).map((avatar, i) => (
                                                        <div
                                                            key={i}
                                                            className="w-5 h-5 rounded-full border border-zinc-900 bg-zinc-700 overflow-hidden"
                                                        >
                                                            {avatar ? (
                                                                <img src={avatar} alt="" className="w-full h-full object-cover" />
                                                            ) : (
                                                                <div className="w-full h-full bg-indigo-600 flex items-center justify-center text-[8px] text-white font-bold">
                                                                    {rec.friendUsernames[i]?.[0]?.toUpperCase() || '?'}
                                                                </div>
                                                            )}
                                                        </div>
                                                    ))}
                                                </div>
                                                <span className="text-[10px] text-zinc-500 truncate ml-1">
                                                    {rec.friendUsernames.slice(0, 2).join(', ')}
                                                    {rec.friendUsernames.length > 2 &&
                                                        ` +${rec.friendUsernames.length - 2}`}
                                                </span>
                                            </div>
                                        )}
                                    </div>
                                </div>
                            ))}
                        </div>
                    )}
                </div>
            )}

            {/* Trending Among Friends */}
            {activeSection === 'trending' && (
                <div className="space-y-4">
                    <div className="flex items-center gap-2 mb-1">
                        <TrendingUp size={18} className="text-emerald-500" />
                        <h2 className="text-lg font-bold">Trending in Your Network</h2>
                        <span className="text-xs text-zinc-500">Most ranked by friends (last 30 days)</span>
                    </div>

                    {trending.length === 0 ? (
                        <div className="text-center py-16 text-zinc-500">
                            <TrendingUp size={40} className="mx-auto mb-3 opacity-40" />
                            <p className="text-sm">No trending activity yet. Follow more friends!</p>
                        </div>
                    ) : (
                        <div className="space-y-2">
                            {trending.map((movie, idx) => (
                                <div
                                    key={movie.tmdbId}
                                    className="flex items-center gap-4 p-3 rounded-xl bg-zinc-900/60 border border-zinc-800/30 hover:border-zinc-700 transition-all"
                                >
                                    {/* Rank number */}
                                    <div className="text-2xl font-black text-zinc-700 w-8 text-center">
                                        {idx + 1}
                                    </div>

                                    {/* Poster thumbnail */}
                                    <div className="w-12 h-[72px] rounded-lg overflow-hidden bg-zinc-800 flex-shrink-0">
                                        {movie.posterUrl ? (
                                            <img
                                                src={movie.posterUrl}
                                                alt={movie.title}
                                                className="w-full h-full object-cover"
                                            />
                                        ) : (
                                            <div className="w-full h-full flex items-center justify-center text-zinc-600">
                                                <Compass size={16} />
                                            </div>
                                        )}
                                    </div>

                                    {/* Info */}
                                    <div className="flex-1 min-w-0">
                                        <h3 className="text-sm font-semibold text-zinc-100 truncate">{movie.title}</h3>
                                        <p className="text-[11px] text-zinc-500 mt-0.5">
                                            {movie.year} · {movie.genres.slice(0, 2).join(', ')}
                                        </p>
                                        <div className="flex items-center gap-3 mt-1.5">
                                            <span className="text-[10px] text-zinc-400">
                                                {movie.recentRankers.slice(0, 3).join(', ')}
                                                {movie.recentRankers.length > 3 &&
                                                    ` +${movie.recentRankers.length - 3} more`}
                                            </span>
                                        </div>
                                    </div>

                                    {/* Stats */}
                                    <div className="flex items-center gap-3 flex-shrink-0">
                                        <div className="text-center">
                                            <div className="flex items-center gap-1">
                                                <Flame size={12} className="text-orange-500" />
                                                <span className="text-sm font-bold text-zinc-200">{movie.rankerCount}</span>
                                            </div>
                                            <span className="text-[9px] text-zinc-500 block">rankers</span>
                                        </div>
                                        <span
                                            className="w-8 h-8 rounded-lg flex items-center justify-center text-xs font-bold text-black"
                                            style={{ backgroundColor: TIER_COLORS[movie.avgTier] || '#71717a' }}
                                        >
                                            {movie.avgTier}
                                        </span>
                                    </div>
                                </div>
                            ))}
                        </div>
                    )}
                </div>
            )}

            {/* Genre Taste Profile */}
            {activeSection === 'genres' && (
                <div className="space-y-4">
                    <div className="flex items-center gap-2 mb-1">
                        <Star size={18} className="text-amber-500" />
                        <h2 className="text-lg font-bold">Your Taste DNA</h2>
                        <span className="text-xs text-zinc-500">Genre distribution across your rankings</span>
                    </div>

                    <div className="bg-zinc-900/60 rounded-2xl border border-zinc-800/30 p-6">
                        <GenreRadarChart genres={genreProfile} />
                    </div>
                </div>
            )}
        </div>
    );
};

export default DiscoverView;
