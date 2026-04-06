import React from 'react';
import { Link } from 'react-router-dom';
import { MessageCircle, List } from 'lucide-react';
import { FeedCard, ReactionType } from '../../types';
import { ReactionPicker } from './ReactionPicker';
import { FeedCardMenu } from './FeedCardMenu';
import { useTranslation } from '../../contexts/LanguageContext';
import { relativeDate } from '../../utils/relativeDate';

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
  const { t } = useTranslation();
  const posters = card.listPosterUrls ?? [];

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
        <div className="text-sm">
          <Link
            to={`/profile/${card.userId}`}
            className="font-medium text-foreground hover:underline"
          >
            {card.displayName || card.username}
          </Link>
          <span className="text-muted-foreground"> created a list</span>
        </div>
        <span className="ml-auto text-xs text-muted-foreground">
          {relativeDate(card.createdAt, t)}
        </span>
        <FeedCardMenu
          onMuteUser={() => onMuteUser(card.userId)}
          username={card.username}
        />
      </div>

      {/* Content */}
      <div className="mb-3">
        {card.listTitle && (
          <p className="font-medium text-foreground text-base mb-2">
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
                className={`w-12 h-18 rounded-md object-cover border border-border ${
                  i === 0 ? 'ml-0' : '-ml-2'
                } relative`}
                style={{ zIndex: posters.length - i }}
              />
            ))
          ) : (
            <div className="w-12 h-18 rounded-md bg-secondary flex items-center justify-center">
              <List className="w-5 h-5 text-muted-foreground" />
            </div>
          )}
        </div>

        {card.listItemCount != null && (
          <span className="text-xs text-muted-foreground">
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
          className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground transition-colors ml-auto"
        >
          <MessageCircle className="w-4 h-4" />
          {commentCount > 0 && <span>{commentCount}</span>}
        </button>
      </div>
    </div>
  );
};
