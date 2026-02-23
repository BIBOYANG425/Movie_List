import React, { useState } from 'react';
import { Link } from 'react-router-dom';
import { Heart, MessageCircle, AlertTriangle, Eye, EyeOff, Trash2 } from 'lucide-react';
import { MovieReview, Tier } from '../types';
import { TIER_COLORS } from '../constants';

interface MovieReviewCardProps {
    review: MovieReview;
    currentUserId?: string;
    onLike?: (reviewId: string) => void;
    onDelete?: (reviewId: string) => void;
}

function relativeDate(iso: string): string {
    const diff = Date.now() - new Date(iso).getTime();
    const mins = Math.floor(diff / 60000);
    if (mins < 1) return 'just now';
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return `${hrs}h ago`;
    const days = Math.floor(hrs / 24);
    if (days < 7) return `${days}d ago`;
    return new Date(iso).toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

export const MovieReviewCard: React.FC<MovieReviewCardProps> = ({
    review,
    currentUserId,
    onLike,
    onDelete,
}) => {
    const [showSpoiler, setShowSpoiler] = useState(false);
    const isOwn = currentUserId === review.userId;
    const tierColor = review.ratingTier ? TIER_COLORS[review.ratingTier as Tier] : '';

    return (
        <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4 hover:border-zinc-700 transition-colors">
            {/* Header: avatar, username, tier badge, time */}
            <div className="flex items-start justify-between gap-3">
                <div className="flex items-center gap-3 min-w-0">
                    <Link to={`/profile/${review.userId}`} className="shrink-0">
                        <img
                            src={review.avatarUrl || `https://api.dicebear.com/8.x/thumbs/svg?seed=${review.username}`}
                            alt={review.username}
                            className="w-9 h-9 rounded-full border border-zinc-700 object-cover"
                        />
                    </Link>
                    <div className="min-w-0">
                        <div className="flex items-center gap-2 flex-wrap">
                            <Link
                                to={`/profile/${review.userId}`}
                                className="text-sm font-semibold text-white hover:text-indigo-400 transition-colors truncate"
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
                            <span className="text-xs text-zinc-500">{relativeDate(review.createdAt)}</span>
                            <span className="text-zinc-700">·</span>
                            <span className="text-xs text-zinc-500 truncate">{review.mediaTitle}</span>
                        </div>
                    </div>
                </div>

                {isOwn && onDelete && (
                    <button
                        onClick={() => onDelete(review.id)}
                        className="p-1.5 text-zinc-600 hover:text-red-400 rounded-lg hover:bg-zinc-800 transition-colors shrink-0"
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
                        className="flex items-center gap-2 px-3 py-2 rounded-lg bg-amber-500/10 border border-amber-500/20 text-amber-400 text-sm hover:bg-amber-500/15 transition-colors w-full"
                    >
                        <AlertTriangle size={14} />
                        <span className="font-medium">Contains spoilers</span>
                        <Eye size={14} className="ml-auto" />
                        <span>Tap to reveal</span>
                    </button>
                ) : (
                    <div className="relative">
                        <p className="text-sm text-zinc-300 leading-relaxed whitespace-pre-wrap">{review.body}</p>
                        {review.containsSpoilers && showSpoiler && (
                            <button
                                onClick={() => setShowSpoiler(false)}
                                className="flex items-center gap-1 mt-2 text-xs text-amber-500 hover:text-amber-400 transition-colors"
                            >
                                <EyeOff size={12} />
                                <span>Hide spoilers</span>
                            </button>
                        )}
                    </div>
                )}
            </div>

            {/* Actions: like */}
            <div className="flex items-center gap-4 mt-3 pt-3 border-t border-zinc-800/50">
                <button
                    onClick={() => onLike?.(review.id)}
                    className={`flex items-center gap-1.5 text-xs transition-colors ${review.isLikedByViewer
                            ? 'text-pink-400 hover:text-pink-300'
                            : 'text-zinc-500 hover:text-pink-400'
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
