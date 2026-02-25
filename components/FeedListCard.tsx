import React from 'react';
import { Link } from 'react-router-dom';
import { MessageCircle, List } from 'lucide-react';
import { FeedCard, ReactionType } from '../types';
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

interface FeedListCardProps {
  card: FeedCard;
  onToggleReaction: (eventId: string, reaction: ReactionType) => void;
  onMuteUser: (userId: string) => void;
  onOpenComments: (eventId: string) => void;
  commentCount: number;
}

export const FeedListCard: React.FC<FeedListCardProps> = ({
  card,
  onToggleReaction,
  onMuteUser,
  onOpenComments,
  commentCount,
}) => {
  const posters = card.listPosterUrls ?? [];

  return (
    <div className="bg-zinc-900 border border-zinc-800 rounded-xl p-4 hover:border-zinc-700 transition-colors">
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
            <div className="w-8 h-8 rounded-full bg-zinc-700 flex items-center justify-center text-xs text-zinc-300">
              {card.username.charAt(0).toUpperCase()}
            </div>
          )}
        </Link>
        <div className="text-sm">
          <Link
            to={`/profile/${card.userId}`}
            className="font-medium text-white hover:underline"
          >
            {card.displayName || card.username}
          </Link>
          <span className="text-zinc-400"> created a list</span>
        </div>
        <span className="ml-auto text-xs text-zinc-500">
          {relativeDate(card.createdAt)}
        </span>
        <FeedCardMenu
          onMuteUser={() => onMuteUser(card.userId)}
          username={card.username}
        />
      </div>

      {/* Content */}
      <div className="mb-3">
        {card.listTitle && (
          <p className="font-medium text-white text-base mb-2">
            {card.listTitle}
          </p>
        )}

        {/* Poster strip */}
        <div className="flex items-center mb-1">
          {posters.length > 0 ? (
            posters.slice(0, 4).map((url, i) => (
              <img
                key={i}
                src={url}
                alt=""
                className={`w-12 h-18 rounded-md object-cover border border-zinc-800 ${
                  i === 0 ? 'ml-0' : '-ml-2'
                } relative`}
                style={{ zIndex: posters.length - i }}
              />
            ))
          ) : (
            <div className="w-12 h-18 rounded-md bg-zinc-800 flex items-center justify-center">
              <List className="w-5 h-5 text-zinc-500" />
            </div>
          )}
        </div>

        {card.listItemCount != null && (
          <span className="text-xs text-zinc-400">
            {card.listItemCount} movies
          </span>
        )}
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
          className="flex items-center gap-1 text-xs text-zinc-400 hover:text-white transition-colors ml-auto"
        >
          <MessageCircle className="w-4 h-4" />
          {commentCount > 0 && <span>{commentCount}</span>}
        </button>
      </div>
    </div>
  );
};
