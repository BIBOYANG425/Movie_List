import React, { useCallback, useEffect, useRef, useState } from 'react';
import { FeedCard, FeedComment, FeedFilters, ReactionType } from '../types';
import {
  addFeedComment,
  addMute,
  deleteFeedComment,
  getFeedCards,
  listFeedComments,
  removeMute,
  toggleReaction,
  getMutes,
} from '../services/feedService';
import { FeedFilterBar } from './FeedFilterBar';
import { FeedRankingCard } from './FeedRankingCard';
import { FeedReviewCard } from './FeedReviewCard';
import { FeedMilestoneCard } from './FeedMilestoneCard';
import { FeedListCard } from './FeedListCard';
import { FeedCommentThread } from './FeedCommentThread';
import { ErrorBoundary } from './ErrorBoundary';
import { Rss, Compass } from 'lucide-react';
import { SkeletonList } from './SkeletonCard';
import { useTranslation } from '../contexts/LanguageContext';

interface SocialFeedViewProps {
  userId: string;
}

const PAGE_SIZE = 20;

export const SocialFeedView: React.FC<SocialFeedViewProps> = ({ userId }) => {
  const { t } = useTranslation();
  const [cards, setCards] = useState<FeedCard[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [hasMore, setHasMore] = useState(true);
  const [filters, setFilters] = useState<FeedFilters>({ tab: 'friends' });

  // Comments state
  const [openCommentEventId, setOpenCommentEventId] = useState<string | null>(null);
  const [comments, setComments] = useState<FeedComment[]>([]);
  const [commentsLoading, setCommentsLoading] = useState(false);

  const observerRef = useRef<HTMLDivElement | null>(null);

  const loadFeed = useCallback(async (reset = false) => {
    if (reset) {
      setLoading(true);
      setCards([]);
      setHasMore(true);
    } else {
      setLoadingMore(true);
    }

    const offset = reset ? 0 : cards.length;
    const newCards = await getFeedCards(userId, filters, offset, PAGE_SIZE);

    if (reset) {
      setCards(newCards);
    } else {
      setCards(prev => [...prev, ...newCards]);
    }

    setHasMore(newCards.length >= PAGE_SIZE);
    setLoading(false);
    setLoadingMore(false);
  }, [userId, filters, cards.length]);

  // Load feed on mount and when filters change
  useEffect(() => {
    loadFeed(true);
  }, [userId, filters.tab, filters.cardType, filters.tier, filters.timeRange, filters.bracket]);

  // Infinite scroll via IntersectionObserver
  useEffect(() => {
    if (!observerRef.current || !hasMore || loading || loadingMore) return;

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries[0]?.isIntersecting && hasMore && !loadingMore) {
          loadFeed(false);
        }
      },
      { threshold: 0.1 },
    );

    observer.observe(observerRef.current);
    return () => observer.disconnect();
  }, [hasMore, loading, loadingMore, loadFeed]);

  const handleFilterChange = (newFilters: FeedFilters) => {
    setFilters(newFilters);
  };

  const handleTabChange = (tab: 'friends' | 'explore') => {
    setFilters(prev => ({ ...prev, tab }));
  };

  // ── Reactions ───────────────────────────────────────────────────────────

  const handleToggleReaction = async (eventId: string, reaction: ReactionType) => {
    const card = cards.find(c => c.id === eventId);
    if (!card) return;

    const hasReaction = card.myReactions.includes(reaction);
    const shouldAdd = !hasReaction;

    // Optimistic update
    setCards(prev => prev.map(c => {
      if (c.id !== eventId) return c;
      const newMyReactions = shouldAdd
        ? [...c.myReactions, reaction]
        : c.myReactions.filter(r => r !== reaction);
      const newCounts = { ...c.reactionCounts };
      newCounts[reaction] = Math.max(0, (newCounts[reaction] ?? 0) + (shouldAdd ? 1 : -1));
      return { ...c, myReactions: newMyReactions, reactionCounts: newCounts };
    }));

    // If want_to_watch reaction is added, we could also add to watchlist here in future
    const ok = await toggleReaction(userId, eventId, reaction, shouldAdd);
    if (!ok) {
      // Revert optimistic update
      setCards(prev => prev.map(c => {
        if (c.id !== eventId) return c;
        const revertMyReactions = shouldAdd
          ? c.myReactions.filter(r => r !== reaction)
          : [...c.myReactions, reaction];
        const revertCounts = { ...c.reactionCounts };
        revertCounts[reaction] = Math.max(0, (revertCounts[reaction] ?? 0) + (shouldAdd ? -1 : 1));
        return { ...c, myReactions: revertMyReactions, reactionCounts: revertCounts };
      }));
    }
  };

  // ── Comments ────────────────────────────────────────────────────────────

  const handleOpenComments = async (eventId: string) => {
    if (openCommentEventId === eventId) {
      setOpenCommentEventId(null);
      setComments([]);
      return;
    }

    setOpenCommentEventId(eventId);
    setCommentsLoading(true);
    const feedComments = await listFeedComments(eventId);
    setComments(feedComments);
    setCommentsLoading(false);
  };

  const handleAddComment = async (body: string, parentCommentId?: string) => {
    if (!openCommentEventId) return;
    const ok = await addFeedComment(userId, openCommentEventId, body, parentCommentId);
    if (ok) {
      const feedComments = await listFeedComments(openCommentEventId);
      setComments(feedComments);
      // Update comment count on card
      setCards(prev => prev.map(c =>
        c.id === openCommentEventId ? { ...c, commentCount: c.commentCount + 1 } : c,
      ));
    }
  };

  const handleDeleteComment = async (commentId: string) => {
    if (!openCommentEventId) return;
    const ok = await deleteFeedComment(userId, commentId);
    if (ok) {
      const feedComments = await listFeedComments(openCommentEventId);
      setComments(feedComments);
      setCards(prev => prev.map(c =>
        c.id === openCommentEventId ? { ...c, commentCount: Math.max(0, c.commentCount - 1) } : c,
      ));
    }
  };

  // ── Mutes ───────────────────────────────────────────────────────────────

  const handleMuteUser = async (targetUserId: string) => {
    const ok = await addMute(userId, 'user', targetUserId);
    if (ok) {
      setCards(prev => prev.filter(c => c.userId !== targetUserId));
    }
  };

  const handleMuteMovie = async (tmdbId: string) => {
    const ok = await addMute(userId, 'movie', tmdbId);
    if (ok) {
      setCards(prev => prev.filter(c => c.mediaTmdbId !== tmdbId));
    }
  };

  // ── Render ──────────────────────────────────────────────────────────────

  const renderCard = (card: FeedCard) => {
    const commonProps = {
      key: card.id,
      card,
      onToggleReaction: handleToggleReaction,
      onMuteUser: handleMuteUser,
      onOpenComments: handleOpenComments,
      commentCount: card.commentCount,
    };

    let cardElement: React.ReactNode;

    switch (card.cardType) {
      case 'ranking':
        cardElement = (
          <FeedRankingCard
            {...commonProps}
            onMuteMovie={card.mediaTmdbId ? () => handleMuteMovie(card.mediaTmdbId!) : undefined}
          />
        );
        break;
      case 'review':
        cardElement = (
          <FeedReviewCard
            {...commonProps}
            onMuteMovie={card.mediaTmdbId ? () => handleMuteMovie(card.mediaTmdbId!) : undefined}
          />
        );
        break;
      case 'milestone':
        cardElement = <FeedMilestoneCard {...commonProps} />;
        break;
      case 'list':
        cardElement = <FeedListCard {...commonProps} />;
        break;
      default:
        return null;
    }

    return (
      <ErrorBoundary key={card.id}>
      <div>
        {cardElement}
        {openCommentEventId === card.id && (
          <div className="mt-1 bg-zinc-900 border border-zinc-800 border-t-0 rounded-b-xl px-4 pb-4">
            <FeedCommentThread
              comments={comments}
              commentCount={card.commentCount}
              currentUserId={userId}
              onAddComment={handleAddComment}
              onDeleteComment={handleDeleteComment}
              onToggleOpen={() => handleOpenComments(card.id)}
              isOpen={true}
              loading={commentsLoading}
            />
          </div>
        )}
      </div>
      </ErrorBoundary>
    );
  };

  return (
    <div className="space-y-4">
      {/* Sub-tabs: Friends Feed / Explore Feed */}
      <div className="flex gap-2 bg-card rounded-xl p-1 border border-border">
        <button
          onClick={() => handleTabChange('friends')}
          className={`flex-1 flex items-center justify-center gap-2 px-3 py-2 rounded-lg text-sm font-semibold transition-all ${
            filters.tab === 'friends'
              ? 'bg-elevated text-cream shadow-lg'
              : 'text-dim hover:text-muted'
          }`}
        >
          <Rss size={16} />
          {t('feed.friendsFeed')}
        </button>
        <button
          onClick={() => handleTabChange('explore')}
          className={`flex-1 flex items-center justify-center gap-2 px-3 py-2 rounded-lg text-sm font-semibold transition-all ${
            filters.tab === 'explore'
              ? 'bg-elevated text-cream shadow-lg'
              : 'text-dim hover:text-muted'
          }`}
        >
          <Compass size={16} />
          {t('feed.explore')}
        </button>
      </div>

      {/* Filters */}
      <FeedFilterBar filters={filters} onFilterChange={handleFilterChange} />

      {/* Feed Cards */}
      {loading ? (
        <div className="space-y-3">
          <SkeletonList count={4} variant="feed" />
        </div>
      ) : cards.length === 0 ? (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-8 text-center">
          <p className="text-zinc-400 text-sm">
            {filters.tab === 'friends'
              ? t('feed.emptyFriends')
              : t('feed.emptyExplore')}
          </p>
        </div>
      ) : (
        <div className="space-y-3">
          {cards.map(renderCard)}

          {/* Infinite scroll sentinel */}
          {hasMore && (
            <div ref={observerRef} className="flex items-center justify-center py-4">
              {loadingMore && (
                <div className="w-6 h-6 border-2 border-indigo-500 border-t-transparent rounded-full animate-spin" />
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
};
