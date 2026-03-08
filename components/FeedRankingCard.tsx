import React from 'react';
import { Link } from 'react-router-dom';
import { MessageCircle } from 'lucide-react';
import { FeedCard, ReactionType } from '../types';
import { TIER_COLORS } from '../constants';
import { ReactionPicker } from './ReactionPicker';
import { FeedCardMenu } from './FeedCardMenu';

function relativeDate(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.floor(hrs / 24);
  return `${days}d ago`;
}

interface FeedRankingCardProps {
  card: FeedCard;
  onToggleReaction: (eventId: string, reaction: ReactionType) => void;
  onMuteUser: (userId: string) => void;
  onMuteMovie?: (tmdbId: string) => void;
  onOpenComments: (eventId: string) => void;
  commentCount: number;
}

export const FeedRankingCard: React.FC<FeedRankingCardProps> = ({
  card,
  onToggleReaction,
  onMuteUser,
  onMuteMovie,
  onOpenComments,
  commentCount,
}) => {
  return (
    <div className="bg-card border border-border rounded-xl p-4 hover:border-border transition-colors">
      {/* Header */}
      <div className="flex items-center gap-2 mb-3">
        <Link to={`/profile/${card.userId}`}>
          {card.avatarUrl ? (
            <img
              src={card.avatarUrl}
              alt={card.username}
              className="w-8 h-8 rounded-full object-cover"
            />
          ) : (
            <div className="w-8 h-8 rounded-full bg-secondary flex items-center justify-center text-xs text-muted-foreground">
              {card.username.charAt(0).toUpperCase()}
            </div>
          )}
        </Link>
        <Link
          to={`/profile/${card.userId}`}
          className="text-sm font-medium text-foreground hover:underline"
        >
          {card.displayName || card.username}
        </Link>
        <span className="ml-auto text-xs text-muted-foreground">
          {relativeDate(card.createdAt)}
        </span>
        <FeedCardMenu
          onMuteUser={() => onMuteUser(card.userId)}
          onMuteMovie={
            card.mediaTmdbId ? () => onMuteMovie?.(card.mediaTmdbId!) : undefined
          }
          username={card.username}
          movieTitle={card.mediaTitle}
        />
      </div>

      {/* Content */}
      <div className="flex gap-3 mb-3">
        {card.mediaPosterUrl && (
          <img
            src={card.mediaPosterUrl}
            alt={card.mediaTitle ?? ''}
            className="w-16 h-24 rounded-lg object-cover flex-shrink-0"
          />
        )}
        <div className="flex flex-col gap-1 min-w-0">
          {card.mediaTitle && (
            <span className="font-medium text-foreground truncate">
              {card.mediaTitle}
            </span>
          )}
          {card.mediaTier && (
            <span
              className={`text-xs font-bold px-1.5 py-0.5 rounded border w-fit ${
                TIER_COLORS[card.mediaTier]
              }`}
            >
              {card.mediaTier}
            </span>
          )}
          {card.bracket && (
            <span className="text-xs text-muted-foreground">{card.bracket}</span>
          )}
        </div>
      </div>

      {/* Footer */}
      <div className="flex items-center gap-2">
        <ReactionPicker
          reactionCounts={card.reactionCounts}
          myReactions={card.myReactions}
          onToggle={(reaction) => onToggleReaction(card.id, reaction)}
        />
        <button
          onClick={() => onOpenComments(card.id)}
          className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground transition-colors ml-auto"
        >
          <MessageCircle className="w-4 h-4" />
          {commentCount > 0 && <span>{commentCount}</span>}
        </button>
      </div>
    </div>
  );
};
