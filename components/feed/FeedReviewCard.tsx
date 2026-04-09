import React, { useState } from 'react';
import { Link } from 'react-router-dom';
import { MessageCircle, AlertTriangle, Eye, EyeOff } from 'lucide-react';
import { FeedCard, ReactionType } from '../../types';
import { TIER_COLORS, TIER_BORDER_ACCENT, TIER_SCORE_BG } from '../../constants';
import { ReactionPicker } from './ReactionPicker';
import { FeedCardMenu } from './FeedCardMenu';
import { useTranslation } from '../../contexts/LanguageContext';
import { relativeDate } from '../../utils/relativeDate';

interface FeedReviewCardProps {
    card: FeedCard;
    onToggleReaction: (eventId: string, reaction: ReactionType) => void;
    onMuteUser: (userId: string) => void;
    onMuteMovie?: (tmdbId: string) => void;
    onOpenComments: (eventId: string) => void;
    onMovieClick?: (tmdbId: string) => void;
    commentCount: number;
}

export const FeedReviewCard: React.FC<FeedReviewCardProps> = ({
    card,
    onToggleReaction,
    onMuteUser,
    onMuteMovie,
    onOpenComments,
    onMovieClick,
    commentCount,
}) => {
    const { locale, t } = useTranslation();
    const [showSpoiler, setShowSpoiler] = useState(false);
    const [expanded, setExpanded] = useState(false);

    const tierColor = card.mediaTier ? TIER_COLORS[card.mediaTier] : '';
    const tierAccent = card.mediaTier ? TIER_BORDER_ACCENT[card.mediaTier] : '';
    const reviewText = card.reviewBody ?? '';
    const isLong = reviewText.length > 280;

    const handleCardClick = (e: React.MouseEvent) => {
        const target = e.target as HTMLElement;
        if (target.closest('a, button, [role="button"]')) return;
        onOpenComments(card.id);
    };

    const handleMovieClick = (e: React.MouseEvent) => {
        e.stopPropagation();
        if (card.mediaTmdbId && onMovieClick) {
            onMovieClick(card.mediaTmdbId);
        }
    };

    return (
        <div
            className={`bg-card border border-border rounded-xl p-3 sm:p-4 hover:border-muted-foreground/30 transition-colors cursor-pointer ${tierAccent ? `border-l-[3px] ${tierAccent}` : ''}`}
            onClick={handleCardClick}
        >
            {/* Header */}
            <div className="flex items-start justify-between gap-2 sm:gap-3">
                <div className="flex items-center gap-2 sm:gap-3 min-w-0">
                    <Link to={`/profile/${card.userId}`} className="shrink-0" onClick={(e) => e.stopPropagation()}>
                        <img
                            src={card.avatarUrl || `https://api.dicebear.com/8.x/thumbs/svg?seed=${card.username}`}
                            alt={card.username}
                            className="w-7 h-7 sm:w-8 sm:h-8 rounded-full border border-border object-cover"
                        />
                    </Link>
                    <div className="min-w-0 flex items-center gap-1.5 sm:gap-2 flex-wrap">
                        <Link
                            to={`/profile/${card.userId}`}
                            className="text-xs sm:text-sm font-semibold text-foreground hover:text-accent transition-colors truncate"
                            onClick={(e) => e.stopPropagation()}
                        >
                            {card.displayName || card.username}
                        </Link>
                        <span className="text-xs text-muted-foreground">{t('feed.reviewed')}</span>
                        {card.mediaTier && (
                            <span className={`text-xs font-bold px-1.5 py-0.5 rounded border ${tierColor}`}>
                                {card.mediaTier}
                            </span>
                        )}
                        <span className="text-xs text-muted-foreground">{relativeDate(card.createdAt, t, locale)}</span>
                    </div>
                </div>

                <FeedCardMenu
                    onMuteUser={() => onMuteUser(card.userId)}
                    onMuteMovie={card.mediaTmdbId && onMuteMovie ? () => onMuteMovie(card.mediaTmdbId!) : undefined}
                    username={card.username}
                    movieTitle={card.mediaTitle}
                />
            </div>

            {/* Content area */}
            <div className="mt-2 sm:mt-3 flex gap-2 sm:gap-3">
                {/* Score badge */}
                {card.mediaTier && card.mediaScore != null && (
                    <div className={`flex flex-col items-center justify-center w-8 sm:w-10 flex-shrink-0 rounded-lg ${TIER_SCORE_BG[card.mediaTier]}`}>
                        <span className="text-base sm:text-lg font-bold leading-none">{card.mediaScore.toFixed(1)}</span>
                        <span className="text-[10px] font-semibold opacity-70">/10</span>
                    </div>
                )}
                {/* Poster */}
                {card.mediaPosterUrl && (
                    <img
                        src={card.mediaPosterUrl}
                        alt={card.mediaTitle ?? 'Movie poster'}
                        className={`w-14 h-21 sm:w-20 sm:h-30 rounded-lg object-cover shrink-0 ${card.mediaTmdbId && onMovieClick ? 'cursor-pointer hover:ring-2 hover:ring-gold/50 transition-all' : ''}`}
                        onClick={handleMovieClick}
                    />
                )}

                {/* Right side: title + review body */}
                <div className="min-w-0 flex-1">
                    {card.mediaTitle && (
                        <h3
                            className={`text-xs sm:text-sm font-semibold text-foreground truncate ${card.mediaTmdbId && onMovieClick ? 'cursor-pointer hover:text-gold transition-colors' : ''}`}
                            onClick={handleMovieClick}
                        >
                            {card.mediaTitle}
                        </h3>
                    )}

                    <div className="mt-2">
                        {card.containsSpoilers && !showSpoiler ? (
                            <button
                                onClick={() => setShowSpoiler(true)}
                                className="flex items-center gap-2 px-3 py-2 rounded-lg bg-amber-500/10 border border-amber-500/20 text-gold text-sm hover:bg-amber-500/15 transition-colors w-full"
                            >
                                <AlertTriangle size={14} />
                                <span className="font-medium">{t('feed.containsSpoilers')}</span>
                                <Eye size={14} className="ml-auto" />
                                <span>{t('feed.tapToReveal')}</span>
                            </button>
                        ) : (
                            <div className="relative">
                                <p className="text-sm text-muted-foreground leading-relaxed whitespace-pre-wrap">
                                    {isLong && !expanded ? `${reviewText.slice(0, 280)}...` : reviewText}
                                </p>
                                {isLong && (
                                    <button
                                        onClick={() => setExpanded(!expanded)}
                                        className="text-xs text-accent hover:text-accent mt-1 transition-colors"
                                    >
                                        {expanded ? t('feed.showLess') : t('feed.showMore')}
                                    </button>
                                )}
                                {card.containsSpoilers && showSpoiler && (
                                    <button
                                        onClick={() => setShowSpoiler(false)}
                                        className="flex items-center gap-1 mt-2 text-xs text-gold hover:text-gold transition-colors"
                                    >
                                        <EyeOff size={12} />
                                        <span>{t('feed.hideSpoilers')}</span>
                                    </button>
                                )}
                            </div>
                        )}
                    </div>
                </div>
            </div>

            {/* Footer: reactions + comments */}
            <div className="flex items-center gap-3 sm:gap-4 mt-2 sm:mt-3 pt-2 sm:pt-3 border-t border-border/50">
                <ReactionPicker
                    reactionCounts={card.reactionCounts}
                    myReactions={card.myReactions}
                    onToggle={(reaction) => onToggleReaction(card.id, reaction)}
                />
                <button
                    onClick={() => onOpenComments(card.id)}
                    className="flex items-center gap-1.5 text-xs text-muted-foreground hover:text-accent transition-colors ml-auto"
                >
                    <MessageCircle size={14} />
                    {commentCount > 0 && <span>{commentCount}</span>}
                </button>
            </div>
        </div>
    );
};

export default FeedReviewCard;
