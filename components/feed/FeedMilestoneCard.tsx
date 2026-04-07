import React from 'react';
import { Link } from 'react-router-dom';
import { MessageCircle, Award } from 'lucide-react';
import { FeedCard, ReactionType } from '../../types';
import { ReactionPicker } from './ReactionPicker';
import { FeedCardMenu } from './FeedCardMenu';
import { useTranslation } from '../../contexts/LanguageContext';
import { relativeDate } from '../../utils/relativeDate';

interface FeedMilestoneCardProps {
  card: FeedCard;
  onToggleReaction: (eventId: string, reaction: ReactionType) => void;
  onMuteUser: (userId: string) => void;
  onOpenComments: (eventId: string) => void;
  commentCount: number;
}

export const FeedMilestoneCard: React.FC<FeedMilestoneCardProps> = ({
  card,
  onToggleReaction,
  onMuteUser,
  onOpenComments,
  commentCount,
}) => {
  const { t, locale } = useTranslation();
  return (
    <div className="bg-card border border-border rounded-xl p-4 hover:border-border transition-colors">
      {/* Single row layout */}
      <div className="flex items-start gap-3 mb-3">
        {/* Badge icon */}
        <div className="w-10 h-10 rounded-full bg-amber-500/10 flex items-center justify-center text-lg flex-shrink-0">
          {card.badgeIcon ? (
            <span>{card.badgeIcon}</span>
          ) : (
            <Award className="w-5 h-5 text-gold" />
          )}
        </div>

        {/* Text column */}
        <div className="flex flex-col gap-0.5 min-w-0 flex-1">
          <p className="text-sm">
            <Link
              to={`/profile/${card.userId}`}
              className="font-medium text-foreground hover:underline"
            >
              {card.displayName || card.username}
            </Link>
            <span className="text-muted-foreground"> unlocked a badge</span>
          </p>
          {card.milestoneDescription && (
            <p className="text-sm text-muted-foreground">{card.milestoneDescription}</p>
          )}
          <span className="text-xs text-muted-foreground/60">
            {relativeDate(card.createdAt, t, locale)}
          </span>
        </div>

        {/* Menu */}
        <FeedCardMenu
          onMuteUser={() => onMuteUser(card.userId)}
          username={card.username}
        />
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
