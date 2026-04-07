import React, { useEffect, useState } from 'react';
import FocusTrap from 'focus-trap-react';
import { RankedItem, Tier, MovieSocialStats, StreamingAvailability, Bracket } from '../../types';
import { X, Star, MessageCircle, Link, ChevronRight, Check, RefreshCw } from 'lucide-react';
import { getExtendedMovieDetails, getTVSeasonDetails, getTVShowDetails, TMDBMovie } from '../../services/tmdbService';
import { getMovieSocialStats, getTVSocialStats } from '../../services/friendsService';
import { TIER_COLORS, TIER_LABELS } from '../../constants';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../contexts/AuthContext';
import { useTranslation } from '../../contexts/LanguageContext';
import { shareOrCopyLink } from '../../utils/shareLink';
import { JournalConversation } from '../journal/JournalConversation';
import { ErrorBoundary } from '../shared/ErrorBoundary';

interface MediaDetailModalProps {
    initialItem?: RankedItem;
    tmdbId: string;
    userScore?: number;
    onClose: () => void;
    onSaveForLater?: (movie: TMDBMovie) => void;
    onStartRanking?: (movie: TMDBMovie) => void;
    onOpenJournal?: (tmdbId: string) => void;
    onRerank?: (item: RankedItem) => void;
}

interface TVSeasonViewModel {
    title: string;
    year: string;
    posterUrl: string;
    backdropUrl?: string | null;
    overview: string;
    genres: string[];
    creator?: string;
    seasonTitle?: string;
    episodeCount?: number;
    voteAverage?: number;
}

function parseTVSeasonId(id: string): { showTmdbId: number; seasonNumber: number } | null {
    const match = id.match(/^tv_(\d+)_s(\d+)$/);
    if (!match) return null;
    return {
        showTmdbId: Number(match[1]),
        seasonNumber: Number(match[2]),
    };
}

export const MediaDetailModal: React.FC<MediaDetailModalProps> = ({ initialItem, tmdbId, userScore, onClose, onSaveForLater, onStartRanking, onOpenJournal, onRerank }) => {
    const tvTarget = initialItem?.type === 'tv_season'
        ? {
            showTmdbId: initialItem.showTmdbId ?? parseTVSeasonId(tmdbId)?.showTmdbId ?? 0,
            seasonNumber: initialItem.seasonNumber ?? parseTVSeasonId(tmdbId)?.seasonNumber ?? 0,
        }
        : parseTVSeasonId(tmdbId);
    const isTVSeason = Boolean(tvTarget);
    const rankingTable = isTVSeason ? 'tv_rankings' : 'user_rankings';

    const defaultMovie: TMDBMovie | null = initialItem && !isTVSeason ? {
        ...initialItem,
        type: 'movie' as const,
        tmdbId: parseInt(initialItem.id.replace(/^tmdb_/, ''), 10),
        overview: ''
    } : null;
    const defaultTVDetails: TVSeasonViewModel | null = isTVSeason && initialItem ? {
        title: initialItem.title,
        year: initialItem.year,
        posterUrl: initialItem.posterUrl,
        backdropUrl: null,
        overview: '',
        genres: initialItem.genres,
        creator: initialItem.creator,
        seasonTitle: initialItem.seasonTitle,
        episodeCount: initialItem.episodeCount,
    } : null;

    const [movie, setMovie] = useState<TMDBMovie | null>(defaultMovie);
    const [tvDetails, setTvDetails] = useState<TVSeasonViewModel | null>(defaultTVDetails);
    const [streaming, setStreaming] = useState<StreamingAvailability | null>(null);
    const [director, setDirector] = useState<string | null>(initialItem?.director ?? initialItem?.creator ?? null);

    const [rankedItem, setRankedItem] = useState<RankedItem | null>(initialItem ?? null);
    const [rankContext, setRankContext] = useState<{ above: string, below: string, date: string } | null>(null);

    const [socialStats, setSocialStats] = useState<MovieSocialStats | null>(null);
    const [journalOpen, setJournalOpen] = useState(false);
    const [linkCopied, setLinkCopied] = useState(false);
    const { user } = useAuth();
    const { locale, t } = useTranslation();

    const handleShare = async () => {
        const url = `${window.location.origin}/app?movieId=${encodeURIComponent(tmdbId)}`;
        const copied = await shareOrCopyLink(detailTitle ?? t('detail.shareTitle'), url);
        if (copied) {
            setLinkCopied(true);
            setTimeout(() => setLinkCopied(false), 2000);
        }
    };
    const [socialLoading, setSocialLoading] = useState(true);

    useEffect(() => {
        // Esc to close
        const handleKeyDown = (e: KeyboardEvent) => {
            if (e.key === 'Escape') onClose();
        };
        window.addEventListener('keydown', handleKeyDown);
        return () => window.removeEventListener('keydown', handleKeyDown);
    }, [onClose]);

    useEffect(() => {
        let didCancel = false;

        const fetchData = async () => {
            const { data: userData } = await supabase.auth.getUser();
            const userId = userData.user?.id;
            if (didCancel) return;

            if (isTVSeason && tvTarget?.showTmdbId && tvTarget.seasonNumber) {
                const [show, season] = await Promise.all([
                    getTVShowDetails(tvTarget.showTmdbId),
                    getTVSeasonDetails(tvTarget.showTmdbId, tvTarget.seasonNumber, initialItem?.title ?? ''),
                ]);

                if (!didCancel && (show || season)) {
                    setTvDetails((prev) => ({
                        title: show?.name ?? prev?.title ?? initialItem?.title ?? '',
                        year: season?.airDate?.slice(0, 4) ?? show?.year ?? prev?.year ?? initialItem?.year ?? '',
                        posterUrl: season?.posterUrl ?? show?.posterUrl ?? prev?.posterUrl ?? initialItem?.posterUrl ?? '',
                        backdropUrl: show?.backdropUrl ?? prev?.backdropUrl ?? null,
                        overview: season?.overview || show?.overview || prev?.overview || '',
                        genres: show?.genres ?? prev?.genres ?? initialItem?.genres ?? [],
                        creator: show?.creators[0] ?? prev?.creator ?? initialItem?.creator,
                        seasonTitle: season?.name ?? prev?.seasonTitle ?? initialItem?.seasonTitle,
                        episodeCount: season?.episodeCount ?? prev?.episodeCount ?? initialItem?.episodeCount,
                        voteAverage: show?.voteAverage ?? prev?.voteAverage,
                    }));
                    setDirector(show?.creators[0] ?? initialItem?.creator ?? null);
                }
            } else if (!movie?.backdropUrl || !streaming) {
                // tmdbId might be "tmdb_123" or "123"
                const numericId = parseInt(tmdbId.replace('tmdb_', ''), 10);
                if (!isNaN(numericId)) {
                    const extended = await getExtendedMovieDetails(numericId);
                    if (!didCancel && extended) {
                        setMovie(prev => ({ ...prev, ...extended.movie } as TMDBMovie));
                        setStreaming(extended.streaming);
                        if (extended.director) setDirector(extended.director);
                    }
                }
            }

            if (!userId) {
                if (!didCancel) setSocialLoading(false);
                return;
            }

            // Fetch User's specific ranking context from the correct table
            const { data: ranks } = await supabase
                .from(rankingTable)
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
                            type: isTVSeason ? 'tv_season' : 'movie',
                            genres: item.genres,
                            director: isTVSeason ? undefined : item.director,
                            creator: isTVSeason ? item.creator : undefined,
                            showTmdbId: isTVSeason ? item.show_tmdb_id : undefined,
                            seasonNumber: isTVSeason ? item.season_number : undefined,
                            seasonTitle: isTVSeason ? item.season_title : undefined,
                            episodeCount: isTVSeason ? item.episode_count : undefined,
                            tier: item.tier as Tier,
                            rank: item.rank_position,
                            bracket: item.bracket as Bracket,
                            notes: item.notes,
                        });
                    }

                    // Compute "Ranked above X, below Y" within same tier
                    const sameTier = ranks.filter(r => r.tier === item.tier).sort((a, b) => a.rank_position - b.rank_position);
                    const subIndex = sameTier.findIndex(r => r.tmdb_id === tmdbId);

                    let aboveStr = '';
                    let belowStr = '';
                    if (subIndex > 0) aboveStr = sameTier[subIndex - 1].title;
                    if (subIndex < sameTier.length - 1) belowStr = sameTier[subIndex + 1].title;

                    setRankContext({
                        above: aboveStr,
                        below: belowStr,
                        date: new Date(item.updated_at).toLocaleDateString(locale, { month: 'short', day: 'numeric', year: 'numeric' })
                    });
                }
            }

            setSocialLoading(true);
            const stats = isTVSeason
                ? await getTVSocialStats(userId, tmdbId)
                : await getMovieSocialStats(userId, tmdbId);
            if (!didCancel) {
                setSocialStats(stats);
                setSocialLoading(false);
            }
        };

        fetchData();
        return () => {
            didCancel = true;
        };
    }, [tmdbId, initialItem, isTVSeason, rankingTable, tvTarget?.showTmdbId, tvTarget?.seasonNumber, locale]);

    const detailTitle = isTVSeason ? (tvDetails?.title ?? initialItem?.title ?? '') : (movie?.title ?? '');
    const detailYear = isTVSeason ? (tvDetails?.year ?? initialItem?.year ?? '') : (movie?.year ?? '');
    const detailPosterUrl = isTVSeason ? (tvDetails?.posterUrl ?? initialItem?.posterUrl ?? '') : (movie?.posterUrl ?? '');
    const detailBackdropUrl = isTVSeason ? (tvDetails?.backdropUrl ?? null) : (movie?.backdropUrl ?? null);
    const detailGenres = isTVSeason ? (tvDetails?.genres ?? initialItem?.genres ?? []) : (movie?.genres ?? []);
    const detailOverview = isTVSeason ? (tvDetails?.overview ?? '') : (movie?.overview ?? '');
    const detailSeasonTitle = isTVSeason ? (tvDetails?.seasonTitle ?? initialItem?.seasonTitle) : undefined;
    const detailEpisodeCount = isTVSeason ? (tvDetails?.episodeCount ?? initialItem?.episodeCount) : undefined;
    const detailVoteAverage = isTVSeason ? tvDetails?.voteAverage : movie?.voteAverage;

    if (!detailTitle) return null;

    return (
        <FocusTrap focusTrapOptions={{ allowOutsideClick: true }}>
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-md transition-opacity">
            {/* Click outside to close */}
            <div className="absolute inset-0" onClick={onClose} />

            {/* Modal Container */}
            <div
                className="relative w-full h-full sm:h-[90vh] sm:rounded-3xl sm:max-w-2xl bg-card sm:shadow-2xl flex flex-col overflow-hidden"
                onClick={(e) => e.stopPropagation()}
            >
                {/* Close Button */}
                <button
                    onClick={onClose}
                    className="absolute top-4 right-4 z-20 p-2 bg-black/50 backdrop-blur-md rounded-full text-foreground/70 hover:text-foreground hover:bg-black/80 transition"
                    aria-label="Close"
                >
                    <X size={20} />
                </button>

                {/* Scrollable Content */}
                <div className="flex-1 overflow-y-auto overflow-x-hidden hide-scrollbar">

                    {/* 🎬 Hero Section */}
                    <div className="relative w-full pb-6 border-b border-border/30">
                        {/* Backdrop */}
                        <div className="absolute inset-0 h-80 bg-card overflow-hidden">
                            {detailBackdropUrl ? (
                                <img src={detailBackdropUrl} alt="" className="w-full h-full object-cover opacity-60 mix-blend-screen animate-fade-in" />
                            ) : (
                                <div className="w-full h-full animate-pulse bg-secondary" />
                            )}
                            <div className="absolute inset-0 bg-gradient-to-t from-bg via-bg/80 to-transparent" />
                        </div>

                        <div className="relative pt-32 px-6 flex flex-col items-center">
                            <div className="w-32 sm:w-40 aspect-[2/3] rounded-xl shadow-[0_10px_40px_rgba(0,0,0,0.8)] overflow-hidden border border-border/30 shrink-0">
                                <img src={detailPosterUrl} alt={`${detailTitle} poster`} className="w-full h-full object-cover" />
                            </div>

                            <h2 className="mt-5 text-3xl font-serif text-foreground text-center leading-tight tracking-tight">
                                {detailTitle}
                            </h2>

                            {isTVSeason && detailSeasonTitle && (
                                <p className="mt-1 text-sm text-purple-400 font-medium text-center">
                                    {detailSeasonTitle}
                                    {detailEpisodeCount ? ` · ${detailEpisodeCount} ${t('detail.episodes')}` : ''}
                                </p>
                            )}

                            <div className="mt-2 flex items-center justify-center gap-2 text-sm text-muted-foreground">
                                <span className="font-semibold text-muted-foreground">{detailYear}</span>
                                {director && (
                                    <>
                                        <span>·</span>
                                        <span>{director}</span>
                                    </>
                                )}
                                {!isTVSeason && movie?.runtime && (
                                    <>
                                        <span>·</span>
                                        <span>{Math.floor(movie.runtime / 60)}h {movie.runtime % 60}m</span>
                                    </>
                                )}
                            </div>

                            {detailGenres.length > 0 && (
                                <div className="mt-3 flex flex-wrap justify-center gap-1.5">
                                    {detailGenres.map(g => (
                                        <span key={g} className="px-2.5 py-1 text-[11px] font-bold tracking-wider uppercase bg-white/5 border border-border/30 rounded-full text-muted-foreground">
                                            {g}
                                        </span>
                                    ))}
                                </div>
                            )}

                            {detailOverview && (
                                <p className="mt-5 text-sm text-muted-foreground text-center leading-relaxed max-w-md">
                                    {detailOverview}
                                </p>
                            )}

                            {/* Streaming Badges */}
                            {streaming?.flatrate && streaming.flatrate.length > 0 && (
                                <div className="mt-6 flex flex-col items-center">
                                    <span className="text-xs font-semibold text-muted-foreground uppercase tracking-widest mb-2">{t('detail.streamNow')}</span>
                                    <div className="flex gap-2">
                                        {streaming.flatrate.map(p => (
                                            <div key={p.providerId} className="w-8 h-8 rounded-lg overflow-hidden border border-border/30 opacity-80 hover:opacity-100 transition shadow-sm" title={p.providerName}>
                                                <img src={p.logoUrl} alt={p.providerName} className="w-full h-full object-cover" />
                                            </div>
                                        ))}
                                    </div>
                                </div>
                            )}
                        </div>
                    </div>

                    {/* 📊 Scores Banner */}
                    <div className="px-6 py-6 border-b border-border/30 flex justify-between gap-4">
                        <div className="flex-1 bg-white/5 rounded-2xl p-4 flex flex-col items-center justify-center text-center border border-border/30">
                            <span className="text-[10px] font-bold uppercase tracking-widest text-muted-foreground mb-1">{t('detail.globalScore')}</span>
                            <div className="flex items-center gap-1">
                                <Star size={14} className="text-gold fill-current" />
                                <span className="text-xl font-black text-foreground">{detailVoteAverage?.toFixed(1) || '--'}</span>
                            </div>
                        </div>

                        <div className="flex-1 bg-white/5 rounded-2xl p-4 flex flex-col items-center justify-center text-center border border-gold/20 shadow-[0_0_15px_rgba(99,102,241,0.1)]">
                            <span className="text-[10px] font-bold uppercase tracking-widest text-accent mb-1">{t('detail.yourScore')}</span>
                            <div className="flex items-center gap-1">
                                {rankedItem ? (
                                    <>
                                        <span className={`w-2 h-2 rounded-full ${TIER_COLORS[rankedItem.tier].replace('border-', 'bg-').replace('text-', 'bg-')}`} />
                                        <span className="text-xl font-black text-foreground">{userScore?.toFixed(1) ?? rankedItem.tier}</span>
                                    </>
                                ) : (
                                    <span className="text-xl font-bold text-muted-foreground/60">--</span>
                                )}
                            </div>
                            {rankedItem && <span className="text-[9px] text-muted-foreground mt-1">{rankedItem.tier} {t('detail.tierSuffix')}</span>}
                        </div>

                        <div className="flex-1 bg-white/5 rounded-2xl p-4 flex flex-col items-center justify-center text-center border border-border/30">
                            <span className="text-[10px] font-bold uppercase tracking-widest text-muted-foreground mb-1">{t('detail.friendAvg')}</span>
                            <div className="flex items-center gap-1">
                                {socialStats?.avgFriendScore !== undefined ? (
                                    <span className="text-xl font-black text-foreground">{socialStats.avgFriendScore}</span>
                                ) : (
                                    <span className="text-xl font-bold text-muted-foreground/60">--</span>
                                )}
                            </div>
                            {socialStats?.avgFriendScore !== undefined && (
                                <span className="text-[9px] text-muted-foreground mt-1">{t('detail.outOf10')}</span>
                            )}
                        </div>
                    </div>

                    {/* 📊 Your Ranking Context */}
                    <div className="px-6 py-8 border-b border-border/30">
                        {rankedItem ? (
                            <div className="bg-white/5 border border-border/30 rounded-2xl p-5">
                                <div className="flex items-start justify-between">
                                    <div>
                                        <div className="flex items-center gap-2">
                                            <div className={`px-1.5 py-0.5 rounded-full text-[10px] font-bold border ${TIER_COLORS[rankedItem.tier]}`}>
                                                {rankedItem.tier}
                                            </div>
                                            <h3 className="text-lg font-bold text-foreground">{t('detail.yourRank').replace('{rank}', String(rankedItem.rank + 1))}</h3>
                                        </div>

                                        {(rankContext?.above || rankContext?.below) && (
                                            <div className="mt-2 text-sm text-muted-foreground leading-relaxed">
                                                {rankContext.above && <span>{t('detail.rankedAbove')} <span className="text-foreground italic">{rankContext.above}</span></span>}
                                                {rankContext.above && rankContext.below && <span> · </span>}
                                                {rankContext.below && <span>{t('detail.rankedBelow')} <span className="text-foreground italic">{rankContext.below}</span></span>}
                                            </div>
                                        )}

                                        {rankContext?.date && (
                                            <div className="mt-3 flex items-center gap-1.5 text-xs text-muted-foreground font-mono uppercase tracking-wide">
                                                <Star size={12} /> {t('detail.watched')} {rankContext.date}
                                            </div>
                                        )}
                                    </div>

                                    <button
                                        onClick={() => { if (rankedItem && onRerank) { onRerank(rankedItem); onClose(); } }}
                                        className="px-4 py-2 bg-white/5 hover:bg-white/10 border border-border/30 rounded-xl text-xs font-bold transition flex items-center gap-2"
                                    >
                                        <RefreshCw size={12} />
                                        {t('detail.reRank')}
                                    </button>
                                </div>
                            </div>
                        ) : (
                            <div className="bg-white/5 border border-border/30 rounded-2xl p-6 text-center">
                                <h3 className="text-lg font-bold text-foreground mb-1">{t('detail.notYetRanked')}</h3>
                                <p className="text-sm text-muted-foreground mb-4">
                                    {isTVSeason ? t('detail.addSeasonHint') : t('detail.addMovieHint')}
                                </p>
                                {!isTVSeason && (
                                    <div className="flex justify-center gap-3">
                                        <button
                                            onClick={() => { if (movie && onStartRanking) onStartRanking(movie); }}
                                            className="px-5 py-2.5 bg-gold hover:bg-gold-muted text-foreground font-bold rounded-xl text-sm transition"
                                        >
                                            {t('detail.iveWatchedThis')}
                                        </button>
                                        <button
                                            onClick={() => { if (movie && onSaveForLater) onSaveForLater(movie); }}
                                            className="px-5 py-2.5 bg-white/10 hover:bg-white/15 text-foreground font-bold rounded-xl text-sm transition border border-border/30"
                                        >
                                            {t('detail.wantToWatch')}
                                        </button>
                                    </div>
                                )}
                            </div>
                        )}
                    </div>

                    {/* Friends' Corner */}
                    <div className="px-6 py-8 pb-16">
                        <h3 className="text-xs font-bold text-muted-foreground uppercase tracking-widest mb-4">{t('detail.friendsThink')}</h3>

                        {socialLoading ? (
                            <div className="animate-pulse flex gap-3 h-16 bg-white/5 rounded-xl border border-border/30" />
                        ) : socialStats && socialStats.friendsWatched > 0 ? (
                            <div className="space-y-4">

                                <div className="flex items-center gap-4">
                                    <div className="flex -space-x-2">
                                        {socialStats.friendAvatars.map((url, i) => (
                                            <div key={i} className="w-8 h-8 rounded-full border-2 border-[#0a0a0c] bg-secondary overflow-hidden">
                                                <img src={url} alt="" className="w-full h-full object-cover" />
                                            </div>
                                        ))}
                                    </div>
                                    <div className="text-sm font-medium text-muted-foreground">
                                        <span className="text-foreground font-bold">{socialStats.friendsWatched === 1 ? t('detail.friendWatched') : t('detail.friendsWatched').replace('{count}', String(socialStats.friendsWatched))}</span>
                                    </div>
                                </div>

                                {/* Individual friend scores */}
                                {socialStats.friendRankings.length > 0 && (
                                    <div className="space-y-2">
                                        {socialStats.friendRankings.map((fr) => (
                                            <div key={fr.userId} className="flex items-center gap-3 bg-white/5 border border-border/30 rounded-xl px-3 py-2">
                                                <div className="w-7 h-7 rounded-full border border-border bg-secondary overflow-hidden flex-shrink-0">
                                                    {fr.avatarUrl ? (
                                                        <img src={fr.avatarUrl} alt={fr.username} className="w-full h-full object-cover" />
                                                    ) : (
                                                        <div className="w-full h-full flex items-center justify-center text-[10px] text-muted-foreground font-bold bg-card">
                                                            {fr.username.charAt(0).toUpperCase()}
                                                        </div>
                                                    )}
                                                </div>
                                                <span className="text-sm font-semibold text-foreground flex-1">{fr.username}</span>
                                                <div className={`px-1.5 py-0.5 rounded text-[10px] font-bold border ${TIER_COLORS[fr.tier]}`}>
                                                    {fr.tier}
                                                </div>
                                                <span className="text-sm font-black text-foreground w-10 text-right">{fr.score}</span>
                                            </div>
                                        ))}
                                    </div>
                                )}

                                {socialStats.avgFriendScore !== undefined && (
                                    <div className="inline-flex items-center gap-2 bg-accent/10 border border-gold/20 px-3 py-1.5 rounded-lg text-accent text-sm font-semibold">
                                        <div className="w-1.5 h-1.5 rounded-full bg-accent" />
                                        {t('detail.avgScore').replace('{score}', String(socialStats.avgFriendScore))}
                                    </div>
                                )}

                                {socialStats.topFriendReview && (
                                    <div className="bg-white/5 border border-border/30 rounded-xl p-4 mt-2">
                                        <p className="text-base text-foreground font-medium italic">"{socialStats.topFriendReview.body}"</p>
                                        <div className="flex items-center gap-2 mt-3 text-xs text-muted-foreground">
                                            <img src={socialStats.topFriendReview.avatarUrl} alt={socialStats.topFriendReview.username} className="w-5 h-5 rounded-full" />
                                            <span className="font-semibold text-muted-foreground">{socialStats.topFriendReview.username}</span>
                                            <span>{t('detail.rankedIt')} <span className="font-bold text-foreground">#{socialStats.topFriendReview.rankPosition + 1}</span></span>
                                        </div>
                                    </div>
                                )}

                                {socialStats?.recentActivity && socialStats.recentActivity.length > 0 && (
                                    <div className="mt-6 pt-6 border-t border-border/20">
                                        <h4 className="text-[10px] font-bold text-muted-foreground uppercase tracking-widest mb-3">{t('detail.recentActivity')}</h4>
                                        <div className="space-y-4">
                                            {socialStats.recentActivity.map(activity => (
                                                <div key={activity.id} className="flex items-center gap-3">
                                                    <div className="w-8 h-8 rounded-full border border-border bg-secondary overflow-hidden flex-shrink-0">
                                                        {activity.avatarUrl ? (
                                                            <img src={activity.avatarUrl} alt={activity.username} className="w-full h-full object-cover" />
                                                        ) : (
                                                            <div className="w-full h-full flex items-center justify-center text-[10px] text-muted-foreground font-bold bg-card">
                                                                {activity.username.charAt(0).toUpperCase()}
                                                            </div>
                                                        )}
                                                    </div>
                                                    <div className="flex-1 min-w-0">
                                                        <p className="text-xs text-muted-foreground">
                                                            <span className="font-bold text-foreground">{activity.username}</span>
                                                            {' '}
                                                            {activity.action === 'ranked' && (
                                                                <>{t('detail.rankedThis')} <span className={`text-[10px] font-bold ${TIER_COLORS[activity.tier || ''] || 'text-muted-foreground'}`}>{activity.tier || t('detail.inTheirList')}</span></>
                                                            )}
                                                            {activity.action === 'reviewed' && t('detail.leftReview')}
                                                            {activity.action === 'bookmarked' && t('detail.addedWatchlist')}
                                                        </p>
                                                        <p className="text-[10px] text-muted-foreground mt-0.5">
                                                            {new Date(activity.timestamp).toLocaleDateString(locale, { month: 'short', day: 'numeric' })}
                                                        </p>
                                                    </div>
                                                </div>
                                            ))}
                                        </div>
                                    </div>
                                )}

                                <button className="flex items-center gap-2 text-sm text-accent font-bold hover:text-accent transition group mt-6">
                                    {t('detail.seeAllFriendRankings').replace('{count}', String(socialStats.friendsWatched))}
                                    <ChevronRight size={14} className="group-hover:translate-x-1 transition-transform" />
                                </button>
                            </div>
                        ) : (
                            <div className="text-sm text-muted-foreground italic bg-white/5 p-4 rounded-xl border-dashed border border-border/30">
                                {t('detail.noFriendsRanked')}
                            </div>
                        )}
                    </div>
                </div>

                {/* 🎯 Action Footer (Sticky Bottom) */}
                <div className="flex-shrink-0 bg-background border-t border-border p-4 pb-[max(1rem,env(safe-area-inset-bottom))] shadow-[0_-10px_40px_rgba(0,0,0,0.5)] flex items-center gap-3">
                    {rankedItem ? (
                        <>
                            <button
                                onClick={() => setJournalOpen(true)}
                                className="flex-1 bg-gold hover:bg-gold-muted text-foreground font-bold py-3.5 rounded-xl transition flex items-center justify-center gap-2 shadow-lg shadow-gold/20 active:scale-[0.98]"
                            >
                                <MessageCircle size={18} />
                                {t('detail.leaveReview')}
                            </button>
                            <button
                                onClick={handleShare}
                                className="w-12 h-12 flex items-center justify-center bg-white/5 border border-border/30 rounded-xl hover:bg-white/10 transition text-muted-foreground hover:text-foreground"
                                title={linkCopied ? t('detail.linkCopied') : t('detail.shareLink')}
                            >
                                {linkCopied ? <Check size={18} className="text-green-400" /> : <Link size={18} />}
                            </button>
                        </>
                    ) : (
                        <>
                            {isTVSeason ? (
                                <button
                                    onClick={onClose}
                                    className="flex-1 bg-white/5 border border-border/30 text-foreground font-bold py-3.5 rounded-xl transition flex items-center justify-center gap-2 hover:bg-white/10 active:scale-[0.98]"
                                >
                                    {t('detail.close')}
                                </button>
                            ) : (
                                <>
                                    <button
                                        onClick={() => { if (movie && onStartRanking) onStartRanking(movie); }}
                                        className="flex-1 bg-gold hover:bg-gold-muted text-foreground font-bold py-3.5 rounded-xl transition flex items-center justify-center gap-2 shadow-lg shadow-gold/20 active:scale-[0.98]"
                                    >
                                        {t('detail.watched_btn')}
                                    </button>
                                    <button
                                        onClick={() => { if (movie && onSaveForLater) onSaveForLater(movie); }}
                                        className="px-6 bg-white/5 border border-border/30 text-foreground font-bold py-3.5 rounded-xl transition flex items-center justify-center gap-2 hover:bg-white/10 active:scale-[0.98]"
                                    >
                                        {t('detail.wantToWatch')}
                                    </button>
                                </>
                            )}
                        </>
                    )}
                </div>

            </div>

            {journalOpen && rankedItem && user && (
                <ErrorBoundary>
                    <JournalConversation
                        isOpen={journalOpen}
                        item={rankedItem}
                        userId={user.id}
                        onDismiss={() => setJournalOpen(false)}
                        onSaved={() => setJournalOpen(false)}
                    />
                </ErrorBoundary>
            )}
        </div>
        </FocusTrap>
    );
};
