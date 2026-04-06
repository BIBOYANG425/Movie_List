import React, { useState } from 'react';
import { Link } from 'react-router-dom';
import { Heart, MessageCircle, AlertTriangle, Eye, EyeOff, Trash2 } from 'lucide-react';
import { MovieReview, Tier } from '../../types';
import { TIER_COLORS } from '../../constants';
import { useTranslation } from '../../contexts/LanguageContext';
import { relativeDate } from '../../utils/relativeDate';

interface MovieReviewCardProps {
    review: MovieReview;
    currentUserId?: string;
    onLike?: (reviewId: string) => void;
    onDelete?: (reviewId: string) => void;
}

export const MovieReviewCard: React.FC<MovieReviewCardProps> = ({
    review,
    currentUserId,
    onLike,
    onDelete,
}) => {
    const { locale, t } = useTranslation();
    const [showSpoiler, setShowSpoiler] = useState(false);
    const isOwn = currentUserId === review.userId;
    const tierColor = review.ratingTier ? TIER_COLORS[review.ratingTier as Tier] : '';

    return (
        <div className="bg-card border border-border rounded-xl p-4 hover:border-border transition-colors">
            {/* Header: avatar, username, tier badge, time */}
            <div className="flex items-start justify-between gap-3">
                <div className="flex items-center gap-3 min-w-0">
                    <Link to={`/profile/${review.userId}`} className="shrink-0">
                        <img
                            src={review.avatarUrl || `https://api.dicebear.com/8.x/thumbs/svg?seed=${review.username}`}
                            alt={review.username}
                            className="w-9 h-9 rounded-full border border-border object-cover"
                        />
                    </Link>
                    <div className="min-w-0">
                        <div className="flex items-center gap-2 flex-wrap">
                            <Link
                                to={`/profile/${review.userId}`}
                                className="text-sm font-semibold text-foreground hover:text-accent transition-colors truncate"
                            >
                                {review.displayName || review.username}
                            </Link>
                            {review.ratingTier && (
                                <span className={`text-xs font-bold px-1.5 py-0.5 rounded border ${tierColor}`}>
                                    {review.ratingTier}
                                </span>
                            )}
                        </div>
                        <div className="flex items-center gap-2 mt-0.5">
                            <span className="text-xs text-muted-foreground">{relativeDate(review.createdAt, t, locale)}</span>
                            <span className="text-muted-foreground/40">·</span>
                            <span className="text-xs text-muted-foreground truncate">{review.mediaTitle}</span>
                        </div>
                    </div>
                </div>

                {isOwn && onDelete && (
                    <button
                        onClick={() => onDelete(review.id)}
                        className="p-1.5 text-muted-foreground/60 hover:text-red-400 rounded-lg hover:bg-secondary transition-colors shrink-0"
                        title="Delete review"
                    >
                        <Trash2 size={14} />
                    </button>
                )}
            </div>

            {/* Review body */}
            <div className="mt-3">
                {review.containsSpoilers && !showSpoiler ? (
                    <button
                        onClick={() => setShowSpoiler(true)}
                        className="flex items-center gap-2 px-3 py-2 rounded-lg bg-amber-500/10 border border-amber-500/20 text-gold text-sm hover:bg-amber-500/15 transition-colors w-full"
                    >
                        <AlertTriangle size={14} />
                        <span className="font-medium">Contains spoilers</span>
                        <Eye size={14} className="ml-auto" />
                        <span>Tap to reveal</span>
                    </button>
                ) : (
                    <div className="relative">
                        <p className="text-sm text-muted-foreground leading-relaxed whitespace-pre-wrap">{review.body}</p>
                        {review.containsSpoilers && showSpoiler && (
                            <button
                                onClick={() => setShowSpoiler(false)}
                                className="flex items-center gap-1 mt-2 text-xs text-gold hover:text-gold transition-colors"
                            >
                                <EyeOff size={12} />
                                <span>Hide spoilers</span>
                            </button>
                        )}
                    </div>
                )}
            </div>

            {/* Actions: like */}
            <div className="flex items-center gap-4 mt-3 pt-3 border-t border-border/50">
                <button
                    onClick={() => onLike?.(review.id)}
                    className={`flex items-center gap-1.5 text-xs transition-colors ${review.isLikedByViewer
                            ? 'text-pink-400 hover:text-pink-300'
                            : 'text-muted-foreground hover:text-pink-400'
                        }`}
                >
                    <Heart size={14} className={review.isLikedByViewer ? 'fill-current' : ''} />
                    <span>{review.likeCount > 0 ? review.likeCount : ''}</span>
                </button>
            </div>
        </div>
    );
};

export default MovieReviewCard;
