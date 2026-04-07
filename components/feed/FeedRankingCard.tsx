import React from 'react';
import { Link } from 'react-router-dom';
import { MessageCircle, Users } from 'lucide-react';
import { FeedCard, ReactionType } from '../../types';
import { TIER_COLORS, TIER_LABELS, TIER_BORDER_ACCENT, TIER_SCORE_BG } from '../../constants';
import { ReactionPicker } from './ReactionPicker';
import { FeedCardMenu } from './FeedCardMenu';
import { useTranslation } from '../../contexts/LanguageContext';
import { relativeDate } from '../../utils/relativeDate';

interface FeedRankingCardProps {
  card: FeedCard;
  onToggleReaction: (eventId: string, reaction: ReactionType) => void;
  onMuteUser: (userId: string) => void;
  onMuteMovie?: (tmdbId: string) => void;
  onOpenComments: (eventId: string) => void;
  onMovieClick?: (tmdbId: string) => void;
  commentCount: number;
}

export const FeedRankingCard: React.FC<FeedRankingCardProps> = ({
  card,
  onToggleReaction,
  onMuteUser,
  onMuteMovie,
  onOpenComments,
  onMovieClick,
  commentCount,
}) => {
  const { t, locale } = useTranslation();
  const tierAccent = card.mediaTier ? TIER_BORDER_ACCENT[card.mediaTier] : '';

  const handleCardClick = (e: React.MouseEvent) => {
    // Don't trigger if clicking an interactive element
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
      <div className="flex items-center gap-2 mb-2 sm:mb-3">
        <Link to={`/profile/${card.userId}`} onClick={(e) => e.stopPropagation()}>
          {card.avatarUrl ? (
            <img
              src={card.avatarUrl}
              alt={card.username}
              className="w-7 h-7 sm:w-8 sm:h-8 rounded-full object-cover"
            />
          ) : (
            <div className="w-7 h-7 sm:w-8 sm:h-8 rounded-full bg-secondary flex items-center justify-center text-xs text-muted-foreground">
              {card.username.charAt(0).toUpperCase()}
            </div>
          )}
        </Link>
        <Link
          to={`/profile/${card.userId}`}
          className="text-xs sm:text-sm font-medium text-foreground hover:underline truncate"
          onClick={(e) => e.stopPropagation()}
        >
          {card.displayName || card.username}
        </Link>
        <span className="ml-auto text-xs text-muted-foreground">
          {relativeDate(card.createdAt, t, locale)}
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
      <div className="flex gap-2 sm:gap-3 mb-2 sm:mb-3">
        {/* Score badge */}
        {card.mediaTier && card.mediaScore != null && (
          <div className={`flex flex-col items-center justify-center w-8 sm:w-10 flex-shrink-0 rounded-lg ${TIER_SCORE_BG[card.mediaTier]}`}>
            <span className="text-base sm:text-lg font-bold leading-none">{card.mediaScore.toFixed(1)}</span>
            <span className="text-[10px] font-semibold opacity-70">/10</span>
          </div>
        )}
        {card.mediaPosterUrl && (
          <img
            src={card.mediaPosterUrl}
            alt={card.mediaTitle ?? ''}
            className={`w-12 h-18 sm:w-16 sm:h-24 rounded-lg object-cover flex-shrink-0 ${card.mediaTmdbId && onMovieClick ? 'cursor-pointer hover:ring-2 hover:ring-gold/50 transition-all' : ''}`}
            onClick={handleMovieClick}
          />
        )}
        <div className="flex flex-col gap-1 min-w-0">
          {card.mediaTitle && (
            <span
              className={`text-sm sm:text-base font-medium text-foreground truncate ${card.mediaTmdbId && onMovieClick ? 'cursor-pointer hover:text-gold transition-colors' : ''}`}
              onClick={handleMovieClick}
            >
              {card.mediaTitle}
            </span>
          )}
          {card.mediaTier && (
            <span
              className={`text-xs font-bold px-1.5 py-0.5 rounded border w-fit ${
                TIER_COLORS[card.mediaTier]
              }`}
            >
              {card.mediaTier} — {TIER_LABELS[card.mediaTier]}
            </span>
          )}
          {card.bracket && (
            <span className="text-xs text-muted-foreground">{card.bracket}</span>
          )}
        </div>
      </div>

      {/* Watched with */}
      {card.watchedWithUsernames && card.watchedWithUsernames.length > 0 && (
        <div className="flex items-center gap-1.5 mb-3 text-xs text-muted-foreground">
          <Users className="w-3.5 h-3.5 text-accent" />
          <span>{t('feed.watchedWith')} {card.watchedWithUsernames.map(u => `@${u}`).join(', ')}</span>
        </div>
      )}

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
