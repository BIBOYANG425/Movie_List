import React, { useEffect, useMemo, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { RotateCcw, Tv, Film, BookOpen } from 'lucide-react';
import { Tier, RankedItem, WatchlistItem, MediaType, Bracket, ComparisonLogEntry } from '../types';
import { TIERS, TIER_SCORE_RANGES, MIN_MOVIES_FOR_SCORES, MAX_TIER_TOLERANCE, BRACKETS, BRACKET_LABELS } from '../constants';
import { computeTierScore, classifyBracket } from '../services/rankingAlgorithm';
import { TierRow } from '../components/ranking/TierRow';
import { AddMediaModal } from '../components/media/AddMediaModal';
import { AddTVSeasonModal } from '../components/media/AddTVSeasonModal';
import { RankingFlowModal } from '../components/media/RankingFlowModal';
import { Watchlist } from '../components/media/Watchlist';
import { UniversalSearch } from '../components/shared/UniversalSearch';
import { SocialFeedView } from '../components/feed/SocialFeedView';
import { DiscoverView } from '../components/social/DiscoverView';
import { NotificationBell } from '../components/social/NotificationBell';
import { MediaDetailModal } from '../components/media/MediaDetailModal';
import { JournalConversation } from '../components/journal/JournalConversation';
import { ErrorBoundary } from '../components/shared/ErrorBoundary';
import { FirstRunGuide } from '../components/shared/FirstRunGuide';
import { Toast } from '../components/shared/Toast';
import { LanguageToggle } from '../components/shared/LanguageToggle';
import AppLayout from '../components/layout/AppLayout';
import { supabase } from '../lib/supabase';
import { useAuth } from '../contexts/AuthContext';
import { useTranslation } from '../contexts/LanguageContext';
import { logRankingActivityEvent } from '../services/friendsService';
import { createStub } from '../services/stubService';
import { TMDBMovie, TMDBTVShow } from '../services/tmdbService';
import { OpenLibraryBook } from '../services/openLibraryService';
import { useLocalizedItems, useLocalizedWatchlist } from '../hooks/useLocalizedItems';

const SCORE_MAX = 10.0;
const SCORE_MIN = 0.1;

/** Determine the "natural" tier for a given score based on equal brackets. */
function getNaturalTier(score: number): Tier {
  for (const tier of TIERS) {
    const range = TIER_SCORE_RANGES[tier];
    if (score >= range.min) return tier;
  }
  return Tier.D;
}

/** Dynamic tolerance: shrinks as the list grows. */
function getTierTolerance(totalItems: number): number {
  return Math.min(MAX_TIER_TOLERANCE, MAX_TIER_TOLERANCE * (MIN_MOVIES_FOR_SCORES / totalItems));
}

function computeScores(items: RankedItem[]): Map<string, number> {
  const scoreMap = new Map<string, number>();

  for (const tier of TIERS) {
    const tierItems = items
      .filter((i) => i.tier === tier)
      .sort((a, b) => a.rank - b.rank);

    const totalInTier = tierItems.length;
    if (totalInTier === 0) continue;

    const range = TIER_SCORE_RANGES[tier];

    tierItems.forEach((item, index) => {
      const score = computeTierScore(index, totalInTier, range.min, range.max);
      scoreMap.set(item.id, Number(score.toFixed(1)));
    });
  }

  return scoreMap;
}

/**
 * Sticky-tier logic: checks each item's computed score against its current
 * tier bracket. If the score has drifted beyond the dynamic tolerance, the
 * item is reassigned to its natural tier.
 * Returns a list of items that need tier updates (empty if none changed).
 */
function computeStickyTiers(
  items: RankedItem[],
  scoreMap: Map<string, number>,
): { id: string; newTier: Tier }[] {
  const total = items.length;
  if (total < MIN_MOVIES_FOR_SCORES) return [];

  const tolerance = getTierTolerance(total);
  const changes: { id: string; newTier: Tier }[] = [];

  for (const item of items) {
    const score = scoreMap.get(item.id);
    if (score === undefined) continue;

    const range = TIER_SCORE_RANGES[item.tier];
    const lowerBound = range.min - tolerance;
    const upperBound = range.max + tolerance;

    if (score < lowerBound || score > upperBound) {
      const naturalTier = getNaturalTier(score);
      if (naturalTier !== item.tier) {
        changes.push({ id: item.id, newTier: naturalTier });
      }
    }
  }

  return changes;
}

function rowToRankedItem(row: any): RankedItem {
  const wwIds = row.watched_with_user_ids;
  return {
    id: row.tmdb_id,
    title: row.title,
    year: row.year ?? '',
    posterUrl: row.poster_url ?? '',
    type: row.type as MediaType,
    genres: row.genres ?? [],
    director: row.director,
    tier: row.tier as Tier,
    rank: row.rank_position,
    bracket: (row.bracket as Bracket) ?? classifyBracket(row.genres ?? []),
    notes: row.notes,
    watchedWithUserIds: Array.isArray(wwIds) && wwIds.length > 0 ? wwIds : undefined,
  };
}

function rowToWatchlistItem(row: any): WatchlistItem {
  return {
    id: row.tmdb_id,
    title: row.title,
    year: row.year ?? '',
    posterUrl: row.poster_url ?? '',
    type: row.type as MediaType,
    genres: row.genres ?? [],
    director: row.director,
    addedAt: row.added_at,
  };
}

function rowToTVRankedItem(row: any): RankedItem {
  const wwIds = row.watched_with_user_ids;
  return {
    id: row.tmdb_id,
    title: row.title,
    year: row.year ?? '',
    posterUrl: row.poster_url ?? '',
    type: 'tv_season',
    genres: row.genres ?? [],
    creator: row.creator,
    showTmdbId: row.show_tmdb_id,
    seasonNumber: row.season_number,
    seasonTitle: row.season_title,
    episodeCount: row.episode_count,
    tier: row.tier as Tier,
    rank: row.rank_position,
    bracket: (row.bracket as Bracket) ?? classifyBracket(row.genres ?? []),
    notes: row.notes,
    watchedWithUserIds: Array.isArray(wwIds) && wwIds.length > 0 ? wwIds : undefined,
  };
}

function rowToTVWatchlistItem(row: any): WatchlistItem {
  return {
    id: row.tmdb_id,
    title: row.title,
    year: row.year ?? '',
    posterUrl: row.poster_url ?? '',
    type: 'tv_season',
    genres: row.genres ?? [],
    creator: row.creator,
    showTmdbId: row.show_tmdb_id,
    seasonNumber: row.season_number,
    seasonTitle: row.season_title,
    episodeCount: row.episode_count,
    addedAt: row.added_at,
  };
}

function rowToBookRankedItem(row: any): RankedItem {
  const wwIds = row.watched_with_user_ids;
  return {
    id: row.tmdb_id,
    title: row.title,
    year: row.year ?? '',
    posterUrl: row.poster_url ?? '',
    type: 'book',
    genres: row.genres ?? [],
    author: row.author,
    pageCount: row.page_count ?? undefined,
    isbn: row.isbn ?? undefined,
    olWorkKey: row.ol_work_key ?? undefined,
    olRatingsAverage: row.ol_ratings_average ?? undefined,
    globalScore: row.ol_ratings_average != null ? row.ol_ratings_average * 2 : undefined,
    tier: row.tier as Tier,
    rank: row.rank_position,
    bracket: (row.bracket as Bracket) ?? classifyBracket(row.genres ?? []),
    notes: row.notes,
    watchedWithUserIds: Array.isArray(wwIds) && wwIds.length > 0 ? wwIds : undefined,
  };
}

function rowToBookWatchlistItem(row: any): WatchlistItem {
  return {
    id: row.tmdb_id,
    title: row.title,
    year: row.year ?? '',
    posterUrl: row.poster_url ?? '',
    type: 'book',
    genres: row.genres ?? [],
    author: row.author,
    pageCount: row.page_count ?? undefined,
    isbn: row.isbn ?? undefined,
    olWorkKey: row.ol_work_key ?? undefined,
    olRatingsAverage: row.ol_ratings_average ?? undefined,
    addedAt: row.added_at,
  };
}

const RankingAppPage = () => {
  const { user, profile, signOut } = useAuth();
  const { t } = useTranslation();
  const navigate = useNavigate();
  const [items, setItems] = useState<RankedItem[]>([]);
  const [watchlist, setWatchlist] = useState<WatchlistItem[]>([]);
  const [tvItems, setTvItems] = useState<RankedItem[]>([]);
  const [tvWatchlist, setTvWatchlist] = useState<WatchlistItem[]>([]);
  const [bookItems, setBookItems] = useState<RankedItem[]>([]);
  const [bookWatchlist, setBookWatchlist] = useState<WatchlistItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [isTVModalOpen, setIsTVModalOpen] = useState(false);
  const [isBookModalOpen, setIsBookModalOpen] = useState(false);
  const [bookItemToRank, setBookItemToRank] = useState<RankedItem | null>(null);
  const [activeTab, setActiveTab] = useState<'ranking' | 'watchlist' | 'feed' | 'discover'>('ranking');
  const [mediaMode, setMediaMode] = useState<'movies' | 'tv' | 'books'>('movies');
  const [filterType, setFilterType] = useState<'all' | 'movie'>('all');
  const [activeBracket, setActiveBracket] = useState<Bracket | 'all'>('all');
  const [activeGenre, setActiveGenre] = useState<string | null>(null);
  const [migrationState, setMigrationState] = useState<{ item: RankedItem, targetTier: Tier } | null>(null);
  const [preselectedForRank, setPreselectedForRank] = useState<WatchlistItem | TMDBMovie | RankedItem | null>(null);
  const [preselectedTVItem, setPreselectedTVItem] = useState<RankedItem | null>(null);
  const [draggedItemId, setDraggedItemId] = useState<string | null>(null);
  const [journalSheetItem, setJournalSheetItem] = useState<RankedItem | null>(null);
  const [toastMessage, setToastMessage] = useState<string | null>(null);
  const [unreadNotifCount, setUnreadNotifCount] = useState(0);
  const [searchParams, setSearchParams] = useSearchParams();
  const linkedMovieId = searchParams.get('movieId');

  useEffect(() => {
    if (!user) return;

    const fetchData = async () => {
      setLoading(true);

      // Migrate onboarding picks from localStorage if present
      const ONBOARDING_KEY = 'spool_onboarding_picks';
      const stored = localStorage.getItem(ONBOARDING_KEY);
      if (stored) {
        try {
          const picks: RankedItem[] = JSON.parse(stored);
          if (picks.length > 0) {
            const rows = picks.map(item => ({
              user_id: user.id,
              tmdb_id: item.id,
              title: item.title,
              year: item.year,
              poster_url: item.posterUrl,
              type: item.type,
              genres: item.genres,
              director: item.director ?? null,
              tier: item.tier,
              rank_position: item.rank,
              bracket: item.bracket,
              primary_genre: item.genres[0] ?? null,
              notes: item.notes ?? null,
              updated_at: new Date().toISOString(),
            }));
            await supabase.from('user_rankings').upsert(rows, { onConflict: 'user_id,tmdb_id' });
          }
        } catch { /* ignore */ }
        localStorage.removeItem(ONBOARDING_KEY);
      }

      const [rankingsRes, watchlistRes, tvRankingsRes, tvWatchlistRes, bookRankingsRes, bookWatchlistRes] = await Promise.all([
        supabase
          .from('user_rankings')
          .select('*')
          .eq('user_id', user.id)
          .order('tier')
          .order('rank_position'),
        supabase
          .from('watchlist_items')
          .select('*')
          .eq('user_id', user.id)
          .order('added_at', { ascending: false }),
        supabase
          .from('tv_rankings')
          .select('*')
          .eq('user_id', user.id)
          .order('tier')
          .order('rank_position'),
        supabase
          .from('tv_watchlist_items')
          .select('*')
          .eq('user_id', user.id)
          .order('added_at', { ascending: false }),
        supabase
          .from('book_rankings')
          .select('*')
          .eq('user_id', user.id)
          .order('tier')
          .order('rank_position'),
        supabase
          .from('book_watchlist_items')
          .select('*')
          .eq('user_id', user.id)
          .order('added_at', { ascending: false }),
      ]);

      if (rankingsRes.data) setItems(rankingsRes.data.map(rowToRankedItem));
      if (watchlistRes.data) setWatchlist(watchlistRes.data.map(rowToWatchlistItem));
      if (tvRankingsRes.data) setTvItems(tvRankingsRes.data.map(rowToTVRankedItem));
      if (tvWatchlistRes.data) setTvWatchlist(tvWatchlistRes.data.map(rowToTVWatchlistItem));
      if (bookRankingsRes.data) setBookItems(bookRankingsRes.data.map(rowToBookRankedItem));
      if (bookWatchlistRes.data) setBookWatchlist(bookWatchlistRes.data.map(rowToBookWatchlistItem));

      setLoading(false);
    };

    fetchData();
  }, [user]);

  // Note: previously redirected to /onboarding/movies when items < MIN_MOVIES_FOR_SCORES,
  // but this caused redirect loops. Users can access onboarding via the normal flow instead.

  const handleReset = async () => {
    if (!user) return;
    const label = mediaMode === 'books' ? 'book' : mediaMode === 'tv' ? 'TV' : 'movie';
    if (!window.confirm(t('ranking.resetConfirm').replace('{label}', label))) return;

    if (mediaMode === 'books') {
      await supabase.from('book_rankings').delete().eq('user_id', user.id);
      setBookItems([]);
    } else if (mediaMode === 'tv') {
      await supabase.from('tv_rankings').delete().eq('user_id', user.id);
      setTvItems([]);
    } else {
      await supabase.from('user_rankings').delete().eq('user_id', user.id);
      setItems([]);
    }
  };

  const handleDragStart = (e: React.DragEvent, id: string) => {
    setDraggedItemId(id);
    e.dataTransfer.effectAllowed = 'move';
  };

  const handleDrop = async (e: React.DragEvent, targetTier: Tier) => {
    e.preventDefault();
    if (!draggedItemId || !user) return;

    const droppedId = draggedItemId;
    const movedItem = items.find((i) => i.id === droppedId);
    setDraggedItemId(null);

    if (!movedItem) return;

    if (movedItem.tier !== targetTier) {
      // Trigger Spool tier migration comparison flow
      setMigrationState({ item: movedItem, targetTier });
      setIsModalOpen(true);
      return;
    }

    // Compute new rank from current items snapshot (before state update)
    const others = items.filter((i) => i.id !== droppedId);
    const newRank = others.filter((i) => i.tier === targetTier).length;

    setItems((prev) => {
      const movedItem = prev.find((i) => i.id === droppedId);
      if (!movedItem) return prev;

      const rest = prev.filter((i) => i.id !== droppedId);
      const newItem = { ...movedItem, tier: targetTier, rank: newRank };

      return [...rest, newItem].sort((a, b) => {
        if (a.tier === b.tier) return a.rank - b.rank;
        return 0;
      });
    });

    await supabase
      .from('user_rankings')
      .update({ tier: targetTier, rank_position: newRank, updated_at: new Date().toISOString() })
      .eq('user_id', user.id)
      .eq('tmdb_id', droppedId);

    if (movedItem) {
      await logRankingActivityEvent(
        user.id,
        {
          id: movedItem.id,
          title: movedItem.title,
          tier: targetTier,
          posterUrl: movedItem.posterUrl,
          notes: movedItem.notes,
          year: movedItem.year,
        },
        'ranking_move',
      );
    }
  };

  const handleDropOnItem = async (e: React.DragEvent, targetId: string) => {
    e.preventDefault();
    e.stopPropagation();
    if (!draggedItemId || !user || draggedItemId === targetId) return;

    const droppedId = draggedItemId;
    const movedItem = items.find((i) => i.id === droppedId);
    const targetItem = items.find((i) => i.id === targetId);
    setDraggedItemId(null);

    if (!movedItem || !targetItem) return;

    if (movedItem.tier !== targetItem.tier) {
      // Trigger Spool tier migration comparison flow, target is targetItem.tier
      setMigrationState({ item: movedItem, targetTier: targetItem.tier });
      setIsModalOpen(true);
      return;
    }

    // Move within the SAME tier
    let updatedTierList: RankedItem[] = [];
    const prevItems = [...items];
    setItems((prev) => {
      const tierItems = prev.filter(i => i.tier === targetItem.tier).sort((a, b) => a.rank - b.rank);
      const otherItems = prev.filter(i => i.tier !== targetItem.tier);

      // Find indices
      const oldIndex = tierItems.findIndex(i => i.id === droppedId);
      const newIndex = tierItems.findIndex(i => i.id === targetId);

      if (oldIndex === -1 || newIndex === -1) return prev;

      // Reorder array
      const [removed] = tierItems.splice(oldIndex, 1);
      tierItems.splice(newIndex, 0, removed);

      // Reassign ranks
      updatedTierList = tierItems.map((item, idx) => ({ ...item, rank: idx }));

      return [...otherItems, ...updatedTierList];
    });

    if (updatedTierList.length > 0) {
      const rowsToUpdate = updatedTierList.map(item => ({
        user_id: user.id,
        tmdb_id: item.id,
        title: item.title,
        year: item.year,
        poster_url: item.posterUrl,
        type: item.type,
        genres: item.genres,
        director: item.director ?? null,
        tier: item.tier,
        rank_position: item.rank,
        bracket: item.bracket ?? classifyBracket(item.genres),
        primary_genre: item.genres[0] ?? null,
        notes: item.notes ?? null,
        updated_at: new Date().toISOString(),
      }));
      const { error } = await supabase.from('user_rankings').upsert(rowsToUpdate, { onConflict: 'user_id,tmdb_id' });
      if (error) {
        console.error('Failed to save ranking:', error);
        setToastMessage(t('ranking.failedSave'));
        setItems(prevItems);
      }
    }
  };

  const addItem = async (newItem: RankedItem) => {
    if (!user) return;

    let updatedTierList: RankedItem[] = [];

    setItems((prev) => {
      const tierItems = prev
        .filter((i) => i.tier === newItem.tier && i.id !== newItem.id)
        .sort((a, b) => a.rank - b.rank);
      const otherItems = prev.filter((i) => i.tier !== newItem.tier && i.id !== newItem.id);

      const newTierList = [...tierItems];
      newTierList.splice(newItem.rank, 0, newItem);

      updatedTierList = newTierList.map((item, index) => ({ ...item, rank: index }));
      return [...otherItems, ...updatedTierList];
    });

    if (updatedTierList.length > 0) {
      const rowsToUpdate = updatedTierList.map(item => ({
        user_id: user.id,
        tmdb_id: item.id,
        title: item.title,
        year: item.year,
        poster_url: item.posterUrl,
        type: item.type,
        genres: item.genres,
        director: item.director ?? null,
        tier: item.tier,
        rank_position: item.rank,
        bracket: item.bracket ?? classifyBracket(item.genres),
        primary_genre: item.genres[0] ?? null,
        notes: item.notes ?? null,
        watched_with_user_ids: item.watchedWithUserIds ?? [],
        updated_at: new Date().toISOString(),
      }));
      const { error } = await supabase.from('user_rankings').upsert(rowsToUpdate, { onConflict: 'user_id,tmdb_id' });
      if (error) {
        console.error('Failed to save ranking:', error);
        setToastMessage(t('ranking.failedSaveRanking'));
        return;
      }
    }

    await logRankingActivityEvent(
      user.id,
      {
        id: newItem.id,
        title: newItem.title,
        tier: newItem.tier,
        posterUrl: newItem.posterUrl,
        notes: newItem.notes,
        year: newItem.year,
        watchedWithUserIds: newItem.watchedWithUserIds,
      },
      'ranking_add',
    );

    // Generate ticket stub (fire-and-forget)
    createStub(user.id, {
      mediaType: 'movie',
      tmdbId: newItem.id,
      title: newItem.title,
      posterPath: newItem.posterUrl,
      tier: newItem.tier,
    }).catch(() => {});
  };

  const removeItem = async (id: string) => {
    if (!user) return;
    const removedItem = items.find((item) => item.id === id);

    let affectedTierItems: RankedItem[] = [];

    setItems((prev) => {
      const without = prev.filter((i) => i.id !== id);
      const tiers = new Set(without.map((i) => i.tier));
      let result: RankedItem[] = [];

      tiers.forEach((tier) => {
        const tierItems = without
          .filter((i) => i.tier === tier)
          .sort((a, b) => a.rank - b.rank)
          .map((item, idx) => ({ ...item, rank: idx }));
        result = [...result, ...tierItems];
        // Track items in the removed movie's tier for DB reindex
        if (removedItem && tier === removedItem.tier) {
          affectedTierItems = tierItems;
        }
      });

      return result;
    });

    await supabase
      .from('user_rankings')
      .delete()
      .eq('user_id', user.id)
      .eq('tmdb_id', id);

    // Persist reindexed ranks for remaining items in the affected tier
    if (affectedTierItems.length > 0) {
      const rowsToUpdate = affectedTierItems.map(item => ({
        user_id: user.id,
        tmdb_id: item.id,
        title: item.title,
        year: item.year,
        poster_url: item.posterUrl,
        type: item.type,
        genres: item.genres,
        director: item.director ?? null,
        tier: item.tier,
        rank_position: item.rank,
        bracket: item.bracket ?? classifyBracket(item.genres),
        primary_genre: item.genres[0] ?? null,
        notes: item.notes ?? null,
        updated_at: new Date().toISOString(),
      }));
      const { error } = await supabase.from('user_rankings').upsert(rowsToUpdate, { onConflict: 'user_id,tmdb_id' });
      if (error) {
        console.error('Failed to reindex ranks after removal:', error);
        setToastMessage(t('ranking.failedUpdate'));
      }
    }

    if (removedItem) {
      await logRankingActivityEvent(
        user.id,
        {
          id: removedItem.id,
          title: removedItem.title,
          tier: removedItem.tier,
          posterUrl: removedItem.posterUrl,
          notes: removedItem.notes,
          year: removedItem.year,
        },
        'ranking_remove',
      );
    }
  };

  const addToWatchlist = async (item: WatchlistItem | TMDBMovie) => {
    if (!user) return;
    if (watchlist.some((w) => w.id === item.id)) return;

    const watchItem: WatchlistItem = {
      ...item,
      addedAt: 'addedAt' in item ? item.addedAt : new Date().toISOString(),
      type: 'movie',
      director: 'director' in item ? item.director : undefined,
    };

    setWatchlist((prev) => [watchItem, ...prev]);

    const { error } = await supabase.from('watchlist_items').upsert({
      user_id: user.id,
      tmdb_id: watchItem.id,
      title: watchItem.title,
      year: watchItem.year,
      poster_url: watchItem.posterUrl,
      type: watchItem.type,
      genres: watchItem.genres,
      director: watchItem.director ?? null,
    }, { onConflict: 'user_id,tmdb_id' });

    if (error) {
      console.error('Failed to save to watchlist:', error);
      setToastMessage(t('ranking.failedSave'));
      setWatchlist((prev) => prev.filter((w) => w.id !== watchItem.id));
      return;
    }

    setToastMessage(t('toast.movieSaved'));
  };

  const removeFromWatchlist = async (id: string) => {
    if (!user) return;

    setWatchlist((prev) => prev.filter((w) => w.id !== id));

    await supabase
      .from('watchlist_items')
      .delete()
      .eq('user_id', user.id)
      .eq('tmdb_id', id);
  };

  const addToTVWatchlist = async (item: WatchlistItem) => {
    if (!user) return;
    if (tvWatchlist.some((w) => w.id === item.id)) return;

    setTvWatchlist((prev) => [item, ...prev]);

    const { error } = await supabase.from('tv_watchlist_items').upsert({
      user_id: user.id,
      tmdb_id: item.id,
      show_tmdb_id: item.showTmdbId ?? 0,
      season_number: item.seasonNumber ?? 0,
      title: item.title,
      season_title: item.seasonTitle ?? null,
      year: item.year,
      poster_url: item.posterUrl,
      type: 'tv_season',
      genres: item.genres,
      creator: item.creator ?? null,
    }, { onConflict: 'user_id,tmdb_id' });

    if (error) {
      console.error('Failed to save to TV watchlist:', error);
      setToastMessage(t('ranking.failedSave'));
      setTvWatchlist((prev) => prev.filter((w) => w.id !== item.id));
      return;
    }

    setToastMessage(t('toast.movieSaved'));
  };

  const removeTVFromWatchlist = async (id: string) => {
    if (!user) return;

    setTvWatchlist((prev) => prev.filter((w) => w.id !== id));

    await supabase
      .from('tv_watchlist_items')
      .delete()
      .eq('user_id', user.id)
      .eq('tmdb_id', id);
  };

  const rankFromWatchlist = (item: WatchlistItem) => {
    if (item.type === 'book') {
      const bookItem: RankedItem = {
        id: item.id,
        title: item.title,
        year: item.year,
        posterUrl: item.posterUrl,
        type: 'book',
        genres: item.genres,
        author: item.author,
        pageCount: item.pageCount,
        isbn: item.isbn,
        olWorkKey: item.olWorkKey,
        olRatingsAverage: item.olRatingsAverage,
        globalScore: item.olRatingsAverage != null ? item.olRatingsAverage * 2 : undefined,
        bracket: classifyBracket(item.genres),
        tier: Tier.B,
        rank: 0,
      };
      setBookItemToRank(bookItem);
      setIsBookModalOpen(true);
    } else if (item.type === 'tv_season') {
      const tvItem: RankedItem = {
        id: item.id,
        title: item.title,
        year: item.year,
        posterUrl: item.posterUrl,
        type: 'tv_season',
        genres: item.genres,
        creator: item.creator,
        showTmdbId: item.showTmdbId,
        seasonNumber: item.seasonNumber,
        seasonTitle: item.seasonTitle,
        episodeCount: item.episodeCount,
        bracket: classifyBracket(item.genres),
        tier: Tier.B,
        rank: 0,
      };
      setPreselectedTVItem(tvItem);
      setIsTVModalOpen(true);
    } else {
      setPreselectedForRank(item);
      setIsModalOpen(true);
    }
  };

  // ─── TV CRUD ──────────────────────────────────────────────────────────────

  const persistTVRankings = async (updatedItems: RankedItem[]) => {
    if (!user || updatedItems.length === 0) return;
    const rows = updatedItems.map(item => ({
      user_id: user.id,
      tmdb_id: item.id,
      show_tmdb_id: item.showTmdbId ?? 0,
      season_number: item.seasonNumber ?? 0,
      title: item.title,
      season_title: item.seasonTitle ?? null,
      year: item.year,
      poster_url: item.posterUrl,
      type: 'tv_season',
      genres: item.genres,
      creator: item.creator ?? null,
      tier: item.tier,
      rank_position: item.rank,
      bracket: item.bracket ?? classifyBracket(item.genres),
      primary_genre: item.genres[0] ?? null,
      notes: item.notes ?? null,
      watched_with_user_ids: item.watchedWithUserIds ?? [],
      episode_count: item.episodeCount ?? null,
      updated_at: new Date().toISOString(),
    }));
    const { error } = await supabase.from('tv_rankings').upsert(rows, { onConflict: 'user_id,tmdb_id' });
    if (error) {
      console.error('Failed to save TV ranking:', error);
      setToastMessage(t('ranking.failedSaveTV'));
    }
  };

  const addTVItem = async (newItem: RankedItem) => {
    if (!user) return;

    let updatedTierList: RankedItem[] = [];

    setTvItems((prev) => {
      const tierItems = prev
        .filter((i) => i.tier === newItem.tier && i.id !== newItem.id)
        .sort((a, b) => a.rank - b.rank);
      const otherItems = prev.filter((i) => i.tier !== newItem.tier && i.id !== newItem.id);

      const newTierList = [...tierItems];
      newTierList.splice(newItem.rank, 0, newItem);

      updatedTierList = newTierList.map((item, index) => ({ ...item, rank: index }));
      return [...otherItems, ...updatedTierList];
    });

    await persistTVRankings(updatedTierList);

    await logRankingActivityEvent(
      user.id,
      {
        id: newItem.id,
        title: newItem.title,
        tier: newItem.tier,
        posterUrl: newItem.posterUrl,
        notes: newItem.notes,
        year: newItem.year,
        watchedWithUserIds: newItem.watchedWithUserIds,
      },
      'ranking_add',
    );

    // Generate ticket stub (fire-and-forget)
    createStub(user.id, {
      mediaType: 'tv_season',
      tmdbId: newItem.id,
      title: newItem.title,
      posterPath: newItem.posterUrl,
      tier: newItem.tier,
    }).catch(() => {});
  };

  const removeTVItem = async (id: string) => {
    if (!user) return;
    const removedItem = tvItems.find((item) => item.id === id);

    let affectedTierItems: RankedItem[] = [];

    setTvItems((prev) => {
      const without = prev.filter((i) => i.id !== id);
      const tiers = new Set(without.map((i) => i.tier));
      let result: RankedItem[] = [];

      tiers.forEach((tier) => {
        const tierItems = without
          .filter((i) => i.tier === tier)
          .sort((a, b) => a.rank - b.rank)
          .map((item, idx) => ({ ...item, rank: idx }));
        result = [...result, ...tierItems];
        if (removedItem && tier === removedItem.tier) {
          affectedTierItems = tierItems;
        }
      });

      return result;
    });

    await supabase
      .from('tv_rankings')
      .delete()
      .eq('user_id', user.id)
      .eq('tmdb_id', id);

    if (affectedTierItems.length > 0) {
      await persistTVRankings(affectedTierItems);
    }

    if (removedItem) {
      await logRankingActivityEvent(
        user.id,
        {
          id: removedItem.id,
          title: removedItem.title,
          tier: removedItem.tier,
          posterUrl: removedItem.posterUrl,
          notes: removedItem.notes,
          year: removedItem.year,
        },
        'ranking_remove',
      );
    }
  };

  const handleTVDrop = async (e: React.DragEvent, targetTier: Tier) => {
    e.preventDefault();
    if (!draggedItemId || !user) return;

    const droppedId = draggedItemId;
    const movedItem = tvItems.find((i) => i.id === droppedId);
    setDraggedItemId(null);

    if (!movedItem) return;
    const sourceTier = movedItem.tier;

    let affectedItems: RankedItem[] = [];

    setTvItems((prev) => {
      const item = prev.find((i) => i.id === droppedId);
      if (!item) return prev;

      const rest = prev.filter((i) => i.id !== droppedId);

      // Reindex source tier (gap left by moved item)
      const sourceTierItems = rest
        .filter((i) => i.tier === sourceTier)
        .sort((a, b) => a.rank - b.rank)
        .map((it, idx) => ({ ...it, rank: idx }));

      // Target tier: add moved item at the end, then reindex
      const targetTierItems = rest
        .filter((i) => i.tier === targetTier)
        .sort((a, b) => a.rank - b.rank);
      const newRank = targetTierItems.length;
      const movedWithNewTier = { ...item, tier: targetTier, rank: newRank };
      const updatedTargetItems = [...targetTierItems, movedWithNewTier].map((it, idx) => ({ ...it, rank: idx }));

      // Other tiers unchanged
      const otherItems = rest.filter((i) => i.tier !== sourceTier && i.tier !== targetTier);

      // Collect all items that need DB persistence (both tiers)
      affectedItems = sourceTier === targetTier
        ? updatedTargetItems
        : [...sourceTierItems, ...updatedTargetItems];

      return [...otherItems, ...sourceTierItems, ...updatedTargetItems].filter(
        // Deduplicate: if source === target, sourceTierItems is empty (item was removed)
        (item, idx, arr) => arr.findIndex(a => a.id === item.id) === idx
      );
    });

    if (affectedItems.length > 0) {
      await persistTVRankings(affectedItems);
    }

    if (movedItem) {
      await logRankingActivityEvent(
        user.id,
        {
          id: movedItem.id,
          title: movedItem.title,
          tier: targetTier,
          posterUrl: movedItem.posterUrl,
          notes: movedItem.notes,
          year: movedItem.year,
        },
        'ranking_move',
      );
    }
  };

  const handleTVDropOnItem = async (e: React.DragEvent, targetId: string) => {
    e.preventDefault();
    e.stopPropagation();
    if (!draggedItemId || !user || draggedItemId === targetId) return;

    const droppedId = draggedItemId;
    const movedItem = tvItems.find((i) => i.id === droppedId);
    const targetItem = tvItems.find((i) => i.id === targetId);

    if (!movedItem || !targetItem) {
      setDraggedItemId(null);
      return;
    }

    // Cross-tier drop on an item → delegate to tier-level drop handler
    if (movedItem.tier !== targetItem.tier) {
      await handleTVDrop(e, targetItem.tier);
      return;
    }

    setDraggedItemId(null);

    let updatedTierList: RankedItem[] = [];
    setTvItems((prev) => {
      const tierItems = prev.filter(i => i.tier === targetItem.tier).sort((a, b) => a.rank - b.rank);
      const otherItems = prev.filter(i => i.tier !== targetItem.tier);

      const oldIndex = tierItems.findIndex(i => i.id === droppedId);
      const newIndex = tierItems.findIndex(i => i.id === targetId);

      if (oldIndex === -1 || newIndex === -1) return prev;

      const [removed] = tierItems.splice(oldIndex, 1);
      tierItems.splice(newIndex, 0, removed);

      updatedTierList = tierItems.map((item, idx) => ({ ...item, rank: idx }));
      return [...otherItems, ...updatedTierList];
    });

    if (updatedTierList.length > 0) {
      await persistTVRankings(updatedTierList);
    }
  };

  // ─── Book CRUD ────────────────────────────────────────────────────────────

  const persistBookRankings = async (updatedItems: RankedItem[]) => {
    if (!user || updatedItems.length === 0) return;
    const rows = updatedItems.map(item => ({
      user_id: user.id,
      tmdb_id: item.id,
      title: item.title,
      year: item.year,
      poster_url: item.posterUrl,
      type: 'book',
      genres: item.genres,
      author: item.author ?? null,
      tier: item.tier,
      rank_position: item.rank,
      bracket: item.bracket ?? classifyBracket(item.genres),
      primary_genre: item.genres[0] ?? null,
      notes: item.notes ?? null,
      watched_with_user_ids: item.watchedWithUserIds ?? [],
      page_count: item.pageCount ?? null,
      isbn: item.isbn ?? null,
      ol_work_key: item.olWorkKey ?? null,
      ol_ratings_average: item.olRatingsAverage ?? null,
      updated_at: new Date().toISOString(),
    }));
    const { error } = await supabase.from('book_rankings').upsert(rows, { onConflict: 'user_id,tmdb_id' });
    if (error) {
      console.error('Failed to save book ranking:', error);
      setToastMessage(t('ranking.failedSaveBook'));
    }
  };

  const addBookItem = async (newItem: RankedItem) => {
    if (!user) return;
    let updatedTierList: RankedItem[] = [];

    setBookItems((prev) => {
      const tierItems = prev
        .filter((i) => i.tier === newItem.tier && i.id !== newItem.id)
        .sort((a, b) => a.rank - b.rank);
      const otherItems = prev.filter((i) => i.tier !== newItem.tier && i.id !== newItem.id);
      const newTierList = [...tierItems];
      newTierList.splice(newItem.rank, 0, newItem);
      updatedTierList = newTierList.map((item, index) => ({ ...item, rank: index }));
      return [...otherItems, ...updatedTierList];
    });

    await persistBookRankings(updatedTierList);

    await logRankingActivityEvent(
      user.id,
      {
        id: newItem.id,
        title: newItem.title,
        tier: newItem.tier,
        posterUrl: newItem.posterUrl,
        notes: newItem.notes,
        year: newItem.year,
        watchedWithUserIds: newItem.watchedWithUserIds,
      },
      'ranking_add',
    );
  };

  const removeBookItem = async (id: string) => {
    if (!user) return;
    const removedItem = bookItems.find((item) => item.id === id);
    let affectedTierItems: RankedItem[] = [];

    setBookItems((prev) => {
      const without = prev.filter((i) => i.id !== id);
      const tiers = new Set(without.map((i) => i.tier));
      let result: RankedItem[] = [];
      tiers.forEach((tier) => {
        const tierItems = without
          .filter((i) => i.tier === tier)
          .sort((a, b) => a.rank - b.rank)
          .map((item, idx) => ({ ...item, rank: idx }));
        result = [...result, ...tierItems];
        if (removedItem && tier === removedItem.tier) {
          affectedTierItems = tierItems;
        }
      });
      return result;
    });

    await supabase.from('book_rankings').delete().eq('user_id', user.id).eq('tmdb_id', id);

    if (affectedTierItems.length > 0) {
      await persistBookRankings(affectedTierItems);
    }

    if (removedItem) {
      await logRankingActivityEvent(user.id, {
        id: removedItem.id, title: removedItem.title, tier: removedItem.tier,
        posterUrl: removedItem.posterUrl, notes: removedItem.notes, year: removedItem.year,
      }, 'ranking_remove');
    }
  };

  const addToBookWatchlist = async (item: WatchlistItem) => {
    if (!user) return;
    if (bookWatchlist.some((w) => w.id === item.id)) return;

    setBookWatchlist((prev) => [item, ...prev]);

    const { error } = await supabase.from('book_watchlist_items').upsert({
      user_id: user.id,
      tmdb_id: item.id,
      title: item.title,
      year: item.year,
      poster_url: item.posterUrl,
      type: 'book',
      genres: item.genres,
      author: item.author ?? null,
      page_count: item.pageCount ?? null,
      isbn: item.isbn ?? null,
      ol_work_key: item.olWorkKey ?? null,
      ol_ratings_average: item.olRatingsAverage ?? null,
    }, { onConflict: 'user_id,tmdb_id' });

    if (error) {
      console.error('Failed to save to book watchlist:', error);
      setToastMessage(t('ranking.failedSave'));
      setBookWatchlist((prev) => prev.filter((w) => w.id !== item.id));
      return;
    }
    setToastMessage(t('toast.bookSaved'));
  };

  const removeBookFromWatchlist = async (id: string) => {
    if (!user) return;
    setBookWatchlist((prev) => prev.filter((w) => w.id !== id));
    await supabase.from('book_watchlist_items').delete().eq('user_id', user.id).eq('tmdb_id', id);
  };

  const handleBookDrop = async (e: React.DragEvent, targetTier: Tier) => {
    e.preventDefault();
    if (!draggedItemId || !user) return;
    const droppedId = draggedItemId;
    const movedItem = bookItems.find((i) => i.id === droppedId);
    setDraggedItemId(null);
    if (!movedItem) return;
    const sourceTier = movedItem.tier;
    let affectedItems: RankedItem[] = [];

    setBookItems((prev) => {
      const item = prev.find((i) => i.id === droppedId);
      if (!item) return prev;
      const rest = prev.filter((i) => i.id !== droppedId);
      const sourceTierItems = rest.filter((i) => i.tier === sourceTier).sort((a, b) => a.rank - b.rank).map((it, idx) => ({ ...it, rank: idx }));
      const targetTierItems = rest.filter((i) => i.tier === targetTier).sort((a, b) => a.rank - b.rank);
      const newRank = targetTierItems.length;
      const movedWithNewTier = { ...item, tier: targetTier, rank: newRank };
      const updatedTargetItems = [...targetTierItems, movedWithNewTier].map((it, idx) => ({ ...it, rank: idx }));
      const otherItems = rest.filter((i) => i.tier !== sourceTier && i.tier !== targetTier);
      affectedItems = sourceTier === targetTier ? updatedTargetItems : [...sourceTierItems, ...updatedTargetItems];
      return [...otherItems, ...sourceTierItems, ...updatedTargetItems].filter((item, idx, arr) => arr.findIndex(a => a.id === item.id) === idx);
    });

    if (affectedItems.length > 0) await persistBookRankings(affectedItems);
    if (movedItem) {
      await logRankingActivityEvent(user.id, { id: movedItem.id, title: movedItem.title, tier: targetTier, posterUrl: movedItem.posterUrl, notes: movedItem.notes, year: movedItem.year }, 'ranking_move');
    }
  };

  const handleBookDropOnItem = async (e: React.DragEvent, targetId: string) => {
    e.preventDefault();
    e.stopPropagation();
    if (!draggedItemId || !user || draggedItemId === targetId) return;
    const droppedId = draggedItemId;
    const movedItem = bookItems.find((i) => i.id === droppedId);
    const targetItem = bookItems.find((i) => i.id === targetId);
    if (!movedItem || !targetItem) { setDraggedItemId(null); return; }
    if (movedItem.tier !== targetItem.tier) { await handleBookDrop(e, targetItem.tier); return; }
    setDraggedItemId(null);
    let updatedTierList: RankedItem[] = [];
    setBookItems((prev) => {
      const tierItems = prev.filter(i => i.tier === targetItem.tier).sort((a, b) => a.rank - b.rank);
      const otherItems = prev.filter(i => i.tier !== targetItem.tier);
      const oldIndex = tierItems.findIndex(i => i.id === droppedId);
      const newIndex = tierItems.findIndex(i => i.id === targetId);
      if (oldIndex === -1 || newIndex === -1) return prev;
      const [removed] = tierItems.splice(oldIndex, 1);
      tierItems.splice(newIndex, 0, removed);
      updatedTierList = tierItems.map((item, idx) => ({ ...item, rank: idx }));
      return [...otherItems, ...updatedTierList];
    });
    if (updatedTierList.length > 0) await persistBookRankings(updatedTierList);
  };

  const handleAddBookItem = async (newItem: RankedItem) => {
    await addBookItem(newItem);
    setToastMessage(t('toast.ranked').replace('{tier}', newItem.tier));
    if (bookItemToRank) {
      await removeBookFromWatchlist(bookItemToRank.id);
      setBookItemToRank(null);
    }
  };

  const handleAddTVItem = async (newItem: RankedItem) => {
    await addTVItem(newItem);
    if (preselectedTVItem) {
      await removeTVFromWatchlist(preselectedTVItem.id);
      setPreselectedTVItem(null);
    }
    setToastMessage(t('toast.ranked').replace('{tier}', newItem.tier));
  };

  const handleAddItem = async (newItem: RankedItem) => {
    const wasMigration = !!migrationState;
    await addItem(newItem);
    if (preselectedForRank) {
      await removeFromWatchlist(preselectedForRank.id);
      setPreselectedForRank(null);
    }
    if (migrationState) {
      setMigrationState(null);
    }
    setToastMessage(
      wasMigration
        ? t('toast.moved').replace('{tier}', newItem.tier)
        : t('toast.ranked').replace('{tier}', newItem.tier)
    );
    setJournalSheetItem(newItem);
  };

  const handleCompareLog = async (log: ComparisonLogEntry) => {
    if (!user) return;
    try {
      await supabase.from('comparison_logs').insert({
        user_id: user.id,
        session_id: log.sessionId,
        movie_a_tmdb_id: log.movieAId,
        movie_b_tmdb_id: log.movieBId,
        winner: log.winner,
        round: log.round,
        phase: log.phase,
        question_text: log.questionText,
      });
    } catch (err) {
      console.error('Failed to log comparison:', err);
    }
  };

  const watchlistIds = useMemo(() => new Set(watchlist.map((w) => w.id)), [watchlist]);
  const tvWatchlistIds = useMemo(() => new Set(tvWatchlist.map((w) => w.id)), [tvWatchlist]);
  const bookWatchlistIds = useMemo(() => new Set(bookWatchlist.map((w) => w.id)), [bookWatchlist]);
  const allRankedIds = useMemo(() => new Set([...items.map(i => i.id), ...tvItems.map(i => i.id), ...bookItems.map(i => i.id)]), [items, tvItems, bookItems]);
  const allWatchlistIds = useMemo(() => new Set([...watchlistIds, ...tvWatchlistIds, ...bookWatchlistIds]), [watchlistIds, tvWatchlistIds, bookWatchlistIds]);

  // Active items based on media mode
  const activeItems = mediaMode === 'movies' ? items : mediaMode === 'tv' ? tvItems : bookItems;
  const activeWatchlist = mediaMode === 'movies' ? watchlist : mediaMode === 'tv' ? tvWatchlist : bookWatchlist;

  const bracketCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    activeItems.forEach(i => {
      const b = i.bracket ?? 'Commercial';
      counts[b] = (counts[b] ?? 0) + 1;
    });
    return counts;
  }, [activeItems]);

  const availableGenres = useMemo(() => {
    const genres = new Set<string>();
    activeItems.forEach(i => {
      if (activeBracket === 'all' || i.bracket === activeBracket) {
        i.genres.forEach(g => genres.add(g));
      }
    });
    return Array.from(genres).sort();
  }, [activeItems, activeBracket]);

  const filteredItems = useMemo(() => {
    let filtered = mediaMode === 'movies'
      ? (filterType === 'all' ? items : items.filter((i) => i.type === filterType))
      : mediaMode === 'tv' ? tvItems : bookItems;
    if (activeBracket !== 'all') {
      filtered = filtered.filter(i => i.bracket === activeBracket);
    }
    if (activeGenre) {
      filtered = filtered.filter(i => i.genres.includes(activeGenre));
    }
    return filtered;
  }, [items, tvItems, bookItems, mediaMode, filterType, activeBracket, activeGenre]);

  const localizedItems = useLocalizedItems(filteredItems);
  const localizedWatchlist = useLocalizedWatchlist(activeWatchlist);

  const scoreMap = useMemo(() => computeScores(localizedItems), [localizedItems]);
  const showScores = localizedItems.length >= MIN_MOVIES_FOR_SCORES;

  if (loading) {
    return (
      <div className="min-h-screen bg-background flex items-center justify-center">
        <div className="w-8 h-8 border-2 border-gold border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  const handleViewChange = (view: string) => {
    if (view === 'profile' && user) {
      navigate(`/profile/${user.id}`);
      return;
    }
    setActiveTab(view as typeof activeTab);
  };

  // Universal search handlers
  const handleSearchRankMovie = (movie: TMDBMovie) => {
    setPreselectedForRank(movie);
    setIsModalOpen(true);
  };
  const handleSearchRankTV = (show: TMDBTVShow) => {
    setPreselectedTVItem({
      id: show.id,
      title: show.name,
      year: show.year,
      posterUrl: show.posterUrl ?? '',
      type: 'tv_season',
      genres: show.genres ?? [],
      tier: Tier.B,
      rank: 0,
    } as RankedItem);
    setIsTVModalOpen(true);
  };
  const handleSearchRankBook = (book: OpenLibraryBook) => {
    const asRankedItem: RankedItem = {
      id: book.id,
      title: book.title,
      year: book.year,
      posterUrl: book.posterUrl,
      type: 'book',
      genres: book.genres,
      author: book.author,
      pageCount: book.pageCount,
      isbn: book.isbn,
      olWorkKey: book.olWorkKey,
      olRatingsAverage: book.olRatingsAverage,
      globalScore: book.globalScore,
      bracket: classifyBracket(book.genres),
      tier: Tier.B,
      rank: 0,
    };
    setBookItemToRank(asRankedItem);
    setIsBookModalOpen(true);
  };
  const handleSearchSaveMovie = (movie: TMDBMovie) => { addToWatchlist(movie); };
  const handleSearchSaveTV = (show: TMDBTVShow) => {
    const item: WatchlistItem = {
      id: show.id,
      title: show.name,
      year: show.year,
      posterUrl: show.posterUrl ?? '',
      type: 'tv_season',
      genres: show.genres ?? [],
      addedAt: new Date().toISOString(),
    };
    addToTVWatchlist(item);
  };
  const handleSearchSaveBook = (book: OpenLibraryBook) => {
    const item: WatchlistItem = {
      id: book.id,
      title: book.title,
      year: book.year,
      posterUrl: book.posterUrl,
      type: 'book',
      genres: book.genres,
      author: book.author,
      pageCount: book.pageCount,
      isbn: book.isbn,
      olWorkKey: book.olWorkKey,
      olRatingsAverage: book.olRatingsAverage,
      addedAt: new Date().toISOString(),
    };
    addToBookWatchlist(item);
  };

  const headerActions = (
    <>
      {user && <NotificationBell userId={user.id} onUnreadCountChange={setUnreadNotifCount} />}
      <LanguageToggle />
      <button
        onClick={signOut}
        title="Sign out"
        className="text-muted-foreground hover:text-foreground text-xs font-medium transition-colors px-2 py-1"
      >
        {t('nav.logOut')}
      </button>
    </>
  );

  return (
    <AppLayout activeView={activeTab} onViewChange={handleViewChange} headerActions={headerActions} unreadNotificationCount={unreadNotifCount}>
      <div className="max-w-5xl mx-auto px-4 py-6 space-y-6">

        {/* Page header — inside content area, not the global nav */}
        <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
          <div>
            <h1 className="font-serif text-2xl text-foreground tracking-tight">{t('ranking.myCanon')}</h1>
            <p className="text-xs text-muted-foreground/60 hidden sm:block">{t('ranking.subtitle')}</p>
          </div>
          <div className="flex items-center gap-3">
            <div className="flex bg-card/50 rounded-lg p-1 border border-border/30">
              <button
                onClick={() => setMediaMode('movies')}
                className={`px-3 py-1.5 rounded-md text-xs font-semibold transition-all flex items-center gap-1.5 ${mediaMode === 'movies' ? 'bg-secondary text-foreground shadow' : 'text-muted-foreground hover:text-foreground'}`}
              >
                <Film size={13} />
                {t('nav.movies')}
              </button>
              <button
                onClick={() => setMediaMode('tv')}
                className={`px-3 py-1.5 rounded-md text-xs font-semibold transition-all flex items-center gap-1.5 ${mediaMode === 'tv' ? 'bg-secondary text-foreground shadow' : 'text-muted-foreground hover:text-foreground'}`}
              >
                <Tv size={13} />
                {t('nav.tv')}
              </button>
              <button
                onClick={() => { setMediaMode('books'); setActiveBracket('all'); setActiveGenre(null); }}
                className={`px-3 py-1.5 rounded-md text-xs font-semibold transition-all flex items-center gap-1.5 ${mediaMode === 'books' ? 'bg-secondary text-foreground shadow' : 'text-muted-foreground hover:text-foreground'}`}
              >
                <BookOpen size={13} />
                {t('nav.books')}
              </button>
            </div>
            <button
              onClick={handleReset}
              title={t('tab.resetRankings')}
              className="p-2 rounded-lg text-muted-foreground hover:text-foreground hover:bg-secondary/30 transition-colors"
            >
              <RotateCcw size={16} />
            </button>
          </div>
        </div>

        {activeTab === 'ranking' && (
          <div className="space-y-3">
            <UniversalSearch
              rankedIds={allRankedIds}
              watchlistIds={allWatchlistIds}
              onRankMovie={handleSearchRankMovie}
              onRankTV={handleSearchRankTV}
              onRankBook={handleSearchRankBook}
              onSaveMovie={handleSearchSaveMovie}
              onSaveTV={handleSearchSaveTV}
              onSaveBook={handleSearchSaveBook}
            />

            {/* Filters: bracket tabs + genre pills on one line */}
            {mediaMode !== 'books' && (
            <div className="flex items-center gap-3 overflow-x-auto pb-1 scrollbar-hide">
              {/* Bracket tabs */}
              <div className="flex items-center gap-0.5 flex-shrink-0">
                <button
                  onClick={() => { setActiveBracket('all'); setActiveGenre(null); }}
                  className={`px-2.5 py-1 rounded-md text-xs font-semibold transition-all ${activeBracket === 'all' ? 'text-foreground bg-secondary/60' : 'text-muted-foreground hover:text-foreground'}`}
                >
                  All <span className="opacity-40">{activeItems.length}</span>
                </button>
                {BRACKETS.map(bracket => {
                  const count = bracketCounts[bracket] ?? 0;
                  return (
                    <button
                      key={bracket}
                      onClick={() => { setActiveBracket(bracket); setActiveGenre(null); }}
                      className={`px-2.5 py-1 rounded-md text-xs font-semibold transition-all ${activeBracket === bracket ? 'text-foreground bg-secondary/60' : 'text-muted-foreground hover:text-foreground'} ${count === 0 ? 'opacity-30' : ''}`}
                    >
                      {BRACKET_LABELS[bracket]} <span className="opacity-40">{count}</span>
                    </button>
                  );
                })}
              </div>

              {/* Genre pills — shown when filtering by bracket or when a genre is active */}
              {(activeBracket !== 'all' || activeGenre) && availableGenres.length > 0 && (
                <>
                  <div className="w-px h-4 bg-border/40 flex-shrink-0" />
                  <div className="flex items-center gap-1.5 flex-shrink-0">
                    {activeGenre && (
                      <button
                        onClick={() => setActiveGenre(null)}
                        className="px-2 py-0.5 rounded-full text-[11px] font-medium text-accent bg-accent/15 border border-accent/20 transition-all"
                      >
                        {activeGenre} ×
                      </button>
                    )}
                    {availableGenres.filter(g => g !== activeGenre).map(genre => (
                      <button
                        key={genre}
                        onClick={() => setActiveGenre(genre)}
                        className="px-2 py-0.5 rounded-full text-[11px] font-medium text-muted-foreground/70 hover:text-muted-foreground transition-all"
                      >
                        {genre}
                      </button>
                    ))}
                  </div>
                </>
              )}
            </div>
            )}
          </div>
        )}

        {/* --- Tab Content --- */}
        {activeTab === 'ranking' && localizedItems.length === 0 && (
          <FirstRunGuide onStartSearch={() => {
            const searchInput = document.querySelector<HTMLInputElement>('[data-universal-search] input');
            searchInput?.focus();
          }} />
        )}
        {activeTab === 'ranking' && localizedItems.length > 0 && (
          <ErrorBoundary>
          <div className="space-y-4">
            {TIERS.map((tier, tierIndex) => (
              <TierRow
                key={tier}
                tier={tier}
                index={tierIndex}
                items={localizedItems.filter((i) => i.tier === tier).sort((a, b) => a.rank - b.rank)}
                scoreMap={scoreMap}
                showScores={showScores}
                onDrop={mediaMode === 'books' ? (e, tier) => handleBookDrop(e, tier) : mediaMode === 'tv' ? (e, tier) => handleTVDrop(e, tier) : (e, tier) => handleDrop(e, tier)}
                onDropOnItem={mediaMode === 'books' ? handleBookDropOnItem : mediaMode === 'tv' ? handleTVDropOnItem : handleDropOnItem}
                onDragStart={handleDragStart}
                onDelete={mediaMode === 'books' ? removeBookItem : mediaMode === 'tv' ? removeTVItem : removeItem}
                onOpenJournal={(movieId) => {
                  const ranked = items.find(i => i.id === movieId) ?? tvItems.find(i => i.id === movieId) ?? bookItems.find(i => i.id === movieId);
                  if (ranked) setJournalSheetItem(ranked);
                }}
                onRerank={(item) => {
                  if (mediaMode === 'books') {
                    removeBookItem(item.id);
                    setBookItemToRank(item);
                    setIsBookModalOpen(true);
                  } else if (mediaMode === 'tv') {
                    removeTVItem(item.id);
                    setPreselectedTVItem(item);
                    setIsTVModalOpen(true);
                  } else {
                    removeItem(item.id);
                    setPreselectedForRank(item);
                    setIsModalOpen(true);
                  }
                }}
              />
            ))}
          </div>
          </ErrorBoundary>
        )}

        {activeTab === 'watchlist' && (
          <Watchlist
            items={localizedWatchlist}
            onRemove={mediaMode === 'books' ? removeBookFromWatchlist : mediaMode === 'tv' ? removeTVFromWatchlist : removeFromWatchlist}
            onRank={rankFromWatchlist}
          />
        )}

        {activeTab === 'feed' && user && (
          <SocialFeedView
            userId={user.id}
            onMovieClick={(tmdbId) => {
              const newParams = new URLSearchParams(searchParams);
              newParams.set('movieId', tmdbId);
              setSearchParams(newParams);
            }}
          />
        )}

        {activeTab === 'discover' && user && (
          <DiscoverView
            userId={user.id}
            onMovieClick={(id) => setSearchParams({ movieId: id })}
            onSaveForLater={(movie) => {
              void addToWatchlist(movie);
            }}
          />
        )}

      </div>

      <ErrorBoundary>
      <AddMediaModal
        isOpen={isModalOpen}
        onClose={() => {
          setIsModalOpen(false);
          setPreselectedForRank(null);
          setMigrationState(null);
        }}
        onAdd={handleAddItem}
        onSaveForLater={addToWatchlist}
        currentItems={items}
        watchlistIds={watchlistIds}
        preselectedItem={migrationState ? migrationState.item : preselectedForRank}
        preselectedTier={migrationState ? migrationState.targetTier : undefined}
        onCompare={handleCompareLog}
        onMovieInfoClick={(id) => setSearchParams({ movieId: id })}
      />
      </ErrorBoundary>

      <ErrorBoundary>
      <AddTVSeasonModal
        isOpen={isTVModalOpen}
        onClose={() => { setIsTVModalOpen(false); setPreselectedTVItem(null); }}
        onAdd={handleAddTVItem}
        onSaveForLater={addToTVWatchlist}
        currentItems={tvItems}
        watchlistIds={tvWatchlistIds}
        onCompare={handleCompareLog}
        preselectedItem={preselectedTVItem}
      />
      </ErrorBoundary>

      {/* Book Ranking Flow Modal */}
      {bookItemToRank && (
        <ErrorBoundary>
        <RankingFlowModal
          isOpen={isBookModalOpen}
          onClose={() => { setIsBookModalOpen(false); setBookItemToRank(null); }}
          onAdd={handleAddBookItem}
          selectedItem={bookItemToRank}
          currentItems={bookItems}
          onCompare={handleCompareLog}
        />
        </ErrorBoundary>
      )}

      {/* Deep linked Movie Modal */}
      {linkedMovieId && (() => {
        const foundItem = items.find(i => i.id === linkedMovieId) ?? tvItems.find(i => i.id === linkedMovieId) ?? bookItems.find(i => i.id === linkedMovieId);
        // Compute score from the correct collection since scoreMap only covers current mediaMode
        const linkedScoreMap = foundItem
          ? computeScores(items.includes(foundItem) ? items : tvItems.includes(foundItem) ? tvItems : bookItems)
          : undefined;
        const linkedScore = foundItem && linkedScoreMap ? linkedScoreMap.get(foundItem.id) : undefined;
        return (
          <MediaDetailModal
            tmdbId={linkedMovieId}
            initialItem={foundItem ?? undefined}
            userScore={linkedScore}
            onClose={() => {
              const newParams = new URLSearchParams(searchParams);
              newParams.delete('movieId');
              setSearchParams(newParams);
            }}
            onSaveForLater={(movie) => {
              addToWatchlist(movie);
              // Close the modal
              const newParams = new URLSearchParams(searchParams);
              newParams.delete('movieId');
              setSearchParams(newParams);
            }}
            onStartRanking={(movie) => {
              const newParams = new URLSearchParams(searchParams);
              newParams.delete('movieId');
              setSearchParams(newParams);
              setPreselectedForRank(movie);
              setIsModalOpen(true);
            }}
            onOpenJournal={(movieId) => {
              // Find or create a RankedItem to open journal
              const ranked = items.find(i => i.id === movieId);
              if (ranked) {
                const newParams = new URLSearchParams(searchParams);
                newParams.delete('movieId');
                setSearchParams(newParams);
                setJournalSheetItem(ranked);
              }
            }}
            onRerank={(item) => {
              const newParams = new URLSearchParams(searchParams);
              newParams.delete('movieId');
              setSearchParams(newParams);
              removeItem(item.id);
              setPreselectedForRank(item);
              setIsModalOpen(true);
            }}
          />
        );
      })()}

      {/* Journal Entry Sheet (after ranking) */}
      {journalSheetItem && user && (
        <ErrorBoundary>
        <JournalConversation
          isOpen={!!journalSheetItem}
          item={journalSheetItem}
          userId={user.id}
          onDismiss={() => setJournalSheetItem(null)}
          onSaved={() => { setJournalSheetItem(null); setToastMessage(t('journal.saved')); }}
        />
        </ErrorBoundary>
      )}

      {toastMessage && (
        <Toast message={toastMessage} onDone={() => setToastMessage(null)} />
      )}
    </AppLayout>
  );
};

export default RankingAppPage;
