import React, { useState } from 'react';
import { Link } from 'react-router-dom';
import { MessageCircle, AlertTriangle, Eye, EyeOff } from 'lucide-react';
import { FeedCard, ReactionType } from '../types';
import { TIER_COLORS } from '../constants';
import { ReactionPicker } from './ReactionPicker';
import { FeedCardMenu } from './FeedCardMenu';

interface FeedReviewCardProps {
    card: FeedCard;
    onToggleReaction: (eventId: string, reaction: ReactionType) => void;
    onMuteUser: (userId: string) => void;
    onMuteMovie?: (tmdbId: string) => void;
    onOpenComments: (eventId: string) => void;
    commentCount: number;
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

export const FeedReviewCard: React.FC<FeedReviewCardProps> = ({
    card,
    onToggleReaction,
    onMuteUser,
    onMuteMovie,
    onOpenComments,
    commentCount,
}) => {
    const [showSpoiler, setShowSpoiler] = useState(false);
    const [expanded, setExpanded] = useState(false);

    const tierColor = card.mediaTier ? TIER_COLORS[card.mediaTier] : '';
    const reviewText = card.reviewBody ?? '';
    const isLong = reviewText.length > 280;

    return (
        <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4 hover:border-zinc-700 transition-colors">
            {/* Header */}
            <div className="flex items-start justify-between gap-3">
                <div className="flex items-center gap-3 min-w-0">
                    <Link to={`/profile/${card.userId}`} className="shrink-0">
                        <img
                            src={card.avatarUrl || `https://api.dicebear.com/8.x/thumbs/svg?seed=${card.username}`}
                            alt={card.username}
                            className="w-8 h-8 rounded-full border border-zinc-700 object-cover"
                        />
                    </Link>
                    <div className="min-w-0 flex items-center gap-2 flex-wrap">
                        <Link
                            to={`/profile/${card.userId}`}
                            className="text-sm font-semibold text-white hover:text-indigo-400 transition-colors truncate"
                        >
                            {card.displayName || card.username}
                        </Link>
                        <span className="text-xs text-zinc-500">reviewed</span>
                        {card.mediaTier && (
                            <span className={`text-xs font-bold px-1.5 py-0.5 rounded border ${tierColor}`}>
                                {card.mediaTier}
                            </span>
                        )}
                        <span className="text-xs text-zinc-500">{relativeDate(card.createdAt)}</span>
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
            <div className="mt-3 flex gap-3">
                {/* Poster */}
                {card.mediaPosterUrl && (
                    <img
                        src={card.mediaPosterUrl}
                        alt={card.mediaTitle ?? 'Movie poster'}
                        className="w-20 h-30 rounded-lg object-cover shrink-0"
                    />
                )}

                {/* Right side: title + review body */}
                <div className="min-w-0 flex-1">
                    {card.mediaTitle && (
                        <h3 className="text-sm font-semibold text-white truncate">{card.mediaTitle}</h3>
                    )}

                    <div className="mt-2">
                        {card.containsSpoilers && !showSpoiler ? (
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
                                <p className="text-sm text-zinc-300 leading-relaxed whitespace-pre-wrap">
                                    {isLong && !expanded ? `${reviewText.slice(0, 280)}...` : reviewText}
                                </p>
                                {isLong && (
                                    <button
                                        onClick={() => setExpanded(!expanded)}
                                        className="text-xs text-indigo-400 hover:text-indigo-300 mt-1 transition-colors"
                                    >
                                        {expanded ? 'Show less' : 'Show more'}
                                    </button>
                                )}
                                {card.containsSpoilers && showSpoiler && (
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
                </div>
            </div>

            {/* Footer: reactions + comments */}
            <div className="flex items-center gap-4 mt-3 pt-3 border-t border-zinc-800/50">
                <ReactionPicker
                    reactionCounts={card.reactionCounts}
                    myReactions={card.myReactions}
                    onToggle={(reaction) => onToggleReaction(card.id, reaction)}
                />
                <button
                    onClick={() => onOpenComments(card.id)}
                    className="flex items-center gap-1.5 text-xs text-zinc-500 hover:text-indigo-400 transition-colors ml-auto"
                >
                    <MessageCircle size={14} />
                    {commentCount > 0 && <span>{commentCount}</span>}
                </button>
            </div>
        </div>
    );
};

export default FeedReviewCard;
